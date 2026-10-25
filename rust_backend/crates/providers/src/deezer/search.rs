use super::{
    Check, DeezerClient, ResolverError,
    cache::{Bucket, Value},
};
use spotiflac_core::metadata::{
    SearchAlbumResult, SearchAllResult, SearchArtistResult, SearchPlaylistResult,
    deezer::{self, AlbumSearch, ArtistSearch, PlaylistSearch, TrackSearch},
};
use spotiflac_network::query;
use std::sync::Arc;

impl DeezerClient {
    pub fn search_all(
        &self,
        query: &str,
        track_limit: isize,
        artist_limit: isize,
        filter: &str,
        check: &Check<'_>,
    ) -> Result<Arc<SearchAllResult>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        let (tracks, artists, albums, playlists) = match filter {
            "track" => (50, 0, 0, 0),
            "artist" => (0, 20, 0, 0),
            "album" => (0, 0, 20, 0),
            "playlist" => (0, 0, 0, 20),
            _ => (track_limit, artist_limit, 5, 5),
        };
        if tracks < 0 || artists < 0 {
            return Err(ResolverError::Failed("negative search limit".into()));
        }
        let key = format!("deezer:all:{query}:{tracks}:{artists}:{albums}:{playlists}:{filter}");
        if let Some(Value::Search(result)) = self.cached(Bucket::Search, &key) {
            return Ok(result);
        }
        let mut parameters = query::Query::new();
        query::set(&mut parameters, "q", query);
        let encoded = query::encode(&parameters);
        let endpoint = |kind: &str, limit: isize| {
            format!("https://api.deezer.com/2.0/search/{kind}?{encoded}&limit={limit}")
        };
        let mut result = SearchAllResult::default();
        if tracks > 0 {
            let response: TrackSearch = self
                .get_json(&endpoint("track", tracks), check)
                .map_err(|error| context(error, "deezer track search failed"))?;
            if let Some(error) = response.error.0 {
                return Err(ResolverError::Failed(format!(
                    "deezer API error: {} (code {})",
                    error.message, error.code
                )));
            }
            result.tracks = response
                .data
                .unwrap_or_default()
                .iter()
                .map(|track| track.metadata())
                .collect();
        }
        let fetch_artists = || {
            (artists > 0)
                .then(|| self.get_json::<ArtistSearch>(&endpoint("artist", artists), check))
        };
        let fetch_albums = || {
            (albums > 0).then(|| self.get_json::<AlbumSearch>(&endpoint("album", albums), check))
        };
        let fetch_playlists = || {
            (playlists > 0)
                .then(|| self.get_json::<PlaylistSearch>(&endpoint("playlist", playlists), check))
        };
        let parallel = [artists, albums, playlists]
            .into_iter()
            .filter(|n| *n > 0)
            .count()
            > 1;
        let (artist_response, album_response, playlist_response) = std::thread::scope(|scope| {
            let artist = (parallel && artists > 0).then(|| {
                std::thread::Builder::new()
                    .name("search-artists".into())
                    .spawn_scoped(scope, fetch_artists)
            });
            let album = (parallel && albums > 0).then(|| {
                std::thread::Builder::new()
                    .name("search-albums".into())
                    .spawn_scoped(scope, fetch_albums)
            });
            let playlist = fetch_playlists();
            let artist = match artist {
                Some(Ok(worker)) => worker
                    .join()
                    .map_err(|_| ResolverError::Failed("artist search panicked".into()))?,
                _ => fetch_artists(),
            };
            let album = match album {
                Some(Ok(worker)) => worker
                    .join()
                    .map_err(|_| ResolverError::Failed("album search panicked".into()))?,
                _ => fetch_albums(),
            };
            Ok::<_, ResolverError>((artist, album, playlist))
        })?;
        if let Some(response) = artist_response {
            match response {
                Ok(response) if response.error.0.is_none() => {
                    result.artists = response
                        .data
                        .unwrap_or_default()
                        .iter()
                        .map(|artist| SearchArtistResult {
                            id: format!("deezer:{}", artist.id),
                            name: artist.name.clone(),
                            images: artist.image(),
                            followers: artist.nb_fan,
                            popularity: 0,
                        })
                        .collect();
                }
                Err(error @ (ResolverError::Cancelled(_) | ResolverError::Closed)) => {
                    return Err(error);
                }
                _ => {}
            }
        }
        if let Some(response) = album_response {
            match response {
                Ok(response) if response.error.0.is_none() => {
                    result.albums = response
                        .data
                        .unwrap_or_default()
                        .iter()
                        .map(|album| SearchAlbumResult {
                            id: format!("deezer:{}", album.id),
                            name: album.title.clone(),
                            artists: album.artist.name.clone(),
                            images: album.image(),
                            release_date: album.release_date.clone(),
                            total_tracks: album.nb_tracks,
                            album_type: deezer::album_type(&album.record_type),
                        })
                        .collect();
                }
                Err(error @ (ResolverError::Cancelled(_) | ResolverError::Closed)) => {
                    return Err(error);
                }
                _ => {}
            }
        }
        if let Some(response) = playlist_response {
            match response {
                Ok(response) if response.error.0.is_none() => {
                    result.playlists = response
                        .data
                        .unwrap_or_default()
                        .iter()
                        .map(|playlist| SearchPlaylistResult {
                            id: format!("deezer:{}", playlist.id),
                            name: playlist.title.clone(),
                            owner: playlist.user.name.clone(),
                            images: playlist.image(),
                            total_tracks: playlist.nb_tracks,
                        })
                        .collect();
                }
                Err(error @ (ResolverError::Cancelled(_) | ResolverError::Closed)) => {
                    return Err(error);
                }
                _ => {}
            }
        }
        check().map_err(ResolverError::Cancelled)?;
        let result = Arc::new(result);
        self.store(Bucket::Search, key, Value::Search(result.clone()));
        Ok(result)
    }
}

pub(super) fn context(error: ResolverError, message: &str) -> ResolverError {
    match error {
        ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy => error,
        _ => ResolverError::Failed(format!("{message}: {error}")),
    }
}
