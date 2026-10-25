//! Process-style diagnostic buffer scoped to the native backend environment.

use crate::host::decode_go_utf8;
use crate::redact::sanitize_bytes;
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::Mutex;

const CAPACITY: usize = 500;
const MAX_MESSAGE: usize = 4000;

#[derive(Clone, Debug, Serialize)]
pub struct LogEntry {
    pub timestamp: String,
    pub level: String,
    pub tag: String,
    pub message: String,
}

#[derive(Default)]
struct State {
    entries: VecDeque<LogEntry>,
    next_index: i64,
    enabled: bool,
    closed: bool,
}

#[derive(Default)]
pub struct LogBuffer(Mutex<State>, Mutex<()>);

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("log buffer closed")]
pub struct LogClosed;

impl State {
    fn check(&self) -> Result<(), LogClosed> {
        if self.closed { Err(LogClosed) } else { Ok(()) }
    }
}

impl LogBuffer {
    pub fn set_enabled(&self, enabled: bool) -> Result<(), LogClosed> {
        let mut state = self.0.lock().expect("log buffer lock");
        state.check()?;
        state.enabled = enabled;
        Ok(())
    }

    pub fn is_enabled(&self) -> Result<bool, LogClosed> {
        let state = self.0.lock().expect("log buffer lock");
        state.check()?;
        Ok(state.enabled)
    }

    pub fn add(&self, level: &str, tag: &str, message: &str) -> Result<(), LogClosed> {
        self.add_message(level, tag, || message.as_bytes().to_vec(), false)
    }

    fn add_message(
        &self,
        level: &str,
        tag: &str,
        message: impl FnOnce() -> Vec<u8>,
        sanitized: bool,
    ) -> Result<(), LogClosed> {
        // Serialize append/output order without holding the state lock during
        // stderr IO. Snapshot readers and shutdown can still access the buffer.
        let _output = self.1.lock().expect("log output lock");
        let mut state = self.0.lock().expect("log buffer lock");
        state.check()?;
        if !state.enabled && level != "ERROR" && level != "FATAL" {
            return Ok(());
        }
        let message = message();
        let message = if sanitized {
            message
        } else {
            sanitize_bytes(message)
        };
        let message = decode_go_utf8(&truncate(message));
        let entry = LogEntry {
            timestamp: chrono::Local::now().format("%H:%M:%S%.3f").to_string(),
            level: level.into(),
            tag: tag.into(),
            message,
        };
        if state.entries.len() == CAPACITY {
            state.entries.pop_front();
        }
        let line = format!("[{}] {}", entry.tag, entry.message);
        state.entries.push_back(entry);
        state.next_index = state.next_index.wrapping_add(1);
        drop(state);
        use std::io::Write;
        let _ = writeln!(std::io::stderr().lock(), "{line}");
        Ok(())
    }

    pub fn backend(&self, message: &str) -> Result<(), LogClosed> {
        self.backend_bytes(message.as_bytes(), false)
    }

    fn backend_bytes(&self, mut message: &[u8], sanitized: bool) -> Result<(), LogClosed> {
        if message.last() == Some(&b'\n') {
            message = &message[..message.len() - 1];
        }
        let mut tag = "Rust".to_owned();
        if message.first() == Some(&b'[')
            && let Some(end) = message
                .iter()
                .position(|byte| *byte == b']')
                .filter(|end| *end > 1)
        {
            tag = decode_go_utf8(&message[1..end]);
            message = trim_bytes(&message[end + 1..]);
        }
        let lowercase = spotiflac_core::matching::lowercase(&decode_go_utf8(message));
        let level = if lowercase.contains("error") || lowercase.contains("failed") {
            "ERROR"
        } else if lowercase.contains("warning") || lowercase.contains("warn") {
            "WARN"
        } else if lowercase.contains("success") || lowercase.contains("match found") {
            "INFO"
        } else if lowercase.contains("searching")
            || lowercase.contains("trying")
            || lowercase.contains("found")
        {
            "DEBUG"
        } else {
            "INFO"
        };
        self.add_message(level, &tag, || message.to_vec(), sanitized)
    }

