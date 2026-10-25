use super::store::DownloadFile;
use super::{
    DownloadOptions, Failure, fingerprint, header, next_delay, retryable, set_header,
    status_failure, validator,
};
use crate::files::FilePath;
use spotiflac_network::{HttpRequest, HttpResponse, HttpStream, NetworkSession};
use std::io::Write;
use std::time::Duration;

#[allow(clippy::too_many_arguments)]
pub(super) fn download(
    path: &FilePath,
    network: &NetworkSession,
    url: &str,
    options: DownloadOptions,
    chunk_size: u64,
    check: &dyn Fn() -> Result<(), String>,
    wait: &dyn Fn(Duration) -> Result<(), String>,
    progress: &mut dyn FnMut(u64, i64),
) -> Result<serde_json::Value, Failure> {
    options.item.start();
    let mut attempts = 0;
    let mut delay = Duration::from_millis(options.policy.initial_retry_delay_ms as u64);
    let probe = loop {
        attempts += 1;
        check().map_err(|error| Failure::new("cancelled", error, attempts))?;
        let response = open(network, url, &options, "bytes=0-1", "", false, check);
        let failure = match response {
            Ok(mut stream) if matches!(stream.response.status, 200 | 206) => {
                // Finish the two-byte range so the first chunk reuses this connection.
                stream.discard(check);
                break stream.response;
            }
            Ok(stream) => {
                let mut failure = status_failure(&stream.response, &options.policy, attempts);
                failure.error = format!("chunked probe HTTP {}", stream.response.status);
                failure
            }
            Err(error) => Failure::new(
                "transient_network",
                format!("chunked probe failed: {error}"),
                attempts,
            ),
        };
        check().map_err(|error| Failure::new("cancelled", error, attempts))?;
        if attempts >= options.policy.max_attempts
            || (failure.http_status > 0 && !retryable(failure.http_status))
        {
            return Err(failure);
        }
        wait(retry_delay(&failure, delay))
            .map_err(|error| Failure::new("cancelled", error, attempts))?;
        delay = next_delay(delay, &options.policy);
    };
    let total = total_length(&probe);
    let validator = validator(&probe);
    let fingerprint = fingerprint(url);
    let mut output = DownloadFile::open(
        path,
        &fingerprint,
        options.persistent && !validator.is_empty() && !fingerprint.is_empty(),
    )
    .map_err(|error| {
        Failure::new(
            "storage_error",
            format!("failed to create chunked staged file: {error}"),
            0,
        )
    })?;
    if output.restored
        && (output.state.validator != validator
            || (output.state.total > 0 && total > 0 && output.state.total != total))
    {
        output
            .restart()
            .map_err(|error| Failure::new("storage_error", error, 0))?;
    }
    output.state.validator = validator.clone();
    output.state.total = total;
    options.item.initial(output.state.bytes, total);
    let reporter = options.item.reporter(output.state.bytes, total);
    let mut notified = output.state.bytes;
    let mut completed_chunk = false;
    let mut buffer = [0; 64 << 10];
    while output.state.total <= 0 || output.state.bytes < output.state.total as u64 {
        let mut start = output.state.bytes;
        let mut end = start.saturating_add(chunk_size - 1);
        if output.state.total > 0 {
            end = end.min(output.state.total as u64 - 1);
        }
        let mut delay = Duration::from_millis(options.policy.initial_retry_delay_ms as u64);
        let mut full_response = false;
        let mut chunk_complete = false;
        let mut failure = Failure::new("transient_network", "chunked transfer failed", attempts);
        for attempt in 1..=options.policy.max_attempts {
            attempts += 1;
            check().map_err(|error| Failure::new("cancelled", error, attempts))?;
            let continuation = attempt == 1 && completed_chunk;
            let response = open(
                network,
                url,
                &options,
                &format!("bytes={start}-{end}"),
                &validator,
                continuation,
                check,
            );
            let mut stream = match response {
                Ok(stream) => stream,
                Err(error) => {
                    check().map_err(|error| Failure::new("cancelled", error, attempts))?;
                    failure = Failure::new(
                        "transient_network",
                        format!("chunked request at {start} failed: {error}"),
                        attempts,
                    );
                    if attempt == options.policy.max_attempts {
                        break;
                    }
                    wait(delay).map_err(|error| Failure::new("cancelled", error, attempts))?;
                    delay = next_delay(delay, &options.policy);
                    continue;
                }
            };
            let status = stream.response.status;
            if !matches!(status, 200 | 206) {
                failure = status_failure(&stream.response, &options.policy, attempts);
                failure.error = format!("chunked HTTP {status} at offset {start}");
                stream.discard(check);
                if !retryable(status) || attempt == options.policy.max_attempts {
                    break;
                }
                wait(retry_delay(&failure, delay))
                    .map_err(|error| Failure::new("cancelled", error, attempts))?;
                delay = next_delay(delay, &options.policy);
                continue;
            }
            let range = header(&stream.response, "Content-Range");
            if status == 206 && !range.starts_with(&format!("bytes {start}-")) {
                let mut failure = Failure::new(
                    "integrity_failed",
                    format!("chunked response has unexpected Content-Range {range:?} at {start}"),
                    attempts,
                );
                failure.http_status = status;
                return Err(failure);
            }
            let next_validator = super::validator(&stream.response);
            if !next_validator.is_empty() && !validator.is_empty() && next_validator != validator {
                return Err(Failure::new(
                    "integrity_failed",
                    "chunked response validator changed during transfer",
                    attempts,
                ));
            }
            let length = header(&stream.response, "Content-Length")
                .parse::<i64>()
                .unwrap_or(-1);
            if status == 200 && start > 0 {
                output.restart().map_err(|error| {
                    Failure::new(
                        "storage_error",
                        format!("failed to restart ignored range: {error}"),
                        attempts,
                    )
                })?;
                output.state.validator = validator.clone();
                start = 0;
                if length > 0 {
                    output.state.total = length;
                }
            }
            let mut received = continuation;
            let body_result = loop {
                let guard = options
                    .budget
                    .as_ref()
                    .map(|budget| budget.enter(!received));
                let read = stream.read(&mut buffer, check);
                drop(guard);
                match read {
                    Ok(0) => break Ok(()),
                    Ok(count) => {
                        received = true;
                        output.file.write_all(&buffer[..count]).map_err(|error| {
                            Failure::new(
                                "storage_error",
                                format!("failed to write chunked output: {error}"),
                                attempts,
                            )
                        })?;
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
                    }
                    Err(error) => break Err(error),
                }
            };
            drop(stream);
            let written = output.state.bytes - start;
            let expected = if status == 206 && length <= 0 {
                end.saturating_sub(start).saturating_add(1) as i64
            } else {
                length
            };
            let body_result = body_result.and_then(|()| {
                if expected > 0 && written != expected as u64 {
                    Err("unexpected EOF".into())
                } else {
                    Ok(())
                }
            });
            if body_result.is_ok() && written > 0 {
                full_response = status == 200;
                chunk_complete = true;
                completed_chunk = true;
                break;
            }
            output.rewind(start).map_err(|error| {
                Failure::new(
                    "storage_error",
                    format!("failed to roll back incomplete chunk: {error}"),
                    attempts,
                )
            })?;
            if output.state.total > 0 {
                options.item.set(
                    start as f64 / output.state.total as f64,
                    start,
                    output.state.total,
                );
            }
            failure = Failure::new(
                "transient_network",
                body_result.err().map_or_else(
                    || format!("chunk at {start} was empty"),
                    |error| format!("failed to read chunk at {start}: {error}"),
                ),
                attempts,
            );
            if let Err(error) = check() {
                output.checkpoint(true);
                return Err(Failure::new("cancelled", error, attempts));
            }
            if attempt == options.policy.max_attempts {
                break;
            }
            wait(delay).map_err(|error| Failure::new("cancelled", error, attempts))?;
            delay = next_delay(delay, &options.policy);
        }
        if !chunk_complete {
            output.checkpoint(true);
            return Err(failure);
        }
        output.checkpoint(false);
        if full_response || (output.state.total <= 0 && output.state.bytes - start < chunk_size) {
            break;
        }
    }
    if output.state.bytes == 0
        || (output.state.total > 0 && output.state.bytes != output.state.total as u64)
    {
        return Err(Failure::new(
            "integrity_failed",
            format!(
                "chunked transfer size mismatch: expected {} bytes, wrote {}",
                output.state.total, output.state.bytes
            ),
            attempts,
        ));
    }
    output.publish(check).map_err(|error| {
        Failure::new(
            "storage_error",
            format!("failed to publish file: {error}"),
            attempts,
        )
    })?;
    options
        .item
        .set(1.0, output.state.bytes, output.state.bytes as i64);
    Ok(
        serde_json::json!({"success":true,"path":path.display(),"size":output.state.bytes,"attempts":attempts}),
    )
}

