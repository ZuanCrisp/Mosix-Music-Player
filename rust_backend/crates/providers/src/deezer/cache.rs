use super::{Check, DeezerClient, ResolverError};
use spotiflac_core::metadata::{
    AlbumExtendedMetadata, AlbumResponsePayload, ArtistResponsePayload, SearchAllResult,
};
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub(super) enum Value {
    Search(Arc<SearchAllResult>),
    Album(Arc<AlbumResponsePayload>),
    Artist(Arc<ArtistResponsePayload>),
    Extended(Arc<AlbumExtendedMetadata>),
    AlbumId(String),
}

#[derive(Clone, Copy)]
pub(super) enum Bucket {
    Search,
    Album,
    Artist,
}

struct Entry {
    value: Value,
    expires: Instant,
}

#[derive(Default)]
pub(super) struct Cache {
    search: BTreeMap<String, Entry>,
    albums: BTreeMap<String, Entry>,
    artists: BTreeMap<String, Entry>,
    pub isrc: BTreeMap<String, String>,
    last_cleanup: Option<Instant>,
}

impl Cache {
    fn bucket(&mut self, bucket: Bucket) -> &mut BTreeMap<String, Entry> {
        match bucket {
            Bucket::Search => &mut self.search,
            Bucket::Album => &mut self.albums,
            Bucket::Artist => &mut self.artists,
        }
    }

    pub fn get(&mut self, bucket: Bucket, key: &str, now: Instant) -> Option<Value> {
        self.bucket(bucket)
            .get(key)
            .filter(|entry| now <= entry.expires)
            .map(|entry| entry.value.clone())
    }

    pub fn put(&mut self, bucket: Bucket, key: String, value: Value, now: Instant) {
        self.bucket(bucket).insert(
            key,
            Entry {
                value,
                expires: now + Duration::from_secs(600),
            },
        );
        self.cleanup(now);
    }

    pub fn cleanup(&mut self, now: Instant) {
        let periodic = self
            .last_cleanup
            .is_none_or(|last| now.saturating_duration_since(last) >= Duration::from_secs(300));
        for (bucket, limit) in [
            (Bucket::Search, 300),
            (Bucket::Album, 200),
            (Bucket::Artist, 200),
        ] {
            let entries = self.bucket(bucket);
            if periodic || entries.len() > limit {
                entries.retain(|_, entry| now <= entry.expires);
                while entries.len() > limit {
                    let key = entries
                        .iter()
                        .min_by_key(|(_, entry)| entry.expires)
                        .unwrap()
                        .0
                        .clone();
                    entries.remove(&key);
                }
            }
        }
        while self.isrc.len() > 4000 {
            self.isrc.pop_first();
        }
        if periodic {
            self.last_cleanup = Some(now);
        }
    }
}

#[derive(Default)]
pub(super) struct Flight {
    result: Mutex<Option<Result<Value, ResolverError>>>,
    ready: Condvar,
}

impl DeezerClient {
    pub(super) fn cached(&self, bucket: Bucket, key: &str) -> Option<Value> {
        self.cache.lock().unwrap().get(bucket, key, Instant::now())
    }

    pub(super) fn store(&self, bucket: Bucket, key: String, value: Value) {
        self.cache
            .lock()
            .unwrap()
            .put(bucket, key, value, Instant::now());
    }

