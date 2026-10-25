//! Application metadata JSON, preserving the distinct legacy tag-reader JSON.

use super::{AudioMetadata, read_audio_tags, read_container_format};
use crate::media::{mp3_quality, ogg_quality, probe_mp4_quality, probe_quality, riff_quality};
use serde_json::{Map, Value};
use std::io::{self, Read, Seek, SeekFrom};

/// Read the public ReadFileMetadataWithHint payload from an already-owned file.
/// The path remains its identity; a display hint supplies only a missing suffix.
pub fn read_file_metadata(
    file: &mut (impl Read + Seek),
    path: &str,
    hint: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let mut file = ObservedReader {
        file,
        check,
        failure: None,
    };
    let result = read_metadata(&mut file, path, hint);
    // Parsers tolerate absent/corrupt tags, but must not turn an OS error or
    // cancellation into success, even if the parser swallowed a read error.
    if let Some(error) = file.failure {
        return Err(error);
    }
    check()?;
    result
}

fn read_metadata(file: &mut (impl Read + Seek), path: &str, hint: &str) -> Result<Value, String> {
    let extension = file_metadata_extension(path, hint)?;
    let container = read_container_format(file, &extension[1..])?;
    let (mut format, mut codec) = match container {
        "flac" => ("flac", "flac"),
        "m4a" | "mp4" | "aac" => ("m4a", ""),
        "mp3" => ("mp3", "mp3"),
        "ogg" | "opus" => ("opus", "opus"),
        "ape" => ("ape", "ape"),
        "wv" => ("wv", "wv"),
        "mpc" => ("mpc", "mpc"),
        "wav" => ("wav", "pcm"),
        "aiff" | "aif" | "aifc" => ("aiff", "pcm"),
        _ => unreachable!("validated metadata extension"),
    };
    let size = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())? as i64;
    let mut metadata = read_audio_tags(file, container, &|| Ok(()));
    if format == "flac" && metadata.is_err() {
        let fallback = read_audio_tags(file, "ogg", &|| Ok(()));
        if fallback.is_ok() {
            metadata = fallback;
            format = "opus";
            codec = "opus";
        } else {
            return Err(format!(
                "failed to read metadata: {}",
                metadata.unwrap_err()
            ));
        }
    }
    let mut result = match metadata {
        Ok(metadata) => tag_fields(metadata, format != "flac")?,
        Err(_) => {
            let mut fields = tag_fields(AudioMetadata::default(), false)?;
            fields.retain(|key, _| !key.starts_with("replaygain_"));
            fields
        }
    };
    result.insert("format".into(), format.into());
    result.insert("audio_codec".into(), codec.into());
    result.insert("duration".into(), 0.into());
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let quality = match format {
        "flac" => probe_quality(file, &|| Ok(())),
        "m4a" => probe_mp4_quality(file, &|| Ok(())),
        "mp3" => mp3_quality(file, size),
        "opus" => ogg_quality(file, size, path),
        "wav" | "aiff" => riff_quality(file, size, format == "aiff"),
        _ => return Ok(result.into()),
    };
    if let Ok(quality) = quality {
        result.insert("sample_rate".into(), quality.sample_rate.into());
        result.insert("duration".into(), quality.duration.into());
        if format != "opus" {
            result.insert("bit_depth".into(), quality.bit_depth.into());
        }
        let bitrate = match format {
            "flac" => {
                if !quality.codec.is_empty() {
                    result.insert("audio_codec".into(), quality.codec.into());
                }
                if size > 0 && quality.sample_rate > 0 && quality.total_samples > 0 {
                    Some(
                        (size as f64 * 8.0
                            / (quality.total_samples as f64 / quality.sample_rate as f64)
                            / 1000.0) as i64,
                    )
                } else {
                    None
                }
            }
            "m4a" => {
                let mapped = match quality.codec.trim().to_lowercase().as_str() {
                    "flac" => "flac",
                    "alac" => "alac",
                    "eac3" | "ec-3" => "eac3",
                    "ac3" | "ac-3" => "ac3",
                    "ac4" | "ac-4" => "ac4",
                    "opus" => "opus",
                    _ => "m4a",
                };
                result.insert("format".into(), mapped.into());
                result.insert("audio_codec".into(), quality.codec.into());
                if quality.bitrate > 0 && !matches!(mapped, "flac" | "alac") {
                    Some(quality.bitrate)
                } else if quality.duration > 0 && size > 0 {
                    Some((size as f64 * 8.0 / quality.duration as f64 / 1000.0) as i64)
                } else {
                    None
                }
            }
            "mp3" | "opus" if quality.bitrate > 0 => Some(quality.bitrate / 1000),
            _ => None,
        };
        if let Some(bitrate) = bitrate {
            result.insert("bitrate".into(), bitrate.into());
        }
    }
    Ok(result.into())
}

/// Validate before opening the native path: Go rejects unsupported suffixes
/// even when that path does not exist or cannot be opened.
pub fn file_metadata_extension(path: &str, hint: &str) -> Result<String, String> {
    let path_ext = extension(path);
    let suffix = if path_ext.is_empty() {
        extension(hint)
    } else {
        path_ext
    }
    .to_lowercase();
    match suffix.as_str() {
        ".flac" | ".m4a" | ".mp4" | ".aac" | ".mp3" | ".ogg" | ".opus" | ".ape" | ".wv"
        | ".mpc" | ".wav" | ".aiff" | ".aif" | ".aifc" => Ok(suffix),
        _ => Err(format!("unsupported file format: {path}")),
    }
}

fn tag_fields(
    mut metadata: AudioMetadata,
    year_fallback: bool,
) -> Result<Map<String, Value>, String> {
    if year_fallback && metadata.date.is_empty() {
        metadata.date = metadata.year.clone();
    }
    let Value::Object(mut fields) = serde_json::to_value(metadata).map_err(|e| e.to_string())?
    else {
        unreachable!("AudioMetadata serializes as an object");
    };
    fields.remove("year");
    for suffix in ["track_gain", "track_peak", "album_gain", "album_peak"] {
        if let Some(value) = fields.remove(&format!("replay_gain_{suffix}")) {
            fields.insert(format!("replaygain_{suffix}"), value);
        }
    }
    Ok(fields)
}

// filepath.Ext includes a leading dotfile and a trailing dot, unlike Path::extension.
fn extension(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or_default();
    name.rfind('.').map_or("", |index| &name[index..])
}

pub(super) struct ObservedReader<'a, R> {
    pub(super) file: &'a mut R,
    pub(super) check: &'a dyn Fn() -> Result<(), String>,
    pub(super) failure: Option<String>,
}

impl<R> ObservedReader<'_, R> {
    fn check(&mut self) -> io::Result<()> {
        if let Some(error) = &self.failure {
            return Err(io::Error::other(error.clone()));
        }
        (self.check)().map_err(|error| {
            self.failure = Some(error.clone());
            io::Error::other(error)
        })
    }

    fn record<T>(&mut self, result: io::Result<T>) -> io::Result<T> {
        if let Err(error) = &result {
            self.failure = Some(error.to_string());
        }
        result
    }
}

impl<R: Read> Read for ObservedReader<'_, R> {
    fn read(&mut self, data: &mut [u8]) -> io::Result<usize> {
        self.check()?;
        let result = self.file.read(data);
        self.record(result)
    }
}

impl<R: Seek> Seek for ObservedReader<'_, R> {
    fn seek(&mut self, offset: SeekFrom) -> io::Result<u64> {
        self.check()?;
        let result = self.file.seek(offset);
        self.record(result)
    }
}
