use super::segment_store::{SegmentFile, SegmentOutput};
use super::{DownloadOptions, Failure, header, next_delay, retryable, status_failure};
use crate::files::{ExtensionFiles, FilePath};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use spotiflac_network::{HttpRequest, NetworkSession};
use std::collections::BTreeMap;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
pub(crate) struct Segment {
    pub url: String,
    pub headers: BTreeMap<String, String>,
}

struct Completed {
    file: SegmentFile,
    size: u64,
    attempts: i64,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn download(
    files: &ExtensionFiles,
    path: &FilePath,
    network: &NetworkSession,
    segments: &[Segment],
    options: DownloadOptions,
    check: &(dyn Fn() -> Result<(), String> + Sync),
    progress: &mut dyn FnMut(u64, usize, usize),
) -> Result<serde_json::Value, Failure> {
    let _guard = files
        .lock(path, check)
        .map_err(|error| Failure::new("cancelled", error, 0))?;
    let mut hash = Sha256::new();
    for segment in segments {
        hash.update(segment.url.as_bytes());
        hash.update([0]);
    }
    let mut output = SegmentOutput::open(
        path,
        crate::binary::encode(&hash.finalize(), "hex").expect("hex encoding"),
        segments.len(),
        options.persistent,
    )
    .map_err(|error| {
        Failure::new(
            "storage_error",
            format!("failed to create segmented output: {error}"),
            0,
        )
    })?;
    let restored = output.next_index() == segments.len() && output.bytes() > 0;
    options.item.start();
    options.item.set(
        output.next_index() as f64 / segments.len() as f64,
        output.bytes(),
        0,
    );
    let reporter = options.item.reporter(output.bytes(), 0);
    if !restored {
        let mut next_job = output.next_index();
        let stop = AtomicBool::new(false);
        let completed = AtomicBool::new(false);
        let received = AtomicU64::new(output.bytes());
        let worker_count = (options.policy.max_parallel_segments as usize)
            .min(segments.len() - output.next_index());
        let mut first_failure = None;
        let mut pending = BTreeMap::new();
        let parent = std::sync::Arc::clone(&output.parent);
        let staged = output.staged.clone();
        let (jobs, job_receiver) = mpsc::sync_channel(worker_count);
        let job_receiver = Mutex::new(job_receiver);
        // Scoped workers cannot outlive the JS call, its cancellation lease, or
        // its directory capability. Only this VM thread invokes JS callbacks.
        thread::scope(|scope| {
            let (sender, receiver) = mpsc::sync_channel(worker_count);
            for _ in 0..worker_count {
                jobs.send(next_job).expect("segment workers not started");
                next_job += 1;
            }
            let mut jobs = (next_job < segments.len()).then_some(jobs);
            for _ in 0..worker_count {
                let sender = sender.clone();
                let parent = &parent;
                let staged = &staged;
                let job_receiver = &job_receiver;
                let stop = &stop;
                let received = &received;
                let completed = &completed;
                let options = &options;
                let reporter = &reporter;
                let spawned = thread::Builder::new()
                    .name("extension-segment".into())
                    .stack_size(2 << 20)
                    .spawn_scoped(scope, move || {
                        let check_worker = || {
                            check()?;
                            if stop.load(Ordering::Acquire) {
                                return Err("download cancelled".into());
                            }
                            Ok(())
                        };
                        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            loop {
                                if check_worker().is_err() {
                                    break;
                                }
                                let Ok(index) = job_receiver
                                    .lock()
                                    .unwrap_or_else(|error| error.into_inner())
                                    .recv()
                                else {
                                    break;
                                };
                                let segment = &segments[index];
                                let result = fetch(
                                    segment,
                                    index,
                                    parent,
                                    staged,
                                    network,
                                    options,
                                    received,
                                    completed,
                                    reporter,
                                    &check_worker,
                                );
                                let failed = result.is_err();
                                if sender.send((index, result)).is_err() || failed {
                                    break;
                                }
                            }
                        }));
                        if let Err(panic) = result {
                            let _ = sender.send((
                                usize::MAX,
                                Err(Failure::new("storage_error", "segment worker panicked", 0)),
                            ));
                            std::panic::resume_unwind(panic);
                        }
                    });
                if let Err(error) = spawned {
                    first_failure = Some(Failure::new(
                        "storage_error",
                        format!("failed to start segment worker: {error}"),
                        0,
                    ));
                    stop.store(true, Ordering::Release);
                    jobs.take();
                    break;
                }
            }
            drop(sender);
            loop {
                if let Err(error) = check() {
                    first_failure.get_or_insert_with(|| Failure::new("cancelled", error, 0));
                    stop.store(true, Ordering::Release);
                    jobs.take();
                }
                let (index, result) = match receiver.recv_timeout(Duration::from_millis(10)) {
                    Ok(result) => result,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                };
                match result {
                    Err(error) => {
                        first_failure.get_or_insert(error);
                        stop.store(true, Ordering::Release);
                        jobs.take();
                    }
                    Ok(result) => {
                        pending.insert(index, result);
                    }
                }
                while let Some(mut ready) = pending.remove(&output.next_index()) {
                    let index = output.next_index();
                    if let Err(error) = output.append(&mut ready.file, ready.size, check) {
                        first_failure.get_or_insert_with(|| {
                            Failure::new(
                                "storage_error",
                                format!("failed to append segment {index}: {error}"),
                                ready.attempts,
                            )
                        });
                        stop.store(true, Ordering::Release);
                        jobs.take();
                        break;
                    }
                    output.checkpoint(false);
                    drop(ready);
                    options.item.set(
                        output.next_index() as f64 / segments.len() as f64,
                        received.load(Ordering::Acquire),
                        0,
                    );
                    let _charge = options.budget.as_ref().map(|budget| budget.enter(true));
                    progress(
                        received.load(Ordering::Acquire),
                        output.next_index(),
                        segments.len(),
                    );
                    // Only assembly releases a slot: completed files and active
                    // requests together never exceed the worker count.
                    if let Some(sender) = &jobs {
                        if sender.send(next_job).is_err() {
                            jobs.take();
                        } else {
                            next_job += 1;
                            if next_job == segments.len() {
                                jobs.take();
                            }
                        }
                    }
                }
            }
        });
        if let Some(error) = first_failure {
            output.checkpoint(true);
            return Err(error);
        }
    }
    if output.next_index() != segments.len() || output.bytes() == 0 {
        return Err(Failure::new(
            "integrity_failed",
            format!(
                "segmented transfer incomplete: assembled {} of {} segments",
                output.next_index(),
                segments.len()
            ),
            0,
        ));
    }
    output.publish(check).map_err(|error| {
        Failure::new(
            "storage_error",
            format!("failed to publish segmented output: {error}"),
            0,
        )
    })?;
    options.item.set(1.0, output.bytes(), output.bytes() as i64);
    let mut result = serde_json::json!({"success":true,"path":path.display(),"size":output.bytes(),"segments":segments.len()});
    if restored {
        result["resumed"] = true.into();
    }
    Ok(result)
}

