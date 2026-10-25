use super::{Check, ResolverError, check_active};
use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct RateLimiter {
    timestamps: Mutex<VecDeque<Instant>>,
    maximum: usize,
    window: Duration,
}

impl RateLimiter {
    pub fn new(maximum: usize, window: Duration) -> Self {
        Self {
            timestamps: Mutex::new(VecDeque::new()),
            maximum,
            window,
        }
    }

    pub fn wait(&self, check: &Check<'_>) -> Result<(), ResolverError> {
        loop {
            check_active(check)?;
            let mut timestamps = self.timestamps.lock().unwrap();
            let now = Instant::now();
            while timestamps
                .front()
                .is_some_and(|stamp| now.duration_since(*stamp) >= self.window)
            {
                timestamps.pop_front();
            }
            if timestamps.len() < self.maximum {
                timestamps.push_back(now);
                return Ok(());
            }
            let remaining = self
                .window
                .saturating_sub(now.duration_since(*timestamps.front().unwrap()));
            drop(timestamps);
            std::thread::sleep(remaining.min(Duration::from_millis(25)));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_waiters_reserve_distinct_slots_and_can_cancel() {
        let limiter = RateLimiter::new(1, Duration::from_millis(30));
        let stamps = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| {
                    limiter.wait(&|| Ok(())).unwrap();
                    stamps.lock().unwrap().push(Instant::now());
                });
            }
        });
        let mut stamps = stamps.into_inner().unwrap();
        stamps.sort_unstable();
        assert!(stamps.last().unwrap().duration_since(stamps[0]) >= Duration::from_millis(85));
        let limiter = RateLimiter::new(1, Duration::from_secs(60));
        limiter.wait(&|| Ok(())).unwrap();
        let started = Instant::now();
        assert_eq!(
            limiter.wait(&|| if started.elapsed() >= Duration::from_millis(30) {
                Err("cancel rate wait".into())
            } else {
                Ok(())
            }),
            Err(ResolverError::Cancelled("cancel rate wait".into()))
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
