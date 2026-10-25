//! Request cancellation with Go-compatible sentinels and reference counting.
//!
//! Each registry owns one domain. Leases release their reference on drop; an
//! explicit release also wakes a pending wait. Shutdown closes the instance and
//! wakes all leases, including untracked requests with an empty ID.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::task::Waker;
use std::thread::Thread;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancellationDomain {
    Download,
    ExtensionRequest,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancellationError {
    DownloadCancelled,
    ExtensionRequestCancelled,
    RegistryClosed,
    LeaseReleased,
}

impl fmt::Display for CancellationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::DownloadCancelled => "download cancelled",
            Self::ExtensionRequestCancelled => "extension request cancelled",
            Self::RegistryClosed => "cancellation registry closed",
            Self::LeaseReleased => "request lease released",
        })
    }
}

impl std::error::Error for CancellationError {}

#[derive(Default)]
struct Entry {
    cancelled: Arc<AtomicBool>,
    references: usize,
}

#[derive(Default)]
struct State {
    closed: bool,
    entries: BTreeMap<String, Entry>,
}

impl State {
    fn check_open(&self) -> Result<(), CancellationError> {
        if self.closed {
            Err(CancellationError::RegistryClosed)
        } else {
            Ok(())
        }
    }
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    waker: Option<Waker>,
    threads: Mutex<Vec<Weak<Thread>>>,
}

impl Shared {
    fn notify(&self) {
        self.changed.notify_all();
        self.threads
            .lock()
            .expect("cancellation thread lock")
            .retain(|thread| {
                if let Some(thread) = thread.upgrade() {
                    thread.unpark();
                    true
                } else {
                    false
                }
            });
        if let Some(waker) = &self.waker {
            waker.wake_by_ref();
        }
    }
}

pub struct CancellationRegistry {
    shared: Arc<Shared>,
    domain: CancellationDomain,
}

impl CancellationRegistry {
    pub fn new(domain: CancellationDomain) -> Self {
        Self {
            shared: Arc::new(Shared::default()),
            domain,
        }
    }

    /// Wake an external executor after cancellation, release or shutdown.
    /// The executor must recheck its own request; other IDs may still be active.
    pub fn with_waker(domain: CancellationDomain, waker: Waker) -> Self {
        Self {
            shared: Arc::new(Shared {
                waker: Some(waker),
                ..Shared::default()
            }),
            domain,
        }
    }

    pub fn acquire(&self, id: &str) -> Result<RequestLease, CancellationError> {
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        state.check_open()?;
        let cancelled = if id.is_empty() {
            Arc::new(AtomicBool::new(false))
        } else {
            let entry = state.entries.entry(id.to_owned()).or_default();
            entry.references += 1;
            Arc::clone(&entry.cancelled)
        };
        Ok(RequestLease {
            shared: Arc::clone(&self.shared),
            id: id.to_owned(),
            domain: self.domain,
            cancelled,
            released: AtomicBool::new(false),
        })
    }

    pub fn cancel(&self, id: &str) -> Result<(), CancellationError> {
        self.cancel_many(std::iter::once(id))
    }

    pub fn cancel_many<'a>(
        &self,
        ids: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), CancellationError> {
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        state.check_open()?;
        let mut changed = false;
        for id in ids.into_iter().filter(|id| !id.is_empty()) {
            state
                .entries
                .entry(id.to_owned())
                .or_default()
                .cancelled
                .store(true, Ordering::Release);
            changed = true;
        }
        drop(state);
        if changed {
            self.shared.notify();
        }
        Ok(())
    }

    /// Cancel active work only. Idle sentinels remain available to reset/retry.
    /// IDs are sorted for deterministic native results; Go's ordering is unspecified.
    pub fn cancel_active(&self) -> Result<Vec<String>, CancellationError> {
        let state = self.shared.state.lock().expect("cancellation state lock");
        state.check_open()?;
        let mut ids = Vec::new();
        for (id, entry) in &state.entries {
            if entry.references > 0 {
                entry.cancelled.store(true, Ordering::Release);
                ids.push(id.clone());
            }
        }
        drop(state);
        self.shared.notify();
        Ok(ids)
    }

    pub fn is_cancelled(&self, id: &str) -> Result<bool, CancellationError> {
        let state = self.shared.state.lock().expect("cancellation state lock");
        state.check_open()?;
        Ok(state
            .entries
            .get(id)
            .is_some_and(|entry| entry.cancelled.load(Ordering::Acquire)))
    }

    pub fn reset_if_idle(&self, id: &str) -> Result<(), CancellationError> {
        self.reset_many_if_idle(std::iter::once(id))
    }

    /// Clear only the selected idle sentinels under one registry lock. Leases
    /// from a still-unwinding attempt keep their cancellation state intact.
    pub fn reset_many_if_idle<'a>(
        &self,
        ids: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), CancellationError> {
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        state.check_open()?;
        for id in ids {
            if state
                .entries
                .get(id)
                .is_some_and(|entry| entry.references == 0)
            {
                state.entries.remove(id);
            }
        }
        Ok(())
    }

    /// Terminal and idempotent. A new registry is required for subsequent work.
    pub fn shutdown(&self) {
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        state.closed = true;
        state.entries.clear();
        drop(state);
        self.shared.notify();
    }
}