#[allow(clippy::too_many_arguments)]
fn fetch(
    segment: &Segment,
    index: usize,
    parent: &std::sync::Arc<cap_std::fs::Dir>,
    staged: &std::ffi::OsString,
    network: &NetworkSession,
    options: &DownloadOptions,
    received: &AtomicU64,
    completed: &AtomicBool,
    reporter: &spotiflac_core::progress::ItemTransferProgressReporter,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Completed, Failure> {
    let mut delay = Duration::from_millis(options.policy.initial_retry_delay_ms as u64);
    for attempt in 1..=options.policy.max_attempts {
        check().map_err(|error| Failure::new("cancelled", error, attempt))?;
        let mut file = SegmentFile::open(parent, staged, index).map_err(|error| {
            Failure::new(
                "storage_error",
                format!("failed to create segment file: {error}"),
                attempt,
            )
        })?;
        let continuation = attempt == 1 && completed.load(Ordering::Acquire);
        let charge = options
            .budget
            .as_ref()
            .map(|budget| budget.enter(!continuation));
        let stream = network.open_stream(
            HttpRequest {
                url: segment.url.clone(),
                method: "GET".into(),
                body: String::new(),
                headers: segment.headers.clone(),
                default_json: false,
                user_agent: options.app_version.user_agent(),
            },
            Duration::from_secs(24 * 60 * 60),
            Duration::from_secs(60),
            check,
        );
        drop(charge);
        let mut failure = match stream {
            Err(error) => Failure::new("transient_network", error, attempt),
            Ok(mut stream) => {
                let status = stream.response.status;
                if !(200..300).contains(&status) {
                    let mut failure = status_failure(&stream.response, &options.policy, attempt);
                    failure.error = format!("segment {index} HTTP error: {status}");
                    stream.discard(check);
                    if !retryable(status) || attempt == options.policy.max_attempts {
                        return Err(failure);
                    }
                    failure
                } else {
                    let expected = header(&stream.response, "Content-Length")
                        .parse::<i64>()
                        .unwrap_or(-1);
                    let mut size = 0;
                    let mut buffer = [0; 64 << 10];
                    let result = loop {
                        let charge = options.budget.as_ref().map(|budget| {
                            budget
                                .enter(!matches!(status, 200 | 206) || (size == 0 && !continuation))
                        });
                        let read = stream.read(&mut buffer, check);
                        drop(charge);
                        match read {
                            Ok(0) => break Ok(()),
                            Ok(count) => {
                                if let Err(error) = file.file.write_all(&buffer[..count]) {
                                    break Err(error.to_string());
                                }
                                size += count as u64;
                                received.fetch_add(count as u64, Ordering::AcqRel);
                                reporter.report(received.load(Ordering::Acquire) as i64, 0);
                            }
                            Err(error) => break Err(error),
                        }
                    };
                    let result = result.and_then(|()| {
                        if expected > 0 && size != expected as u64 {
                            Err("unexpected EOF".into())
                        } else {
                            Ok(())
                        }
                    });
                    if result.is_ok() && size > 0 {
                        completed.store(true, Ordering::Release);
                        return Ok(Completed {
                            file,
                            size,
                            attempts: attempt,
                        });
                    }
                    received.fetch_sub(size, Ordering::AcqRel);
                    let message = result.err().map_or_else(
                        || format!("segment {index} response was empty"),
                        |error| format!("failed to read segment {index}: {error}"),
                    );
                    Failure::new("transient_network", message, attempt)
                }
            }
        };
        drop(file);
        if let Err(error) = check() {
            failure = Failure::new("cancelled", error, attempt);
        }
        if attempt == options.policy.max_attempts || failure.error_type == "cancelled" {
            return Err(failure);
        }
        let retry = if failure.retry_after_seconds > 0 {
            Duration::from_secs(failure.retry_after_seconds.into())
        } else {
            delay
        };
        let _charge = options.budget.as_ref().map(|budget| budget.enter(true));
        let began = Instant::now();
        while began.elapsed() < retry {
            check().map_err(|error| Failure::new("cancelled", error, attempt))?;
            thread::sleep(
                retry
                    .saturating_sub(began.elapsed())
                    .min(Duration::from_millis(10)),
            );
        }
        delay = next_delay(delay, &options.policy);
    }
    unreachable!("policy has at least one attempt")
}
