//! Go-compatible successful-lyrics cache with bounded, atomic persistence.

use serde::{Deserialize, Serialize};
use spotiflac_core::lyrics::LyricsResponse;
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const MAX_ENTRIES: usize = 500;
pub const TTL: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_PERSISTED_BYTES: u64 = 64 << 20;
const SNAPSHOT_VERSION: u32 = 5;

#[derive(Clone)]
struct Entry {
    response: Arc<LyricsResponse>,
    expires_at: SystemTime,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct Snapshot {
    version: u32,
    entries: BTreeMap<String, PersistedEntry>,
}

#[derive(Deserialize, Serialize)]
struct PersistedEntry {
    response: Option<LyricsResponse>,
    expires_at: i64,
}

#[derive(Default)]
struct State {
    entries: BTreeMap<String, Entry>,
    path: Option<PathBuf>,
    pending: Option<(PathBuf, BTreeMap<String, Entry>)>,
    writing: bool,
    flush: bool,
    error: Option<String>,
}

#[derive(Default)]
struct Inner {
    state: Mutex<State>,
    ready: Condvar,
}

#[derive(Default)]
pub struct LyricsCache {
    inner: Arc<Inner>,
}

fn clone_response(response: &LyricsResponse) -> LyricsResponse {
    let mut result = response.clone();
    // append([]LyricsLine(nil), empty...) in Go collapses [] to null.
    if result.lines().is_empty() {
        result.lines = None;
    }
    result
}

impl LyricsCache {
    pub fn get(&self, key: &str, now: SystemTime) -> Option<LyricsResponse> {
        let state = self.inner.state.lock().expect("lyrics cache lock");
        state
            .entries
            .get(key)
            .filter(|entry| now <= entry.expires_at)
            .map(|entry| clone_response(&entry.response))
    }

    pub fn set(&self, key: String, response: &LyricsResponse, now: SystemTime) {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        if state.entries.len() >= MAX_ENTRIES {
            state.entries.retain(|_, entry| now <= entry.expires_at);
            while state.entries.len() >= MAX_ENTRIES {
                let oldest = state
                    .entries
                    .iter()
                    .min_by_key(|(_, entry)| entry.expires_at)
                    .map(|(key, _)| key.clone())
                    .expect("full lyrics cache");
                state.entries.remove(&oldest);
            }
        }
        state.entries.insert(
            key,
            Entry {
                response: Arc::new(clone_response(response)),
                expires_at: now + TTL,
            },
        );
        self.schedule(&mut state);
    }

