use super::{CallGraph, CallNode, Check, LyricsError, cache::LyricsCache};
use spotiflac_core::lyrics::{LyricsResponse, config, config::FetchOptions, matching};
use spotiflac_core::matching::lowercase;
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant, SystemTime};

const POLL: Duration = Duration::from_millis(25);
const NEGATIVE_TTL: Duration = Duration::from_secs(5 * 60);
const UNAVAILABLE_COOLDOWN: Duration = Duration::from_secs(10 * 60);
const PRIORITY_GRACE: Duration = Duration::from_secs(5);
const MAX_NEGATIVE: usize = 500;
const MAX_FLIGHTS: usize = 64;

#[derive(Clone, Debug, Default)]
pub struct SearchRequest {
    pub spotify_id: String,
    pub track: String,
    pub artist: String,
    pub duration: f64,
    pub options: FetchOptions,
    /// Native wait dependency, replaced by the service's flight before dispatch.
    pub caller: Option<CallNode>,
}

/// Built-in clients and the installed extension manager implement this boundary.
/// Calls execute on native workers. Implementations must observe `check` during
/// blocking work and must not reenter the same JavaScript VM from a lyrics call.
pub trait LyricsFetcher: Send + Sync + 'static {
    fn call_graph(&self) -> Option<CallGraph> {
        None
    }

    /// Pure owner-liveness check, also applied before cached/heuristic results.
    /// This can run while the service state is locked; do not block or call a VM.
    fn check(&self) -> Result<(), LyricsError> {
        Ok(())
    }

    fn extensions(&self) -> Vec<String> {
        Vec::new()
    }

    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError>;
}

type FetchResult = Result<LyricsResponse, LyricsError>;

struct Flight {
    node: CallNode,
    waiters: AtomicUsize,
    result: Mutex<Option<FetchResult>>,
    ready: Condvar,
}

struct Waiter(Arc<Flight>);
impl Drop for Waiter {
    fn drop(&mut self) {
        self.0.waiters.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Default)]
struct State {
    // Retain an empty selection separately from the effective default order.
    providers: Vec<String>,
    options: FetchOptions,
    generation: u64,
    negative: BTreeMap<String, Instant>,
    health: BTreeMap<String, Instant>,
    flights: BTreeMap<(u64, String), Arc<Flight>>,
    active: usize,
}

struct Inner {
    fetcher: Arc<dyn LyricsFetcher>,
    calls: CallGraph,
    state: Mutex<State>,
    idle: Condvar,
    closed: AtomicBool,
    cache: LyricsCache,
}

pub struct LyricsService {
    inner: Arc<Inner>,
}

impl LyricsService {
    pub fn new(fetcher: Arc<dyn LyricsFetcher>) -> Self {
        let calls = fetcher.call_graph().unwrap_or_default();
        Self {
            inner: Arc::new(Inner {
                fetcher,
                calls,
                state: Mutex::default(),
                idle: Condvar::new(),
                closed: AtomicBool::new(false),
                cache: LyricsCache::default(),
            }),
        }
    }

    pub fn providers(&self) -> Vec<String> {
        config::provider_order(
            &self
                .inner
                .state
                .lock()
                .expect("lyrics service lock")
                .providers,
        )
    }

    pub fn set_providers(&self, providers: &[String]) -> Result<(), LyricsError> {
        let normalized = config::normalize_provider_order(providers);
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.health.clear();
        if state.providers != normalized {
            state.providers = normalized;
            state.generation = state.generation.wrapping_add(1);
            self.inner.cache.clear();
        }
        Ok(())
    }

    pub fn options(&self) -> FetchOptions {
        self.inner
            .state
            .lock()
            .expect("lyrics service lock")
            .options
            .clone()
    }

    pub fn set_options(&self, mut options: FetchOptions) -> Result<(), LyricsError> {
        options.normalize();
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        if state.options != options {
            state.options = options;
            state.generation = state.generation.wrapping_add(1);
            self.inner.cache.clear();
        }
        Ok(())
    }

