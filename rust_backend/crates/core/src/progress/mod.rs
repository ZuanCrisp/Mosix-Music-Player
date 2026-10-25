//! Go-compatible sparse download progress, shared by every native consumer.

mod reporter;
mod subscription;

pub use reporter::{ItemProgressWriter, ItemTransferProgressReporter};
pub use subscription::ProgressSubscription;

use serde::Serialize;
use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Condvar, Mutex};

pub const UPDATE_BYTES: i64 = 128 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ItemProgress {
    pub item_id: String,
    pub bytes_total: i64,
    pub bytes_received: i64,
    pub progress: f64,
    pub speed_mbps: f64,
    pub is_downloading: bool,
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub stage: String,
    #[serde(skip)]
    revision: i64,
}

#[derive(PartialEq)]
struct BridgeState {
    bytes_bucket: i64,
    total: i64,
    percent: i64,
    speed_tenths: i64,
    downloading: bool,
    status: String,
    stage: String,
}

impl ItemProgress {
    fn bridge(&self) -> BridgeState {
        let progress = if self.progress.is_nan() || self.progress <= 0.0 {
            0.0
        } else {
            self.progress.min(1.0)
        };
        let speed = if self.speed_mbps.is_nan() || self.speed_mbps <= 0.0 {
            0.0
        } else {
            self.speed_mbps
        };
        BridgeState {
            bytes_bucket: self.bytes_received / UPDATE_BYTES,
            total: self.bytes_total,
            percent: (progress * 100.0).round() as i64,
            speed_tenths: rounded_speed(speed * 10.0),
            downloading: self.is_downloading,
            status: self.status.clone(),
            stage: self.stage.clone(),
        }
    }

    fn finite(&self) -> bool {
        self.progress.is_finite() && self.speed_mbps.is_finite()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProgressError {
    Closed,
    SubscriptionClosed,
}

impl fmt::Display for ProgressError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Closed => "download progress registry closed",
            Self::SubscriptionClosed => "download progress subscription closed",
        })
    }
}

impl std::error::Error for ProgressError {}

struct State {
    items: BTreeMap<String, ItemProgress>,
    removed: BTreeMap<String, i64>,
    seq: i64,
    reset: i64,
    dirty: bool,
    cached: String,
    closed: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            items: BTreeMap::new(),
            removed: BTreeMap::new(),
            seq: 0,
            reset: 0,
            dirty: true,
            cached: "{\"items\":{}}".into(),
            closed: false,
        }
    }
}

impl State {
    fn check(&self) -> Result<(), ProgressError> {
        if self.closed {
            Err(ProgressError::Closed)
        } else {
            Ok(())
        }
    }

    fn next(&mut self, changed: &Condvar) -> i64 {
        let seq = self.advance();
        changed.notify_all();
        seq
    }

    fn advance(&mut self) -> i64 {
        self.seq = self.seq.wrapping_add(1);
        self.dirty = true;
        self.seq
    }

    fn delta(&self, since: i64) -> String {
        if since >= self.seq {
            return String::new();
        }
        #[derive(Serialize)]
        struct Delta<'a> {
            seq: i64,
            #[serde(skip_serializing_if = "std::ops::Not::not")]
            reset: bool,
            #[serde(skip_serializing_if = "BTreeMap::is_empty")]
            items: BTreeMap<&'a String, &'a ItemProgress>,
            #[serde(skip_serializing_if = "Vec::is_empty")]
            removed: Vec<&'a String>,
        }
        let reset = since <= 0 || since < self.reset;
        let items: BTreeMap<_, _> = self
            .items
            .iter()
            .filter(|(_, item)| reset || item.revision > since)
            .collect();
        // serde_json represents non-finite floats as null; encoding/json fails
        // the whole document instead. Preserve Go's empty/fallback responses.
        if items.values().any(|item| !item.finite()) {
            return String::new();
        }
        let removed = if reset {
            Vec::new()
        } else {
            self.removed
                .iter()
                .filter(|(_, revision)| **revision > since)
                .map(|(id, _)| id)
                .collect()
        };
        serde_json::to_string(&Delta {
            seq: self.seq,
            reset,
            items,
            removed,
        })
        .unwrap_or_default()
    }
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Default)]
pub struct ProgressRegistry {
    shared: Arc<Shared>,
}

