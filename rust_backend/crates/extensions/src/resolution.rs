//! Resolver allowance shared by a download call and its native segment workers.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub(crate) struct ResolutionBudget(Mutex<State>);

struct State {
    remaining: Duration,
    started: Instant,
    pauses: usize,
    charges: usize,
}

impl State {
    fn remaining(&self, now: Instant) -> Duration {
        if self.pauses == 0 || self.charges > 0 {
            self.remaining
                .saturating_sub(now.saturating_duration_since(self.started))
        } else {
            self.remaining
        }
    }

    fn settle(&mut self, now: Instant) {
        self.remaining = self.remaining(now);
        self.started = now;
    }
}

impl ResolutionBudget {
    pub fn new(allowance: Duration) -> Arc<Self> {
        Arc::new(Self(Mutex::new(State {
            remaining: allowance,
            started: Instant::now(),
            pauses: 0,
            charges: 0,
        })))
    }

    pub fn remaining(&self) -> Duration {
        self.0
            .lock()
            .expect("resolution budget lock")
            .remaining(Instant::now())
    }

    pub fn enter(self: &Arc<Self>, charge: bool) -> BudgetGuard {
        let mut state = self.0.lock().expect("resolution budget lock");
        state.settle(Instant::now());
        if charge {
            state.charges += 1;
        } else {
            state.pauses += 1;
        }
        BudgetGuard {
            budget: Arc::clone(self),
            charge,
        }
    }
}

pub(crate) struct BudgetGuard {
    budget: Arc<ResolutionBudget>,
    charge: bool,
}

impl Drop for BudgetGuard {
    fn drop(&mut self) {
        let mut state = self.budget.0.lock().expect("resolution budget lock");
        state.settle(Instant::now());
        if self.charge {
            state.charges -= 1;
        } else {
            state.pauses -= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn charges_override_nested_pauses_and_exhaustion_is_terminal() {
        let now = Instant::now();
        let mut state = State {
            remaining: Duration::from_secs(60),
            started: now,
            pauses: 0,
            charges: 0,
        };
        state.settle(now + Duration::from_secs(10));
        state.pauses = 2;
        assert_eq!(
            state.remaining(now + Duration::from_secs(3600)),
            Duration::from_secs(50)
        );
        state.settle(now + Duration::from_secs(3600));
        state.charges = 1;
        state.settle(now + Duration::from_secs(3610));
        assert_eq!(state.remaining, Duration::from_secs(40));
        state.charges = 0;
        state.settle(now + Duration::from_secs(4000));
        state.pauses = 0;
        state.settle(now + Duration::from_secs(4041));
        assert_eq!(state.remaining, Duration::ZERO);
        state.pauses = 1;
        assert_eq!(
            state.remaining(now + Duration::from_secs(5000)),
            Duration::ZERO
        );
    }
}