    pub fn set_persistence_path(&self, path: &Path) -> Result<(), LyricsError> {
        let _state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        self.inner
            .cache
            .set_persistence_path(path, SystemTime::now());
        Ok(())
    }

    pub fn cache_size(&self) -> usize {
        self.inner.cache.len()
    }

    pub fn clear_cache(&self) -> Result<usize, LyricsError> {
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        Ok(self.inner.cache.clear())
    }

    pub fn drop_memory(&self) -> Result<usize, LyricsError> {
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        state.negative.clear();
        state.health.clear();
        Ok(self.inner.cache.drop_memory())
    }

    pub fn fetch(&self, mut request: SearchRequest, check: &Check<'_>) -> FetchResult {
        self.inner.check(check)?;
        let extensions = self.inner.fetcher.extensions();
        let (flight, start, flight_key, providers, _dependency) = {
            let mut state = self.inner.state.lock().expect("lyrics service lock");
            self.inner.check(check)?;
            request.options = state.options.clone();
            let providers = config::provider_order(&state.providers);
            let key = config::cache_key(
                &request.spotify_id,
                &request.track,
                &request.artist,
                request.duration,
                &providers,
                &extensions,
                &request.options,
            );
            let now = Instant::now();
            if state.negative.get(&key).is_some_and(|expiry| now < *expiry) {
                return Err(LyricsError::NotFound("lyrics not found (cached)".into()));
            }
            state.negative.remove(&key);
            let flight_key = (state.generation, key);
            let existing = state
                .flights
                .get(&flight_key)
                .filter(|flight| flight.waiters.load(Ordering::Acquire) > 0)
                .cloned();
            let (flight, start) = if let Some(flight) = existing {
                (flight, false)
            } else {
                if state.active >= MAX_FLIGHTS {
                    return Err(LyricsError::Other(
                        "too many concurrent lyrics searches".into(),
                    ));
                }
                let flight = Arc::new(Flight {
                    node: self.inner.calls.node(),
                    waiters: AtomicUsize::new(0),
                    result: Mutex::new(None),
                    ready: Condvar::new(),
                });
                (flight, true)
            };
            let dependency = request
                .caller
                .as_ref()
                .map(|caller| caller.wait_for(&flight.node))
                .transpose()
                .map_err(LyricsError::Recursive)?;
            if start {
                state
                    .flights
                    .insert(flight_key.clone(), Arc::clone(&flight));
                state.active += 1;
            }
            request.caller = Some(flight.node.clone());
            flight.waiters.fetch_add(1, Ordering::AcqRel);
            (flight, start, flight_key, providers, dependency)
        };
        let _waiter = Waiter(Arc::clone(&flight));
        if start {
            let inner = Arc::clone(&self.inner);
            let worker_flight = Arc::clone(&flight);
            let worker_key = flight_key.clone();
            let spawned = std::thread::Builder::new()
                .name("lyrics-search".into())
                .spawn(move || {
                    let check = || {
                        if inner.closed.load(Ordering::Acquire) {
                            Err("lyrics service is closed".into())
                        } else if worker_flight.waiters.load(Ordering::Acquire) == 0 {
                            Err("lyrics request cancelled".into())
                        } else {
                            Ok(())
                        }
                    };
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        inner.fetch_uncached(
                            &request,
                            &providers,
                            &extensions,
                            worker_key.0,
                            &check,
                        )
                    }))
                    .unwrap_or_else(|_| Err(LyricsError::Other("lyrics provider panicked".into())));
                    inner.finish(&worker_key, &worker_flight, result);
                });
            if let Err(error) = spawned {
                self.inner.finish(
                    &flight_key,
                    &flight,
                    Err(LyricsError::Other(error.to_string())),
                );
            }
        }
        loop {
            self.inner.check(check)?;
            let result = flight.result.lock().expect("lyrics flight lock");
            if let Some(value) = result.as_ref() {
                let value = value.clone();
                drop(result);
                self.inner.check(check)?;
                return value;
            }
            drop(
                flight
                    .ready
                    .wait_timeout(result, POLL)
                    .expect("lyrics flight lock"),
            );
        }
    }

    /// Cancel workers, wait for their HTTP/extension calls to unwind, then flush
    /// successful data. Native owners call this before releasing the service.
    pub fn shutdown(&self) -> Result<(), String> {
        self.inner.closed.store(true, Ordering::Release);
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        while state.active > 0 {
            state = self.inner.idle.wait(state).expect("lyrics service lock");
        }
        drop(state);
        self.inner.cache.flush()
    }
}

