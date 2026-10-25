use super::{Check, ResolverError, check_active};
use mornye_network::{HttpRequest, NetworkService, NetworkSession, url::UrlParts};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

pub struct ResolverHttp {
    session: Arc<NetworkSession>,
    overrides: BTreeMap<String, String>,
    timeout: Duration,
}

pub struct Response {
    pub url: String,
    pub body: Vec<u8>,
    pub status: u16,
    pub headers: BTreeMap<String, Vec<String>>,
}

impl ResolverHttp {
    pub fn new(
        network: &Arc<NetworkService>,
        overrides: BTreeMap<String, String>,
        timeout: Duration,
    ) -> Result<Self, ResolverError> {
        for (origin, replacement) in &overrides {
            for value in [origin, replacement] {
                let url = UrlParts::parse(value)
                    .ok_or_else(|| ResolverError::Failed("invalid resolver origin".into()))?;
                if url.scheme != "https"
                    || url.hostname.is_empty()
                    || url.has_credentials
                    || !matches!(url.raw_path.as_str(), "" | "/")
                    || !url.raw_query.is_empty()
                    || !url.fragment.is_empty()
                {
                    return Err(ResolverError::Failed(
                        "resolver overrides require HTTPS origins without credentials".into(),
                    ));
                }
            }
        }
        Ok(Self {
            session: network.native_session(timeout),
            overrides,
            timeout,
        })
    }

    pub fn request(
        &self,
        endpoint: &str,
        body: Option<String>,
        html: bool,
        check: &Check<'_>,
    ) -> Result<Response, ResolverError> {
        self.execute(endpoint, body, html, None, check)
    }

    pub fn metadata(
        &self,
        endpoint: &str,
        language: &str,
        check: &Check<'_>,
    ) -> Result<Response, ResolverError> {
        self.execute(endpoint, None, false, Some(language), check)
    }

    fn execute(
        &self,
        endpoint: &str,
        body: Option<String>,
        html: bool,
        language: Option<&str>,
        check: &Check<'_>,
    ) -> Result<Response, ResolverError> {
        check_active(check)?;
        let parts = UrlParts::parse(endpoint)
            .ok_or_else(|| ResolverError::Failed("invalid resolver URL".into()))?;
        let origin = format!("{}://{}", parts.scheme, parts.authority());
        let replacement = self.overrides.get(&origin);
        let endpoint = if let Some(base) = replacement {
            format!(
                "{}{}",
                base.trim_end_matches('/'),
                &endpoint[origin.len()..]
            )
        } else {
            endpoint.into()
        };
        let mut headers = BTreeMap::new();
        if let Some(language) = language {
            headers.insert("Accept".into(), "application/json".into());
            headers.insert("Accept-Language".into(), language.into());
        }
        if html && origin == "https://song.link" {
            headers.insert("Accept".into(), "text/html,application/xhtml+xml".into());
        }
        if body.is_some() {
            headers.insert("Content-Type".into(), "application/json".into());
        }
        let post = body.is_some();
        let failure = |message: String| {
            if let Err(cancelled) = check() {
                ResolverError::Cancelled(cancelled)
            } else if message == "network policy changed" {
                ResolverError::Cancelled(message)
            } else if message.starts_with("invalid ")
                || message == "blocking HTTP host called from async executor"
            {
                ResolverError::Failed(message)
            } else {
                ResolverError::Transport(message)
            }
        };
        let mut stream = self
            .session
            .open_stream(
                HttpRequest {
                    url: endpoint,
                    method: if post { "POST" } else { "GET" }.into(),
                    body: body.unwrap_or_default(),
                    headers,
                    default_json: false,
                    user_agent: if language.is_some() {
                        "Go-http-client/1.1".into()
                    } else {
                        mornye_network::random_user_agent()
                    },
                },
                self.timeout,
                self.timeout,
                check,
            )
            .map_err(failure)?;
        let status = stream.response.status;
        if language.is_none() && status != 200 && !(post && status == 201) {
            return Err(ResolverError::Failed(format!("HTTP {status}")));
        }
        let mut url = stream.response.url.clone();
        if let Some(base) = replacement {
            let base = base.trim_end_matches('/');
            if let Some(suffix) = url.strip_prefix(base)
                && (suffix.is_empty() || suffix.starts_with(['/', '?', '#']))
            {
                url = format!("{origin}{suffix}");
            }
        }
        if origin == "https://song.link" {
            let hostname = UrlParts::parse(&url)
                .map(|parts| parts.hostname.to_ascii_lowercase())
                .unwrap_or_default();
            if !matches!(
                hostname.as_str(),
                "song.link" | "album.link" | "artist.link" | "odesli.co" | "www.odesli.co"
            ) {
                return Err(ResolverError::Failed(
                    "web page redirected to an unexpected host".into(),
                ));
            }
        }
        let limit = if language.is_some() {
            16 << 20
        } else if html {
            8 << 20
        } else {
            2 << 20
        };
        let body = stream
            .read_limited(limit, &mut [0; 16 << 10], check)
            .map_err(failure)?
            .ok_or_else(|| ResolverError::Failed(format!("response exceeds {limit} bytes")))?;
        check_active(check)?;
        if body.is_empty() && language.is_none() {
            return Err(ResolverError::Failed("response body is empty".into()));
        }
        Ok(Response {
            url,
            body,
            status,
            headers: stream.response.headers.clone(),
        })
    }
}
