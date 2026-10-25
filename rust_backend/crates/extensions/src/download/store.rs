use crate::files::FilePath;
use cap_std::fs::{Dir, File, OpenOptions};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
pub(super) struct Checkpoint {
    version: i64,
    fingerprint: String,
    pub validator: String,
    pub bytes: u64,
    pub total: i64,
    updated_at: u64,
}

pub(super) struct DownloadFile {
    parent: Dir,
    target: OsString,
    staged: OsString,
    checkpoint_name: OsString,
    pub file: File,
    pub state: Checkpoint,
    pub restored: bool,
    keep_partial: bool,
    promoted: bool,
    saved_bytes: u64,
    saved_at: Instant,
}

impl DownloadFile {
    pub fn open(path: &FilePath, fingerprint: &str, keep_partial: bool) -> Result<Self, String> {
        let (parent, target) = path.open_parent().map_err(|error| error.to_string())?;
        let mut staged = target.clone();
        staged.push(".partial");
        let mut checkpoint_name = staged.clone();
        checkpoint_name.push(".checkpoint.json");
        for name in [&staged, &checkpoint_name] {
            match parent.symlink_metadata(name) {
                Ok(info) if !info.is_file() => {
                    return Err("download staging path is not a regular file".into());
                }
                Err(error) if error.kind() != io::ErrorKind::NotFound => {
                    return Err(error.to_string());
                }
                _ => {}
            }
        }
        let state = keep_partial
            .then(|| {
                let mut file = parent
                    .open_with(&checkpoint_name, private_options().read(true))
                    .ok()?;
                let mut data = Vec::new();
                (&mut file)
                    .take((1 << 20) + 1)
                    .read_to_end(&mut data)
                    .ok()?;
                if data.len() > 1 << 20 {
                    return None;
                }
                let state: Checkpoint = serde_json::from_slice(&data).ok()?;
                (state.version == 1
                    && !state.fingerprint.is_empty()
                    && state.fingerprint == fingerprint
                    && !state.validator.is_empty()
                    && state.bytes > 0)
                    .then_some(state)
            })
            .flatten();
        let restored = state.is_some();
        if !restored {
            remove_if_present(&parent, &staged).map_err(|error| error.to_string())?;
            remove_if_present(&parent, &checkpoint_name).map_err(|error| error.to_string())?;
        }
        let file = parent
            .open_with(
                &staged,
                private_options().read(true).write(true).create(true),
            )
            .map_err(|error| error.to_string())?;
        if !file
            .metadata()
            .map_err(|error| error.to_string())?
            .is_file()
        {
            return Err("download staging path is not a regular file".into());
        }
        let mut result = Self {
            parent,
            target,
            staged,
            checkpoint_name,
            file,
            state: state.unwrap_or_default(),
            restored,
            keep_partial,
            promoted: false,
            saved_bytes: 0,
            saved_at: Instant::now(),
        };
        result.state.fingerprint = fingerprint.to_owned();
        result.state.bytes = result.state.bytes.min(
            result
                .file
                .metadata()
                .map_err(|error| error.to_string())?
                .len(),
        );
        result
            .file
            .set_len(result.state.bytes)
            .map_err(|error| error.to_string())?;
        result
            .file
            .seek(SeekFrom::Start(result.state.bytes))
            .map_err(|error| error.to_string())?;
        result.saved_bytes = result.state.bytes;
        Ok(result)
    }

    pub fn restart(&mut self) -> Result<(), String> {
        self.rewind(0)?;
        self.state.validator.clear();
        remove_if_present(&self.parent, &self.checkpoint_name).map_err(|error| error.to_string())
    }

    pub fn rewind(&mut self, bytes: u64) -> Result<(), String> {
        self.file
            .set_len(bytes)
            .map_err(|error| error.to_string())?;
        self.file
            .seek(SeekFrom::Start(bytes))
            .map_err(|error| error.to_string())?;
        self.state.bytes = bytes;
        Ok(())
    }

    pub fn checkpoint(&mut self, force: bool) {
        if !self.keep_partial || self.state.validator.is_empty() || self.state.bytes == 0 {
            return;
        }
        if !force
            && self.state.bytes.saturating_sub(self.saved_bytes) < 8 << 20
            && self.saved_at.elapsed().as_secs() < 5
        {
            return;
        }
        self.saved_bytes = self.state.bytes;
        self.saved_at = Instant::now();
        // Data reaches stable storage before publishing its checkpoint pointer.
        // A failed save is retried on the next interval, not on every read.
        let _ = self.save();
    }

    fn save(&mut self) -> io::Result<()> {
        self.file.sync_all()?;
        self.state.version = 1;
        self.state.updated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let bytes = serde_json::to_vec(&self.state)?;
        let mut temporary = self.checkpoint_name.clone();
        temporary.push(".tmp");
        // Remove the directory entry itself; an old symlink is never followed.
        remove_if_present(&self.parent, &temporary)?;
        let result = (|| {
            let mut file = self
                .parent
                .open_with(&temporary, private_options().write(true).create_new(true))?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            self.parent
                .rename(&temporary, &self.parent, &self.checkpoint_name)
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
        let _ = self.parent.remove_file(&self.checkpoint_name);
        let _ = self
            .parent
            .try_clone()
            .and_then(|parent| parent.into_std_file().sync_all());
        Ok(())
    }
}

impl Drop for DownloadFile {
    fn drop(&mut self) {
        if self.promoted || !self.keep_partial {
            let _ = self.parent.remove_file(&self.checkpoint_name);
            if !self.promoted {
                let _ = self.parent.remove_file(&self.staged);
            }
        }
    }
}

pub(super) fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(
            (rustix::fs::OFlags::NONBLOCK | rustix::fs::OFlags::NOFOLLOW).bits() as i32,
        );
    }
    options
}

pub(super) fn remove_if_present(parent: &Dir, name: &OsString) -> io::Result<()> {
    match parent.remove_file(name) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}
