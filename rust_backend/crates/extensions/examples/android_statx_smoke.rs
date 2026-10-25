//! Run on Android with `-C link-arg=-Wl,--wrap=dlsym`.
//! `--legacy` hides Bionic's statx symbol and kills raw statx syscalls, modeling
//! the older app sandbox. `--probe-blocked-syscall` must exit with SIGSYS.

#[cfg(target_os = "android")]
#[allow(unsafe_code, reason = "isolated native sandbox regression test")]
mod android {
    use std::ffi::{CStr, c_char, c_void};
    use std::sync::atomic::{AtomicBool, Ordering};

    static HIDE_STATX: AtomicBool = AtomicBool::new(false);

    unsafe extern "C" {
        fn __real_dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    }

    // This symbol only exists in the smoke-test executable, never in the app.
    #[unsafe(no_mangle)]
    unsafe extern "C" fn __wrap_dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void {
        // SAFETY: dlsym receives a valid NUL-terminated symbol name.
        if HIDE_STATX.load(Ordering::Relaxed) && unsafe { CStr::from_ptr(name) } == c"statx" {
            return std::ptr::null_mut();
        }
        // SAFETY: forward the original dlsym arguments without modification.
        unsafe { __real_dlsym(handle, name) }
    }

    fn forbid_raw_statx() {
        // Load seccomp_data.nr; terminate only statx, allow other syscalls.
        let filter = [
            libc::sock_filter {
                code: 0x20,
                jt: 0,
                jf: 0,
                k: 0,
            },
            libc::sock_filter {
                code: 0x15,
                jt: 0,
                jf: 1,
                k: libc::SYS_statx as u32,
            },
            libc::sock_filter {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: 0x8000_0000,
            },
            libc::sock_filter {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: 0x7fff_0000,
            },
        ];
        let program = libc::sock_fprog {
            len: filter.len() as u16,
            filter: filter.as_ptr().cast_mut(),
        };
        // SAFETY: the kernel copies this initialized filter synchronously.
        unsafe {
            assert_eq!(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), 0);
            assert_eq!(libc::prctl(libc::PR_SET_SECCOMP, 2, &program, 0, 0), 0);
        }
    }

    pub fn run() {
        let legacy = std::env::args().any(|arg| arg == "--legacy");
        let probe = std::env::args().any(|arg| arg == "--probe-blocked-syscall");
        if legacy || probe {
            HIDE_STATX.store(true, Ordering::Relaxed);
            forbid_raw_statx();
        }
        if probe {
            // SAFETY: the sandbox must terminate this process before executing
            // statx. Null output would otherwise fail with EFAULT, not write.
            unsafe {
                libc::syscall(
                    libc::SYS_statx,
                    -100,
                    c".".as_ptr(),
                    0,
                    0,
                    std::ptr::null_mut::<c_void>(),
                );
            }
            panic!("raw statx was not blocked");
        }

        let temp = tempfile::tempdir_in("/data/local/tmp").unwrap();
        std::fs::write(temp.path().join("track.flac"), b"audio payload").unwrap();
        let dir =
            cap_std::fs::Dir::open_ambient_dir(temp.path(), cap_std::ambient_authority()).unwrap();
        let file = dir.open("track.flac").unwrap();
        assert_eq!(file.metadata().unwrap().len(), 13);
        assert_eq!(dir.metadata("track.flac").unwrap().len(), 13);
        assert_eq!(dir.symlink_metadata("track.flac").unwrap().len(), 13);
        assert_eq!(rustix::fs::fstat(&file).unwrap().st_size, 13);
        assert_eq!(
            rustix::fs::statat(&dir, "track.flac", rustix::fs::AtFlags::empty())
                .unwrap()
                .st_size,
            13
        );
        let extended = rustix::fs::statx(
            &dir,
            "track.flac",
            rustix::fs::AtFlags::empty(),
            rustix::fs::StatxFlags::BASIC_STATS,
        );
        if legacy {
            assert_eq!(extended.unwrap_err(), rustix::io::Errno::NOSYS);
        } else if let Ok(stat) = extended {
            assert_eq!(stat.stx_size, 13);
        }
        dir.rename("track.flac", &dir, "renamed.flac").unwrap();
        assert_eq!(dir.read("renamed.flac").unwrap(), b"audio payload");
        println!("metadata, capability paths, and statx fallback passed (legacy={legacy})");
    }
}

fn main() {
    #[cfg(target_os = "android")]
    android::run();
    #[cfg(not(target_os = "android"))]
    eprintln!("This smoke test runs on Android.");
}
