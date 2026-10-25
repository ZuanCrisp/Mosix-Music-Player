//! Shared backend logic, independent of mobile bindings and UI runtimes.

pub mod app_version;
pub mod cancellation;
pub mod clock;
pub mod cover;
pub mod cue;
pub mod downloads;
pub mod filename;
pub mod isrc;
pub mod lyrics;
pub mod matching;
pub mod media;
pub mod metadata;
pub mod native_audio_analysis;
pub mod native_palette;
pub mod progress;
pub mod resolver;
pub mod tags;
mod text;
pub use text::json_surrogates as normalize_json_surrogates;