impl ProgressRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start(&self, id: &str) -> Result<(), ProgressError> {
        let mut state = self.shared.state.lock().expect("progress state lock");
        state.check()?;
        let revision = state.next(&self.shared.changed);
        state.items.insert(
            id.to_owned(),
            ItemProgress {
                item_id: id.to_owned(),
                bytes_total: 0,
                bytes_received: 0,
                progress: 0.0,
                speed_mbps: 0.0,
                is_downloading: false,
                status: "preparing".into(),
                stage: String::new(),
                revision,
            },
        );
        state.removed.remove(id);
        Ok(())
    }

    fn update(
        &self,
        id: &str,
        update: impl FnOnce(&mut ItemProgress),
    ) -> Result<(), ProgressError> {
        let mut state = self.shared.state.lock().expect("progress state lock");
        state.check()?;
        if let Some(item) = state.items.get_mut(id) {
            let before = item.bridge();
            update(item);
            if item.bridge() != before {
                let revision = state.next(&self.shared.changed);
                state.items.get_mut(id).expect("existing progress").revision = revision;
            }
        }
        Ok(())
    }

    pub fn preparing(&self, id: &str, stage: &str) -> Result<(), ProgressError> {
        self.update(id, |item| {
            item.progress = 0.0;
            item.bytes_received = 0;
            item.bytes_total = 0;
            item.speed_mbps = 0.0;
            item.is_downloading = true;
            item.status = "preparing".into();
            item.stage = stage.to_owned();
        })
    }

    pub fn downloading(&self, id: &str) -> Result<(), ProgressError> {
        self.update(id, mark_downloading)
    }

    pub fn set_received(&self, id: &str, received: i64) -> Result<(), ProgressError> {
        self.update(id, |item| set_received(item, received))
    }

    pub fn set_received_with_speed(
        &self,
        id: &str,
        received: i64,
        speed: f64,
    ) -> Result<(), ProgressError> {
        self.update(id, |item| {
            item.speed_mbps = speed;
            set_received(item, received);
        })
    }

    pub fn set_progress(
        &self,
        id: &str,
        progress: f64,
        received: i64,
        total: i64,
    ) -> Result<(), ProgressError> {
        self.update(id, |item| {
            let has_bytes = received > 0 || total > 0;
            item.progress = if item.status != "preparing" || has_bytes || progress >= 1.0 {
                progress
            } else {
                0.0
            };
            if received > 0 {
                item.bytes_received = received;
            }
            if total > 0 {
                item.bytes_total = total;
            }
            if has_bytes || progress >= 1.0 || item.status == "downloading" {
                mark_downloading(item);
            }
        })
    }

    pub fn finalizing(&self, id: &str) -> Result<(), ProgressError> {
        self.update(id, |item| {
            item.progress = 1.0;
            item.status = "finalizing".into();
            item.stage.clear();
        })
    }

    pub fn complete(&self, id: &str) -> Result<(), ProgressError> {
        self.update(id, |item| {
            item.progress = 1.0;
            item.is_downloading = false;
            item.status = "completed".into();
            item.stage.clear();
        })
    }

    pub fn remove(&self, id: &str) -> Result<(), ProgressError> {
        self.remove_many(std::iter::once(id))
    }

    pub fn remove_many<'a>(
        &self,
        ids: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), ProgressError> {
        let mut state = self.shared.state.lock().expect("progress state lock");
        state.check()?;
        let mut changed = false;
        for id in ids {
            if state.items.remove(id).is_some() {
                let seq = state.advance();
                state.removed.insert(id.to_owned(), seq);
                if state.removed.len() > 512 {
                    let mut revisions: Vec<_> = state.removed.values().copied().collect();
                    revisions.sort_unstable();
                    let cutoff = revisions[revisions.len() / 2];
                    state.removed.retain(|_, revision| *revision > cutoff);
                    state.reset = state.reset.max(cutoff);
                }
                changed = true;
            }
            // Even removing a missing ID invalidates the snapshot cache in Go.
            state.dirty = true;
        }
        drop(state);
        if changed {
            self.shared.changed.notify_all();
        }
        Ok(())
    }

    pub fn item(&self, id: &str) -> Result<String, ProgressError> {
        let state = self.shared.state.lock().expect("progress state lock");
        state.check()?;
        Ok(match state.items.get(id) {
            Some(item) if item.finite() => serde_json::to_string(item).unwrap_or_default(),
            Some(_) => String::new(),
            None => "{}".into(),
        })
    }

    pub fn snapshot(&self) -> Result<String, ProgressError> {
        let mut state = self.shared.state.lock().expect("progress state lock");
        state.check()?;
        if state.dirty {
            if state.items.values().any(|item| !item.finite()) {
                return Ok("{\"items\":{}}".into());
            }
            #[derive(Serialize)]
            struct Snapshot<'a> {
                items: &'a BTreeMap<String, ItemProgress>,
            }
            state.cached = serde_json::to_string(&Snapshot {
                items: &state.items,
            })
            .expect("finite progress JSON");
            state.dirty = false;
        }
        Ok(state.cached.clone())
    }

    pub fn subscribe(&self) -> Result<ProgressSubscription, ProgressError> {
        self.shared
            .state
            .lock()
            .expect("progress state lock")
            .check()?;
        Ok(ProgressSubscription::new(Arc::clone(&self.shared)))
    }

    pub fn wait_delta(&self, since: i64, timeout_ms: i64) -> Result<String, ProgressError> {
        self.subscribe()?.wait_delta(since, timeout_ms)
    }

    pub fn shutdown(&self) {
        let mut state = self.shared.state.lock().expect("progress state lock");
        state.closed = true;
        state.items.clear();
        state.removed.clear();
        state.cached.clear();
        self.shared.changed.notify_all();
    }
}

