mod apple;
mod direct;
mod proxy;

pub use direct::genius_text;

use super::{
    Check, LyricsError, LyricsFetcher, SearchRequest,
    http::{LyricsHttp, Params, Request, pairs},
    lrclib::LrcLibClient,
};
use spotiflac_core::app_version::AppVersion;
use spotiflac_core::lyrics::{LyricsResponse, errors, matching, models, text_from_bytes};
use spotiflac_network::NetworkService;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// Shared platform resolution remains a separate domain. Its implementation
/// must preserve the full resolver chain and observe the lookup cancellation.
pub trait TrackResolver: Send + Sync + 'static {
    fn deezer_id_from_spotify(
        &self,
        spotify_id: &str,
        check: &Check<'_>,
    ) -> Result<String, LyricsError>;
}

pub struct BuiltinLyricsClient {
    http: LyricsHttp,
    lrclib: LrcLibClient,
    resolver: Arc<dyn TrackResolver>,
    apple_token: Mutex<String>,
}

impl BuiltinLyricsClient {
    pub fn new(
        network: &Arc<NetworkService>,
        version: impl Into<AppVersion>,
        resolver: Arc<dyn TrackResolver>,
    ) -> Self {
        Self::with_endpoints(network, version, resolver, BTreeMap::new())
            .expect("built-in provider endpoints")
    }

    /// Native-only endpoint injection for integration fixtures or deployments.
    /// The application and extension SDK never accept arbitrary override maps.
    pub fn with_endpoints(
        network: &Arc<NetworkService>,
        version: impl Into<AppVersion>,
        resolver: Arc<dyn TrackResolver>,
        endpoints: BTreeMap<String, String>,
    ) -> Result<Self, LyricsError> {
        Ok(Self {
            lrclib: LrcLibClient::with_endpoint(
                network,
                endpoints
                    .get("https://lrclib.net")
                    .map(String::as_str)
                    .unwrap_or("https://lrclib.net"),
                super::http::BROWSER_UA.into(),
            )?,
            http: LyricsHttp::new(network, version, endpoints)?,
            resolver,
            apple_token: Mutex::new(String::new()),
        })
    }

    pub fn fetch_once(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        match provider {
            "lrclib" => self.lrclib.fetch_lyrics(request, check),
            "netease" => self.netease(request, check),
            "musixmatch" => self.musixmatch(request, check),
            "apple_music" => self.apple(request, check),
            "spotify" => self.spotify(request, check),
            "deezer" => self.deezer(request, check),
            "youtube" => self.youtube(request, check),
            "lyricsplus" => self.lyrics_plus(request, "", check),
            "qqmusic" => self.qqmusic(request, check),
            "kugou" => self.kugou(request, check),
            "genius" => self.genius(request, check),
            _ => Err(LyricsError::Other(format!("unknown provider: {provider}"))),
        }
    }

    fn proxy_body(
        &self,
        endpoint: &str,
        params: Params,
        check: &Check<'_>,
    ) -> Result<String, LyricsError> {
        let mut request = Request::new(endpoint);
        request.params = params;
        request.allowed = &[];
        let response = self.http.get(request, check)?;
        let text = text_from_bytes(&response.body);
        let text = text.trim();
        if let Some(message) = errors::detect_payload(text) {
            return Err(if errors::payload_not_found(&message) {
                LyricsError::NotFound(message)
            } else {
                LyricsError::Unavailable(message)
            });
        }
        if response.status != 200 {
            return Err(LyricsError::Unavailable(format!(
                "HTTP {}",
                response.status
            )));
        }
        if text.is_empty() {
            return Err(LyricsError::Unavailable("empty response".into()));
        }
        Ok(text.into())
    }
}

impl LyricsFetcher for BuiltinLyricsClient {
    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        if provider == "lrclib" {
            return self.fetch_once(provider, request, check);
        }
        let primary = matching::primary_artist(&request.artist);
        let primary_differs = primary != request.artist;
        let simplified = matching::simplify_track(&request.track);
        let mut attempt = request.clone();
        attempt.artist = primary;
        let mut result = self.fetch_once(provider, &attempt, check);
        if retryable(&result) && primary_differs {
            result = self.fetch_once(provider, request, check);
        }
        if retryable(&result)
            && simplified != request.track
            && matches!(
                provider,
                "netease" | "spotify" | "youtube" | "kugou" | "genius" | "lyricsplus"
            )
        {
            attempt.track = simplified;
            if provider == "spotify" {
                attempt.spotify_id.clear();
            }
            result = self.fetch_once(provider, &attempt, check);
        }
        result
    }
}

fn retryable(result: &Result<LyricsResponse, LyricsError>) -> bool {
    matches!(result, Err(error) if !matches!(error, LyricsError::Unavailable(_) | LyricsError::Cancelled(_)))
}

fn from_text(text: &str, provider: &str, source: &str) -> Result<LyricsResponse, LyricsError> {
    let response = LyricsResponse::from_text(text, provider, source);
    if response.has_usable_text() {
        Ok(response)
    } else {
        Err(LyricsError::NotFound(format!(
            "no lyrics found on {provider}"
        )))
    }
}

fn artists(artists: &[models::Artist]) -> String {
    artists
        .iter()
        .map(|artist| artist.name.trim())
        .filter(|name| !name.is_empty())
        .collect::<Vec<_>>()
        .join(", ")
}

fn select<'a, T>(
    values: &'a [T],
    request: &SearchRequest,
    fields: impl Fn(&T) -> (String, String, f64, bool),
) -> Option<&'a T> {
    let mut best = None;
    let mut best_score = -1;
    for value in values {
        let (track, artist, duration, allowed) = fields(value);
        if !allowed {
            continue;
        }
        let score = matching::score(
            &track,
            &artist,
            duration,
            &request.track,
            &request.artist,
            request.duration,
        );
        if score > best_score {
            best = Some(value);
            best_score = score;
        }
    }
    best
}

fn matches(track: &str, artist: &str, duration: f64, request: &SearchRequest) -> bool {
    matching::titles_match(track, &request.track, false)
        && matching::artists_match(artist, &request.artist)
        && matching::duration_matches(duration, request.duration)
}