impl Drop for LyricsService {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

impl Inner {
    fn check(&self, check: &Check<'_>) -> Result<(), LyricsError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LyricsError::Cancelled("lyrics service is closed".into()));
        }
        check().map_err(LyricsError::Cancelled)?;
        self.fetcher.check()
    }

    fn finish(&self, key: &(u64, String), flight: &Arc<Flight>, result: FetchResult) {
        let mut state = self.state.lock().expect("lyrics service lock");
        if state.generation == key.0 && !self.closed.load(Ordering::Acquire) {
            if result.as_ref().is_err_and(|error| {
                !matches!(error, LyricsError::Cancelled(_) | LyricsError::Recursive(_))
            }) {
                let now = Instant::now();
                state.negative.retain(|_, expiry| now < *expiry);
                while state.negative.len() >= MAX_NEGATIVE {
                    state.negative.pop_first();
                }
                state.negative.insert(key.1.clone(), now + NEGATIVE_TTL);
            } else if result.is_ok() {
                state.negative.remove(&key.1);
            }
        }
        *flight.result.lock().expect("lyrics flight lock") = Some(result);
        flight.ready.notify_all();
        if state
            .flights
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, flight))
        {
            state.flights.remove(key);
        }
        state.active -= 1;
        self.idle.notify_all();
    }

    fn fetch_uncached(
        &self,
        request: &SearchRequest,
        providers: &[String],
        extensions: &[String],
        generation: u64,
        check: &Check<'_>,
    ) -> FetchResult {
        self.check(check)?;
        let key = config::cache_key(
            "",
            &request.track,
            &request.artist,
            request.duration,
            providers,
            extensions,
            &request.options,
        );
        if matching::is_likely_instrumental(&request.track) {
            let result = LyricsResponse {
                instrumental: true,
                source: "Heuristic: Instrumental".into(),
                ..LyricsResponse::default()
            };
            self.store(generation, key, &result, check)?;
            return Ok(result);
        }
        let providers = config::resolve_order(providers, extensions);
        let mut fallback = None;
        if let Some(mut cached) = self.cache.get(&key, SystemTime::now()) {
            let extension = cached.source.strip_prefix("Extension:");
            let selected = extension.is_some_and(|id| {
                providers.contains(&format!("extension:{}", lowercase(id.trim())))
            });
            let has_extensions = providers.iter().any(|name| name.starts_with("extension:"));
            if (extension.is_none() && !has_extensions) || selected {
                cached.source.push_str(" (cached)");
                return Ok(cached);
            }
            if extension.is_none() {
                fallback = Some(cached);
            }
        }
        let result = self.search(&providers, request, generation, check, PRIORITY_GRACE);
        self.check(check)?;
        if let Err(error @ LyricsError::Cancelled(_)) = result {
            return Err(error);
        }
        let recursive = match &result {
            Err(error @ LyricsError::Recursive(_)) => Some(error.clone()),
            _ => None,
        };
        if let Ok(lyrics) = result
            && lyrics.has_usable_text()
        {
            self.store(generation, key, &lyrics, check)?;
            return Ok(lyrics);
        }
        if let Some(mut cached) = fallback {
            cached.source.push_str(" (cached fallback)");
            return Ok(cached);
        }
        if let Some(error) = recursive {
            return Err(error);
        }
        Err(LyricsError::Other(
            "lyrics not found from any source".into(),
        ))
    }

    fn store(
        &self,
        generation: u64,
        key: String,
        response: &LyricsResponse,
        check: &Check<'_>,
    ) -> Result<(), LyricsError> {
        let state = self.state.lock().expect("lyrics service lock");
        self.check(check)?;
        if state.generation == generation {
            self.cache.set(key, response, SystemTime::now());
        }
        Ok(())
    }

    fn search(
        &self,
        providers: &[String],
        request: &SearchRequest,
        generation: u64,
        check: &Check<'_>,
        grace: Duration,
    ) -> FetchResult {
        let candidates: Vec<_> = {
            let mut state = self.state.lock().expect("lyrics service lock");
            let now = Instant::now();
            state.health.retain(|_, expiry| now < *expiry);
            providers
                .iter()
                .enumerate()
                .filter(|(_, name)| !state.health.contains_key(*name))
                .collect()
        };
        let stopped = AtomicBool::new(false);
        let next = AtomicUsize::new(0);
        let control = || {
            if stopped.load(Ordering::Acquire) {
                Err("lyrics provider search cancelled".into())
            } else {
                check()
            }
        };
        std::thread::scope(|scope| {
            let (sender, receiver) = mpsc::channel();
            for _ in 0..candidates.len().min(3) {
                let sender = sender.clone();
                let candidates = &candidates;
                let control = &control;
                let next = &next;
                scope.spawn(move || {
                    loop {
                        if control().is_err() {
                            break;
                        }
                        let Some(&(index, name)) =
                            candidates.get(next.fetch_add(1, Ordering::AcqRel))
                        else {
                            break;
                        };
                        let result = catch_unwind(AssertUnwindSafe(|| {
                            self.fetcher.fetch(name, request, control)
                        }))
                        .unwrap_or_else(|_| {
                            Err(LyricsError::Other("lyrics provider panicked".into()))
                        });
                        if control().is_ok() {
                            let mut state = self.state.lock().expect("lyrics service lock");
                            if state.generation == generation {
                                match &result {
                                    Ok(lyrics) if lyrics.has_usable_text() => {
                                        state.health.remove(name);
                                    }
                                    Err(LyricsError::Unavailable(_)) => {
                                        state.health.insert(
                                            name.clone(),
                                            Instant::now() + UNAVAILABLE_COOLDOWN,
                                        );
                                    }
                                    _ => {}
                                }
                            }
                        }
                        if sender.send((index, result)).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(sender);
            let mut completed = vec![false; providers.len()];
            let mut best: Option<(usize, LyricsResponse)> = None;
            let mut deadline = None;
            let mut last_error = None;
            let mut recursive = None;
            let result = loop {
                if let Err(error) = self.check(check) {
                    break Err(error);
                }
                if let Some((index, _)) = &best {
                    let pending = candidates
                        .iter()
                        .any(|(earlier, _)| earlier < index && !completed[*earlier]);
                    if !pending || deadline.is_some_and(|limit| Instant::now() >= limit) {
                        break Ok(best.take().expect("best lyrics result").1);
                    }
                }
                match receiver.recv_timeout(POLL) {
                    Ok((index, result)) => {
                        completed[index] = true;
                        if let Err(error @ LyricsError::Recursive(_)) = &result {
                            recursive = Some(error.clone());
                        }
                        if let Err(error) = &result {
                            last_error = Some(error.clone());
                        }
                        if let Ok(lyrics) = result
                            && lyrics.has_usable_text()
                            && best.as_ref().is_none_or(|(current, _)| index < *current)
                        {
                            best = Some((index, lyrics));
                            deadline = Some(Instant::now() + grace);
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        break best.map(|(_, lyrics)| lyrics).ok_or_else(|| {
                            recursive.or(last_error).unwrap_or_else(|| {
                                LyricsError::Other("lyrics not found from any source".into())
                            })
                        });
                    }
                }
            };
            stopped.store(true, Ordering::Release);
            result
        })
    }
}

#[cfg(test)]
mod tests;
