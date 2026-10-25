//! The native download domain owns cancellation and progress together.

use crate::cancellation::{
    CancellationDomain, CancellationError, CancellationRegistry, RequestLease,
};
use crate::progress::ProgressRegistry;
use std::sync::Arc;

/// Application download input, shared by the strategy and extension facades.
/// Keep Go's null/duplicate/case-folded JSON handling in the existing decoder.
#[derive(Clone, Default, serde::Serialize)]
pub struct DownloadRequest {
    pub contract_version: i64,
    pub isrc: String,
    pub service: String,
    pub download_provider: String,
    pub provider_track_id: String,
    pub spotify_id: String,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub album_artist: String,
    pub cover_url: String,
    pub cover_max_dimension: i64,
    pub output_dir: String,
    pub album_folder_template: String,
    pub output_path: String,
    pub output_fd: i64,
    pub output_ext: String,
    pub filename_format: String,
    pub quality: String,
    pub embed_metadata: bool,
    pub artist_tag_mode: String,
    pub embed_lyrics: bool,
    pub embed_replaygain: bool,
    pub post_processing_enabled: bool,
    pub track_number: i64,
    pub playlist_position: i64,
    pub disc_number: i64,
    pub total_tracks: i64,
    pub total_discs: i64,
    pub release_date: String,
    pub item_id: String,
    pub duration_ms: i64,
    pub source: String,
    pub genre: String,
    pub label: String,
    pub copyright: String,
    pub composer: String,
    pub comment: String,
    pub explicit: bool,
    pub album_type: String,
    pub upc: String,
    pub tidal_id: String,
    pub qobuz_id: String,
    pub deezer_id: String,
    pub lyrics_mode: String,
    pub use_extensions: bool,
    pub use_fallback: bool,
    pub requires_container_conversion: bool,
    pub allow_quality_variant: bool,
    pub quality_variant: String,
    pub songlink_region: String,
    pub network_concurrency_limit: i64,
}

crate::lyrics::json::go_deserialize!(DownloadRequest {
    "contract_version" => contract_version, "isrc" => isrc, "service" => service,
    "download_provider" => download_provider, "provider_track_id" => provider_track_id,
    "spotify_id" => spotify_id, "track_name" => track_name, "artist_name" => artist_name,
    "album_name" => album_name, "album_artist" => album_artist, "cover_url" => cover_url,
    "cover_max_dimension" => cover_max_dimension, "output_dir" => output_dir,
    "album_folder_template" => album_folder_template, "output_path" => output_path,
    "output_fd" => output_fd, "output_ext" => output_ext, "filename_format" => filename_format,
    "quality" => quality, "embed_metadata" => embed_metadata, "artist_tag_mode" => artist_tag_mode,
    "embed_lyrics" => embed_lyrics, "embed_replaygain" => embed_replaygain,
    "post_processing_enabled" => post_processing_enabled, "track_number" => track_number,
    "playlist_position" => playlist_position, "disc_number" => disc_number,
    "total_tracks" => total_tracks, "total_discs" => total_discs, "release_date" => release_date,
    "item_id" => item_id, "duration_ms" => duration_ms, "source" => source, "genre" => genre,
    "label" => label, "copyright" => copyright, "composer" => composer, "comment" => comment,
    "explicit" => explicit, "album_type" => album_type, "upc" => upc, "tidal_id" => tidal_id,
    "qobuz_id" => qobuz_id, "deezer_id" => deezer_id, "lyrics_mode" => lyrics_mode,
    "use_extensions" => use_extensions, "use_fallback" => use_fallback,
    "requires_container_conversion" => requires_container_conversion,
    "allow_quality_variant" => allow_quality_variant, "quality_variant" => quality_variant,
    "songlink_region" => songlink_region, "network_concurrency_limit" => network_concurrency_limit,
});

impl DownloadRequest {
    pub fn parse(raw: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(&crate::text::json_surrogates(raw))
    }

    pub fn normalize(&mut self) {
        for value in [
            &mut self.track_name,
            &mut self.artist_name,
            &mut self.album_name,
            &mut self.album_artist,
            &mut self.output_dir,
            &mut self.output_path,
            &mut self.output_ext,
        ] {
            *value = value.trim().to_owned();
        }
    }
}

pub struct DownloadState {
    pub progress: Arc<ProgressRegistry>,
    pub cancellation: Arc<CancellationRegistry>,
}

impl Default for DownloadState {
    fn default() -> Self {
        Self {
            progress: Arc::new(ProgressRegistry::new()),
            cancellation: Arc::new(CancellationRegistry::new(CancellationDomain::Download)),
        }
    }
}

impl DownloadState {
    pub fn acquire(&self, id: &str) -> Result<RequestLease, CancellationError> {
        self.cancellation.acquire(id)
    }

    pub fn cancel(&self, id: &str) -> Result<(), CancellationError> {
        if !id.is_empty() {
            self.cancellation.cancel(id)?;
            let _ = self.progress.remove(id);
        }
        Ok(())
    }

    pub fn cancel_active(&self) -> Result<Vec<String>, CancellationError> {
        let ids = self.cancellation.cancel_active()?;
        for id in &ids {
            let _ = self.progress.remove(id);
        }
        Ok(ids)
    }

    /// The application's bulk cancel/clear operation. Cancellation includes
    /// queued sentinels; progress cleanup is best effort even during shutdown.
    pub fn cancel_many(&self, ids: &[String]) -> Result<(), CancellationError> {
        let cancelled = self
            .cancellation
            .cancel_many(ids.iter().map(String::as_str));
        let _ = self.progress.remove_many(ids.iter().map(String::as_str));
        cancelled
    }

    pub fn shutdown(&self) {
        self.cancellation.shutdown();
        self.progress.shutdown();
    }
}

impl Drop for DownloadState {
    fn drop(&mut self) {
        self.shutdown();
    }
}
