use super::{FileStamp, IndexFiles};
use std::fs::{self, OpenOptions};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Ambient filesystem access for the trusted native application. JavaScript
/// hosts must use their scoped adapter instead.
pub struct NativeFiles;

impl IndexFiles for NativeFiles {
    fn list(
        &self,
        directory: &str,
        check: &(dyn Fn() -> Result<(), String> + Sync),
    ) -> Result<Vec<FileStamp>, String> {
        let mut pending = vec![PathBuf::from(directory)];
        let mut result = Vec::new();
        while let Some(path) = pending.pop() {
            check()?;
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if !metadata.is_dir() {
                result.push(stamp(&path, &metadata));
                continue;
            }
            let Ok(entries) = fs::read_dir(&path) else {
                continue;
            };
            let mut names = Vec::new();
            for entry in entries {
                check()?;
                if let Ok(entry) = entry {
                    names.push(entry.file_name());
                }
            }
            names.sort();
            pending.extend(names.into_iter().rev().map(|name| clean(&path.join(name))));
        }
        check()?;
        Ok(result)
    }

    fn read(
        &self,
        path: &str,
        check: &(dyn Fn() -> Result<(), String> + Sync),
    ) -> Result<String, String> {
        check()?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
        }
        let Ok(mut file) = options.open(path) else {
            return Ok(String::new());
        };
        if !file.metadata().is_ok_and(|metadata| metadata.is_file()) {
            return Ok(String::new());
        }
        let format = Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        super::read_isrc(&mut file, &format, check)
    }

    fn stat(&self, path: &str) -> Result<Option<FileStamp>, String> {
        Ok(fs::metadata(path)
            .ok()
            .map(|metadata| stamp(Path::new(path), &metadata)))
    }
}

fn stamp(path: &Path, metadata: &fs::Metadata) -> FileStamp {
    let modified_ns = metadata
        .modified()
        .map(|time| match time.duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_nanos() as i128,
            Err(error) => -(error.duration().as_nanos() as i128),
        })
        .unwrap_or_default();
    FileStamp {
        path: path.to_string_lossy().into_owned(),
        size: metadata.len(),
        modified_ns,
        directory: metadata.is_dir(),
    }
}

fn clean(path: &Path) -> PathBuf {
    let mut output = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir if output.file_name().is_some_and(|name| name != "..") => {
                output.pop();
            }
            Component::ParentDir if output.has_root() => {}
            other => output.push(other.as_os_str()),
        }
    }
    if output.as_os_str().is_empty() {
        output.push(".");
    }
    output
}