    pub(crate) fn extension(&self, id: &str, level: &str, arguments: Vec<String>, total: usize) {
        let mut message = Vec::new();
        for (index, argument) in arguments.into_iter().take(8).enumerate() {
            if index > 0 {
                message.push(b' ');
            }
            let bytes = argument.as_bytes();
            message.extend_from_slice(&bytes[..bytes.len().min(512)]);
            if bytes.len() > 512 {
                message.extend_from_slice(b"...[truncated]");
            }
        }
        if total > 8 {
            if !message.is_empty() {
                message.push(b' ');
            }
            message.extend_from_slice(format!("...[{} more args]", total - 8).as_bytes());
        }
        let formatted = truncate(sanitize_bytes(message));
        let mut line = if level.is_empty() {
            format!("[Extension:{id}] ")
        } else {
            format!("[Extension:{id}:{level}] ")
        }
        .into_bytes();
        line.extend(formatted);
        line.push(b'\n');
        let _ = self.backend_bytes(&line, true);
    }

    pub fn all(&self) -> Result<String, LogClosed> {
        let state = self.0.lock().expect("log buffer lock");
        state.check()?;
        Ok(serde_json::to_string(&state.entries).expect("log entries JSON"))
    }

    pub fn since(&self, index: i64) -> Result<String, LogClosed> {
        let state = self.0.lock().expect("log buffer lock");
        state.check()?;
        let earliest = state.next_index - state.entries.len() as i64;
        let skip = if index >= state.next_index {
            state.entries.len()
        } else {
            (index.max(earliest) - earliest) as usize
        };
        let logs: Vec<_> = state.entries.iter().skip(skip).collect();
        Ok(serde_json::json!({"logs":logs,"next_index":state.next_index}).to_string())
    }

    pub fn clear(&self) -> Result<(), LogClosed> {
        let mut state = self.0.lock().expect("log buffer lock");
        state.check()?;
        state.entries.clear();
        Ok(())
    }

    pub fn count(&self) -> Result<u64, LogClosed> {
        let state = self.0.lock().expect("log buffer lock");
        state.check()?;
        Ok(state.entries.len() as u64)
    }

    pub fn shutdown(&self) {
        let mut state = self.0.lock().expect("log buffer lock");
        state.closed = true;
        state.entries.clear();
    }
}

impl Drop for LogBuffer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn truncate(mut message: Vec<u8>) -> Vec<u8> {
    if message.len() > MAX_MESSAGE {
        message.truncate(MAX_MESSAGE);
        if let Err(error) = std::str::from_utf8(&message) {
            message.truncate(error.valid_up_to());
        }
        message.extend_from_slice(b"...[truncated]");
    }
    message
}

fn trim_bytes(bytes: &[u8]) -> &[u8] {
    // Invalid bytes are non-whitespace in Go and are retained until JSON export.
    let decoded = decode_go_utf8(bytes);
    let left = decoded.len() - decoded.trim_start().len();
    let right = decoded.len() - decoded.trim_end().len();
    let end = bytes.len().saturating_sub(right);
    if left >= end { &[] } else { &bytes[left..end] }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_messages_skip_conversion_but_errors_and_closed_state_are_preserved() {
        let logs = LogBuffer::default();
        logs.add_message(
            "DEBUG",
            "Example",
            || panic!("disabled message copied"),
            false,
        )
        .unwrap();
        for level in ["ERROR", "FATAL"] {
            logs.add(level, "Example", "password=fixture-secret;")
                .unwrap();
        }
        let values: serde_json::Value = serde_json::from_str(&logs.all().unwrap()).unwrap();
        assert_eq!(values[0]["message"], "password=[REDACTED];");
        assert_eq!(values[1]["level"], "FATAL");
        logs.shutdown();
        assert_eq!(logs.add("DEBUG", "Example", "ignored"), Err(LogClosed));
    }

    #[test]
    fn extension_redaction_precedes_level_inference_and_preserves_raw_byte_truncation() {
        let logs = LogBuffer::default();
        logs.set_enabled(true).unwrap();
        logs.extension(
            "example",
            "WARN",
            vec!["password=failed-secret;".into(), "é".repeat(257)],
            2,
        );
        let values: serde_json::Value = serde_json::from_str(&logs.all().unwrap()).unwrap();
        assert_eq!(values[0]["level"], "INFO");
        assert_eq!(values[0]["tag"], "Extension:example:WARN");
        assert_eq!(
            values[0]["message"],
            format!("password=[REDACTED]; {}...[truncated]", "é".repeat(256))
        );
        logs.extension(
            "example",
            "",
            vec!["failure: failed password=fixture-secret;".into()],
            1,
        );
        assert_eq!(logs.count().unwrap(), 2);
        let values: serde_json::Value = serde_json::from_str(&logs.all().unwrap()).unwrap();
        assert_eq!(values[1]["level"], "ERROR");
        assert!(!logs.all().unwrap().contains("fixture-secret"));
    }
}
