use super::Backend;
use crate::files::ExtensionFiles;
use cap_std::fs::{File, OpenOptions};
use serde_json::{Value, json};
use spotiflac_core::tags::{
    embed_flac_metadata, rewrite_ac4_config, rewrite_ac4_metadata, rewrite_audio_tags,
    rewrite_flac_tags_if_changed, rewrite_m4a_freeform,
};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::Read;

impl Backend {
    pub fn rewrite_split_artist_tags(
        &self,
        path: &str,
        artist: &str,
        album_artist: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<String, String> {
        let fields = BTreeMap::from([
            ("ARTIST".into(), artist.into()),
            ("ALBUMARTIST".into(), album_artist.into()),
        ]);
        self.embed_flac_fields_response(
            path,
            &fields,
            "split_vorbis",
            (
                "Failed to rewrite artist tags",
                "Split artist tags written successfully",
            ),
            check,
        )
    }

    pub(super) fn embed_flac_fields_response(
        &self,
        path: &str,
        fields: &BTreeMap<String, String>,
        artist_mode: &str,
        messages: (&str, &str),
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        check()?;
        self.environment()
            .native_files()?
            .resolve_legacy(path)?
            .native_display()?;
        if let Err(error) = self.rewrite_tag_file(path, &check, |source, output, _| {
            embed_flac_metadata(source, output, fields, artist_mode, None, &check)?;
            Ok(true)
        }) {
            check()?;
            return Ok(
                crate::download::native_error_response(&format!("{}: {error}", messages.0))
                    .to_string(),
            );
        }
        Ok(json!({"success":true,"message":messages.1}).to_string())
    }

    /// Preserve the application facade, including native-editor fallback to
    /// FFmpeg. Permission and lifecycle failures must never become success.
    pub fn edit_file_metadata(
        &self,
        path: &str,
        metadata_json: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        check()?;
        let decoded: Option<BTreeMap<String, Option<String>>> = serde_json::from_str(metadata_json)
            .map_err(|error| format!("invalid metadata JSON: {error}"))?;
        let null_fields = decoded.is_none();
        let fields: BTreeMap<String, String> = decoded
            .unwrap_or_default()
            .into_iter()
            .map(|(key, value)| (key, value.unwrap_or_default()))
            .collect();
        let files = self.manager.environment().native_files()?;
        let target = files.resolve_legacy(path)?;
        target.native_display()?;
        if let Some(cover) = fields.get("cover_path").filter(|p| !p.trim().is_empty()) {
            files.resolve_legacy(cover.trim())?.native_display()?;
        }
        let lower = path.to_lowercase();
        let suffix = |extensions: &[&str]| extensions.iter().any(|ext| lower.ends_with(ext));
        let m4a = suffix(&[".m4a", ".mp4", ".m4b"]);
        let mp4 = target
            .open(OpenOptions::new().read(true))
            .ok()
            .is_some_and(|mut file| {
                let mut header = [0; 12];
                file.read(&mut header)
                    .is_ok_and(|count| count >= 8 && &header[4..8] == b"ftyp")
            });
        check()?;
        let mut replay_gain = false;
        let only_replay_gain = fields.iter().all(|(key, _)| {
            let allowed = matches!(
                key.trim().to_lowercase().as_str(),
                "replaygain_track_gain"
                    | "replaygain_track_peak"
                    | "replaygain_album_gain"
                    | "replaygain_album_peak"
            );
            replay_gain |= allowed;
            allowed
        });
        let success = |method: &str| json!({"success":true,"method":method});
        if only_replay_gain && replay_gain && (m4a || mp4) {
            self.edit_m4a_freeform(path, &fields, true, &check)
                .map_err(|error| format!("failed to write M4A metadata: {error}"))?;
            return Ok(success("native_m4a_replaygain"));
        }
        let required = if suffix(&[".flac"]) {
            if mp4 {
                return Err("failed to write FLAC metadata: file is an MP4/M4A stream under a .flac name; rename it to .m4a".into());
            }
            Some(("flac", "native", "failed to write FLAC metadata"))
        } else if suffix(&[".wav"]) {
            Some(("wav", "native_wav", "failed to write WAV metadata"))
        } else if suffix(&[".aiff", ".aif", ".aifc"]) {
            Some(("aiff", "native_aiff", "failed to write AIFF metadata"))
        } else if suffix(&[".ape", ".wv", ".mpc"]) {
            Some(("ape", "native_ape", "failed to write APE tags"))
        } else {
            None
        };
        if let Some((format, method, prefix)) = required {
            self.edit_audio_tags(path, format, &fields, &check)
                .map_err(|error| format!("{prefix}: {error}"))?;
            return Ok(success(method));
        }
        for (applicable, format, method) in [
            (suffix(&[".mp3"]), "mp3", "native_mp3"),
            (suffix(&[".ogg", ".opus"]), "ogg", "native_ogg"),
            (m4a || mp4, "m4a", "native_m4a"),
        ] {
            if applicable {
                if self.edit_audio_tags(path, format, &fields, &check).is_ok() {
                    return Ok(success(method));
                }
                // Recheck capabilities after a failed attempt too: a revoked
                // grant or replaced symlink must not be handed to FFmpeg.
                let files = self.manager.environment().native_files()?;
                files.resolve_legacy(path)?.native_display()?;
                if let Some(cover) = fields.get("cover_path").filter(|p| !p.trim().is_empty()) {
                    files.resolve_legacy(cover.trim())?.native_display()?;
                }
            }
            check()?;
        }
        Ok(
            json!({"success":true,"method":"ffmpeg","fields":if null_fields { Value::Null } else { json!(fields) }}),
        )
    }

    /// Edit supported tag containers through the same file grants and output
    /// locks as downloads/lyrics. Platform descriptors are staged by the native
    /// adapter before calling this path-based, atomic publication operation.
    pub fn edit_audio_tags(
        &self,
        path: &str,
        format: &str,
        fields: &BTreeMap<String, String>,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        if !matches!(
            format,
            "flac"
                | "mp3"
                | "m4a"
                | "mp4"
                | "m4b"
                | "ogg"
                | "opus"
                | "wav"
                | "aiff"
                | "aif"
                | "aifc"
                | "ape"
                | "wv"
                | "mpc"
        ) {
            return Err(format!("unsupported tag writer: {format}"));
        }
        self.rewrite_tag_file(path, &check, |source, output, files| {
            let cover = read_cover(
                files,
                fields.get("cover_path").map(|p| p.trim()),
                matches!(format, "wav" | "aiff" | "aif" | "aifc"),
                &check,
            )?;
            if format == "flac" {
                return rewrite_flac_tags_if_changed(
                    source,
                    output,
                    fields,
                    cover.as_deref(),
                    &check,
                );
            }
            rewrite_audio_tags(source, output, format, fields, cover.as_deref(), &check)?;
            Ok(true)
        })
        .map(|_| ())
    }

    pub fn edit_m4a_freeform(
        &self,
        path: &str,
        fields: &BTreeMap<String, String>,
        replay_gain_only: bool,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<bool, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let applicable = if replay_gain_only {
            [
                "replaygain_track_gain",
                "replaygain_track_peak",
                "replaygain_album_gain",
                "replaygain_album_peak",
            ]
            .iter()
            .any(|key| fields.contains_key(*key))
        } else {
            fields.contains_key("isrc") || fields.contains_key("label")
        };
        if !applicable {
            return Ok(false);
        }
        self.rewrite_tag_file(path, &check, |source, output, _| {
            rewrite_m4a_freeform(source, output, fields, replay_gain_only, &check)
        })
    }

    pub fn ensure_ac4_config(
        &self,
        path: &str,
        reference: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        self.rewrite_tag_file(path, &check, |source, output, files| {
            rewrite_ac4_config(
                source,
                output,
                || {
                    files
                        .resolve_legacy(reference)?
                        .open(OpenOptions::new().read(true))
                        .map_err(|error| error.to_string())
                },
                &check,
            )
        })
        .map(|_| ())
    }

    pub fn write_ac4_metadata(
        &self,
        path: &str,
        metadata_json: &str,
        cover_path: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<bool, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        self.rewrite_tag_file(path, &check, |source, output, files| {
            rewrite_ac4_metadata(
                source,
                output,
                metadata_json,
                || read_cover(files, Some(cover_path), false, &check),
                &check,
            )
        })
    }

    // Callers hold the root operation guard and supply the combined root/lease check.
    pub(super) fn rewrite_tag_file(
        &self,
        path: &str,
        check: &dyn Fn() -> Result<(), String>,
        edit: impl FnOnce(&mut File, &mut File, &ExtensionFiles) -> Result<bool, String>,
    ) -> Result<bool, String> {
        let files = self.manager.environment().native_files()?;
        let target = files.resolve_legacy(path)?;
        let _lock = files.lock(&target, check)?;
        target.native_display()?;
        target.require_parent()?;
        let mut source = target
            .open(OpenOptions::new().read(true).write(true))
            .map_err(|e| e.to_string())?;
        let permissions = source.metadata().map_err(|e| e.to_string())?.permissions();
        let mut stage = target.stage_existing_parent().map_err(|e| e.to_string())?;
        stage
            .file
            .set_permissions(permissions)
            .map_err(|e| e.to_string())?;
        let changed = edit(&mut source, &mut stage.file, &files)?;
        check()?;
        drop(source);
        if changed {
            stage.publish(check)?;
        }
        Ok(changed)
    }
}

fn read_cover(
    files: &ExtensionFiles,
    path: Option<&str>,
    required: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Vec<u8>>, String> {
    let Some(path) = path.filter(|path| !path.trim().is_empty()) else {
        return Ok(None);
    };
    let path = files.resolve_legacy(path)?;
    // Go ignores a missing/unreadable cover while applying tags.
    let mut file = match path.open(OpenOptions::new().read(true)) {
        Ok(file) => file,
        Err(error) if required => return Err(format!("read cover art: {error}")),
        Err(_) => return Ok(None),
    };
    if file.metadata().map_err(|e| e.to_string())?.len() > 64 * 1024 * 1024 {
        return Err("cover exceeds 64 MiB".into());
    }
    let mut data = Vec::new();
    let mut buffer = [0; 65536];
    loop {
        check()?;
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        if data.len() + count > 64 * 1024 * 1024 {
            return Err("cover exceeds 64 MiB".into());
        }
        data.extend_from_slice(&buffer[..count]);
    }
    if required && data.is_empty() {
        return Err("cover art is empty".into());
    }
    Ok(Some(data))
}
