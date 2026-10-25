use super::{ProgressRegistry, UPDATE_BYTES};
use crate::cancellation::CancellationRegistry;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct ItemTransferProgressReporter {
    progress: Arc<ProgressRegistry>,
    id: String,
    state: Mutex<ReportState>,
}

struct ReportState {
    received: i64,
    total: i64,
    at: Instant,
}

impl ItemTransferProgressReporter {
    pub fn new(progress: Arc<ProgressRegistry>, id: &str, received: i64, total: i64) -> Self {
        Self {
            progress,
            id: id.to_owned(),
            state: Mutex::new(ReportState {
                received,
                total,
                at: Instant::now(),
            }),
        }
    }

    pub fn report(&self, received: i64, total: i64) {
        self.report_at(received, total, Instant::now());
    }

    fn report_at(&self, received: i64, total: i64, now: Instant) {
        if self.id.is_empty() {
            return;
        }
        let mut state = self.state.lock().expect("progress reporter lock");
        let delta = received.wrapping_sub(state.received);
        if (0..UPDATE_BYTES).contains(&delta)
            && total == state.total
            && now.saturating_duration_since(state.at) < Duration::from_millis(250)
        {
            return;
        }
        *state = ReportState {
            received,
            total,
            at: now,
        };
        if total > 0 {
            let _ = self.progress.set_progress(
                &self.id,
                received as f64 / total as f64,
                received,
                total,
            );
        } else {
            let _ = self.progress.set_received(&self.id, received);
        }
    }
}

/// Adapter for media writers. Network transfer reporters deliberately do not
/// synthesize speed: the existing Go writer owns that separate behavior.
pub struct ItemProgressWriter<W> {
    writer: W,
    id: String,
    progress: Arc<ProgressRegistry>,
    cancellation: Arc<CancellationRegistry>,
    current: i64,
    last_reported: i64,
    last_time: Instant,
    last_bytes: i64,
}

impl<W> ItemProgressWriter<W> {
    pub fn new(
        writer: W,
        id: &str,
        progress: Arc<ProgressRegistry>,
        cancellation: Arc<CancellationRegistry>,
    ) -> Self {
        Self {
            writer,
            id: id.to_owned(),
            progress,
            cancellation,
            current: 0,
            last_reported: 0,
            last_time: Instant::now(),
            last_bytes: 0,
        }
    }

    pub fn into_inner(self) -> W {
        self.writer
    }
}

impl<W: Write> Write for ItemProgressWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if !self.id.is_empty() {
            match self.cancellation.is_cancelled(&self.id) {
                Ok(true) => return Err(io::Error::other("download cancelled")),
                Err(error) => return Err(io::Error::other(error)),
                Ok(false) => {}
            }
        }
        let count = self.writer.write(bytes)?;
        self.current = self.current.wrapping_add(count as i64);
        if self.last_reported == 0 || self.current.wrapping_sub(self.last_reported) >= UPDATE_BYTES
        {
            let now = Instant::now();
            let elapsed = now.saturating_duration_since(self.last_time).as_secs_f64();
            let speed = if elapsed > 0.0 {
                self.current.wrapping_sub(self.last_bytes) as f64 / (1024.0 * 1024.0) / elapsed
            } else {
                0.0
            };
            let _ = self
                .progress
                .set_received_with_speed(&self.id, self.current, speed);
            self.last_reported = self.current;
            self.last_bytes = self.current;
            self.last_time = now;
        }
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coalescing_flushes_threshold_interval_total_changes_and_rollbacks() {
        let progress = Arc::new(ProgressRegistry::new());
        progress.start("example").unwrap();
        let reporter =
            ItemTransferProgressReporter::new(Arc::clone(&progress), "example", 0, 1 << 20);
        let now = reporter.state.lock().unwrap().at;
        let received = || {
            serde_json::from_str::<serde_json::Value>(&progress.item("example").unwrap()).unwrap()["bytes_received"].as_i64().unwrap()
        };
        reporter.report_at(65536, 1 << 20, now);
        assert_eq!(received(), 0);
        reporter.report_at(UPDATE_BYTES, 1 << 20, now);
        assert_eq!(received(), UPDATE_BYTES);
        reporter.report_at(UPDATE_BYTES + 1, 1 << 20, now + Duration::from_millis(250));
        assert_eq!(received(), UPDATE_BYTES + 1);
        reporter.report_at(UPDATE_BYTES + 2, 2 << 20, now + Duration::from_millis(250));
        assert_eq!(received(), UPDATE_BYTES + 2);
        reporter.report_at(1, 2 << 20, now + Duration::from_millis(250));
        assert_eq!(received(), 1);
    }
}
