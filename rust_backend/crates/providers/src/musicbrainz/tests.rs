use super::*;
use spotiflac_core::metadata::musicbrainz::{ArtistCredit, Recording, Release, Tag};
use std::thread;

fn response() -> Arc<Response> {
    Arc::new(Response {
        recordings: Some(vec![Recording {
            tags: Some(vec![Tag {
                count: 1,
                name: "rock".into(),
            }]),
            releases: Some(vec![Release {
                title: "Album".into(),
                artist_credit: Some(vec![ArtistCredit {
                    name: "Example Artist".into(),
                    joinphrase: String::new(),
                }]),
            }]),
        }]),
    })
}

fn until(ready: impl Fn() -> bool) {
    let started = Instant::now();
    while !ready() {
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "fixture did not become ready"
        );
        thread::sleep(Duration::from_millis(1));
    }
}

#[derive(Default)]
struct Probe {
    calls: AtomicUsize,
    active: AtomicUsize,
    cancelled: AtomicUsize,
    release: AtomicBool,
    hold_cancelled: AtomicBool,
    failure: AtomicBool,
}

struct Active<'a>(&'a AtomicUsize);
impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

impl Fetch for Probe {
    fn fetch(&self, isrc: &str, check: &Check<'_>) -> Outcome {
        self.calls.fetch_add(1, Ordering::AcqRel);
        self.active.fetch_add(1, Ordering::AcqRel);
        let _active = Active(&self.active);
        let started = Instant::now();
        while !self.release.load(Ordering::Acquire) {
            if let Err(message) = check() {
                self.cancelled.fetch_add(1, Ordering::AcqRel);
                while self.hold_cancelled.load(Ordering::Acquire)
                    && started.elapsed() < Duration::from_secs(3)
                {
                    thread::sleep(Duration::from_millis(1));
                }
                return Err(ResolverError::Cancelled(message));
            }
            if started.elapsed() >= Duration::from_secs(3) {
                return Err(ResolverError::Failed("fixture timed out".into()));
            }
            thread::sleep(Duration::from_millis(1));
        }
        if self.failure.load(Ordering::Acquire) {
            Err(ResolverError::Transport("fixture transport failed".into()))
        } else if isrc == "EMPTY" {
            Ok(Arc::new(Response::default()))
        } else {
            Ok(response())
        }
    }
}

fn client(probe: &Arc<Probe>) -> Arc<MusicBrainzClient> {
    Arc::new(MusicBrainzClient::with_fetcher(
        probe.clone(),
        MusicBrainzOptions::default(),
    ))
}

#[test]
fn cache_ttls_expiry_and_capacity_follow_go_snapshot_outcomes() {
    let options = MusicBrainzOptions::default();
    let now = Instant::now();
    let mut cache = Cache::default();
    cache.put("empty", Ok(Arc::new(Response::default())), now, &options);
    cache.put(
        "failed",
        Err(ResolverError::Failed("failed".into())),
        now,
        &options,
    );
    assert!(
        cache
            .get("empty", now + Duration::from_secs(11 * 60))
            .unwrap()
            .is_ok()
    );
    assert!(cache.get("empty", now + options.positive_ttl).is_none());
    assert!(
        cache
            .get(
                "failed",
                now + options.negative_ttl - Duration::from_nanos(1)
            )
            .unwrap()
            .is_err()
    );
    assert!(cache.get("failed", now + options.negative_ttl).is_none());
    cache.0.clear();
    for index in 0..MAX_CACHE {
        cache.put(&index.to_string(), Ok(response()), now, &options);
    }
    cache.put("overflow", Ok(response()), now, &options);
    assert_eq!(
        cache.0.len(),
        1,
        "Go resets a full cache when cleanup cannot reclaim entries"
    );
    for index in 0..MAX_CACHE - 1 {
        cache.put(
            &index.to_string(),
            Err(ResolverError::Failed("failed".into())),
            now,
            &options,
        );
    }
    cache.put(
        "after-expiry",
        Ok(response()),
        now + options.negative_ttl + Duration::from_nanos(1),
        &options,
    );
    assert_eq!(cache.0.len(), 2);
    assert!(cache.get("overflow", now).is_some());
}

