//! Migration APIs. Instances here are not connected to the app's Go-owned work.

mod cancellation;
mod data_jobs;
mod extensions;
mod ffmpeg;
mod filename;
mod hires;
mod library_metadata;
mod logging;
mod lyrics;
mod manager;
mod metadata;
mod native_backup;
mod native_cache;
mod native_collections;
mod native_id3;
mod native_library;
mod native_listing;
mod native_lyrics;
mod native_playlist_write;
mod native_playlists;
mod native_xml;
mod network_tags;
mod progress;
mod repository;
mod tags;
mod usb_audio;

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn sanitize_filename(filename: String) -> String {
    spotiflac_core::filename::sanitize_filename(&filename)
}
