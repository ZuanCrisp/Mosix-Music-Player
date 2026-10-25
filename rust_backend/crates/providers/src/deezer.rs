//! Deezer metadata used by native lookups, browsing and platform resolution.

mod browse;
mod cache;
mod extended;
mod search;

use crate::resolver::{Check, ResolverError, http::ResolverHttp};
use serde::de::DeserializeOwned;
use spotiflac_core::{
    lyrics,
    metadata::{
        TrackMetadata,
        deezer::{Track, Tracks},
    },
};
use spotiflac_network::NetworkService;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

pub trait MetadataLookup: Send + Sync + 'static {
    /// Observe `check` during HTTP calls and retry waits so native shutdown can
    /// wait for outstanding metadata requests to release their resources.
    fn search_by_isrc(&self, isrc: &str, check: &Check<'_>)
    -> Result<TrackMetadata, ResolverError>;
}

pub struct DeezerClient {
    http: ResolverHttp,
    language: Mutex<String>,
    cache: Mutex<cache::Cache>,
    flights: Mutex<BTreeMap<String, Arc<cache::Flight>>>,
}

impl DeezerClient {
    pub fn new(network: &Arc<NetworkService>) -> Self {
        Self::with_endpoint(network, "https://api.deezer.com").expect("default Deezer endpoint")
    }

    pub fn with_endpoint(
        network: &Arc<NetworkService>,
        endpoint: &str,
    ) -> Result<Self, ResolverError> {
        Ok(Self {
            http: ResolverHttp::new(
                network,
                BTreeMap::from([("https://api.deezer.com".into(), endpoint.into())]),
                Duration::from_secs(25),
            )?,
            language: Mutex::new(String::new()),
            cache: Mutex::new(cache::Cache::default()),
            flights: Mutex::new(BTreeMap::new()),
        })
    }

    pub fn set_language(&self, tag: &str) {
        *self.language.lock().unwrap() = tag.trim().into();
    }

    pub fn get_track(&self, id: &str, check: &Check<'_>) -> Result<TrackMetadata, ResolverError> {
        let track: Track =
            self.get_json(&format!("https://api.deezer.com/2.0/track/{id}"), check)?;
        Ok(track.metadata())
    }

    fn get_json<T: DeserializeOwned>(
        &self,
        endpoint: &str,
        check: &Check<'_>,
    ) -> Result<T, ResolverError> {
        if endpoint.len() > 64 << 10 {
            return Err(ResolverError::Failed("metadata URL exceeds limit".into()));
        }
        let mut retry_after = Duration::ZERO;
        for attempt in 0..3 {
            if attempt > 0 {
                let delay = if retry_after.is_zero() {
                    Duration::from_millis(500 << (attempt - 1))
                } else {
                    retry_after
                };
                let started = Instant::now();
                while started.elapsed() < delay {
                    check().map_err(ResolverError::Cancelled)?;
                    std::thread::sleep(
                        delay
                            .saturating_sub(started.elapsed())
                            .min(Duration::from_millis(25)),
                    );
                }
            }
            check().map_err(ResolverError::Cancelled)?;
            let language = self.language.lock().unwrap().clone();
            let language = if language.is_empty() || language.to_ascii_lowercase().starts_with("en")
            {
                "en-US,en;q=0.9".into()
            } else {
                format!("{language},en;q=0.8")
            };
            let response = match self.http.metadata(endpoint, &language, check) {
                Ok(response) => response,
                Err(ResolverError::Transport(_)) if attempt < 2 => {
                    retry_after = Duration::ZERO;
                    continue;
                }
                Err(error) => return Err(error),
            };
            if response.status == 200 {
                let result = lyrics::decode_document(&response.body);
                check().map_err(ResolverError::Cancelled)?;
                return result.map_err(|error| ResolverError::Failed(error.to_string()));
            }
            if attempt < 2 && (response.status == 429 || response.status >= 500) {
                retry_after = response
                    .headers
                    .get("retry-after")
                    .and_then(|values| values.first())
                    .map(|value| retry_delay(value, SystemTime::now()))
                    .unwrap_or_default();
                continue;
            }
            return Err(ResolverError::Failed(format!(
                "deezer API returned status {}: {}",
                response.status,
                lyrics::text_from_bytes(&response.body)
            )));
        }
        unreachable!("last metadata attempt returns its result")
    }
}

impl MetadataLookup for DeezerClient {
    fn search_by_isrc(
        &self,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<TrackMetadata, ResolverError> {
        let track = self.get_json::<Track>(
            &format!("https://api.deezer.com/2.0/track/isrc:{isrc}"),
            check,
        );
        match track {
            Ok(track) if track.id != 0 => Ok(track.metadata()),
            Ok(_) => Err(ResolverError::Failed(format!(
                "no track found for ISRC: {isrc}"
            ))),
            Err(error @ ResolverError::Cancelled(_)) => Err(error),
            Err(_) => {
                let tracks: Tracks = self.get_json(
                    &format!("https://api.deezer.com/2.0/search/track?q=isrc:{isrc}&limit=1"),
                    check,
                )?;
                tracks
                    .data
                    .as_deref()
                    .unwrap_or_default()
                    .first()
                    .map(Track::metadata)
                    .ok_or_else(|| {
                        ResolverError::Failed(format!("no track found for ISRC: {isrc}"))
                    })
            }
        }
    }
}

pub fn retry_delay(value: &str, now: SystemTime) -> Duration {
    if let Ok(seconds) = value.parse::<isize>() {
        let nanos = (seconds as i64)
            .wrapping_mul(1_000_000_000)
            .min(120_000_000_000);
        return Duration::from_nanos(nanos.max(0) as u64);
    }
    httpdate::parse_http_date(value)
        .ok()
        .and_then(|date| date.duration_since(now).ok())
        .unwrap_or_default()
        .min(Duration::from_secs(120))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_preserves_integer_overflow_dates_and_two_minute_cap() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        for (input, expected) in [
            ("", 0),
            ("0", 0),
            ("1", 1),
            ("+2", 2),
            ("-1", 0),
            ("121", 120),
            (" 1", 0),
            ("9223372036854775807", 0),
        ] {
            assert_eq!(
                retry_delay(input, now),
                Duration::from_secs(expected),
                "{input}"
            );
        }
        assert_eq!(
            retry_delay(&httpdate::fmt_http_date(now + Duration::from_secs(30)), now),
            Duration::from_secs(30)
        );
        assert_eq!(
            retry_delay(
                &httpdate::fmt_http_date(now + Duration::from_secs(300)),
                now
            ),
            Duration::from_secs(120)
        );
        assert_eq!(
            retry_delay(&httpdate::fmt_http_date(now - Duration::from_secs(30)), now),
            Duration::ZERO
        );
    }
}