impl Drop for CancellationRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub struct RequestLease {
    shared: Arc<Shared>,
    id: String,
    domain: CancellationDomain,
    cancelled: Arc<AtomicBool>,
    released: AtomicBool,
}

impl RequestLease {
    /// Notify a parked native worker on cancellation/release/shutdown. The
    /// caller retains the thread while waiting and rechecks after subscribing.
    pub fn observe_thread(&self, thread: &Arc<Thread>) {
        let mut threads = self
            .shared
            .threads
            .lock()
            .expect("cancellation thread lock");
        threads.retain(|thread| thread.strong_count() > 0);
        threads.push(Arc::downgrade(thread));
    }

    pub fn domain(&self) -> CancellationDomain {
        self.domain
    }

    /// Query the active request identity with Go's whitespace normalization.
    /// The lease itself still retains its original, exact cancellation ID.
    pub fn active_request_cancelled(&self) -> bool {
        if self.domain != CancellationDomain::ExtensionRequest || self.id.trim().is_empty() {
            return false;
        }
        let state = self.shared.state.lock().expect("cancellation state lock");
        state
            .entries
            .get(self.id.trim())
            .is_some_and(|entry| entry.cancelled.load(Ordering::Acquire))
    }

    fn check_live(&self, state: &State) -> Result<(), CancellationError> {
        state.check_open()?;
        if self.released.load(Ordering::Acquire) {
            return Err(CancellationError::LeaseReleased);
        }
        Ok(())
    }

    pub fn is_cancelled(&self) -> Result<bool, CancellationError> {
        let state = self.shared.state.lock().expect("cancellation state lock");
        self.check_live(&state)?;
        Ok(self.cancelled.load(Ordering::Acquire))
    }

    /// Preserve the exact existing download/extension cancellation messages.
    pub fn check_active(&self) -> Result<(), CancellationError> {
        if self.is_cancelled()? {
            return Err(match self.domain {
                CancellationDomain::Download => CancellationError::DownloadCancelled,
                CancellationDomain::ExtensionRequest => {
                    CancellationError::ExtensionRequestCancelled
                }
            });
        }
        Ok(())
    }

    /// Block without polling. True means cancelled, false means heartbeat expiry.
    /// Bounds match the existing progress waiter: default 15 s, maximum 60 s.
    /// Call from a worker thread; cancellation/release/shutdown may run elsewhere.
    pub fn wait_cancelled(&self, timeout_ms: i64) -> Result<bool, CancellationError> {
        let timeout = wait_timeout(timeout_ms);
        let started = Instant::now();
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        loop {
            self.check_live(&state)?;
            if self.cancelled.load(Ordering::Acquire) {
                return Ok(true);
            }
            let remaining = timeout.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Ok(false);
            }
            // Every predicate change takes this same lock, avoiding lost wakeups
            // between checking the predicate and entering Condvar::wait_timeout.
            (state, _) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .expect("cancellation wait lock");
        }
    }

    /// Release this acquisition once; other acquisitions for the same ID remain.
    /// Holding or dropping this old lease cannot remove a later retry's entry.
    pub fn release(&self) {
        let mut state = self.shared.state.lock().expect("cancellation state lock");
        if self.released.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Some(entry) = state.entries.get_mut(&self.id) {
            entry.references -= 1;
            if entry.references == 0 {
                state.entries.remove(&self.id);
            }
        }
        drop(state);
        self.shared.notify();
    }
}

impl Drop for RequestLease {
    fn drop(&mut self) {
        self.release();
    }
}

