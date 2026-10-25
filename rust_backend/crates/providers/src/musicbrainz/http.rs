use super::{Fetch, MusicBrainzOptions, Outcome, POLL};
use crate::resolver::{Check, ResolverError, urls::query_escape};
use spotiflac_core::lyrics::decode_response;
use spotiflac_network::{
    HttpRequest, HttpStream, NetworkService, NetworkSession, random_user_agent, url::UrlParts,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_BODY: usize = 16 << 20;

pub(super) struct Http {
    session: Arc<NetworkSession>,
    endpoint: String,
    timeout: Duration,
    retry_delay: Duration,
}

impl Http {
    pub fn new(
        network: &Arc<NetworkService>,
        options: &MusicBrainzOptions,
    ) -> Result<Self, ResolverError> {
        let endpoint = UrlParts::parse(&options.endpoint)
            .ok_or_else(|| ResolverError::Failed("invalid MusicBrainz origin".into()))?;
        if endpoint.scheme != "https"
            || endpoint.hostname.is_empty()
            || endpoint.has_credentials
            || !matches!(endpoint.raw_path.as_str(), "" | "/")
            || !endpoint.raw_query.is_empty()
            || !endpoint.fragment.is_empty()
        {
            return Err(ResolverError::Failed(
                "MusicBrainz endpoint requires an HTTPS origin without credentials".into(),
            ));
        }
        if options.http_timeout.is_zero() {
            return Err(ResolverError::Failed(
                "MusicBrainz HTTP timeout must be positive".into(),
            ));
        }
        Ok(Self {
            session: network.native_session(options.http_timeout),
            endpoint: options.endpoint.trim_end_matches('/').into(),
            timeout: options.http_timeout,
            retry_delay: options.retry_delay,
        })
    }

    fn wait_retry(&self, check: &Check<'_>) -> Result<(), ResolverError> {
        let started = Instant::now();
        while started.elapsed() < self.retry_delay {
            check().map_err(ResolverError::Cancelled)?;
            std::thread::sleep(self.retry_delay.saturating_sub(started.elapsed()).min(POLL));
        }
        check().map_err(ResolverError::Cancelled)
    }
}

fn failure(message: String, check: &Check<'_>) -> ResolverError {
    if let Err(cancelled) = check() {
        ResolverError::Cancelled(cancelled)
    } else if message == "network policy changed" {
        ResolverError::Cancelled(message)
    } else {
        ResolverError::Transport(message)
    }
}

impl Fetch for Http {
    fn fetch(&self, isrc: &str, check: &Check<'_>) -> Outcome {
        let url = format!(
            "{}/ws/2/recording?query={}&fmt=json&inc=tags+releases+artist-credits",
            self.endpoint,
            query_escape(&format!("isrc:{isrc}"))
        );
        // Go chooses a browser UA once per lookup and reuses it for retries.
        let user_agent = random_user_agent();
        for attempt in 0..3 {
            if attempt > 0 {
                self.wait_retry(check)?;
            }
            check().map_err(ResolverError::Cancelled)?;
            let stream = self.session.open_stream(
                HttpRequest {
                    url: url.clone(),
                    method: "GET".into(),
                    body: String::new(),
                    headers: BTreeMap::new(),
                    default_json: false,
                    user_agent: user_agent.clone(),
                },
                self.timeout,
                self.timeout,
                check,
            );
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(message) => {
                    let error = failure(message, check);
                    if matches!(error, ResolverError::Cancelled(_)) || attempt == 2 {
                        return Err(error);
                    }
                    continue;
                }
            };
            let status = stream.response.status;
            if status != 200 {
                // Failed statuses retry without waiting for their body to finish.
                drop(stream);
                if attempt == 2 {
                    return Err(ResolverError::Failed(format!(
                        "MusicBrainz API returned status: {status}"
                    )));
                }
                continue;
            }
            // Decode/body failures occur after Client.Do in Go and are not retried.
            let body = read_json(&mut stream, check)?;
            let result = decode_response(&body)
                .map(Arc::new)
                .map_err(|error| ResolverError::Failed(error.to_string()));
            check().map_err(ResolverError::Cancelled)?;
            return result;
        }
        unreachable!("last MusicBrainz attempt returns its result")
    }
}

// Locate the first complete compound/string JSON value in one linear scan.
// Go's Decoder.Decode can return before EOF, including a trailing stalled body.
// Full syntax and field validation remain the typed decoder's responsibility.
#[derive(Default)]
struct Boundary {
    started: bool,
    compound: bool,
    depth: usize,
    quoted: bool,
    escaped: bool,
}

impl Boundary {
    fn byte(&mut self, byte: u8) -> bool {
        if !self.started {
            if matches!(byte, b' ' | b'\t' | b'\r' | b'\n') {
                return false;
            }
            self.started = true;
            self.compound = matches!(byte, b'{' | b'[' | b'"');
        }
        if self.quoted {
            if self.escaped {
                self.escaped = false;
            } else if byte == b'\\' {
                self.escaped = true;
            } else if byte == b'"' {
                self.quoted = false;
                return self.depth == 0;
            }
        } else {
            match byte {
                b'"' => self.quoted = true,
                b'{' | b'[' => self.depth += 1,
                b'}' | b']' => {
                    self.depth = self.depth.saturating_sub(1);
                    return self.depth == 0;
                }
                b' ' | b'\t' | b'\r' | b'\n' if !self.compound => return true,
                _ => {}
            }
        }
        false
    }
}

fn read_json(stream: &mut HttpStream, check: &Check<'_>) -> Result<Vec<u8>, ResolverError> {
    let mut boundary = Boundary::default();
    let mut body = Vec::new();
    let mut buffer = [0; 16 << 10];
    loop {
        let count = stream
            .read(&mut buffer, check)
            .map_err(|message| failure(message, check))?;
        if count == 0 {
            return Ok(body);
        }
        let end = buffer[..count].iter().position(|byte| boundary.byte(*byte));
        let length = end.map_or(count, |index| index + 1);
        if body.len() + length > MAX_BODY {
            return Err(ResolverError::Failed(
                "MusicBrainz response exceeds limit".into(),
            ));
        }
        body.extend_from_slice(&buffer[..length]);
        if end.is_some() {
            return Ok(body);
        }
    }
}
