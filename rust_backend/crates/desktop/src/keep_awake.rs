//! Keeps the computer from idle sleeping while the download queue runs
//! (DESIGN 6.1), the desktop counterpart of the Android foreground service
//! and the iOS background task:
//! - macOS: an IOKit `PreventUserIdleSystemSleep` assertion, the assertion
//!   `NSProcessInfo.beginActivity(.idleSystemSleepDisabled)` takes;
//! - Windows: `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`
//!   held by a dedicated thread, because the state belongs to the thread;
//! - Linux: a `systemd-inhibit` child holding a logind `idle:sleep` lock
//!   (`org.freedesktop.login1.Manager.Inhibit`). It runs `cat` on a pipe
//!   from this process, so the lock also ends if the app dies.
//!
//! The OS releases the macOS assertion and the Windows state when the process
//! exits.

use std::sync::Mutex;

/// One active hold; dropping it releases the OS state.
pub(crate) trait Hold: Send {}

type Factory = fn(&str) -> Result<Box<dyn Hold>, String>;

pub(crate) struct KeepAwake {
    acquire: Factory,
    held: Mutex<Option<Box<dyn Hold>>>,
}

impl Default for KeepAwake {
    fn default() -> Self {
        Self::with_factory(platform::acquire)
    }
}

impl KeepAwake {
    pub(crate) fn with_factory(acquire: Factory) -> Self {
        Self {
            acquire,
            held: Mutex::new(None),
        }
    }

    /// Idempotent: a second begin keeps the existing hold.
    pub(crate) fn begin(&self, reason: &str) -> Result<(), String> {
        let mut held = self.held.lock().expect("keep awake lock");
        if held.is_none() {
            *held = Some((self.acquire)(reason)?);
        }
        Ok(())
    }

    /// Returns whether a hold was released. Ending without a hold is fine.
    pub(crate) fn end(&self) -> bool {
        let hold = self.held.lock().expect("keep awake lock").take();
        hold.is_some()
    }

    #[cfg(test)]
    fn is_active(&self) -> bool {
        self.held.lock().expect("keep awake lock").is_some()
    }
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod platform {
    use super::Hold;
    use std::ffi::c_void;

    type CFStringRef = *const c_void;
    const UTF8: u32 = 0x0800_0100;
    const ASSERTION_LEVEL_ON: u32 = 255;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: *const c_void,
            bytes: *const u8,
            len: isize,
            encoding: u32,
            external: u8,
        ) -> CFStringRef;
        fn CFRelease(value: *const c_void);
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPMAssertionCreateWithName(
            kind: CFStringRef,
            level: u32,
            name: CFStringRef,
            id: *mut u32,
        ) -> i32;
        fn IOPMAssertionRelease(id: u32) -> i32;
    }

    struct CfString(CFStringRef);

    impl CfString {
        fn new(text: &str) -> Option<Self> {
            // SAFETY: the bytes are valid UTF-8 for `len` bytes and are copied
            // by CoreFoundation; a NULL allocator selects the default one.
            let value = unsafe {
                CFStringCreateWithBytes(
                    std::ptr::null(),
                    text.as_ptr(),
                    text.len() as isize,
                    UTF8,
                    0,
                )
            };
            (!value.is_null()).then_some(Self(value))
        }
    }

    impl Drop for CfString {
        fn drop(&mut self) {
            // SAFETY: `self.0` is a CFString this wrapper created and owns.
            unsafe { CFRelease(self.0) }
        }
    }

    struct Assertion(u32);

    impl Hold for Assertion {}

    impl Drop for Assertion {
        fn drop(&mut self) {
            // SAFETY: the ID came from a successful IOPMAssertionCreateWithName
            // and is released once.
            unsafe { IOPMAssertionRelease(self.0) };
        }
    }

    pub(super) fn acquire(reason: &str) -> Result<Box<dyn Hold>, String> {
        let kind = CfString::new("PreventUserIdleSystemSleep").ok_or("CFString failed")?;
        let name = CfString::new(reason).ok_or("CFString failed")?;
        let mut id = 0u32;
        // SAFETY: both strings stay alive for the call and `id` is a valid
        // out pointer.
        let status =
            unsafe { IOPMAssertionCreateWithName(kind.0, ASSERTION_LEVEL_ON, name.0, &mut id) };
        if status != 0 {
            return Err(format!("IOPMAssertionCreateWithName failed: {status:#x}"));
        }
        Ok(Box::new(Assertion(id)))
    }
}

