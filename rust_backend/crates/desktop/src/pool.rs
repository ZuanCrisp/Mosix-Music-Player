//! Elastic worker pool. A job never waits behind a busy worker: when no idle
//! worker can take it, a new thread starts. Idle workers exit after a while.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

type Job = Box<dyn FnOnce() + Send + 'static>;

const IDLE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Default)]
struct State {
    jobs: VecDeque<Job>,
    idle: usize,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    ready: Condvar,
}

#[derive(Default)]
pub(crate) struct Pool {
    shared: Arc<Shared>,
}

impl Pool {
    pub(crate) fn submit(&self, job: impl FnOnce() + Send + 'static) {
        let mut state = self.shared.state.lock().expect("pool state");
        state.jobs.push_back(Box::new(job));
        if state.jobs.len() <= state.idle {
            self.shared.ready.notify_one();
            return;
        }
        drop(state);
        let shared = Arc::clone(&self.shared);
        let spawned = std::thread::Builder::new()
            .name("mornye-desktop-call".into())
            .spawn(move || worker(&shared));
        if spawned.is_err() {
            // Thread creation failed (resource limits): an existing worker
            // still drains the queue once it is free.
            self.shared.ready.notify_one();
        }
    }
}

fn worker(shared: &Shared) {
    let mut state = shared.state.lock().expect("pool state");
    loop {
        if let Some(job) = state.jobs.pop_front() {
            drop(state);
            // Jobs report their own panics; keep the worker alive regardless.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
            state = shared.state.lock().expect("pool state");
            continue;
        }
        state.idle += 1;
        let (next, timeout) = shared
            .ready
            .wait_timeout(state, IDLE_TIMEOUT)
            .expect("pool wait");
        state = next;
        state.idle -= 1;
        if timeout.timed_out() && state.jobs.is_empty() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn blocked_job_does_not_delay_others() {
        let pool = Pool::default();
        let (release, blocked) = mpsc::channel::<()>();
        let (done, finished) = mpsc::channel();
        pool.submit(move || {
            let _ = blocked.recv();
        });
        for index in 0..4 {
            let done = done.clone();
            pool.submit(move || done.send(index).unwrap());
        }
        let mut seen: Vec<i32> = (0..4)
            .map(|_| finished.recv_timeout(Duration::from_secs(5)).unwrap())
            .collect();
        seen.sort();
        assert_eq!(seen, [0, 1, 2, 3]);
        release.send(()).unwrap();
    }
}
