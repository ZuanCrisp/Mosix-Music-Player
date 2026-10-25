//! Rust panic records for desktop crash reports (DESIGN 6.6). The hook
//! appends to `<app_support_dir>/logs/rust-panic.log`, next to the Dart log
//! files, then runs the previous hook. Dart reads the file when it detects an
//! unclean exit on the next launch.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Once;

pub(crate) const FILE_NAME: &str = "rust-panic.log";
/// Above this size the file is rotated to `rust-panic.1.log`.
const MAX_BYTES: u64 = 512 * 1024;

pub(crate) fn log_dir(app_support_dir: &Path) -> PathBuf {
    app_support_dir.join("logs")
}

/// Installs the hook once per process; later calls keep the first folder.
pub(crate) fn install(app_support_dir: &Path) {
    static INSTALL: Once = Once::new();
    if app_support_dir.as_os_str().is_empty() {
        return;
    }
    let dir = log_dir(app_support_dir);
    INSTALL.call_once(move || {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let message = info
                .payload()
                .downcast_ref::<&str>()
                .map(|text| (*text).to_owned())
                .or_else(|| info.payload().downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "non-string panic payload".to_owned());
            let location = info
                .location()
                .map(|location| format!("{}:{}", location.file(), location.line()))
                .unwrap_or_default();
            let backtrace = std::backtrace::Backtrace::force_capture().to_string();
            let _ = append(&dir, &record(&message, &location, &backtrace));
            previous(info);
        }));
    });
}

pub(crate) fn record(message: &str, location: &str, backtrace: &str) -> String {
    let thread = std::thread::current();
    format!(
        "[{}] thread '{}' panicked at {location}: {message}\n{backtrace}\n",
        chrono::Utc::now().to_rfc3339(),
        thread.name().unwrap_or("unnamed"),
    )
}

pub(crate) fn append(dir: &Path, text: &str) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let path = dir.join(FILE_NAME);
    if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > MAX_BYTES) {
        fs::rename(&path, dir.join("rust-panic.1.log"))?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(text.as_bytes())?;
    file.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_and_rotates() {
        let directory = tempfile::tempdir().unwrap();
        let logs = log_dir(directory.path());
        let entry = record("boom", "src/lib.rs:1", "backtrace");
        assert!(entry.contains("panicked at src/lib.rs:1: boom"));
        append(&logs, &entry).unwrap();
        append(&logs, &"x".repeat(MAX_BYTES as usize)).unwrap();
        append(&logs, "last\n").unwrap();
        assert_eq!(fs::read_to_string(logs.join(FILE_NAME)).unwrap(), "last\n");
        assert!(
            fs::read_to_string(logs.join("rust-panic.1.log"))
                .unwrap()
                .starts_with(&entry)
        );
    }
}
