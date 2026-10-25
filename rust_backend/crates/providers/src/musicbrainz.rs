//! Shared recording snapshots for native genre and album-artist enrichment.

mod http;
#[cfg(test)]
mod tests;

use crate::coalescer::{Coalescer, Flight, Waiter};
use crate::resolver::{Check, ResolverError};
use mornye_core::matching::uppercase;
use mornye_core::metadata::musicbrainz::Response;
use mornye_network::NetworkService;
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(25);
const MAX_CACHE: usize = 256;
type Outcome = Result<Arc<Response>, ResolverError>;

/// Trusted native/test configuration. These options are not exposed to JS/FFI.
#[derive(Clone)]
pub struct MusicBrainzOptions {
    pub endpoint: String,
    pub http_timeout: Duration,
    pub retry_delay: Duration,
    pub positive_ttl: Duration,
    pub negative_ttl: Duration,
}

impl Default for MusicBrainzOptions {
    fn default() -> Self {
        Self {
            endpoint: "https://musicbrainz.org".into(),
            http_timeout: Duration::from_secs(10),
            retry_delay: Duration::from_secs(2),
            positive_ttl: Duration::from_secs(6 * 60 * 60),
            negative_ttl: Duration::from_secs(10 * 60),
        }
    }
}

trait Fetch: Send + Sync + 'static {
    fn fetch(&self, isrc: &str, check: &Check<'_>) -> Outcome;
}

struct Entry {
    outcome: Outcome,
    expires: Instant,
}

#[derive(Default)]
struct Cache(BTreeMap<String, Entry>);

impl Cache {
    fn get(&self, key: &str, now: Instant) -> Option<Outcome> {
        self.0
            .get(key)
            .filter(|entry| now < entry.expires)
            .map(|entry| entry.outcome.clone())
    }

    fn put(&mut self, key: &str, outcome: Outcome, now: Instant, options: &MusicBrainzOptions) {
        if self.0.len() >= MAX_CACHE {
            self.0.retain(|_, entry| now <= entry.expires);
            if self.0.len() >= MAX_CACHE {
                self.0.clear();
            }
        }
        let ttl = if outcome.is_ok() {
            options.positive_ttl
        } else {
            options.negative_ttl
        };
        self.0.insert(
            key.into(),
            Entry {
                outcome,
                expires: now + ttl,
            },
        );
    }
}

#[derive(Default)]
struct State {
    flights: Coalescer<String, Outcome>,
    workers: Vec<JoinHandle<()>>,
    cache: Cache,
}

struct Inner {
    fetcher: Arc<dyn Fetch>,
    options: MusicBrainzOptions,
    closed: AtomicBool,
    state: Mutex<State>,
    idle: Condvar,
    shutdown: Mutex<()>,
}

pub struct MusicBrainzClient {
    inner: Arc<Inner>,
}

impl MusicBrainzClient {
    pub fn with_options(
        network: &Arc<NetworkService>,
        options: MusicBrainzOptions,
    ) -> Result<Self, ResolverError> {
        let fetcher = Arc::new(http::Http::new(network, &options)?);
        Ok(Self::with_fetcher(fetcher, options))
    }

    fn with_fetcher(fetcher: Arc<dyn Fetch>, options: MusicBrainzOptions) -> Self {
        Self {
            inner: Arc::new(Inner {
                fetcher,
                options,
                closed: AtomicBool::new(false),
                state: Mutex::new(State::default()),
                idle: Condvar::new(),
                shutdown: Mutex::new(()),
            }),
        }
    }

    pub fn genre(&self, isrc: &str, check: &Check<'_>) -> Result<String, ResolverError> {
        let (isrc, snapshot) = self.snapshot(isrc, check)?;
        let result = snapshot.genre(&isrc).map_err(ResolverError::Failed);
        self.inner.check(check)?;
        result
    }

    pub fn album_artist(
        &self,
        isrc: &str,
        album_name: &str,
        check: &Check<'_>,
    ) -> Result<String, ResolverError> {
        let (isrc, snapshot) = self.snapshot(isrc, check)?;
        let result = snapshot
            .album_artist(&isrc, album_name)
            .map_err(ResolverError::Failed);
        self.inner.check(check)?;
        result
    }