impl Drop for ProgressRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn mark_downloading(item: &mut ItemProgress) {
    item.is_downloading = true;
    item.status = "downloading".into();
    item.stage.clear();
}

fn set_received(item: &mut ItemProgress, received: i64) {
    item.bytes_received = received;
    if item.bytes_total > 0 {
        item.progress = received as f64 / item.bytes_total as f64;
    }
    if received > 0 {
        mark_downloading(item);
    }
}

fn rounded_speed(value: f64) -> i64 {
    let value = value.round();
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    if value >= 9_223_372_036_854_775_808.0 {
        return i64::MIN;
    }
    #[cfg(target_arch = "arm")]
    if value >= 18_446_744_073_709_551_616.0 || !value.is_finite() {
        // Go ARM32's int64 conversion delegates out-of-range values to _d2v.
        return (u64::from(value as u32) << 32) as i64;
    } else if value >= 9_223_372_036_854_775_808.0 {
        return value as u64 as i64;
    }
    value as i64
}

#[cfg(test)]
mod batch_tests {
    use super::*;
    use serde_json::{Value, json};

    #[test]
    fn batch_removal_preserves_revisions_tombstones_and_cached_survivors() {
        let registry = ProgressRegistry::new();
        for id in ["a", "b", "keep", ""] {
            registry.start(id).unwrap();
        }
        registry.set_progress("keep", 0.5, 20, 40).unwrap();
        let before: Value = serde_json::from_str(&registry.snapshot().unwrap()).unwrap();
        let seq = registry.shared.state.lock().unwrap().seq;
        registry
            .remove_many(["a", "b", "a", "missing", ""])
            .unwrap();
        let after: Value = serde_json::from_str(&registry.snapshot().unwrap()).unwrap();
        assert_eq!(after, json!({"items": {"keep": before["items"]["keep"]}}));
        let delta: Value = serde_json::from_str(&registry.wait_delta(seq, 1).unwrap()).unwrap();
        assert_eq!(delta, json!({"seq":seq + 3, "removed":["", "a", "b"]}));
        registry.remove_many(["a", "missing"]).unwrap();
        assert_eq!(registry.shared.state.lock().unwrap().seq, seq + 3);
        registry.start("a").unwrap();
        let delta: Value = serde_json::from_str(&registry.wait_delta(seq, 1).unwrap()).unwrap();
        assert_eq!(delta["removed"], json!(["", "b"]));
        assert_eq!(delta["items"]["a"]["status"], "preparing");
    }

    #[test]
    fn pruning_resets_old_cursors_and_retains_newer_removals() {
        let registry = ProgressRegistry::new();
        let ids: Vec<_> = (0..514).map(|i| format!("item-{i:04}")).collect();
        for id in &ids {
            registry.start(id).unwrap();
        }
        registry
            .remove_many(ids.iter().take(513).map(String::as_str))
            .unwrap();
        let state = registry.shared.state.lock().unwrap();
        assert_eq!(state.seq, 1027);
        assert_eq!(state.reset, 771);
        assert_eq!(state.removed.len(), 256);
        let older: Value = serde_json::from_str(&state.delta(770)).unwrap();
        assert_eq!(older["reset"], true);
        assert_eq!(
            older["items"]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            [&ids[513]]
        );
        let newer: Value = serde_json::from_str(&state.delta(771)).unwrap();
        assert_eq!(newer["removed"], json!(ids[257..513]));
        assert!(newer.get("reset").is_none());
    }

    #[test]
    fn batch_wakes_subscribers_and_closed_registry_rejects_empty_batch() {
        let registry = Arc::new(ProgressRegistry::new());
        registry.start("a").unwrap();
        registry.start("b").unwrap();
        let listener = registry.subscribe().unwrap();
        let waiting = std::thread::spawn(move || listener.wait_delta(2, 1000).unwrap());
        registry.remove_many(["a", "b"]).unwrap();
        let delta: Value = serde_json::from_str(&waiting.join().unwrap()).unwrap();
        assert_eq!(delta, json!({"seq":4,"removed":["a","b"]}));
        registry.shutdown();
        assert_eq!(registry.remove_many([]), Err(ProgressError::Closed));
    }
}
