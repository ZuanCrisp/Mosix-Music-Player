mod chunked;
pub(crate) mod progress;
mod segment_store;
pub(crate) mod segments;
mod store;

use crate::files::{ExtensionFiles, FilePath};
use crate::transfer_policy::DownloadTransferPolicy;
use serde::Serialize;
use sha2::{Digest, Sha256};
use spotiflac_core::app_version::AppVersion;
use spotiflac_network::{HttpRequest, HttpResponse, NetworkSession, url::UrlParts};
use std::collections::BTreeMap;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use store::DownloadFile;

#[derive(Serialize)]
pub(crate) struct Failure {
    success: bool,
    error: String,
    error_type: &'static str,
    attempts: i64,
    #[serde(skip_serializing_if = "is_zero")]
    http_status: u16,
    #[serde(skip_serializing_if = "is_zero")]
    retry_after_seconds: u16,
}

fn is_zero(value: &u16) -> bool {
    *value == 0
}

/// Go's native exports share this envelope, including file-only operations.
/// It is distinct from the JS SDK transfer failure payload above.
pub(crate) fn native_error_response(message: &str) -> serde_json::Value {
    let lower = message.to_lowercase();
    let kind = [
        (
            "isp_blocked",
            &["isp blocking", "try using vpn", "change dns"][..],
        ),
        ("cancelled", &["cancel"][..]),
        (
            "verification_required",
            &[
                "verification_required",
                "session is not authenticated",
                "signed session is not authenticated",
                "signed session expired",
            ][..],
        ),
        (
            "provider_reauth_required",
            &["byoa_provider_reauth_required", "reauth_provider"][..],
        ),
        ("request_auth_invalid", &["request_auth_invalid"][..]),
        ("provider_auth_failed", &["provider_auth_failed"][..]),
        ("provider_unavailable", &["provider_unavailable"][..]),
        (
            "rate_limit",
            &[
                "rate limit",
                "http 429",
                "http status 429",
                "status 429",
                "429 for ",
                "429:",
                "429;",
                "too many requests",
            ][..],
        ),
        (
            "permission",
            &[
                "permission",
                "operation not permitted",
                "access denied",
                "failed to create file",
                "failed to create directory",
            ][..],
        ),
        (
            "not_found",
            &[
                "not found",
                "not available",
                "no results",
                "track not found",
                "all services failed",
            ][..],
        ),
        ("network", &["network", "connection", "timeout", "dial"][..]),
    ]
    .into_iter()
    .find(|(_, patterns)| patterns.iter().any(|pattern| lower.contains(pattern)))
    .map_or("unknown", |(kind, _)| kind);
    serde_json::json!({"success":false,"message":"","error":message,"error_type":kind})
}

impl Failure {
    pub(crate) fn new(kind: &'static str, error: impl ToString, attempts: i64) -> Self {
        Self {
            success: false,
            error: error.to_string(),
            error_type: kind,
            attempts,
            http_status: 0,
            retry_after_seconds: 0,
        }
    }
}