#[cfg(windows)]
#[allow(unsafe_code)]
mod platform {
    use super::Hold;
    use std::sync::mpsc;
    use std::thread::JoinHandle;
    use windows_sys::Win32::System::Power::{
        ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState,
    };

    struct Thread {
        stop: Option<mpsc::Sender<()>>,
        handle: Option<JoinHandle<()>>,
    }

    impl Hold for Thread {}

    impl Drop for Thread {
        fn drop(&mut self) {
            drop(self.stop.take());
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    pub(super) fn acquire(_reason: &str) -> Result<Box<dyn Hold>, String> {
        let (stop, stopped) = mpsc::channel::<()>();
        let (started, result) = mpsc::channel::<bool>();
        let handle = std::thread::Builder::new()
            .name("mornye-keep-awake".into())
            .spawn(move || {
                // SAFETY: plain Win32 call without pointers.
                let previous =
                    unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
                let _ = started.send(previous != 0);
                if previous == 0 {
                    return;
                }
                // Blocks until the hold is dropped (the sender closes).
                let _ = stopped.recv();
                // SAFETY: plain Win32 call without pointers.
                unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
            })
            .map_err(|error| error.to_string())?;
        if result.recv() != Ok(true) {
            let _ = handle.join();
            return Err("SetThreadExecutionState failed".into());
        }
        Ok(Box::new(Thread {
            stop: Some(stop),
            handle: Some(handle),
        }))
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod platform {
    use super::Hold;
    use std::process::{Child, Command, Stdio};
    use std::time::Duration;

    struct Inhibitor(Child);

    impl Hold for Inhibitor {}

    impl Drop for Inhibitor {
        fn drop(&mut self) {
            // Closing stdin ends `cat`, which ends the inhibitor lock.
            drop(self.0.stdin.take());
            for _ in 0..20 {
                if matches!(self.0.try_wait(), Ok(Some(_))) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    pub(super) fn acquire(reason: &str) -> Result<Box<dyn Hold>, String> {
        let why = format!("--why={reason}");
        let mut child = Command::new("systemd-inhibit")
            .args([
                "--what=idle:sleep",
                "--who=Mosix",
                why.as_str(),
                "--mode=block",
                "cat",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("systemd-inhibit is unavailable: {error}"))?;
        // A missing logind makes systemd-inhibit exit at once.
        std::thread::sleep(Duration::from_millis(150));
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!("systemd-inhibit exited: {status}"));
        }
        Ok(Box::new(Inhibitor(child)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static ACQUIRED: AtomicUsize = AtomicUsize::new(0);
    static RELEASED: AtomicUsize = AtomicUsize::new(0);

    struct Fake;

    impl Hold for Fake {}

    impl Drop for Fake {
        fn drop(&mut self) {
            RELEASED.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn begin_and_end_are_idempotent() {
        let keep = KeepAwake::with_factory(|_| {
            ACQUIRED.fetch_add(1, Ordering::SeqCst);
            Ok(Box::new(Fake))
        });
        assert!(!keep.end());
        keep.begin("a").unwrap();
        keep.begin("b").unwrap();
        assert!(keep.is_active());
        assert_eq!(ACQUIRED.load(Ordering::SeqCst), 1);
        assert!(keep.end());
        assert!(!keep.end());
        assert_eq!(RELEASED.load(Ordering::SeqCst), 1);
        assert!(!keep.is_active());
    }

    #[test]
    fn a_failed_begin_holds_nothing() {
        let keep = KeepAwake::with_factory(|_| Err("no power management".into()));
        assert!(keep.begin("x").is_err());
        assert!(!keep.is_active());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_assertion_round_trip() {
        let keep = KeepAwake::default();
        keep.begin("Mosix test assertion").unwrap();
        assert!(keep.end());
    }
}