    /// Only Go's two extended-metadata operations coalesce. Waiting callers
    /// can cancel independently; a cancelled leader lets live waiters retry.
    pub(super) fn coalesced(
        &self,
        key: &str,
        check: &Check<'_>,
        fetch: impl Fn() -> Result<Value, ResolverError>,
    ) -> Result<Value, ResolverError> {
        loop {
            check().map_err(ResolverError::Cancelled)?;
            if let Some(value) = self.cached(Bucket::Search, key) {
                return Ok(value);
            }
            let (flight, owner) = {
                let mut flights = self.flights.lock().unwrap();
                match flights.get(key) {
                    Some(flight) => (flight.clone(), false),
                    None => {
                        if flights.len() >= 64 {
                            return Err(ResolverError::Busy);
                        }
                        let flight = Arc::new(Flight::default());
                        flights.insert(key.into(), flight.clone());
                        (flight, true)
                    }
                }
            };
            if owner {
                let result = catch_unwind(AssertUnwindSafe(|| {
                    let value = match self.cached(Bucket::Search, key) {
                        Some(value) => value,
                        None => fetch()?,
                    };
                    check().map_err(ResolverError::Cancelled)?;
                    self.store(Bucket::Search, key.into(), value.clone());
                    Ok(value)
                }))
                .unwrap_or_else(|_| Err(ResolverError::Failed("metadata request panicked".into())));
                self.flights.lock().unwrap().remove(key);
                *flight.result.lock().unwrap() = Some(result.clone());
                flight.ready.notify_all();
                return result;
            }
            let mut result = flight.result.lock().unwrap();
            loop {
                check().map_err(ResolverError::Cancelled)?;
                if let Some(value) = result.as_ref() {
                    if matches!(value, Err(ResolverError::Cancelled(_))) {
                        break;
                    }
                    return value.clone();
                }
                result = flight
                    .ready
                    .wait_timeout(result, Duration::from_millis(25))
                    .unwrap()
                    .0;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    fn until(ready: impl Fn() -> bool) {
        let started = Instant::now();
        while !ready() {
            assert!(started.elapsed() < Duration::from_secs(3));
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn id(value: Result<Value, ResolverError>) -> String {
        match value.unwrap() {
            Value::AlbumId(value) => value,
            _ => panic!("wrong cache type"),
        }
    }

    #[test]
    fn cache_budgets_expiry_and_empty_isrc_follow_the_metadata_contract() {
        let now = Instant::now();
        let mut cache = Cache::default();
        for (bucket, limit) in [
            (Bucket::Search, 300),
            (Bucket::Album, 200),
            (Bucket::Artist, 200),
        ] {
            for index in 0..=limit {
                cache.put(
                    bucket,
                    index.to_string(),
                    Value::AlbumId(index.to_string()),
                    now + Duration::from_millis(index),
                );
            }
            assert!(cache.get(bucket, "0", now).is_none());
            assert!(
                cache
                    .get(bucket, "1", now + Duration::from_secs(600))
                    .is_some()
            );
            assert!(
                cache
                    .get(bucket, "1", now + Duration::from_secs(601))
                    .is_none()
            );
            assert_eq!(cache.bucket(bucket).len(), limit as usize);
        }
        for index in 0..4005 {
            cache.isrc.insert(index.to_string(), String::new());
        }
        cache.cleanup(now + Duration::from_secs(601));
        assert!(cache.search.is_empty() && cache.albums.is_empty() && cache.artists.is_empty());
        assert_eq!(cache.isrc.len(), 4000);
        assert!(cache.isrc.values().all(String::is_empty));
        cache.cleanup(now + Duration::from_secs(86400));
        assert_eq!(cache.isrc.len(), 4000);
    }

    #[test]
    fn metadata_flights_coalesce_and_a_cancelled_waiter_does_not_cancel_the_leader() {
        let network = spotiflac_network::NetworkService::new().unwrap();
        let client = DeezerClient::new(&network);
        let started = AtomicBool::new(false);
        let release = AtomicBool::new(false);
        let cancel = AtomicBool::new(false);
        let checks = AtomicUsize::new(0);
        let calls = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            let leader = scope.spawn(|| {
                client.coalesced("metadata", &|| Ok(()), || {
                    calls.fetch_add(1, Ordering::AcqRel);
                    started.store(true, Ordering::Release);
                    until(|| release.load(Ordering::Acquire));
                    Ok(Value::AlbumId("shared".into()))
                })
            });
            until(|| started.load(Ordering::Acquire));
            let cancelled = scope.spawn(|| {
                client.coalesced(
                    "metadata",
                    &|| {
                        checks.fetch_add(1, Ordering::AcqRel);
                        if cancel.load(Ordering::Acquire) {
                            Err("cancel waiter".into())
                        } else {
                            Ok(())
                        }
                    },
                    || panic!("waiter became leader"),
                )
            });
            until(|| checks.load(Ordering::Acquire) >= 2);
            cancel.store(true, Ordering::Release);
            assert!(matches!(
                cancelled.join().unwrap(),
                Err(ResolverError::Cancelled(_))
            ));
            let waiters: Vec<_> = (0..24)
                .map(|_| {
                    scope.spawn(|| {
                        client.coalesced("metadata", &|| Ok(()), || {
                            panic!("duplicate metadata lookup")
                        })
                    })
                })
                .collect();
            release.store(true, Ordering::Release);
            assert_eq!(id(leader.join().unwrap()), "shared");
            for waiter in waiters {
                assert_eq!(id(waiter.join().unwrap()), "shared");
            }
        });
        assert_eq!(calls.load(Ordering::Acquire), 1);
        assert!(client.flights.lock().unwrap().is_empty());
        assert_eq!(
            id(client.coalesced("metadata", &|| Ok(()), || panic!("cache miss"))),
            "shared"
        );
    }

    #[test]
    fn cancelled_leaders_release_live_waiters_and_panics_leave_no_stuck_flight() {
        let network = spotiflac_network::NetworkService::new().unwrap();
        let client = DeezerClient::new(&network);
        let started = AtomicBool::new(false);
        let cancel = AtomicBool::new(false);
        let checks = AtomicUsize::new(0);
        let retried = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            let leader = scope.spawn(|| {
                client.coalesced("metadata", &|| Ok(()), || {
                    started.store(true, Ordering::Release);
                    until(|| cancel.load(Ordering::Acquire));
                    Err(ResolverError::Cancelled("cancel leader".into()))
                })
            });
            until(|| started.load(Ordering::Acquire));
            let waiter = scope.spawn(|| {
                client.coalesced(
                    "metadata",
                    &|| {
                        checks.fetch_add(1, Ordering::AcqRel);
                        Ok(())
                    },
                    || {
                        retried.fetch_add(1, Ordering::AcqRel);
                        Ok(Value::AlbumId("retry".into()))
                    },
                )
            });
            until(|| checks.load(Ordering::Acquire) >= 2);
            cancel.store(true, Ordering::Release);
            assert!(matches!(
                leader.join().unwrap(),
                Err(ResolverError::Cancelled(_))
            ));
            assert_eq!(id(waiter.join().unwrap()), "retry");
        });
        assert_eq!(retried.load(Ordering::Acquire), 1);
        assert!(
            client
                .coalesced("panic", &|| Ok(()), || panic!("fixture panic"))
                .is_err()
        );
        assert!(client.flights.lock().unwrap().is_empty());
        assert_eq!(
            id(client.coalesced("panic", &|| Ok(()), || Ok(Value::AlbumId(
                "recovered".into()
            )))),
            "recovered"
        );
    }

    #[test]
    fn distinct_pending_metadata_flights_are_bounded_and_release_their_slots() {
        let network = spotiflac_network::NetworkService::new().unwrap();
        let client = DeezerClient::new(&network);
        let entered = AtomicUsize::new(0);
        let release = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let workers: Vec<_> = (0..64)
                .map(|index| {
                    let key = index.to_string();
                    let client = &client;
                    let entered = &entered;
                    let release = &release;
                    scope.spawn(move || {
                        client.coalesced(&key, &|| Ok(()), || {
                            entered.fetch_add(1, Ordering::AcqRel);
                            until(|| release.load(Ordering::Acquire));
                            Ok(Value::AlbumId(key.clone()))
                        })
                    })
                })
                .collect();
            until(|| entered.load(Ordering::Acquire) == 64);
            assert!(matches!(
                client.coalesced("overflow", &|| Ok(()), || panic!("limit bypassed")),
                Err(ResolverError::Busy)
            ));
            release.store(true, Ordering::Release);
            for worker in workers {
                assert!(!id(worker.join().unwrap()).is_empty());
            }
        });
        assert!(client.flights.lock().unwrap().is_empty());
        assert_eq!(
            id(
                client.coalesced("overflow", &|| Ok(()), || Ok(Value::AlbumId(
                    "available".into()
                )))
            ),
            "available"
        );
    }
}