pub(crate) struct DownloadOptions {
    pub item: progress::ItemProgressTarget,
    pub headers: BTreeMap<String, String>,
    pub app_version: AppVersion,
    pub resume: bool,
    pub persistent: bool,
    pub policy: DownloadTransferPolicy,
    pub budget: Option<Arc<crate::resolution::ResolutionBudget>>,
    pub chunk_size: Option<u64>,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn download(
    files: &ExtensionFiles,
    path: &FilePath,
    network: &NetworkSession,
    url: &str,
    mut options: DownloadOptions,
    check: &dyn Fn() -> Result<(), String>,
    wait: &dyn Fn(Duration) -> Result<(), String>,
    progress: &mut dyn FnMut(u64, i64),
) -> Result<serde_json::Value, Failure> {
    let _guard = files
        .lock(path, check)
        .map_err(|error| Failure::new("cancelled", error, 0))?;
    if let Some(chunk_size) = options.chunk_size {
        return chunked::download(
            path, network, url, options, chunk_size, check, wait, progress,
        );
    }
    let caller_range = options
        .headers
        .keys()
        .any(|name| name.eq_ignore_ascii_case("Range"));
    if caller_range {
        options.resume = false;
        options.persistent = false;
    }
    let fingerprint = fingerprint(url);
    let mut output = DownloadFile::open(
        path,
        &fingerprint,
        options.resume && options.persistent && !fingerprint.is_empty(),
    )
    .map_err(|error| {
        Failure::new(
            "storage_error",
            format!("failed to create staged file: {error}"),
            0,
        )
    })?;
    options.item.start();
    options.item.initial(output.state.bytes, output.state.total);
    let reporter = options
        .item
        .reporter(output.state.bytes, output.state.total);
    if output.restored
        && output.state.bytes > 0
        && output.state.total > 0
        && output.state.bytes == output.state.total as u64
    {
        output.publish(check).map_err(|error| {
            Failure::new(
                "storage_error",
                format!("failed to publish restored download: {error}"),
                0,
            )
        })?;
        options
            .item
            .set(1.0, output.state.bytes, output.state.total);
        return Ok(
            serde_json::json!({"success":true,"path":path.display(),"size":output.state.bytes,"attempts":0,"resumed":true}),
        );
    }
    let mut retry_delay = Duration::from_millis(options.policy.initial_retry_delay_ms as u64);
    let mut notified = 0_u64;
    for attempt in 1..=options.policy.max_attempts {
        check().map_err(|error| Failure::new("cancelled", error, attempt))?;
        let mut range_from = if options.resume && !output.state.validator.is_empty() {
            output.state.bytes
        } else {
            0
        };
        let mut headers = options.headers.clone();
        if range_from > 0 {
            set_header(&mut headers, "Range", format!("bytes={range_from}-"));
            set_header(&mut headers, "If-Range", output.state.validator.clone());
        }
        let request = HttpRequest {
            url: url.to_owned(),
            method: "GET".into(),
            body: String::new(),
            headers,
            default_json: false,
            user_agent: options.app_version.user_agent(),
        };
        let charge = options.budget.as_ref().map(|budget| budget.enter(true));
        let stream = network.open_stream(
            request,
            Duration::from_secs(24 * 60 * 60),
            Duration::from_secs(60),
            check,
        );
        drop(charge);
        let mut stream = match stream {
            Ok(stream) => stream,
            Err(error) => {
                check().map_err(|error| Failure::new("cancelled", error, attempt))?;
                if attempt == options.policy.max_attempts {
                    return Err(Failure::new("transient_network", error, attempt));
                }
                if output.state.bytes > 0 && (!options.resume || output.state.validator.is_empty())
                {
                    output
                        .restart()
                        .map_err(|error| Failure::new("storage_error", error, attempt))?;
                }
                wait(retry_delay).map_err(|error| Failure::new("cancelled", error, attempt))?;
                retry_delay = next_delay(retry_delay, &options.policy);
                continue;
            }
        };
        let response = &stream.response;
        let status = response.status;
        if !(200..300).contains(&status) {
            let failure = status_failure(response, &options.policy, attempt);
            let delay = if failure.retry_after_seconds > 0 {
                Duration::from_secs(failure.retry_after_seconds.into())
            } else {
                retry_delay
            };
            stream.discard(check);
            if !retryable(status) || attempt == options.policy.max_attempts {
                return Err(failure);
            }
            wait(delay).map_err(|error| Failure::new("cancelled", error, attempt))?;
            retry_delay = next_delay(retry_delay, &options.policy);
            continue;
        }
        if range_from > 0 && status == 206 {
            let range = header(response, "Content-Range");
            if !range.starts_with(&format!("bytes {range_from}-")) {
                let mut failure = Failure::new(
                    "integrity_failed",
                    format!(
                        "resume failed: unexpected Content-Range {range:?} at {range_from} bytes"
                    ),
                    attempt,
                );
                failure.http_status = status;
                return Err(failure);
            }
            let validator = validator(response);
            if !validator.is_empty() && validator != output.state.validator {
                let mut failure = Failure::new(
                    "integrity_failed",
                    "resume failed: response validator changed",
                    attempt,
                );
                failure.http_status = status;
                return Err(failure);
            }
        }
        if range_from > 0 && status == 200 {
            output
                .rewind(0)
                .map_err(|error| Failure::new("storage_error", error, attempt))?;
            range_from = 0;
        }
        let validator = validator(response);
        if !validator.is_empty() {
            output.state.validator = validator;
        }
        let length = header(response, "Content-Length")
            .parse::<i64>()
            .unwrap_or(-1);
        output.state.total = if status == 206 && !caller_range {
            header(response, "Content-Range")
                .rsplit_once('/')
                .and_then(|(_, total)| total.parse().ok())
                .unwrap_or(if length > 0 {
                    (range_from as i64).saturating_add(length)
                } else {
                    0
                })
        } else {
            length
        };
        if output.state.total > 0 {
            reporter.report(output.state.bytes as i64, output.state.total);
        }
        let mut buffer = [0; 64 << 10];
        let mut received_bytes = false;
        let body_result = loop {
            let budget = options
                .budget
                .as_ref()
                .map(|budget| budget.enter(!received_bytes || !matches!(status, 200 | 206)));
            let read = stream.read(&mut buffer, check);
            drop(budget);
            match read {
                Ok(0) => break Ok(()),
                Ok(count) => {
                    received_bytes = true;
                    if let Err(error) = output.file.write_all(&buffer[..count]) {
                        return Err(Failure::new(
                            "storage_error",
                            format!("failed to write staged file: {error}"),
                            attempt,
                        ));
                    }
                    output.state.bytes += count as u64;
                    reporter.report(output.state.bytes as i64, output.state.total);
                    if output.state.total > 0
                        && (output.state.bytes.saturating_sub(notified) >= 128 << 10
                            || output.state.bytes >= output.state.total as u64)
                    {
                        notified = output.state.bytes;
                        let _charge = options.budget.as_ref().map(|budget| budget.enter(true));
                        progress(output.state.bytes, output.state.total);
                    }
                    output.checkpoint(false);
                }
                Err(error) => break Err(error),
            }
        };
        drop(stream);
        let body_result = body_result.and_then(|()| {
            if output.state.total > 0 && output.state.bytes != output.state.total as u64 {
                Err("unexpected EOF".into())
            } else {
                Ok(())
            }
        });
        if let Err(error) = body_result {
            output.checkpoint(true);
            check().map_err(|error| Failure::new("cancelled", error, attempt))?;
            if attempt == options.policy.max_attempts {
                return Err(Failure::new(
                    "transient_network",
                    format!("failed to read response: {error}"),
                    attempt,
                ));
            }
            if !options.resume || output.state.validator.is_empty() {
                output
                    .restart()
                    .map_err(|error| Failure::new("storage_error", error, attempt))?;
            }
            wait(retry_delay).map_err(|error| Failure::new("cancelled", error, attempt))?;
            retry_delay = next_delay(retry_delay, &options.policy);
            continue;
        }
        if output.state.bytes == 0 {
            return Err(Failure::new(
                "integrity_failed",
                "download response was empty",
                attempt,
            ));
        }
        output.publish(check).map_err(|error| {
            Failure::new(
                "storage_error",
                format!("failed to publish file: {error}"),
                0,
            )
        })?;
        if output.state.total > 0 {
            options
                .item
                .set(1.0, output.state.bytes, output.state.total);
        } else {
            options.item.received(output.state.bytes);
        }
        return Ok(
            serde_json::json!({"success":true,"path":path.display(),"size":output.state.bytes,"attempts":attempt}),
        );
    }
    unreachable!("policy has at least one attempt")
}

fn set_header(headers: &mut BTreeMap<String, String>, name: &str, value: String) {
    headers.retain(|key, _| !key.eq_ignore_ascii_case(name));
    headers.insert(name.to_owned(), value);
}

fn header<'a>(response: &'a HttpResponse, name: &str) -> &'a str {
    response
        .headers
        .get(name)
        .and_then(|values| values.first())
        .map_or("", String::as_str)
}

