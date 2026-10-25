use super::metadata::host_track;
use mornye_core::downloads::DownloadRequest;
use mornye_core::filename::{build_filename_checked, sanitize_filename_preserving_token};
use mornye_providers::resolver::Check;
use serde_json::json;
use std::path::{Path, PathBuf};

pub(super) fn filename(
    request: &DownloadRequest,
    extension: &str,
    check: &Check<'_>,
) -> Result<String, String> {
    let mut metadata = host_track(request).as_object().cloned().unwrap();
    for (key, value) in [
        ("title", json!(request.track_name)),
        ("artist", json!(request.artist_name)),
        ("album", json!(request.album_name)),
        ("track", json!(request.track_number)),
        ("disc", json!(request.disc_number)),
        ("date", json!(request.release_date)),
        ("playlist_position", json!(request.playlist_position)),
        ("provider", json!(request.download_provider)),
        ("provider_id", json!(request.provider_track_id)),
        ("quality", json!(request.quality)),
        ("quality_variant", json!(request.quality_variant)),
    ] {
        metadata.insert(key.into(), value);
    }
    let name = build_filename_checked(&request.filename_format, &metadata, 1024 * 1024, check)?;
    let name = if name.trim().is_empty() {
        format!("{} - {}", request.artist_name, request.track_name)
    } else {
        name
    };
    let extension = if extension.trim().is_empty() {
        ".flac"
    } else {
        extension.trim()
    };
    Ok(format!(
        "{}{}{}",
        sanitize_filename_preserving_token(&name, &request.quality_variant),
        if extension.starts_with('.') { "" } else { "." },
        extension
    ))
}

pub(super) fn album_folder(request: &DownloadRequest, album: &str) -> String {
    if !request.album_folder_template.contains("{album}") || album.trim().is_empty() {
        return String::new();
    }
    let name: String = request
        .album_folder_template
        .replace("{album}", album)
        .chars()
        .filter_map(|ch| {
            if ch < ' ' || ch == '\u{7f}' {
                None
            } else if "<>:\"/\\|?*".contains(ch) {
                Some(' ')
            } else {
                Some(ch)
            }
        })
        .collect();
    let mut name = name
        .trim_matches(['.', ' '])
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    while name.contains("__") {
        name = name.replace("__", "_");
    }
    let name = name.trim_matches(['_', ' ']);
    let mut end = name.len().min(120);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    name[..end].trim_matches(['.', '_', ' ']).into()
}

pub(super) fn output_path(
    request: &DownloadRequest,
    temporary: &Path,
    album: &str,
    check: &Check<'_>,
) -> Result<String, String> {
    if !request.output_path.is_empty() {
        return Ok(request.output_path.clone());
    }
    let mut directory = if request.output_dir.is_empty() {
        temporary.to_owned()
    } else {
        PathBuf::from(&request.output_dir)
    };
    let folder = album_folder(request, album);
    if !request.output_dir.is_empty() && !folder.is_empty() {
        directory = crate::files::clean(&directory)
            .parent()
            .unwrap_or(Path::new("."))
            .join(folder);
    }
    Ok(directory
        .join(filename(request, &request.output_ext, check)?)
        .to_string_lossy()
        .into_owned())
}
