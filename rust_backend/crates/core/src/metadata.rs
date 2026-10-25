//! Application metadata response schemas and built-in provider conversion.

mod catalog;
pub mod deezer;
pub mod musicbrainz;
pub mod reenrich;
pub mod share;
pub use catalog::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackMetadata {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub spotify_id: String,
    pub artists: String,
    pub name: String,
    pub album_name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub album_artist: String,
    pub duration_ms: isize,
    pub images: String,
    pub release_date: String,
    pub track_number: isize,
    #[serde(skip_serializing_if = "zero")]
    pub total_tracks: isize,
    #[serde(skip_serializing_if = "zero")]
    pub disc_number: isize,
    #[serde(skip_serializing_if = "zero")]
    pub total_discs: isize,
    pub external_urls: String,
    pub isrc: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub album_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub artist_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub album_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub composer: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub explicit: bool,
}

fn zero(value: &isize) -> bool {
    *value == 0
}
