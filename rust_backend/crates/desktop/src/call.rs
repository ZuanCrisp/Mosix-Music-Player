//! One method call: decoded arguments, the reply, errors, and cancellation.

use mornye_mobile::RequestLease;
use serde_json::{Map, Value, json};
use std::fmt::Display;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Key Dart adds to the argument map when it moves one `Uint8List` into the
/// separate `bytes` buffer (see FFI_CONTRACT.md, "Binary arguments").
pub const BYTES_KEY: &str = "$bytes_key";

/// MethodChannel arguments, with the binary value restored under its key.
#[derive(Debug)]
pub struct Args {
    value: Value,
    binary: Option<(String, Vec<u8>)>,
}

impl Args {
    /// Decodes `args_json` and restores the binary argument, if any.
    pub fn decode(json: &[u8], bytes: Option<Vec<u8>>) -> Result<Self, CallError> {
        let mut value: Value = if json.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(json).map_err(|error| {
                CallError::invalid_arguments(format!("Arguments are not valid JSON: {error}"))
            })?
        };
        let key = match value.as_object_mut().and_then(|map| map.remove(BYTES_KEY)) {
            None => None,
            Some(Value::String(key)) if !key.is_empty() => Some(key),
            Some(_) => {
                return Err(CallError::invalid_arguments(
                    "Only one binary argument with a string key is supported",
                ));
            }
        };
        let binary = match (key, bytes) {
            (Some(key), bytes) => {
                if value.as_object().is_some_and(|map| map.contains_key(&key)) {
                    return Err(CallError::invalid_arguments(format!(
                        "Binary argument key is already present: {key}"
                    )));
                }
                Some((key, bytes.unwrap_or_default()))
            }
            (None, Some(_)) => {
                return Err(CallError::invalid_arguments(
                    "Binary data was passed without a binary argument key",
                ));
            }
            (None, None) => None,
        };
        Ok(Self { value, binary })
    }

    pub fn value(&self) -> &Value {
        &self.value
    }

    fn map(&self) -> Option<&Map<String, Value>> {
        self.value.as_object()
    }

    /// True when the map has `key`, even with a null value (Swift `!= nil`
    /// on an `NSNull`, Kotlin `containsKey`).
    pub fn has(&self, key: &str) -> bool {
        self.map().is_some_and(|map| map.contains_key(key))
            || self.binary.as_ref().is_some_and(|(name, _)| name == key)
    }

    pub fn opt_string(&self, key: &str) -> Option<&str> {
        self.map()?.get(key)?.as_str()
    }

    /// `args[key] as? String ?? fallback`.
    pub fn string(&self, key: &str, fallback: &str) -> String {
        self.opt_string(key).unwrap_or(fallback).to_owned()
    }

    /// `args[key] as? Bool ?? fallback`.
    pub fn bool(&self, key: &str, fallback: bool) -> bool {
        self.map()
            .and_then(|map| map.get(key))
            .and_then(Value::as_bool)
            .unwrap_or(fallback)
    }

    /// `(args[key] as? NSNumber)?.int64Value`.
    pub fn i64(&self, key: &str) -> Option<i64> {
        let value = self.map()?.get(key)?;
        value
            .as_i64()
            .or_else(|| value.as_u64().map(|value| value as i64))
            .or_else(|| value.as_f64().map(|value| value as i64))
    }

    /// `args[key] as? [String]`; `None` when absent, an error when not a list
    /// of strings.
    pub fn string_list(&self, key: &str) -> Option<Result<Vec<String>, ()>> {
        let value = self.map()?.get(key)?;
        Some(value.as_array().ok_or(()).and_then(|values| {
            values
                .iter()
                .map(|value| value.as_str().map(str::to_owned).ok_or(()))
                .collect()
        }))
    }

    /// The restored binary argument stored under `key`.
    pub fn bytes(&self, key: &str) -> Option<&[u8]> {
        self.binary
            .as_ref()
            .filter(|(name, _)| name == key)
            .map(|(_, bytes)| bytes.as_slice())
    }

    /// Arguments passed as a bare string (`arguments as? String`).
    pub fn as_string(&self) -> Option<&str> {
        self.value.as_str()
    }
}

/// What the MethodChannel handler would have returned.
#[derive(Debug, PartialEq)]
pub enum Reply {
    Json(Value),
    Binary(Vec<u8>),
}

