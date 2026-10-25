use super::{
    Check, DeezerClient, ResolverError,
    cache::{Bucket, Value},
};
use spotiflac_core::metadata::{
    AlbumInfoMetadata, AlbumResponsePayload, AlbumTrackMetadata, ArtistAlbumMetadata,
    ArtistInfoMetadata, ArtistResponsePayload, PlaylistInfoMetadata, PlaylistOwner,
    PlaylistResponsePayload, PlaylistTrackCount,
    deezer::{
        self, AlbumTrackCount, ArtistAlbums, FullAlbum, FullArtist, FullPlaylist, Track, TrackPage,
    },
};
use std::collections::BTreeMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Instant;

impl DeezerClient {
    pub fn get_album(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<Arc<AlbumResponsePayload>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        if let Some(Value::Album(value)) = self.cached(Bucket::Album, id) {
            return Ok(value);
        }
        let album: FullAlbum =
            self.get_json(&format!("https://api.deezer.com/2.0/album/{id}"), check)?;
        let image = album.image();
        let artists = match album.contributors.as_deref() {
            Some(values) if !values.is_empty() => values
                .iter()
                .map(|artist| artist.name.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            _ => album.artist.name.clone(),
        };
        let info = AlbumInfoMetadata {
            total_tracks: album.nb_tracks,
            name: album.title.clone(),
            release_date: album.release_date.clone(),
            artists: artists.clone(),
            artist_id: format!("deezer:{}", album.artist.id),
            images: image.clone(),
            genre: album.genres.display(),
            label: album.label.clone(),
            ..Default::default()
        };
        let mut tracks = album.tracks.data.unwrap_or_default();
        self.remaining_tracks("album", id, album.nb_tracks, &mut tracks, check)?;
        let isrcs = self.track_isrcs(&tracks, check)?;
        let discs = tracks
            .iter()
            .map(|track| track.disk_number)
            .max()
            .unwrap_or_default()
            .max(0);
        let mut result = AlbumResponsePayload {
            album_info: info,
            track_list: Vec::with_capacity(tracks.len()),
        };
        for (index, track) in tracks.iter().enumerate() {
            check().map_err(ResolverError::Cancelled)?;
            result.track_list.push(AlbumTrackMetadata {
                spotify_id: format!("deezer:{}", track.id),
                artists: track.artist_display(),
                name: track.title.clone(),
                album_name: album.title.clone(),
                album_artist: artists.clone(),
                duration_ms: track.duration.wrapping_mul(1000),
                images: image.clone(),
                release_date: album.release_date.clone(),
                track_number: if track.track_position == 0 {
                    (index + 1) as isize
                } else {
                    track.track_position
                },
                total_tracks: album.nb_tracks,
                disc_number: track.disk_number,
                total_discs: discs,
                external_urls: track.link.clone(),
                isrc: isrcs
                    .get(&track.id.to_string())
                    .cloned()
                    .unwrap_or_default(),
                album_id: format!("deezer:{}", album.id),
                album_type: deezer::album_type(&album.record_type),
                explicit: track.is_explicit(),
                ..Default::default()
            });
        }
        check().map_err(ResolverError::Cancelled)?;
        let result = Arc::new(result);
        self.store(Bucket::Album, id.into(), Value::Album(result.clone()));
        Ok(result)
    }

    pub fn get_artist(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<Arc<ArtistResponsePayload>, ResolverError> {
        check().map_err(ResolverError::Cancelled)?;
        if let Some(Value::Artist(value)) = self.cached(Bucket::Artist, id) {
            return Ok(value);
        }
        let artist: FullArtist =
            self.get_json(&format!("https://api.deezer.com/2.0/artist/{id}"), check)?;
        let mut result = ArtistResponsePayload {
            artist_info: ArtistInfoMetadata {
                id: format!("deezer:{}", artist.id),
                name: artist.name.clone(),
                images: artist.image(),
                followers: artist.nb_fan,
                popularity: 0,
            },
            albums: Vec::new(),
        };
        match self.get_json::<ArtistAlbums>(
            &format!("https://api.deezer.com/2.0/artist/{id}/albums?limit=100"),
            check,
        ) {
            Ok(response) => {
                for album in response.data.unwrap_or_default() {
                    check().map_err(ResolverError::Cancelled)?;
                    result.albums.push(ArtistAlbumMetadata {
                        id: format!("deezer:{}", album.id),
                        name: album.title.clone(),
                        release_date: album.release_date.clone(),
                        total_tracks: album.nb_tracks,
                        images: album.image(),
                        album_type: deezer::album_type(&album.record_type),
                        artists: artist.name.clone(),
                    });
                }
                let missing: Vec<_> = result
                    .albums
                    .iter()
                    .enumerate()
                    .filter(|(_, album)| album.total_tracks == 0)
                    .map(|(index, album)| {
                        (index, album.id.trim_start_matches("deezer:").to_owned())
                    })
                    .collect();
                for (index, count) in parallel(&missing, |(index, id)| {
                    let count = self
                        .get_json::<AlbumTrackCount>(
                            &format!("https://api.deezer.com/2.0/album/{id}"),
                            check,
                        )
                        .ok()
                        .map(|album| album.nb_tracks);
                    (*index, count)
                }) {
                    if let Some(count) = count {
                        result.albums[index].total_tracks = count;
                    }
                }
            }
            Err(error @ (ResolverError::Cancelled(_) | ResolverError::Closed)) => {
                return Err(error);
            }
            Err(_) => {}
        }
        check().map_err(ResolverError::Cancelled)?;
        let result = Arc::new(result);
        self.store(Bucket::Artist, id.into(), Value::Artist(result.clone()));
        Ok(result)
    }

    pub fn get_playlist(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<PlaylistResponsePayload, ResolverError> {
        let playlist: FullPlaylist =
            self.get_json(&format!("https://api.deezer.com/2.0/playlist/{id}"), check)?;
        // Unlike album/search, Go does not fall back to the smallest image here.
        let image = deezer::best_image([
            playlist.picture_xl.as_str(),
            &playlist.picture_big,
            &playlist.picture_medium,
        ]);
        let info = PlaylistInfoMetadata {
            tracks: PlaylistTrackCount {
                total: playlist.nb_tracks,
            },
            owner: PlaylistOwner {
                display_name: playlist.creator.name,
                name: playlist.title,
                images: image,
            },
            ..Default::default()
        };
        let mut tracks = playlist.tracks.data.unwrap_or_default();
        self.remaining_tracks("playlist", id, playlist.nb_tracks, &mut tracks, check)?;
        let isrcs = self.track_isrcs(&tracks, check)?;
        let mut result = PlaylistResponsePayload {
            playlist_info: info,
            track_list: Vec::with_capacity(tracks.len()),
        };
        for track in tracks {
            check().map_err(ResolverError::Cancelled)?;
            result.track_list.push(AlbumTrackMetadata {
                spotify_id: format!("deezer:{}", track.id),
                artists: track.artist_display(),
                name: track.title.clone(),
                album_name: track.album.title.clone(),
                album_artist: track.artist.name.clone(),
                duration_ms: track.duration.wrapping_mul(1000),
                images: deezer::best_image([
                    track.album.cover_xl.as_str(),
                    &track.album.cover_big,
                    &track.album.cover_medium,
                ]),
                track_number: track.track_position,
                disc_number: track.disk_number,
                external_urls: track.link.clone(),
                isrc: isrcs
                    .get(&track.id.to_string())
                    .cloned()
                    .unwrap_or_default(),
                album_id: format!("deezer:{}", track.album.id),
                explicit: track.is_explicit(),
                ..Default::default()
            });
        }
        Ok(result)
    }

    fn remaining_tracks(
        &self,
        kind: &str,
        id: &str,
        total: isize,
        tracks: &mut Vec<Track>,
        check: &Check<'_>,
    ) -> Result<(), ResolverError> {
        let mut next = format!(
            "https://api.deezer.com/2.0/{kind}/{id}/tracks?limit=100&index={}",
            tracks.len()
        );
        while (tracks.len() as i128) < total as i128 {
            match self.get_json::<TrackPage>(&next, check) {
                Ok(page) => {
                    let data = page.data.unwrap_or_default();
                    if data.is_empty() {
                        break;
                    }
                    tracks.extend(data);
                    if page.next.is_empty() {
                        break;
                    }
                    next = page.next;
                }
                Err(error @ (ResolverError::Cancelled(_) | ResolverError::Closed)) => {
                    return Err(error);
                }
                Err(_) => break,
            }
        }
        check().map_err(ResolverError::Cancelled)
    }

    fn track_isrcs(
        &self,
        tracks: &[Track],
        check: &Check<'_>,
    ) -> Result<BTreeMap<String, String>, ResolverError> {
        let mut result = BTreeMap::new();
        let mut missing = Vec::new();
        check().map_err(ResolverError::Cancelled)?;
        {
            let mut cache = self.cache.lock().unwrap();
            let mut direct = BTreeMap::new();
            for track in tracks {
                let id = track.id.to_string();
                if !track.isrc.is_empty() {
                    result.insert(id.clone(), track.isrc.clone());
                    if !cache.isrc.contains_key(&id) {
                        direct.insert(id, track.isrc.clone());
                    }
                } else if let Some(isrc) = cache.isrc.get(&id) {
                    result.insert(id, isrc.clone());
                } else {
                    missing.push(id);
                }
            }
            cache.isrc.extend(direct);
            cache.cleanup(Instant::now());
        }
        for (id, isrc) in parallel(&missing, |id| {
            let value = self
                .get_json::<Track>(&format!("https://api.deezer.com/2.0/track/{id}"), check)
                .ok();
            if let Some(track) = &value {
                let mut cache = self.cache.lock().unwrap();
                cache.isrc.insert(id.clone(), track.isrc.clone());
                cache.cleanup(Instant::now());
            }
            (id.clone(), value.map(|track| track.isrc))
        }) {
            if let Some(isrc) = isrc {
                result.insert(id, isrc);
            }
        }
        check().map_err(ResolverError::Cancelled)?;
        Ok(result)
    }
}

/// Keep both OS thread count and HTTP concurrency bounded, including very
/// large playlists. Output retains input order, independent of worker timing.
fn parallel<T: Sync, R: Send>(items: &[T], fetch: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let result = Mutex::new(Vec::with_capacity(items.len()));
    std::thread::scope(|scope| {
        for _ in 0..items.len().min(10) {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(index) else {
                        break;
                    };
                    let value = fetch(item);
                    result.lock().unwrap().push((index, value));
                }
            });
        }
    });
    let mut result = result.into_inner().unwrap();
    result.sort_by_key(|(index, _)| *index);
    result.into_iter().map(|(_, result)| result).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parallel_metadata_work_overlaps_without_exceeding_ten_workers_or_reordering_output() {
        let active = AtomicUsize::new(0);
        let peak = AtomicUsize::new(0);
        let items: Vec<_> = (0..60).collect();
        let result = parallel(&items, |index| {
            let count = active.fetch_add(1, Ordering::AcqRel) + 1;
            peak.fetch_max(count, Ordering::AcqRel);
            std::thread::sleep(std::time::Duration::from_millis(10));
            active.fetch_sub(1, Ordering::AcqRel);
            *index
        });
        assert_eq!(result, items);
        assert!((2..=10).contains(&peak.load(Ordering::Acquire)));
        assert_eq!(active.load(Ordering::Acquire), 0);
    }
}