    pub fn len(&self) -> usize {
        self.inner
            .state
            .lock()
            .expect("lyrics cache lock")
            .entries
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn clear(&self) -> usize {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        let count = state.entries.len();
        state.entries.clear();
        self.schedule(&mut state);
        count
    }

    /// Retain the pending disk snapshot even if memory pressure arrives during
    /// the debounce window. A later process can still restore successful data.
    pub fn drop_memory(&self) -> usize {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        let count = state.entries.len();
        state.entries.clear();
        count
    }

    /// The path must come from the native application's private cache directory.
    /// Missing, invalid or expired files are ignored, matching Go restoration.
    pub fn set_persistence_path(&self, path: &Path, now: SystemTime) {
        if path.as_os_str().is_empty() || path == Path::new(".") {
            return;
        }
        let loaded = read_snapshot(path).unwrap_or_default();
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        state.path = Some(path.to_owned());
        if (1..=SNAPSHOT_VERSION).contains(&loaded.version) {
            for (key, entry) in loaded.entries {
                if state.entries.len() >= MAX_ENTRIES {
                    break;
                }
                let Some(response) = entry.response else {
                    continue;
                };
                // Older versions lost Apple supplements or collapsed group vocals
                // into the second singer instead of preserving the vocal side.
                // Refetch once, preserving other providers' caches.
                if loaded.version < SNAPSHOT_VERSION && response.provider == "Apple Music" {
                    continue;
                }
                let Some(expires_at) = u64::try_from(entry.expires_at)
                    .ok()
                    .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
                else {
                    continue;
                };
                if now < expires_at {
                    state.entries.entry(key).or_insert_with(|| Entry {
                        response: Arc::new(clone_response(&response)),
                        expires_at,
                    });
                }
            }
        }
        if state.pending.is_some() {
            self.schedule(&mut state);
        }
    }

    /// Flush the last scheduled snapshot and report any persistence error.
    pub fn flush(&self) -> Result<(), String> {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        state.flush = true;
        self.inner.ready.notify_all();
        while state.writing {
            state = self.inner.ready.wait(state).expect("lyrics cache lock");
        }
        state.flush = false;
        state.error.clone().map_or(Ok(()), Err)
    }

    fn schedule(&self, state: &mut State) {
        let Some(path) = state.path.clone() else {
            return;
        };
        // Share immutable response bodies across the pending snapshot; writes
        // during the debounce window must not copy every track's lyrics again.
        state.pending = Some((path, state.entries.clone()));
        if state.writing {
            return;
        }
        state.writing = true;
        let inner = Arc::clone(&self.inner);
        if let Err(error) = std::thread::Builder::new()
            .name("lyrics-cache".into())
            .spawn(move || persist(inner))
        {
            state.writing = false;
            state.error = Some(error.to_string());
        }
    }
}

impl Drop for LyricsCache {
    fn drop(&mut self) {
        let _ = self.flush();
    }
}

fn read_snapshot(path: &Path) -> Option<Snapshot> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_PERSISTED_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_PERSISTED_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_PERSISTED_BYTES {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

fn persist(inner: Arc<Inner>) {
    let mut delay = Duration::from_millis(500);
    let mut state = inner.state.lock().expect("lyrics cache lock");
    loop {
        state = inner
            .ready
            .wait_timeout_while(state, delay, |state| !state.flush)
            .expect("lyrics cache lock")
            .0;
        let Some((path, snapshot)) = state.pending.take() else {
            break;
        };
        drop(state);
        let result = write_snapshot(&path, &snapshot);
        state = inner.state.lock().expect("lyrics cache lock");
        state.error = result.err().map(|error| error.to_string());
        if state.pending.is_none() {
            break;
        }
        delay = Duration::from_millis(100);
    }
    state.writing = false;
    inner.ready.notify_all();
}

fn write_snapshot(path: &Path, entries: &BTreeMap<String, Entry>) -> std::io::Result<()> {
    #[derive(Serialize)]
    struct BorrowedEntry<'a> {
        response: &'a LyricsResponse,
        expires_at: i64,
    }
    #[derive(Serialize)]
    struct BorrowedSnapshot<'a> {
        version: u32,
        entries: BTreeMap<&'a str, BorrowedEntry<'a>>,
    }
    let snapshot = BorrowedSnapshot {
        version: SNAPSHOT_VERSION,
        entries: entries
            .iter()
            .map(|(key, entry)| {
                (
                    key.as_str(),
                    BorrowedEntry {
                        response: &entry.response,
                        expires_at: entry
                            .expires_at
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs() as i64,
                    },
                )
            })
            .collect(),
    };
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let bytes = serde_json::to_vec(&snapshot)?;
    if bytes.len() as u64 > MAX_PERSISTED_BYTES {
        return Err(std::io::Error::other(
            "lyrics cache exceeds persistence size limit",
        ));
    }
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(&bytes)?;
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|error| error.error)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_snapshot_refetches_apple_but_preserves_other_providers() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let apple = LyricsResponse::from_text("[00:01.00]Original", "Apple Music", "Apple Music");
        let other = LyricsResponse::from_text("[00:01.00]Original", "LRCLIB", "LRCLIB");
        for version in 1..SNAPSHOT_VERSION {
            let snapshot = serde_json::json!({"version": version, "entries": {
                "apple": {"response": apple, "expires_at": 200},
                "other": {"response": other, "expires_at": 200}
            }});
            fs::write(file.path(), serde_json::to_vec(&snapshot).unwrap()).unwrap();
            let cache = LyricsCache::default();
            cache.set_persistence_path(file.path(), now);
            assert!(cache.get("apple", now).is_none());
            assert_eq!(cache.get("other", now).unwrap().provider, "LRCLIB");
        }
    }

    #[test]
    fn current_snapshot_restores_supplementary_text() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let mut lyrics =
            LyricsResponse::from_text("[00:01.009]Original", "Apple Music", "Apple Music");
        let line = &mut lyrics.lines.as_mut().unwrap()[0];
        line.romanization = Some("Romanized".into());
        line.romanization_words = Some(vec![spotiflac_core::lyrics::LyricsWord {
            text: "Romanized".into(),
            start_time_ms: 1009,
            end_time_ms: 1307,
        }]);
        line.translation = Some("English".into());
        let entries = BTreeMap::from([(
            "apple".into(),
            Entry {
                response: Arc::new(lyrics.clone()),
                expires_at: now + Duration::from_secs(100),
            },
        )]);
        write_snapshot(file.path(), &entries).unwrap();
        let cache = LyricsCache::default();
        cache.set_persistence_path(file.path(), now);
        assert_eq!(cache.get("apple", now), Some(lyrics));
    }
}
