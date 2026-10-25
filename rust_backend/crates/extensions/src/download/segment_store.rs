use super::store::{private_options, remove_if_present};
use crate::files::FilePath;
use cap_std::fs::{Dir, File};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct Checkpoint {
    version: i64,
    fingerprint: String,
    next_index: usize,
    bytes: u64,
    updated_at: u64,
}

pub(super) struct SegmentOutput {
    pub parent: Arc<Dir>,
    target: OsString,
    pub staged: OsString,
    checkpoint: OsString,
    file: File,
    state: Checkpoint,
    keep: bool,
    promoted: bool,
    saved_bytes: u64,
    saved_at: Instant,
    segments: usize,
}

impl SegmentOutput {
    pub fn open(
        path: &FilePath,
        fingerprint: String,
        segments: usize,
        keep: bool,
    ) -> io::Result<Self> {
        let (parent, target) = path.open_parent()?;
        let mut staged = target.clone();
        staged.push(".partial");
        let mut checkpoint = staged.clone();
        checkpoint.push(".checkpoint.json.segments");
        for name in [&staged, &checkpoint] {
            match parent.symlink_metadata(name) {
                Ok(info) if !info.is_file() => {
                    return Err(io::Error::other(
                        "download staging path is not a regular file",
                    ));
                }
                Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
        }
        let state = keep
            .then(|| {
                let file = parent
                    .open_with(&checkpoint, private_options().read(true))
                    .ok()?;
                let mut bytes = Vec::new();
                file.take((1 << 20) + 1).read_to_end(&mut bytes).ok()?;
                if bytes.len() > 1 << 20 {
                    return None;
                }
                let state: Checkpoint = serde_json::from_slice(&bytes).ok()?;
                (state.version == 1
                    && state.fingerprint == fingerprint
                    && state.next_index <= segments
                    && (state.next_index == 0) == (state.bytes == 0))
                    .then_some(state)
            })
            .flatten();
        if state.is_none() {
            remove_if_present(&parent, &staged)?;
            remove_if_present(&parent, &checkpoint)?;
        }
        let mut file = parent.open_with(
            &staged,
            private_options().read(true).write(true).create(true),
        )?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(io::Error::other(
                "download staging path is not a regular file",
            ));
        }
        // A short file loses segment boundaries; the whole assembled prefix
        // must be discarded instead of clamping its byte count.
        let state = state
            .filter(|state| metadata.len() >= state.bytes)
            .unwrap_or_else(|| Checkpoint {
                fingerprint,
                ..Checkpoint::default()
            });
        if state.next_index == 0 {
            remove_if_present(&parent, &checkpoint)?;
        }
        file.set_len(state.bytes)?;
        file.seek(SeekFrom::Start(state.bytes))?;
        Ok(Self {
            parent: Arc::new(parent),
            target,
            staged,
            checkpoint,
            file,
            saved_bytes: state.bytes,
            state,
            keep,
            promoted: false,
            saved_at: Instant::now(),
            segments,
        })
    }

    pub fn next_index(&self) -> usize {
        self.state.next_index
    }

    pub fn bytes(&self) -> u64 {
        self.state.bytes
    }

    pub fn append(
        &mut self,
        segment: &mut SegmentFile,
        size: u64,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        segment
            .file
            .seek(SeekFrom::Start(0))
            .map_err(|error| error.to_string())?;
        let mut buffer = [0; 128 << 10];
        let mut copied = 0;
        let result = (|| {
            loop {
                check()?;
                let count = segment
                    .file
                    .read(&mut buffer)
                    .map_err(|error| error.to_string())?;
                if count == 0 {
                    break;
                }
                self.file
                    .write_all(&buffer[..count])
                    .map_err(|error| error.to_string())?;
                copied += count as u64;
            }
            if copied != size {
                return Err("short segment copy".into());
            }
            Ok(())
        })();
        if result.is_ok() {
            self.state.bytes += copied;
            self.state.next_index += 1;
        } else {
            // Do not checkpoint a half-appended segment on cancellation or I/O failure.
            let _ = self.file.set_len(self.state.bytes);
            let _ = self.file.seek(SeekFrom::Start(self.state.bytes));
        }
        result
    }

    pub fn checkpoint(&mut self, force: bool) {
        if !self.keep
            || self.state.next_index == 0
            || self.state.bytes == 0
            || (!force
                && self.state.bytes.saturating_sub(self.saved_bytes) < 8 << 20
                && self.saved_at.elapsed().as_secs() < 5)
        {
            return;
        }
        if self.save().is_ok() {
            self.saved_bytes = self.state.bytes;
            self.saved_at = Instant::now();
        }
    }

    fn save(&mut self) -> io::Result<()> {
        self.file.sync_all()?;
        self.state.version = 1;
        self.state.updated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let bytes = serde_json::to_vec(&self.state)?;
        let mut temporary = self.checkpoint.clone();
        temporary.push(".tmp");
        remove_if_present(&self.parent, &temporary)?;
        let result = (|| {
            let mut file = self
                .parent
                .open_with(&temporary, private_options().write(true).create_new(true))?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            self.parent
                .rename(&temporary, &self.parent, &self.checkpoint)
        })();
        if result.is_err() {
            let _ = self.parent.remove_file(&temporary);
        }
        result
    }

    pub fn publish(&mut self, check: &dyn Fn() -> Result<(), String>) -> Result<(), String> {
        self.file.sync_all().map_err(|error| error.to_string())?;
        check()?;
        self.parent
            .rename(&self.staged, &self.parent, &self.target)
            .map_err(|error| error.to_string())?;
        self.promoted = true;
        let _ = self.parent.remove_file(&self.checkpoint);
        let _ = self
            .parent
            .try_clone()
            .and_then(|parent| parent.into_std_file().sync_all());
        Ok(())
    }
}

impl Drop for SegmentOutput {
    fn drop(&mut self) {
        // Also clean leftovers from a process that stopped before these workers started.
        for index in 0..self.segments {
            let _ = self.parent.remove_file(segment_name(&self.staged, index));
        }
        if self.promoted || !self.keep {
            let _ = self.parent.remove_file(&self.checkpoint);
            if !self.promoted {
                let _ = self.parent.remove_file(&self.staged);
            }
        }
    }
}

pub(super) struct SegmentFile {
    parent: Arc<Dir>,
    name: OsString,
    pub file: File,
}

impl SegmentFile {
    pub fn open(parent: &Arc<Dir>, staged: &OsString, index: usize) -> io::Result<Self> {
        let name = segment_name(staged, index);
        remove_if_present(parent, &name)?;
        let file = parent.open_with(
            &name,
            private_options().read(true).write(true).create_new(true),
        )?;
        Ok(Self {
            parent: Arc::clone(parent),
            name,
            file,
        })
    }
}

impl Drop for SegmentFile {
    fn drop(&mut self) {
        let _ = self.parent.remove_file(&self.name);
    }
}

fn segment_name(staged: &OsString, index: usize) -> OsString {
    let mut name = staged.clone();
    name.push(format!(".segment.{index:06}"));
    name
}
