use super::{TrackMetadata, zero};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlbumTrackMetadata {
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
    pub album_url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub album_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub composer: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub explicit: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlbumInfoMetadata {
    pub total_tracks: isize,
    pub name: String,
    pub release_date: String,
    pub artists: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub artist_id: String,
    pub images: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub genre: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub label: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub copyright: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlbumResponsePayload {
    pub album_info: AlbumInfoMetadata,
    pub track_list: Vec<AlbumTrackMetadata>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistTrackCount {
    pub total: isize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistOwner {
    pub display_name: String,
    pub name: String,
    pub images: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistInfoMetadata {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub images: String,
    pub tracks: PlaylistTrackCount,
    pub owner: PlaylistOwner,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistResponsePayload {
    pub playlist_info: PlaylistInfoMetadata,
    pub track_list: Vec<AlbumTrackMetadata>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ArtistInfoMetadata {
    pub id: String,
    pub name: String,
    pub images: String,
    pub followers: isize,
    pub popularity: isize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ArtistAlbumMetadata {
    pub id: String,
    pub name: String,
    pub release_date: String,
    pub total_tracks: isize,
    pub images: String,
    pub album_type: String,
    pub artists: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ArtistResponsePayload {
    pub artist_info: ArtistInfoMetadata,
    pub albums: Vec<ArtistAlbumMetadata>,
}

pub type SearchArtistResult = ArtistInfoMetadata;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SearchAlbumResult {
    pub id: String,
    pub name: String,
    pub artists: String,
    pub images: String,
    pub release_date: String,
    pub total_tracks: isize,
    pub album_type: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SearchPlaylistResult {
    pub id: String,
    pub name: String,
    pub owner: String,
    pub images: String,
    pub total_tracks: isize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SearchAllResult {
    pub tracks: Vec<TrackMetadata>,
    pub artists: Vec<SearchArtistResult>,
    pub albums: Vec<SearchAlbumResult>,
    pub playlists: Vec<SearchPlaylistResult>,
}

// Go's internal extended-metadata response has exported, untagged fields.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "PascalCase")]
pub struct AlbumExtendedMetadata {
    pub genre: String,
    pub label: String,
    pub copyright: String,
}
