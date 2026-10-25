use crate::matching::lowercase;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    NotFound,
    Unavailable,
    Other,
}

pub fn http_status(status: u16) -> ErrorKind {
    if status == 429 || status >= 500 {
        ErrorKind::Unavailable
    } else {
        ErrorKind::Other
    }
}

pub fn payload_not_found(message: &str) -> bool {
    let message = lowercase(message);
    [
        "lyrics not found",
        "no lyrics found",
        "no songs found",
        "not found",
    ]
    .iter()
    .any(|signal| message.contains(signal))
}

pub fn classify_payload(status: u16, message: &str) -> ErrorKind {
    if payload_not_found(message) {
        return ErrorKind::NotFound;
    }
    let message = lowercase(message);
    if [
        "rate limit",
        "too many requests",
        "operation too frequent",
        "操作频繁",
        "missing required parameters",
    ]
    .iter()
    .any(|signal| message.contains(signal))
    {
        return ErrorKind::Unavailable;
    }
    http_status(status)
}

pub fn detect_payload(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if !raw.starts_with('{') {
        return None;
    }
    let value: Value = serde_json::from_str(&crate::text::json_surrogates(raw)).ok()?;
    let payload = value.as_object()?;
    if [
        "lyrics",
        "lyric",
        "lrc",
        "content",
        "lines",
        "syncedLyrics",
        "unsyncedLyrics",
    ]
    .iter()
    .any(|key| payload.contains_key(*key))
    {
        return None;
    }
    for key in ["message", "error", "detail", "reason"] {
        if let Some(message) = value[key]
            .as_str()
            .map(str::trim)
            .filter(|text| !text.is_empty())
        {
            return Some(message.into());
        }
    }
    if value["success"] == false || value["isError"] == true {
        return Some("request unsuccessful".into());
    }
    if let Some(code) = value["code"].as_f64()
        && code != 0.0
        && code != 200.0
    {
        for key in ["message", "msg"] {
            if let Some(message) = value[key]
                .as_str()
                .map(str::trim)
                .filter(|text| !text.is_empty())
            {
                return Some(message.into());
            }
        }
        return Some(format!("unexpected response code {code:.0}"));
    }
    None
}
