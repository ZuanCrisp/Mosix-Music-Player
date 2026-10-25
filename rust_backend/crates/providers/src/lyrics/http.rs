use super::{Check, LyricsError};
use serde::de::DeserializeOwned;
use spotiflac_core::app_version::AppVersion;
use spotiflac_core::lyrics::{decode_document, decode_response, errors};
use spotiflac_network::{HttpRequest, HttpStream, NetworkService, NetworkSession};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use url::Url;

pub type Params = BTreeMap<String, String>;
pub const BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";

pub fn pairs(values: &[(&str, &str)]) -> Params {
    values
        .iter()
        .map(|(key, value)| ((*key).into(), (*value).into()))
        .collect()
}

pub struct Request<'a> {
    pub endpoint: &'a str,
    pub params: Params,
    pub headers: Params,
    pub timeout: Duration,
    pub max_bytes: usize,
    /// Empty accepts any status and reads its payload. Explicit non-200 allowed
    /// statuses return immediately without reading a potentially stalled body.
    pub allowed: &'static [u16],
    pub unavailable_errors: bool,
}

impl<'a> Request<'a> {
    pub fn new(endpoint: &'a str) -> Self {
        Self {
            endpoint,
            params: Params::new(),
            headers: pairs(&[("Accept", "application/json")]),
            timeout: Duration::from_secs(15),
            max_bytes: 16 << 20,
            allowed: &[200],
            unavailable_errors: false,
        }
    }
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

pub struct LyricsHttp {
    session: Arc<NetworkSession>,
    app_version: AppVersion,
    overrides: BTreeMap<String, Url>,
}

impl LyricsHttp {
    pub fn new(
        network: &Arc<NetworkService>,
        version: impl Into<AppVersion>,
        overrides: BTreeMap<String, String>,
    ) -> Result<Self, LyricsError> {
        let overrides = overrides
            .into_iter()
            .map(|(origin, replacement)| {
                let url = Url::parse(&replacement)
                    .map_err(|error| LyricsError::Other(error.to_string()))?;
                if url.scheme() != "https"
                    || url.host_str().is_none()
                    || !url.username().is_empty()
                    || url.password().is_some()
                {
                    return Err(LyricsError::Other(
                        "provider override requires HTTPS without credentials".into(),
                    ));
                }
                Ok((origin, url))
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            session: network.native_session(Duration::from_secs(20)),
            app_version: version.into(),
            overrides,
        })
    }

    pub fn get(&self, request: Request<'_>, check: &Check<'_>) -> Result<Response, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        let mut url =
            Url::parse(request.endpoint).map_err(|error| LyricsError::Other(error.to_string()))?;
        if !request.params.is_empty() {
            url.query_pairs_mut().extend_pairs(&request.params);
        }
        if let Some(base) = self.overrides.get(&url.origin().ascii_serialization()) {
            let mut replaced = base.clone();
            replaced.set_path(url.path());
            replaced.set_query(url.query());
            replaced.set_fragment(None);
            url = replaced;
        }
        self.session
            .validate_url(url.as_str())
            .map_err(LyricsError::Other)?;
        let mut stream = self
            .session
            .open_stream(
                HttpRequest {
                    url: url.into(),
                    method: "GET".into(),
                    body: String::new(),
                    headers: request.headers,
                    default_json: false,
                    user_agent: self.app_version.user_agent(),
                },
                request.timeout,
                request.timeout,
                check,
            )
            .map_err(|error| transport_error(error, check))?;
        let status = stream.response.status;
        if !request.allowed.is_empty() && !request.allowed.contains(&status) {
            let message = format!("HTTP {status}");
            return Err(if request.unavailable_errors {
                LyricsError::Unavailable(message)
            } else {
                LyricsError::classified(errors::http_status(status), message)
            });
        }
        if status != 200 && !request.allowed.is_empty() {
            return Ok(Response {
                status,
                body: Vec::new(),
            });
        }
        let body = read(&mut stream, request.max_bytes, check).map_err(|error| {
            if request.unavailable_errors && matches!(error, LyricsError::Other(_)) {
                LyricsError::Unavailable(error.to_string())
            } else {
                error
            }
        })?;
        Ok(Response { status, body })
    }
}

fn transport_error(error: String, check: &Check<'_>) -> LyricsError {
    if let Err(cancelled) = check() {
        return LyricsError::Cancelled(cancelled);
    }
    if error == "network policy changed" {
        return LyricsError::Cancelled(error);
    }
    if error.starts_with("invalid ") || error == "blocking HTTP host called from async executor" {
        LyricsError::Other(error)
    } else {
        LyricsError::Unavailable(error)
    }
}

fn read(stream: &mut HttpStream, limit: usize, check: &Check<'_>) -> Result<Vec<u8>, LyricsError> {
    let mut result = Vec::new();
    let mut buffer = [0; 16 << 10];
    loop {
        let capacity = buffer.len().min(limit + 1 - result.len());
        let count = stream
            .read(&mut buffer[..capacity], check)
            .map_err(|error| transport_error(error, check))?;
        if count == 0 {
            break;
        }
        result.extend_from_slice(&buffer[..count]);
        if result.len() > limit {
            return Err(LyricsError::Other(format!(
                "response exceeds {limit} bytes"
            )));
        }
    }
    check().map_err(LyricsError::Cancelled)?;
    Ok(result)
}

pub fn decode<T: DeserializeOwned>(
    bytes: &[u8],
    streaming: bool,
    check: &Check<'_>,
) -> Result<T, LyricsError> {
    check().map_err(LyricsError::Cancelled)?;
    let result = if streaming {
        decode_response(bytes)
    } else {
        decode_document(bytes)
    };
    check().map_err(LyricsError::Cancelled)?;
    result.map_err(|error| {
        let message = format!("failed to decode lyrics response: {error}");
        if streaming
            && error.is_eof()
            && bytes
                .iter()
                .any(|byte| !matches!(byte, b' ' | b'\t' | b'\n' | b'\r'))
        {
            LyricsError::Unavailable(message)
        } else {
            LyricsError::Other(message)
        }
    })
}