impl Reply {
    pub fn null() -> Self {
        Self::Json(Value::Null)
    }
}

impl From<String> for Reply {
    fn from(value: String) -> Self {
        Self::Json(Value::String(value))
    }
}

impl From<&str> for Reply {
    fn from(value: &str) -> Self {
        Self::Json(Value::String(value.to_owned()))
    }
}

impl From<bool> for Reply {
    fn from(value: bool) -> Self {
        Self::Json(Value::Bool(value))
    }
}

impl From<Value> for Reply {
    fn from(value: Value) -> Self {
        Self::Json(value)
    }
}

impl From<()> for Reply {
    fn from(_: ()) -> Self {
        Self::null()
    }
}

/// Kind 1 payload: `{"code", "message", "details"}`.
#[derive(Debug, Clone, PartialEq)]
pub struct CallError {
    pub code: String,
    pub message: String,
    pub details: Value,
}

impl CallError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            details: Value::Null,
        }
    }

    /// The `FlutterError(code: "ERROR", ...)` every mobile host returns.
    pub fn failure(message: impl Display) -> Self {
        Self::new("ERROR", message.to_string())
    }

    pub fn unimplemented(method: &str) -> Self {
        Self::new(
            "unimplemented",
            format!("Method is not available on desktop: {method}"),
        )
    }

    pub fn invalid_arguments(message: impl Into<String>) -> Self {
        Self::new("invalid_arguments", message)
    }

    pub fn cancelled() -> Self {
        Self::new("cancelled", "Call was cancelled before it started")
    }

    pub fn to_json(&self) -> Vec<u8> {
        json!({"code": self.code, "message": self.message, "details": self.details})
            .to_string()
            .into_bytes()
    }
}

pub type CallResult = Result<Reply, CallError>;

/// Maps backend errors to the hosts' generic `ERROR` code.
pub(crate) trait OrFail<T> {
    fn or_fail(self) -> Result<T, CallError>;
}

impl<T, E: Display> OrFail<T> for Result<T, E> {
    fn or_fail(self) -> Result<T, CallError> {
        self.map_err(CallError::failure)
    }
}

type CancelHook = Box<dyn FnOnce() + Send>;

/// Per-call state shared between the worker and `mornye_cancel`.
#[derive(Default)]
pub(crate) struct CallState {
    cancelled: AtomicBool,
    hooks: Mutex<Vec<CancelHook>>,
    /// Lease acquired synchronously by `mornye_call` (native data jobs), so a
    /// cancellation that follows the call is never lost.
    pub(crate) lease: Mutex<Option<Arc<RequestLease>>>,
}

impl CallState {
    pub(crate) fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        let hooks = std::mem::take(&mut *self.hooks.lock().expect("cancel hooks"));
        for hook in hooks {
            hook();
        }
    }

    /// Runs `hook` on cancellation, or now when the call is already cancelled.
    pub(crate) fn on_cancel(&self, hook: impl FnOnce() + Send + 'static) {
        let mut hooks = self.hooks.lock().expect("cancel hooks");
        if self.is_cancelled() {
            drop(hooks);
            hook();
        } else {
            hooks.push(Box::new(hook));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_binary_argument() {
        let args = Args::decode(
            br#"{"request_id":"a","$bytes_key":"bytes"}"#,
            Some(vec![1, 2, 3]),
        )
        .unwrap();
        assert_eq!(args.bytes("bytes"), Some(&[1u8, 2, 3][..]));
        assert!(args.has("bytes"));
        assert!(!args.has(BYTES_KEY));
        assert_eq!(args.string("request_id", ""), "a");
    }

    #[test]
    fn rejects_binary_without_key_or_with_many_keys() {
        assert_eq!(
            Args::decode(b"{}", Some(vec![1])).unwrap_err().code,
            "invalid_arguments"
        );
        assert_eq!(
            Args::decode(br#"{"$bytes_key":["a","b"]}"#, Some(vec![1]))
                .unwrap_err()
                .code,
            "invalid_arguments"
        );
    }

    #[test]
    fn empty_binary_argument_may_use_null_pointer() {
        let args = Args::decode(br#"{"$bytes_key":"bytes"}"#, None).unwrap();
        assert_eq!(args.bytes("bytes"), Some(&[][..]));
    }
}
