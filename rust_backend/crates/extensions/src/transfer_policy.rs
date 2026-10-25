//! Manifest-declared download policy. Execution belongs to the download manager.

use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadTransferPolicy {
    pub max_attempts: i64,
    pub initial_retry_delay_ms: i64,
    pub max_retry_delay_ms: i64,
    pub resume_policy: String,
    pub persistent_checkpoint: bool,
    pub refresh_stream_on_status: BTreeSet<i64>,
    pub max_parallel_segments: i64,
    pub max_concurrent_downloads: i64,
}

impl Default for DownloadTransferPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            initial_retry_delay_ms: 500,
            max_retry_delay_ms: 8000,
            resume_policy: "none".to_owned(),
            persistent_checkpoint: false,
            refresh_stream_on_status: BTreeSet::from([401, 403]),
            max_parallel_segments: 3,
            max_concurrent_downloads: 3,
        }
    }
}

fn number(value: Option<&Value>, fallback: i64) -> i64 {
    value.and_then(Value::as_f64).map_or(fallback, rounded_int)
}

pub(crate) fn rounded_int(value: f64) -> i64 {
    let rounded = value.round();
    // Go uses the target's conversion: ARM saturates, while x86 returns
    // MinInt on overflow. Keep the native Go int width on ARM32 as well.
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    if rounded >= isize::MAX as f64 || rounded < isize::MIN as f64 {
        return isize::MIN as i64;
    }
    (rounded as isize) as i64
}

impl DownloadTransferPolicy {
    pub fn from_capabilities(capabilities: &Map<String, Value>) -> Self {
        let mut policy = Self::default();
        let Some(config) = capabilities
            .get("downloadTransfer")
            .and_then(Value::as_object)
        else {
            return policy;
        };
        policy.max_attempts = number(config.get("maxAttempts"), policy.max_attempts).clamp(1, 8);
        policy.initial_retry_delay_ms = number(
            config.get("initialRetryDelayMs"),
            policy.initial_retry_delay_ms,
        )
        .clamp(100, 30_000);
        policy.max_retry_delay_ms =
            number(config.get("maxRetryDelayMs"), policy.max_retry_delay_ms)
                .clamp(policy.initial_retry_delay_ms, 120_000);
        if let Some(resume) = config.get("resumePolicy").and_then(Value::as_str) {
            let resume = resume.trim().to_lowercase();
            if matches!(resume.as_str(), "none" | "validated") {
                policy.resume_policy = resume;
            }
        }
        policy.persistent_checkpoint = config.get("persistentCheckpoint")
            == Some(&Value::Bool(true))
            && policy.resume_policy == "validated";
        if let Some(statuses) = config
            .get("refreshStreamOnStatus")
            .and_then(Value::as_array)
        {
            let statuses: BTreeSet<_> = statuses
                .iter()
                .map(|value| number(Some(value), 0))
                .filter(|value| (400..=599).contains(value))
                .collect();
            if !statuses.is_empty() {
                policy.refresh_stream_on_status = statuses;
            }
        }
        policy.max_parallel_segments = number(
            config.get("maxParallelSegments"),
            policy.max_parallel_segments,
        )
        .clamp(1, 8);
        policy.max_concurrent_downloads = number(
            config.get("maxConcurrentDownloads"),
            policy.max_concurrent_downloads,
        )
        .clamp(1, 3);
        policy
    }
}

pub(crate) fn validate(capabilities: &Map<String, Value>) -> Result<(), String> {
    let Some(raw) = capabilities.get("downloadTransfer") else {
        return Ok(());
    };
    let config = raw.as_object().ok_or("must be an object")?;
    if let Some(resume) = config.get("resumePolicy")
        && !matches!(resume.as_str(), Some("none" | "validated"))
    {
        return Err("resumePolicy must be 'none' or 'validated'".to_owned());
    }
    if let Some(checkpoint) = config.get("persistentCheckpoint")
        && !checkpoint.is_boolean()
    {
        return Err("persistentCheckpoint must be a boolean".to_owned());
    }
    for key in [
        "maxAttempts",
        "initialRetryDelayMs",
        "maxRetryDelayMs",
        "maxParallelSegments",
        "maxConcurrentDownloads",
    ] {
        if let Some(value) = config.get(key)
            && number(Some(value), -1) < 0
        {
            return Err(format!("{key} must be a non-negative number"));
        }
    }
    Ok(())
}
