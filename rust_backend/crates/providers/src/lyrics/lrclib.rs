use super::{Check, LyricsError, LyricsFetcher, SearchRequest};
use serde::de::DeserializeOwned;
use spotiflac_core::lyrics::{LyricsResponse, decode_response, errors, lrclib, matching};
use spotiflac_network::{HttpRequest, NetworkService, NetworkSession};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use url::Url;

pub struct LrcLibClient {
    session: Arc<NetworkSession>,
    endpoint: Url,
    user_agent: String,
}

impl LrcLibClient {
    pub fn new(network: &Arc<NetworkService>, user_agent: String) -> Self {
        Self::with_endpoint(network, "https://lrclib.net", user_agent)
            .expect("built-in LRCLIB endpoint")
    }

    /// Native configuration only; JavaScript cannot choose provider endpoints.
    pub fn with_endpoint(
        network: &Arc<NetworkService>,
        endpoint: &str,
        user_agent: String,
    ) -> Result<Self, LyricsError> {
        let endpoint =
            Url::parse(endpoint).map_err(|error| LyricsError::Other(error.to_string()))?;
        if endpoint.scheme() != "https"
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
        {
            return Err(LyricsError::Other(
                "LRCLIB requires an HTTPS endpoint without credentials".into(),
            ));
        }
        Ok(Self {
            session: network.native_session(Duration::from_secs(15)),
            endpoint,
            user_agent,
        })
    }

    fn get<T: DeserializeOwned>(
        &self,
        path: &str,
        parameters: &[(&str, &str)],
        check: &Check<'_>,
    ) -> Result<T, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        let mut url = self.endpoint.clone();
        url.set_path(path);
        url.set_query(None);
        url.set_fragment(None);
        url.query_pairs_mut()
            .extend_pairs(parameters.iter().copied());
        self.session
            .validate_url(url.as_str())
            .map_err(LyricsError::Other)?;
        let response = self
            .session
            .request(
                HttpRequest {
                    url: url.into(),
                    method: "GET".into(),
                    body: String::new(),
                    headers: BTreeMap::new(),
                    default_json: false,
                    user_agent: self.user_agent.clone(),
                },
                check,
            )
            .map_err(|error| {
                if let Err(cancelled) = check() {
                    return LyricsError::Cancelled(cancelled);
                }
                if error == "network policy changed" {
                    return LyricsError::Cancelled(error);
                }
                if error.starts_with("response body exceeds ")
                    || error.starts_with("invalid ")
                    || error == "blocking HTTP host called from async executor"
                {
                    LyricsError::Other(format!("failed to fetch lyrics: {error}"))
                } else {
                    LyricsError::Unavailable(format!("failed to fetch lyrics: {error}"))
                }
            })?;
        check().map_err(LyricsError::Cancelled)?;
        if response.status == 404 {
            return Err(LyricsError::NotFound("lyrics not found".into()));
        }
        if response.status != 200 {
            return Err(LyricsError::classified(
                errors::http_status(response.status),
                format!("unexpected status code: {}", response.status),
            ));
        }
        let result = decode_response(&response.body).map_err(|error| {
            let message = format!("failed to decode response: {error}");
            // Go's streaming decoder reports a truncated JSON value as
            // io.ErrUnexpectedEOF, which its connectivity classifier cools down.
            // An entirely empty body instead produces io.EOF and remains Other.
            if error.is_eof()
                && response
                    .body
                    .iter()
                    .any(|byte| !matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
            {
                LyricsError::Unavailable(message)
            } else {
                LyricsError::Other(message)
            }
        });
        check().map_err(LyricsError::Cancelled)?;
        result
    }

    pub fn metadata(
        &self,
        artist: &str,
        track: &str,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let response: lrclib::LrcLibResponse = self.get(
            "/api/get",
            &[("artist_name", artist), ("track_name", track)],
            check,
        )?;
        if !matching::titles_match(response.track_name(), track, false)
            || !matching::artists_match(&response.artist_name, artist)
        {
            return Err(LyricsError::NotFound(
                "LRCLIB returned mismatched track metadata".into(),
            ));
        }
        Ok(response.into_lyrics())
    }

    pub fn search(
        &self,
        query: &str,
        track: &str,
        artist: &str,
        duration: f64,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let results: Option<Vec<lrclib::LrcLibResponse>> =
            self.get("/api/search", &[("q", query)], check)?;
        let results = results.unwrap_or_default();
        if results.is_empty() {
            return Err(LyricsError::NotFound("no lyrics found".into()));
        }
        lrclib::select(&results, query, track, artist, duration)
            .map(lrclib::LrcLibResponse::into_lyrics)
            .ok_or_else(|| LyricsError::NotFound("no matching lyrics found".into()))
    }

    pub fn fetch_lyrics(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let primary = matching::primary_artist(&request.artist);
        let simplified = matching::simplify_track(&request.track);
        let mut metadata = vec![(primary.as_str(), request.track.as_str(), "LRCLIB")];
        if primary != request.artist {
            metadata.push((&request.artist, &request.track, "LRCLIB"));
        }
        if simplified != request.track {
            metadata.push((&primary, &simplified, "LRCLIB (simplified)"));
        }
        for (artist, track, source) in metadata {
            if let Some(lyrics) = accepted(self.metadata(artist, track, check), source)? {
                return Ok(lyrics);
            }
        }
        let mut searches = vec![(request.track.as_str(), "LRCLIB Search")];
        if simplified != request.track {
            searches.push((&simplified, "LRCLIB Search (simplified)"));
        }
        for (track, source) in searches {
            let result = self.search(
                &format!("{primary} {track}"),
                track,
                &primary,
                request.duration,
                check,
            );
            if let Some(lyrics) = accepted(result, source)? {
                return Ok(lyrics);
            }
        }
        Err(LyricsError::NotFound("LRCLIB: no lyrics found".into()))
    }
}

fn accepted(
    result: Result<LyricsResponse, LyricsError>,
    source: &str,
) -> Result<Option<LyricsResponse>, LyricsError> {
    match result {
        Ok(mut lyrics) if !lyrics.lines().is_empty() || lyrics.instrumental => {
            lyrics.source = source.into();
            Ok(Some(lyrics))
        }
        Err(error @ (LyricsError::Unavailable(_) | LyricsError::Cancelled(_))) => Err(error),
        _ => Ok(None),
    }
}

impl LyricsFetcher for LrcLibClient {
    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        if provider != "lrclib" {
            return Err(LyricsError::Other(format!("unknown provider: {provider}")));
        }
        self.fetch_lyrics(request, check)
    }
}