fn validator(response: &HttpResponse) -> String {
    let etag = header(response, "Etag").trim();
    if !etag.is_empty() && !etag.to_uppercase().starts_with("W/") {
        etag.to_owned()
    } else {
        header(response, "Last-Modified").trim().to_owned()
    }
}

fn fingerprint(url: &str) -> String {
    UrlParts::parse(url).map_or(String::new(), |url| {
        crate::binary::encode(
            &Sha256::digest(format!(
                "{}://{}{}",
                url.scheme.to_lowercase(),
                url.authority().to_lowercase(),
                url.escaped_path()
            )),
            "hex",
        )
        .expect("hex encoding")
    })
}

fn retryable(status: u16) -> bool {
    matches!(status, 408 | 425 | 429 | 500..=u16::MAX)
}

fn status_failure(
    response: &HttpResponse,
    policy: &DownloadTransferPolicy,
    attempt: i64,
) -> Failure {
    let status = response.status;
    let kind = if status == 429 {
        "rate_limited"
    } else if policy.refresh_stream_on_status.contains(&i64::from(status)) {
        "expired_stream"
    } else if retryable(status) {
        "transient_network"
    } else {
        "http_error"
    };
    let mut failure = Failure::new(kind, format!("HTTP error: {status}"), attempt);
    failure.http_status = status;
    let value = header(response, "Retry-After");
    let nanos = if let Ok(seconds) = value.parse::<isize>() {
        i128::from((seconds as i64).wrapping_mul(1_000_000_000))
    } else {
        httpdate::parse_http_date(value)
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |time| {
                time.as_nanos() as i128
                    - SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos() as i128
            })
    };
    if nanos > 0 {
        failure.retry_after_seconds =
            ((nanos.min(120_000_000_000) + 500_000_000) / 1_000_000_000).max(1) as u16;
    }
    failure
}

fn next_delay(current: Duration, policy: &DownloadTransferPolicy) -> Duration {
    let ceiling = current
        .saturating_mul(2)
        .min(Duration::from_millis(policy.max_retry_delay_ms as u64));
    let floor = Duration::from_millis(policy.initial_retry_delay_ms as u64);
    if ceiling <= floor {
        return ceiling;
    }
    let mut random = [0; 8];
    if getrandom::fill(&mut random).is_err() {
        return ceiling;
    }
    floor
        + Duration::from_nanos(
            (u64::from_ne_bytes(random) as f64 / u64::MAX as f64
                * (ceiling - floor).as_nanos() as f64) as u64,
        )
}
