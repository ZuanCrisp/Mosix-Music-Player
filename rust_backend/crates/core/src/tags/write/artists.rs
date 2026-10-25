use super::Fields;
use crate::matching::lowercase;
use regex::Regex;
use std::borrow::Cow;
use std::collections::BTreeSet;
use std::sync::LazyLock;

pub(super) fn primary_artist_mode(mode: &str) -> bool {
    mode.trim().eq_ignore_ascii_case("primary")
}

/// The first credited artist, or the trimmed value when nothing separates it.
/// Dart and Kotlin share this exact separator set so every writer agrees;
/// Vorbis split mode also recognizes these featured-credit variants.
pub(super) fn primary_artist(value: &str) -> String {
    static SEPARATOR: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\s*[,;&]\s*|\s+x\s+|\s+(?:feat(?:uring|ured|ure)?|ft|with)\.?(?:\s+|$)")
            .unwrap()
    });
    let value = value.trim();
    SEPARATOR
        .split(value)
        .map(str::trim)
        .find(|part| !part.is_empty())
        .unwrap_or(value)
        .to_owned()
}

/// Applies the "primary" artist tag mode to editor fields before any format
/// writer runs, so ID3, MP4, APE, RIFF and Vorbis all store the same name.
pub(super) fn artist_mode_fields(fields: &Fields) -> Cow<'_, Fields> {
    let primary = fields
        .get("artist_tag_mode")
        .is_some_and(|mode| primary_artist_mode(mode));
    if !primary
        && ["artist", "album_artist", "composer", "genre"]
            .iter()
            .all(|key| tag_separator(fields, key).is_empty())
    {
        return Cow::Borrowed(fields);
    }
    let mut fields = fields.clone();
    for key in ["artist", "album_artist", "composer", "genre"] {
        let separator = tag_separator(&fields, key).to_owned();
        if let Some(value) = fields.get_mut(key) {
            if primary && matches!(key, "artist" | "album_artist") && !value.trim().is_empty() {
                *value = primary_artist(value);
            }
            *value = super::super::format_metadata_tag_value(value, &separator);
        }
    }
    Cow::Owned(fields)
}

pub(super) fn tag_separator<'a>(fields: &'a Fields, key: &str) -> &'a str {
    let key = match key {
        "ARTIST" | "artist" => "artist_separator",
        "ALBUMARTIST" | "album_artist" => "album_artist_separator",
        "COMPOSER" | "composer" => "composer_separator",
        "GENRE" | "genre" => "genre_separator",
        _ => return "",
    };
    fields
        .get(key)
        .filter(|value| super::super::separators::valid_separator(value))
        .map(String::as_str)
        .unwrap_or_default()
}

pub(super) fn split_artists(value: &str) -> Vec<String> {
    static SPLIT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?i)\s*(?:,|;|&|\bx\b)\s*|\s+\b(?:feat(?:uring|ured|ure)?|ft|with)\.?(?:\s+|$)",
        )
        .unwrap()
    });
    let value = value.trim();
    if value.is_empty() {
        return Vec::new();
    }
    let mut seen = BTreeSet::new();
    let mut result: Vec<String> = SPLIT
        .split(value)
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .filter(|part| seen.insert(lowercase(part)))
        .map(str::to_owned)
        .collect();
    if result.is_empty() {
        result.push(value.into());
    }
    result
}
