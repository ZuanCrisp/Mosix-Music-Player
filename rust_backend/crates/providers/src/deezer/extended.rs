use super::{Check, DeezerClient, MetadataLookup, ResolverError, cache::Value, search::context};
use spotiflac_core::metadata::{
    AlbumExtendedMetadata, TrackMetadata,
    deezer::{FullAlbum, Track},
};
use std::sync::Arc;

impl DeezerClient {
    pub fn get_track_album_id(&self, id: &str, check: &Check<'_>) -> Result<String, ResolverError> {
        match self.coalesced(&format!("track_album:{id}"), check, || {
            let track: Track =
                self.get_json(&format!("https://api.deezer.com/2.0/track/{id}"), check)?;
            Ok(Value::AlbumId(track.album.id.to_string()))
        })? {
            Value::AlbumId(value) => Ok(value),
            _ => unreachable!("track album cache type"),
        }
    }

    pub fn get_album_extended_metadata(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<Arc<AlbumExtendedMetadata>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        if id.is_empty() {
            return Err(ResolverError::Failed("empty album ID".into()));
        }
        match self.coalesced(&format!("album_meta:{id}"), check, || {
            let album: FullAlbum = self
                .get_json(&format!("https://api.deezer.com/2.0/album/{id}"), check)
                .map_err(|error| context(error, "failed to fetch album"))?;
            Ok(Value::Extended(Arc::new(AlbumExtendedMetadata {
                genre: album.genres.display(),
                label: album.label,
                copyright: album.copyright,
            })))
        })? {
            Value::Extended(value) => Ok(value),
            _ => unreachable!("album metadata cache type"),
        }
    }

    pub fn get_extended_metadata_by_track_id(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<Arc<AlbumExtendedMetadata>, ResolverError> {
        let album = self
            .get_track_album_id(id, check)
            .map_err(|error| context(error, "failed to get album ID"))?;
        self.get_album_extended_metadata(&album, check)
    }

    pub fn get_extended_metadata_by_isrc(
        &self,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<Arc<AlbumExtendedMetadata>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        if isrc.is_empty() {
            return Err(ResolverError::Failed("empty ISRC".into()));
        }
        let track = self
            .search_by_isrc(isrc, check)
            .map_err(|error| context(error, "failed to find track by ISRC"))?;
        self.get_extended_metadata_for_track(&track, check)
    }

    pub fn get_extended_metadata_for_track(
        &self,
        track: &TrackMetadata,
        check: &Check<'_>,
    ) -> Result<Arc<AlbumExtendedMetadata>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        let id = track
            .spotify_id
            .strip_prefix("deezer:")
            .unwrap_or(&track.spotify_id);
        if id.is_empty() {
            return Err(ResolverError::Failed("track found but no Deezer ID".into()));
        }
        let album = track
            .album_id
            .strip_prefix("deezer:")
            .unwrap_or(&track.album_id);
        if album.bytes().all(|byte| byte.is_ascii_digit())
            && album.parse::<i64>().is_ok_and(|id| id > 0)
        {
            return self.get_album_extended_metadata(album, check);
        }
        self.get_extended_metadata_by_track_id(id, check)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deezer::cache::Bucket;

    #[test]
    fn known_album_skips_track_lookup_and_invalid_album_uses_existing_fallback() {
        let network = spotiflac_network::NetworkService::new().unwrap();
        let client = DeezerClient::with_endpoint(&network, "https://127.0.0.1:1").unwrap();
        let known = Arc::new(AlbumExtendedMetadata::default());
        let fallback = Arc::new(AlbumExtendedMetadata::default());
        for (key, value) in [
            ("album_meta:100", Value::Extended(known.clone())),
            ("album_meta:200", Value::Extended(fallback.clone())),
            ("track_album:42", Value::AlbumId("200".into())),
        ] {
            client.store(Bucket::Search, key.into(), value);
        }
        let mut track = TrackMetadata {
            spotify_id: "deezer:42".into(),
            ..Default::default()
        };
        for (album, expected) in [
            ("deezer:100", &known),
            ("100", &known),
            ("", &fallback),
            ("deezer:0", &fallback),
            ("0", &fallback),
            ("deezer:-100", &fallback),
            ("deezer:+100", &fallback),
            ("other:100", &fallback),
            ("deezer:9223372036854775808", &fallback),
        ] {
            track.album_id = album.into();
            let result = client
                .get_extended_metadata_for_track(&track, &|| Ok(()))
                .unwrap();
            assert!(Arc::ptr_eq(&result, expected), "album ID: {album}");
        }
        track.album_id = "deezer:100".into();
        assert!(matches!(
            client.get_extended_metadata_for_track(&track, &|| Err("cancelled".into())),
            Err(ResolverError::Cancelled(_))
        ));
        track.spotify_id.clear();
        assert!(matches!(
            client.get_extended_metadata_for_track(&track, &|| Ok(())),
            Err(ResolverError::Failed(message)) if message == "track found but no Deezer ID"
        ));
    }
}
