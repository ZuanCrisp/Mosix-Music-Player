//! Pushed events that replace the mobile EventChannels: download progress
//! (kind 10, `DownloadProgressSubscription.swift`, Android
//! `MainActivityProgressStreams.kt:68-103`) and library scan progress
//! (kind 11, `MainActivityProgressStreams.kt:122-156`). Kind 13 log records
//! are pushed only while subscribed. Kind 12 inbound calls are always sent.

use crate::kind;
use crate::runtime::{self, Runtime};
use mornye_mobile::DownloadProgressSubscription;
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const DOWNLOAD_RETRY: Duration = Duration::from_millis(250);
const DOWNLOAD_WAIT_MS: i64 = 15_000;
const SCAN_INTERVAL: Duration = Duration::from_millis(400);

#[derive(Default)]
struct StreamState {
    /// Incremented on every start and stop; a loop exits once it differs.
    generation: u64,
    active: bool,
    /// Open download subscription, closed on stop to wake its long poll.
    connection: Option<Arc<DownloadProgressSubscription>>,
}

#[derive(Default)]
struct Stream {
    state: Mutex<StreamState>,
}

impl Stream {
    /// Returns the new generation, or `None` when already running.
    fn start(&self) -> Option<u64> {
        let mut state = self.state.lock().expect("stream state");
        if state.active {
            return None;
        }
        state.active = true;
        state.generation += 1;
        Some(state.generation)
    }

    fn stop(&self) {
        let connection = {
            let mut state = self.state.lock().expect("stream state");
            if !state.active {
                return;
            }
            state.active = false;
            state.generation += 1;
            state.connection.take()
        };
        if let Some(connection) = connection {
            connection.stop();
        }
    }

    fn is_current(&self, generation: u64) -> bool {
        self.state.lock().expect("stream state").generation == generation
    }

    /// Stores the connection unless the stream stopped meanwhile.
    fn attach(&self, generation: u64, connection: &Arc<DownloadProgressSubscription>) -> bool {
        let mut state = self.state.lock().expect("stream state");
        if state.generation != generation {
            drop(state);
            connection.stop();
            return false;
        }
        state.connection = Some(Arc::clone(connection));
        true
    }

    fn detach(&self, generation: u64) {
        let mut state = self.state.lock().expect("stream state");
        if state.generation == generation {
            state.connection = None;
        }
    }
}

#[derive(Default)]
pub(crate) struct Events {
    download: Stream,
    scan: Stream,
    logs: AtomicBool,
}

impl Events {
    pub(crate) fn logs_enabled(&self) -> bool {
        self.logs.load(Ordering::SeqCst)
    }
}

/// `mornye_subscribe`. Idempotent; unknown kinds are ignored.
pub(crate) fn subscribe(runtime: &'static Runtime, event: i32) {
    match event {
        kind::DOWNLOAD_PROGRESS => {
            if let Some(generation) = runtime.events.download.start() {
                spawn("mornye-download-progress", move || {
                    download_loop(runtime, generation)
                });
            }
        }
        kind::LIBRARY_SCAN_PROGRESS => {
            if let Some(generation) = runtime.events.scan.start() {
                spawn("mornye-scan-progress", move || {
                    scan_loop(runtime, generation)
                });
            }
        }
        kind::LOG => runtime.events.logs.store(true, Ordering::SeqCst),
        _ => {}
    }
}

/// `mornye_unsubscribe`. Idempotent; unknown kinds are ignored.
pub(crate) fn unsubscribe(runtime: &Runtime, event: i32) {
    match event {
        kind::DOWNLOAD_PROGRESS => runtime.events.download.stop(),
        kind::LIBRARY_SCAN_PROGRESS => runtime.events.scan.stop(),
        kind::LOG => runtime.events.logs.store(false, Ordering::SeqCst),
        _ => {}
    }
}

fn spawn(name: &str, body: impl FnOnce() + Send + 'static) {
    if let Err(error) = std::thread::Builder::new().name(name.into()).spawn(body) {
        runtime::log("error", &format!("Event thread could not start: {error}"));
    }
}

/// Each delta carries `seq`; the next wait resumes after the highest one.
fn download_loop(runtime: &Runtime, generation: u64) {
    let stream = &runtime.events.download;
    let mut sequence = 0i64;
    let mut last_payload: Option<String> = None;
    let mut connection: Option<Arc<DownloadProgressSubscription>> = None;
    while stream.is_current(generation) {
        let current = match &connection {
            Some(current) => Arc::clone(current),
            None => match runtime.backend.open_download_progress() {
                Ok(opened) => {
                    if !stream.attach(generation, &opened) {
                        return;
                    }
                    connection = Some(Arc::clone(&opened));
                    opened
                }
                Err(_) => {
                    // Not initialized yet, or shut down: retry quietly.
                    std::thread::sleep(DOWNLOAD_RETRY);
                    continue;
                }
            },
        };
        match current.wait_delta(sequence, DOWNLOAD_WAIT_MS) {
            Ok(payload) => {
                if !stream.is_current(generation) {
                    break;
                }
                if payload.is_empty() {
                    continue;
                }
                let delta = serde_json::from_str::<Value>(&payload).ok();
                let seq = delta
                    .as_ref()
                    .and_then(|delta| delta.get("seq"))
                    .and_then(Value::as_i64);
                let (Some(delta), Some(seq)) = (&delta, seq) else {
                    std::thread::sleep(DOWNLOAD_RETRY);
                    continue;
                };
                if last_payload.as_deref() == Some(payload.as_str()) {
                    std::thread::sleep(DOWNLOAD_RETRY);
                    continue;
                }
                // Android `updateDownloadProgressSeq`: a reset may lower it.
                if delta.get("reset") == Some(&Value::Bool(true)) || seq > sequence {
                    sequence = seq;
                }
                runtime::emit(0, kind::DOWNLOAD_PROGRESS, payload.clone().into_bytes());
                last_payload = Some(payload);
                std::thread::sleep(DOWNLOAD_RETRY);
            }
            Err(error) => {
                current.stop();
                connection = None;
                stream.detach(generation);
                if !stream.is_current(generation) {
                    break;
                }
                sequence = 0;
                last_payload = None;
                runtime::log(
                    "warn",
                    &format!("Download progress stream poll failed: {error}"),
                );
                std::thread::sleep(DOWNLOAD_RETRY);
            }
        }
    }
    if let Some(connection) = connection {
        connection.stop();
    }
}

/// Sends the current progress first, then each change.
fn scan_loop(runtime: &Runtime, generation: u64) {
    let stream = &runtime.events.scan;
    let mut last_payload: Option<String> = None;
    while stream.is_current(generation) {
        match runtime.backend.library_scan_progress() {
            Ok(payload) => {
                if last_payload.as_deref() != Some(payload.as_str())
                    && stream.is_current(generation)
                {
                    runtime::emit(0, kind::LIBRARY_SCAN_PROGRESS, payload.clone().into_bytes());
                    last_payload = Some(payload);
                }
            }
            Err(error) => runtime::log(
                "warn",
                &format!(
                    "Library scan progress stream poll failed: {}",
                    error.message
                ),
            ),
        }
        std::thread::sleep(SCAN_INTERVAL);
    }
}
