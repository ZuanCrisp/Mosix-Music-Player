use super::{Prepared, PreparedDownloads};
use crate::backend::Backend;
use mornye_core::downloads::DownloadRequest;
use std::time::{Duration, Instant};

impl Backend {
    pub(super) fn cache_prepared(
        &self,
        key: &str,
        request: &DownloadRequest,
        metadata_ready: bool,
    ) {
        if request.item_id.trim().is_empty() {
            return;
        }
        let mut cache = self
            .prepared_downloads
            .lock()
            .expect("prepared downloads lock");
        prune(&mut cache);
        cache.insert(
            request.item_id.trim().into(),
            Prepared {
                key: key.into(),
                request: request.clone(),
                metadata_ready,
                created: Instant::now(),
            },
        );
    }

    pub(super) fn take_prepared(&self, key: &str, request: &mut DownloadRequest) -> Option<bool> {
        let mut cache = self
            .prepared_downloads
            .lock()
            .expect("prepared downloads lock");
        prune(&mut cache);
        let prepared = cache
            .remove(request.item_id.trim())
            .filter(|entry| entry.key == key)?;
        let mut fresh = serde_json::to_value(&*request).expect("download request serialization");
        let old = serde_json::to_value(prepared.request).expect("download request serialization");
        for key in [
            "isrc",
            "spotify_id",
            "track_name",
            "artist_name",
            "album_name",
            "album_artist",
            "cover_url",
            "track_number",
            "disc_number",
            "total_tracks",
            "total_discs",
            "release_date",
            "duration_ms",
            "genre",
            "label",
            "copyright",
            "composer",
            "tidal_id",
            "qobuz_id",
            "deezer_id",
        ] {
            fresh[key] = old[key].clone();
        }
        *request = serde_json::from_value(fresh).expect("typed download request");
        Some(prepared.metadata_ready)
    }
}

fn prune(cache: &mut PreparedDownloads) {
    cache.retain(|_, entry| entry.created.elapsed() < Duration::from_secs(300));
    while cache.len() >= 128 {
        let oldest = cache
            .iter()
            .min_by_key(|(_, entry)| entry.created)
            .map(|(id, _)| id.clone())
            .unwrap();
        cache.remove(&oldest);
    }
}

pub(super) fn preparation_key(request: &DownloadRequest) -> String {
    [
        &request.item_id,
        &request.service,
        &request.source,
        &request.spotify_id,
        &request.tidal_id,
        &request.qobuz_id,
        &request.deezer_id,
        &request.track_name,
        &request.artist_name,
    ]
    .into_iter()
    .enumerate()
    .map(|(index, value)| {
        if matches!(index, 1 | 2 | 7 | 8) {
            value.trim().to_lowercase()
        } else {
            value.trim().to_owned()
        }
    })
    .collect::<Vec<_>>()
    .join("\n")
}
