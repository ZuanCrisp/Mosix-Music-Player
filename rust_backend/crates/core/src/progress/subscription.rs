use super::{ProgressError, Shared};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub struct ProgressSubscription {
    shared: Arc<Shared>,
    closed: AtomicBool,
}

impl ProgressSubscription {
    pub(super) fn new(shared: Arc<Shared>) -> Self {
        Self {
            shared,
            closed: AtomicBool::new(false),
        }
    }

    /// No event is consumed: independent UI/background listeners use their own
    /// sequence, and every waiter sees the same revision. Close wakes only this
    /// subscription semantically; other waiters continue against their deadline.
    pub fn wait_delta(&self, since: i64, timeout_ms: i64) -> Result<String, ProgressError> {
        let timeout = Duration::from_millis(if timeout_ms <= 0 {
            15_000
        } else {
            timeout_ms.min(60_000)
        } as u64);
        let started = Instant::now();
        let mut state = self.shared.state.lock().expect("progress state lock");
        loop {
            state.check()?;
            if self.closed.load(Ordering::Acquire) {
                return Err(ProgressError::SubscriptionClosed);
            }
            if since < state.seq {
                return Ok(state.delta(since));
            }
            let remaining = timeout.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Ok(String::new());
            }
            (state, _) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .expect("progress wait lock");
        }
    }

    pub fn close(&self) {
        let _state = self.shared.state.lock().expect("progress state lock");
        self.closed.store(true, Ordering::Release);
        self.shared.changed.notify_all();
    }
}

impl Drop for ProgressSubscription {
    fn drop(&mut self) {
        self.close();
    }
}
