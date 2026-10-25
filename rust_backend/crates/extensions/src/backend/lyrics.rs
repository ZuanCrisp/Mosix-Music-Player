use super::Backend;
use crate::files::ExtensionFiles;
use cap_std::fs::OpenOptions;
use serde::{Deserialize, Serialize};
use spotiflac_core::lyrics::{LyricsResponse, config, file, lrc};
use spotiflac_providers::lyrics::{Check, SearchRequest};
use std::collections::BTreeMap;
use std::io::Write;

/// Native export arguments. Unlike the private JS SDK, file_path is not trimmed.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct LyricsRequest {
    pub spotify_id: String,
    pub track: String,
    pub artist: String,
    pub file_path: String,
    pub duration_ms: i64,
}

#[derive(Default, Serialize)]
struct LrcResult {
    lyrics: String,
    source: String,
    sync_type: String,
    instrumental: bool,
}

impl Backend {
    pub fn embed_lyrics_to_file(
        &self,
        path: &str,
        lyrics: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let fields = BTreeMap::from([
            ("LYRICS".into(), lyrics.into()),
            ("UNSYNCEDLYRICS".into(), lyrics.into()),
        ]);
        self.embed_flac_fields_response(
            path,
            &fields,
            "",
            ("Failed to embed lyrics", "Lyrics embedded successfully"),
            check,
        )
    }

    pub fn get_lyrics_lrc(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        Ok(self.lrc_result(request, &check)?.lyrics)
    }

    pub fn get_lyrics_lrc_with_source(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        serde_json::to_string(&self.lrc_result(request, &check)?).map_err(|error| error.to_string())
    }

    fn lrc_result(&self, request: &LyricsRequest, check: &Check<'_>) -> Result<LrcResult, String> {
        check()?;
        if !request.file_path.is_empty() {
            let files = self.manager.environment().native_files()?;
            return Ok(match existing(&files, &request.file_path, check)? {
                Some(lyrics) => {
                    let source = lrc::extract_source(&lyrics);
                    LrcResult {
                        source: if source.is_empty() {
                            "Embedded".into()
                        } else {
                            source
                        },
                        sync_type: "EMBEDDED".into(),
                        instrumental: lrc::is_instrumental_marker(&lyrics),
                        lyrics,
                    }
                }
                None => LrcResult::default(),
            });
        }
        let response = self.fetch_lyrics(request, check)?;
        Ok(LrcResult {
            lyrics: render(&response, request),
            source: response.source,
            sync_type: response.sync_type,
            instrumental: response.instrumental,
        })
    }

    pub(super) fn fetch_lyrics(
        &self,
        request: &LyricsRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, String> {
        let mut response = self
            .lyrics
            .fetch(
                SearchRequest {
                    spotify_id: request.spotify_id.clone(),
                    track: request.track.clone(),
                    artist: request.artist.clone(),
                    duration: request.duration_ms as f64 / 1000.0,
                    ..SearchRequest::default()
                },
                check,
            )
            .map_err(|error| error.to_string())?;
        check()?;
        response.normalize_timing();
        Ok(response)
    }

    pub fn set_lyrics_providers_json(&self, raw: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        let providers = config::decode_providers(raw).map_err(|error| error.to_string())?;
        self.lyrics
            .set_providers(&providers)
            .map_err(|error| error.to_string())
    }

    pub fn get_available_lyrics_providers_json(&self) -> Result<String, String> {
        let _operation = self.enter()?;
        serde_json::to_string(&config::available_providers()).map_err(|error| error.to_string())
    }

    pub fn set_lyrics_fetch_options_json(&self, raw: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        let _settings = self.lyrics_settings.lock().expect("lyrics settings lock");
        let mut options = self.lyrics.options();
        options
            .update_json(raw)
            .map_err(|error| error.to_string())?;
        self.lyrics
            .set_options(options)
            .map_err(|error| error.to_string())
    }

    pub fn fetch_and_save_lyrics(
        &self,
        request: &LyricsRequest,
        output_path: &str,
        check: &Check<'_>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let files = self.manager.environment().native_files()?;
        let previous = if request.file_path.is_empty() {
            None
        } else {
            existing(&files, &request.file_path, &check)?
        };
        let (content, message) = if let Some(content) = previous {
            (
                content,
                format!("Saved LRC from embedded/sidecar to: {output_path}"),
            )
        } else {
            let response = self
                .fetch_lyrics(request, &check)
                .map_err(|error| format!("lyrics not found: {error}"))?;
            if response.instrumental {
                return Err("track is instrumental, no lyrics available".into());
            }
            let content = render(&response, request);
            if content.is_empty() {
                return Err("failed to generate LRC content".into());
            }
            let message = format!(
                "Saved LRC to: {output_path} ({} lines)",
                response.lines().len()
            );
            (content, message)
        };
        let write = || -> Result<(), String> {
            let output = files.resolve_legacy(output_path)?;
            let _output = files.lock(&output, &check)?;
            check()?;
            // Go WriteFile does not create missing parents. Reject symlinks and
            // non-regular destinations before an atomic replacement as well.
            output.native_display()?;
            output.require_parent()?;
            let permissions = match output.open(OpenOptions::new().write(true)) {
                Ok(file) => Some(
                    file.metadata()
                        .map_err(|error| error.to_string())?
                        .permissions(),
                ),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.to_string()),
            };
            let mut stage = output
                .stage_existing_parent()
                .map_err(|error| error.to_string())?;
            if let Some(permissions) = permissions {
                stage
                    .file
                    .set_permissions(permissions)
                    .map_err(|error| error.to_string())?;
            }
            for chunk in content.as_bytes().chunks(16 * 1024) {
                check()?;
                stage
                    .file
                    .write_all(chunk)
                    .map_err(|error| error.to_string())?;
            }
            stage.publish(&check)
        };
        write().map_err(|error| format!("failed to write LRC file: {error}"))?;
        let _ = self
            .manager
            .environment()
            .log_buffer()
            .add("INFO", "Lyrics", &message);
        Ok(())
    }
}

fn render(response: &LyricsResponse, request: &LyricsRequest) -> String {
    if response.instrumental {
        "[instrumental:true]".into()
    } else {
        lrc::with_metadata(response, &request.track, &request.artist)
    }
}

fn existing(
    files: &ExtensionFiles,
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<String>, String> {
    let result = file::extract(
        path,
        &|path| {
            files
                .resolve_legacy(path)?
                .open(OpenOptions::new().read(true))
                .map_err(|error| error.to_string())
        },
        check,
    );
    check()?;
    Ok(result.ok().filter(|text| lrc::has_usable_content(text)))
}