#[test]
fn genre_and_album_artist_share_a_flight_without_cancelling_other_callers() {
    let probe = Arc::new(Probe::default());
    let client = client(&probe);
    let cancel = Arc::new(AtomicBool::new(false));
    let first = {
        let (client, cancel) = (client.clone(), cancel.clone());
        thread::spawn(move || {
            client.genre(" usaa00000101 ", &|| {
                if cancel.load(Ordering::Acquire) {
                    Err("caller cancelled".into())
                } else {
                    Ok(())
                }
            })
        })
    };
    until(|| probe.calls.load(Ordering::Acquire) == 1);
    let others: Vec<_> = (0..8)
        .map(|index| {
            let client = client.clone();
            thread::spawn(move || {
                if index % 2 == 0 {
                    client.genre("USAA00000101", &|| Ok(()))
                } else {
                    client.album_artist("USAA00000101", "Album", &|| Ok(()))
                }
            })
        })
        .collect();
    until(|| {
        client.inner.state.lock().unwrap().flights["USAA00000101"]
            .waiters
            .load(Ordering::Acquire)
            == 9
    });
    cancel.store(true, Ordering::Release);
    assert_eq!(
        first.join().unwrap(),
        Err(ResolverError::Cancelled("caller cancelled".into()))
    );
    assert_eq!(probe.cancelled.load(Ordering::Acquire), 0);
    assert_eq!(probe.calls.load(Ordering::Acquire), 1);
    probe.release.store(true, Ordering::Release);
    for (index, worker) in others.into_iter().enumerate() {
        assert_eq!(
            worker.join().unwrap().unwrap(),
            if index % 2 == 0 {
                "Rock"
            } else {
                "Example Artist"
            }
        );
    }
    assert_eq!(
        client
            .album_artist("USAA00000101", "Other", &|| Ok(()))
            .unwrap(),
        "Example Artist"
    );
    assert_eq!(probe.calls.load(Ordering::Acquire), 1);
}

#[test]
fn abandoned_flight_cannot_publish_over_its_replacement() {
    let probe = Arc::new(Probe::default());
    probe.hold_cancelled.store(true, Ordering::Release);
    let client = client(&probe);
    let cancel = Arc::new(AtomicBool::new(false));
    let first = {
        let (client, cancel) = (client.clone(), cancel.clone());
        thread::spawn(move || {
            client.genre("same", &|| {
                if cancel.load(Ordering::Acquire) {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            })
        })
    };
    until(|| probe.calls.load(Ordering::Acquire) == 1);
    cancel.store(true, Ordering::Release);
    assert!(first.join().unwrap().is_err());
    until(|| probe.cancelled.load(Ordering::Acquire) == 1);
    let second = {
        let client = client.clone();
        thread::spawn(move || client.genre("same", &|| Ok(())))
    };
    until(|| probe.calls.load(Ordering::Acquire) == 2);
    probe.release.store(true, Ordering::Release);
    assert_eq!(second.join().unwrap().unwrap(), "Rock");
    probe.hold_cancelled.store(false, Ordering::Release);
    until(|| client.inner.state.lock().unwrap().active == 0);
    assert_eq!(client.genre("same", &|| Ok(())).unwrap(), "Rock");
    assert_eq!(probe.calls.load(Ordering::Acquire), 2);
}

#[test]
fn fetch_failures_and_empty_recordings_are_cached_before_derived_getter_errors() {
    let probe = Arc::new(Probe::default());
    probe.release.store(true, Ordering::Release);
    probe.failure.store(true, Ordering::Release);
    let client = client(&probe);
    assert!(client.genre("failed", &|| Ok(())).is_err());
    probe.failure.store(false, Ordering::Release);
    assert!(client.album_artist("FAILED", "Album", &|| Ok(())).is_err());
    assert_eq!(probe.calls.load(Ordering::Acquire), 1);
    assert_eq!(
        client.genre("empty", &|| Ok(())).unwrap_err().to_string(),
        "no recordings found for ISRC: EMPTY"
    );
    assert_eq!(
        client
            .album_artist("empty", "Album", &|| Ok(()))
            .unwrap_err()
            .to_string(),
        "no MusicBrainz album artist found for ISRC: EMPTY"
    );
    assert_eq!(probe.calls.load(Ordering::Acquire), 2);
    assert_eq!(
        client.genre("", &|| Ok(())).unwrap_err().to_string(),
        "no ISRC provided"
    );
    assert_eq!(
        client
            .album_artist(" \t ", "Album", &|| Ok(()))
            .unwrap_err()
            .to_string(),
        "no ISRC provided"
    );
    assert_eq!(probe.calls.load(Ordering::Acquire), 2);
}

#[test]
fn shutdown_joins_workers_and_rejects_retained_cached_calls() {
    let probe = Arc::new(Probe::default());
    let client = client(&probe);
    let worker = {
        let client = client.clone();
        thread::spawn(move || client.genre("active", &|| Ok(())))
    };
    until(|| probe.calls.load(Ordering::Acquire) == 1);
    let started = Instant::now();
    client.shutdown();
    assert!(worker.join().unwrap().is_err());
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(probe.active.load(Ordering::Acquire), 0);
    assert!(client.inner.state.lock().unwrap().workers.is_empty());
    assert!(client.genre("active", &|| Ok(())).is_err());
    assert!(client.album_artist("", "Album", &|| Ok(())).is_err());
    client.shutdown();
}
