//! Application-facing track/album availability and platform-link contracts.

mod cache;
use super::{Check, Metadata, PlatformResolverService, ResolverError};
pub use cache::AvailabilityService;
use serde::{Deserialize, Serialize};
use spotiflac_core::metadata::TrackMetadata;
use spotiflac_network::{query, url::UrlParts};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackAvailability {
    pub spotify_id: String,
    pub tidal: bool,
    pub amazon: bool,
    pub qobuz: bool,
    pub deezer: bool,
    pub youtube: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub tidal_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub amazon_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub qobuz_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub deezer_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub youtube_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub deezer_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub qobuz_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub tidal_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub youtube_id: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct AlbumAvailability {
    pub spotify_id: String,
    pub deezer: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub deezer_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub deezer_id: String,
}

pub fn from_links(spotify_id: &str, links: &BTreeMap<String, String>) -> TrackAvailability {
    let link = |platform: &str| links.get(platform).cloned().unwrap_or_default();
    let mut result = TrackAvailability {
        spotify_id: spotify_id.into(),
        tidal_url: link("tidal"),
        amazon_url: link("amazonMusic"),
        qobuz_url: link("qobuz"),
        deezer_url: link("deezer"),
        youtube_url: link("youtubeMusic"),
        ..TrackAvailability::default()
    };
    if result.spotify_id.is_empty() {
        result.spotify_id = spotify_id_from_url(&link("spotify"));
    }
    if result.youtube_url.is_empty() {
        result.youtube_url = link("youtube");
    }
    result.tidal = !result.tidal_url.is_empty();
    result.amazon = !result.amazon_url.is_empty();
    result.qobuz = !result.qobuz_url.is_empty();
    result.deezer = !result.deezer_url.is_empty();
    result.youtube = !result.youtube_url.is_empty();
    result.tidal_id = tidal_id_from_url(&result.tidal_url);
    result.qobuz_id = qobuz_id_from_url(&result.qobuz_url);
    result.deezer_id = deezer_id_from_url(&result.deezer_url);
    result.youtube_id = youtube_id_from_url(&result.youtube_url);
    result
}

fn before(value: &str, marker: char) -> &str {
    value
        .find(marker)
        .filter(|index| *index > 0)
        .map_or(value, |index| &value[..index])
}

pub fn deezer_id_from_url(value: &str) -> String {
    before(value.rsplit('/').next().unwrap_or_default(), '?').into()
}
pub fn spotify_id_from_url(value: &str) -> String {
    before(value.split("/track/").nth(1).unwrap_or_default(), '?').into()
}
fn numeric(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

pub fn tidal_id_from_url(value: &str) -> String {
    let value = before(
        before(value.split("/track/").nth(1).unwrap_or_default(), '?'),
        '/',
    )
    .trim();
    if numeric(value) {
        value.into()
    } else {
        String::new()
    }
}

pub fn qobuz_id_from_url(value: &str) -> String {
    let track = tidal_id_from_url(value);
    if !track.is_empty() {
        return track;
    }
    if let Some(id) = value.split("trackId=").nth(1) {
        let id = before(id, '&').trim();
        if numeric(id) {
            return id.into();
        }
    }
    value
        .rsplit('/')
        .map(|part| before(part, '?').trim())
        .find(|part| numeric(part))
        .unwrap_or_default()
        .into()
}

pub fn youtube_id_from_url(value: &str) -> String {
    if let Some(id) = value.split("youtu.be/").nth(1) {
        return before(before(id, '?'), '&').trim().into();
    }
    let Some(url) = UrlParts::parse(value) else {
        return String::new();
    };
    if let Some(id) = query::parse(&url.raw_query)
        .get(b"v".as_slice())
        .and_then(|values| values.first())
        && !id.is_empty()
    {
        return spotiflac_core::lyrics::text_from_bytes(id);
    }
    let path = spotiflac_core::lyrics::text_from_bytes(&url.path);
    path.split("/embed/")
        .nth(1)
        .unwrap_or_default()
        .split('/')
        .next()
        .unwrap_or_default()
        .into()
}

pub fn deezer_id_from_metadata(track: &TrackMetadata) -> String {
    if let Some(id) = track.spotify_id.trim().strip_prefix("deezer:")
        && !id.trim().is_empty()
    {
        return id.trim().into();
    }
    deezer_id_from_url(track.external_urls.trim())
}

fn resolved_links(
    resolver: &PlatformResolverService,
    input: &str,
    check: &Check<'_>,
) -> Result<BTreeMap<String, String>, ResolverError> {
    resolver
        .resolve_url(input, &Metadata::default(), check)
        .map(|result| result.links)
}

fn from_deezer(
    resolver: &PlatformResolverService,
    id: &str,
    check: &Check<'_>,
) -> Result<TrackAvailability, ResolverError> {
    if id.is_empty() {
        return Err(ResolverError::Failed("deezer track ID is empty".into()));
    }
    let input = format!("https://www.deezer.com/track/{id}");
    let mut result = from_links("", &resolved_links(resolver, &input, check)?);
    result.deezer = true;
    result.deezer_id = id.into();
    if result.deezer_url.is_empty() {
        result.deezer_url = input;
    }
    Ok(result)
}

fn album(
    resolver: &PlatformResolverService,
    id: &str,
    check: &Check<'_>,
) -> Result<AlbumAvailability, ResolverError> {
    let links = resolved_links(
        resolver,
        &format!("https://open.spotify.com/album/{id}"),
        check,
    )?;
    let url = links.get("deezer").cloned().unwrap_or_default();
    Ok(AlbumAvailability {
        spotify_id: id.into(),
        deezer: !url.is_empty(),
        deezer_id: deezer_id_from_url(&url),
        deezer_url: url,
    })
}
