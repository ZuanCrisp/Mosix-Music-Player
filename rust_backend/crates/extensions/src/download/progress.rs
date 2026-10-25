use spotiflac_core::progress::{ItemTransferProgressReporter, ProgressRegistry};
use std::sync::Arc;

pub(crate) struct ItemProgressTarget {
    registry: Arc<ProgressRegistry>,
    id: String,
    track: bool,
}

impl ItemProgressTarget {
    pub fn new(registry: Arc<ProgressRegistry>, id: String, track: bool) -> Self {
        Self {
            registry,
            id,
            track,
        }
    }

    pub fn start(&self) {
        if !self.id.is_empty() {
            let _ = self.registry.downloading(&self.id);
        }
    }

    pub fn set(&self, progress: f64, bytes: u64, total: i64) {
        if self.track && !self.id.is_empty() {
            let _ = self
                .registry
                .set_progress(&self.id, progress, bytes as i64, total);
        }
    }

    pub fn initial(&self, bytes: u64, total: i64) {
        if total > 0 {
            self.set(bytes as f64 / total as f64, bytes, total);
        } else {
            self.received(bytes);
        }
    }

    pub fn received(&self, bytes: u64) {
        if self.track && !self.id.is_empty() && bytes > 0 {
            let _ = self.registry.set_received(&self.id, bytes as i64);
        }
    }

    pub fn reporter(&self, bytes: u64, total: i64) -> ItemTransferProgressReporter {
        ItemTransferProgressReporter::new(
            Arc::clone(&self.registry),
            if self.track { &self.id } else { "" },
            bytes as i64,
            total,
        )
    }
}