#[allow(clippy::too_many_arguments)]
fn open(
    network: &NetworkSession,
    url: &str,
    options: &DownloadOptions,
    range: &str,
    validator: &str,
    continuation: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<HttpStream, String> {
    let mut headers = options.headers.clone();
    set_header(&mut headers, "Range", range.to_owned());
    if !validator.is_empty() {
        set_header(&mut headers, "If-Range", validator.to_owned());
    }
    let user_agent = options
        .headers
        .get("User-Agent")
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| options.app_version.user_agent());
    set_header(&mut headers, "User-Agent", user_agent.clone());
    let _guard = options
        .budget
        .as_ref()
        .map(|budget| budget.enter(!continuation));
    network.open_stream(
        HttpRequest {
            url: url.to_owned(),
            method: "GET".into(),
            body: String::new(),
            headers,
            default_json: false,
            user_agent,
        },
        Duration::from_secs(24 * 60 * 60),
        Duration::from_secs(60),
        check,
    )
}

fn total_length(response: &HttpResponse) -> i64 {
    if let Some((_, total)) = header(response, "Content-Range").rsplit_once('/') {
        // Go's chunk probe uses Sscanf rather than the ordinary strict parser.
        let prefix: String = total
            .trim_start()
            .chars()
            .enumerate()
            .take_while(|(index, ch)| {
                ch.is_ascii_digit() || (*index == 0 && (*ch == '-' || *ch == '+'))
            })
            .map(|(_, ch)| ch)
            .collect();
        if let Ok(total) = prefix.parse() {
            return total;
        }
    }
    if response.status == 200 {
        header(response, "Content-Length").parse().unwrap_or(-1)
    } else {
        0
    }
}

fn retry_delay(failure: &Failure, fallback: Duration) -> Duration {
    if failure.retry_after_seconds > 0 {
        Duration::from_secs(failure.retry_after_seconds.into())
    } else {
        fallback
    }
}