    fn snapshot(
        &self,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<(String, Arc<Response>), ResolverError> {
        self.inner.check(check)?;
        if isrc.len() > 64 << 10 {
            return Err(ResolverError::Failed(
                "MusicBrainz ISRC exceeds limit".into(),
            ));
        }
        let key = uppercase(isrc.trim());
        let flight = {
            let mut state = self.inner.state.lock().unwrap();
            self.inner.check(&|| Ok(()))?;
            // Reap completed threads on cache hits too, keeping retained handles bounded.
            let mut pending = Vec::new();
            for worker in state.workers.drain(..) {
                if worker.is_finished() {
                    let _ = worker.join();
                } else {
                    pending.push(worker);
                }
            }
            state.workers = pending;
            if let Some(value) = state.cache.get(&key, Instant::now()) {
                drop(state);
                self.inner.check(check)?;
                return value.map(|value| (key, value));
            }
            if let Some(flight) = state.flights.try_join(&key) {
                flight
            } else {
                if state.flights.is_full() {
                    return Err(ResolverError::Failed(
                        "MusicBrainz lookup limit reached".into(),
                    ));
                }
                let flight = Flight::new(());
                flight.join();
                state.flights.insert(key.clone(), flight.clone());
                let inner = self.inner.clone();
                let worker_key = key.clone();
                let worker_flight = flight.clone();
                // Register the handle under the state lock so shutdown cannot miss it.
                match std::thread::Builder::new()
                    .name("musicbrainz".into())
                    .spawn(move || {
                        let check = || {
                            worker_flight.check(
                                &inner.closed,
                                "MusicBrainz client closed",
                                "MusicBrainz request cancelled",
                            )
                        };
                        let result = catch_unwind(AssertUnwindSafe(|| {
                            if worker_key.is_empty() {
                                Err(ResolverError::Failed("no ISRC provided".into()))
                            } else {
                                inner.fetcher.fetch(&worker_key, &check)
                            }
                        }))
                        .unwrap_or_else(|_| {
                            Err(ResolverError::Failed("MusicBrainz request panicked".into()))
                        });
                        inner.finish(
                            &worker_key,
                            &worker_flight,
                            check().map_err(ResolverError::Cancelled).and(result),
                        );
                    }) {
                    Ok(worker) => state.workers.push(worker),
                    // Spawn failures are published without caching.
                    Err(error) => state.flights.finish(
                        &key,
                        &flight,
                        Err(ResolverError::Failed(error.to_string())),
                        &self.inner.idle,
                    ),
                }
                flight
            }
        };
        let _waiter = Waiter::new(flight.clone());
        flight
            .wait(|| self.inner.check(check))?
            .map(|value| (key, value))
    }

    pub fn shutdown(&self) {
        let _shutdown = self.inner.shutdown.lock().unwrap();
        self.inner.closed.store(true, Ordering::Release);
        let mut state = self.inner.state.lock().unwrap();
        while state.flights.active() != 0 {
            state = self.inner.idle.wait(state).unwrap();
        }
        state.cache.0.clear();
        let workers = std::mem::take(&mut state.workers);
        drop(state);
        for worker in workers {
            let _ = worker.join();
        }
    }
}

impl Drop for MusicBrainzClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl Inner {
    fn check(&self, check: &Check<'_>) -> Result<(), ResolverError> {
        if self.closed.load(Ordering::Acquire) {
            Err(ResolverError::Cancelled("MusicBrainz client closed".into()))
        } else {
            check().map_err(ResolverError::Cancelled)
        }
    }

    fn finish(&self, key: &str, flight: &Arc<Flight<Outcome>>, result: Outcome) {
        let mut state = self.state.lock().unwrap();
        // Only the current flight caches, and only while a caller still wants it.
        if state.flights.is_current(key, flight)
            && !self.closed.load(Ordering::Acquire)
            && flight.waiters() > 0
            && !matches!(
                result,
                Err(ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy)
            )
        {
            state
                .cache
                .put(key, result.clone(), Instant::now(), &self.options);
        }
        state.flights.finish(key, flight, result, &self.idle);
    }
}