fn wait_timeout(timeout_ms: i64) -> Duration {
    let bounded_ms = if timeout_ms <= 0 {
        15_000
    } else {
        timeout_ms.min(60_000)
    };
    Duration::from_millis(bounded_ms as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Weak;
    use std::sync::atomic::AtomicUsize;
    use std::task::Wake;

    #[test]
    fn batch_reset_preserves_active_leases_and_unselected_cancellation() {
        let registry = CancellationRegistry::new(CancellationDomain::Download);
        let active = registry.acquire("active").unwrap();
        let second = registry.acquire("active").unwrap();
        for id in ["active", "idle", "keep", "音楽"] {
            registry.cancel(id).unwrap();
        }
        registry
            .reset_many_if_idle(["active", "idle", "idle", "missing", "", "音楽"])
            .unwrap();
        assert!(active.is_cancelled().unwrap());
        assert!(second.is_cancelled().unwrap());
        assert!(registry.is_cancelled("keep").unwrap());
        assert!(!registry.is_cancelled("idle").unwrap());
        assert!(!registry.is_cancelled("音楽").unwrap());
        active.release();
        registry.reset_many_if_idle(["active"]).unwrap();
        assert!(second.is_cancelled().unwrap());
        second.release();
        let retry = registry.acquire("active").unwrap();
        assert!(!retry.is_cancelled().unwrap());
        drop(active);
        drop(second);
        assert!(!retry.is_cancelled().unwrap());
        registry.cancel("active").unwrap();
        assert!(retry.is_cancelled().unwrap());
    }

    #[test]
    fn batch_reset_matches_individual_resets() {
        let baseline = CancellationRegistry::new(CancellationDomain::Download);
        let batch = CancellationRegistry::new(CancellationDomain::Download);
        let ids: Vec<_> = (0..300).map(|i| format!("item-{i}")).collect();
        let mut held = Vec::new();
        for (index, id) in ids.iter().enumerate() {
            if index % 3 == 0 {
                held.push((baseline.acquire(id).unwrap(), batch.acquire(id).unwrap()));
            }
            baseline.cancel(id).unwrap();
            batch.cancel(id).unwrap();
        }
        let selected: Vec<_> = ids.iter().step_by(2).map(String::as_str).collect();
        for id in &selected {
            baseline.reset_if_idle(id).unwrap();
        }
        batch.reset_many_if_idle(selected).unwrap();
        for id in ids {
            assert_eq!(baseline.is_cancelled(&id), batch.is_cancelled(&id));
        }
        for (old, new) in held {
            assert_eq!(old.is_cancelled(), new.is_cancelled());
        }
    }

    #[test]
    fn closed_registry_rejects_batch_including_empty_input() {
        let registry = CancellationRegistry::new(CancellationDomain::Download);
        registry.cancel("keep").unwrap();
        registry.shutdown();
        assert_eq!(
            registry.reset_many_if_idle(["keep"]),
            Err(CancellationError::RegistryClosed)
        );
        assert_eq!(
            registry.reset_many_if_idle([]),
            Err(CancellationError::RegistryClosed)
        );
        assert!(registry.shared.state.lock().unwrap().entries.is_empty());
    }

    #[test]
    fn external_waker_observes_changes_without_holding_the_registry_lock() {
        #[derive(Default)]
        struct Observer {
            shared: Mutex<Weak<Shared>>,
            calls: AtomicUsize,
        }
        impl Wake for Observer {
            fn wake(self: Arc<Self>) {
                if let Some(shared) = self.shared.lock().unwrap().upgrade() {
                    // Executors may synchronously inspect cancellation on wake.
                    let _state = shared.state.try_lock().expect("wake held registry lock");
                    self.calls.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        let observer = Arc::new(Observer::default());
        let registry = CancellationRegistry::with_waker(
            CancellationDomain::Download,
            Waker::from(Arc::clone(&observer)),
        );
        *observer.shared.lock().unwrap() = Arc::downgrade(&registry.shared);
        let first = registry.acquire("first").unwrap();
        let second = registry.acquire("second").unwrap();
        let anonymous = registry.acquire("").unwrap();
        registry.cancel("first").unwrap();
        assert!(first.is_cancelled().unwrap());
        assert!(!second.is_cancelled().unwrap());
        assert_eq!(observer.calls.load(Ordering::Relaxed), 1);
        registry.cancel("").unwrap();
        assert_eq!(observer.calls.load(Ordering::Relaxed), 1);
        registry
            .cancel_many(["first", "idle", "idle", "", "音楽"])
            .unwrap();
        assert_eq!(observer.calls.load(Ordering::Relaxed), 2);
        assert!(registry.acquire("idle").unwrap().is_cancelled().unwrap());
        assert!(registry.is_cancelled("音楽").unwrap());
        assert!(!second.is_cancelled().unwrap());
        assert!(!anonymous.is_cancelled().unwrap());
        // Dropping the temporary idle lease also notifies its release.
        let before = observer.calls.load(Ordering::Relaxed);
        assert_eq!(registry.cancel_active().unwrap(), ["first", "second"]);
        assert!(second.is_cancelled().unwrap());
        assert!(!anonymous.is_cancelled().unwrap());
        assert_eq!(observer.calls.load(Ordering::Relaxed), before + 1);
        second.release();
        second.release();
        assert_eq!(second.check_active(), Err(CancellationError::LeaseReleased));
        assert_eq!(observer.calls.load(Ordering::Relaxed), before + 2);
        registry.shutdown();
        assert_eq!(
            anonymous.check_active(),
            Err(CancellationError::RegistryClosed)
        );
        assert_eq!(observer.calls.load(Ordering::Relaxed), before + 3);
        assert_eq!(
            registry.cancel_many(["later"]),
            Err(CancellationError::RegistryClosed)
        );
    }

    #[test]
    fn timeout_bounds_do_not_overflow() {
        for input in [i64::MIN, -1, 0] {
            assert_eq!(wait_timeout(input), Duration::from_secs(15));
        }
        assert_eq!(wait_timeout(1), Duration::from_millis(1));
        for input in [60_000, 60_001, i64::MAX] {
            assert_eq!(wait_timeout(input), Duration::from_secs(60));
        }
    }
}
