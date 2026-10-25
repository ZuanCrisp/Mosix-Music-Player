//! Path helpers shared by the dispatcher and the FFmpeg pump.

use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

/// Removes `.` and `..` components without touching the filesystem, like
/// Foundation's `standardizedFileURL` on the mobile hosts.
pub(crate) fn standardize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !result.pop() {
                    result.push(component);
                }
            }
            other => result.push(other),
        }
    }
    result
}

/// Resolves symlinks in the existing part of `path` and keeps the missing
/// tail, like `resolvingSymlinksInPath` (iOS) and `canonicalPath` (Android).
pub(crate) fn resolve(path: &str) -> PathBuf {
    let standardized = standardize(Path::new(path));
    let mut existing = standardized.as_path();
    let mut tail = Vec::new();
    loop {
        if let Ok(resolved) = fs::canonicalize(existing) {
            let mut result = resolved;
            for name in tail.iter().rev() {
                result.push(name);
            }
            return result;
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                tail.push(name.to_os_string());
                existing = parent;
            }
            _ => return standardized,
        }
    }
}

pub(crate) fn resolve_string(path: &str) -> String {
    resolve(path).to_string_lossy().into_owned()
}

/// Mobile `mediaPath`: empty stays empty, everything else is resolved.
pub(crate) fn media_path(path: &str) -> String {
    if path.is_empty() {
        String::new()
    } else {
        resolve_string(path)
    }
}

pub(crate) fn is_absolute(path: &str) -> bool {
    Path::new(path).is_absolute()
}

/// Random RFC 4122 version 4 UUID in upper case, like Foundation's
/// `UUID().uuidString`.
pub(crate) fn uuid() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("system random source");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

pub(crate) fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.char_indices().all(|(index, character)| match index {
            8 | 13 | 18 | 23 => character == '-',
            _ => character.is_ascii_hexdigit(),
        })
}

/// Moves a finished staging file into place. Falls back to copy and remove
/// when the staging root is on another filesystem (for example `/tmp`).
pub(crate) fn publish(staged: &Path, output: &Path) -> io::Result<()> {
    match fs::rename(staged, output) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            fs::copy(staged, output)?;
            fs::remove_file(staged)
        }
        Err(error) => Err(error),
    }
}

/// Removes a file when dropped, ignoring errors, like the hosts' `defer`.
pub(crate) struct RemoveOnDrop(pub(crate) PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_has_canonical_shape() {
        let value = uuid();
        assert!(is_uuid(&value), "{value}");
        assert_eq!(&value[14..15], "4");
        assert!(!is_uuid("not-a-uuid"));
    }

    #[test]
    fn resolve_keeps_missing_tail() {
        let directory = tempfile::tempdir().unwrap();
        let canonical = fs::canonicalize(directory.path()).unwrap();
        let missing = directory.path().join("a/../b/c.txt");
        assert_eq!(
            resolve(missing.to_str().unwrap()),
            canonical.join("b").join("c.txt")
        );
    }
}
