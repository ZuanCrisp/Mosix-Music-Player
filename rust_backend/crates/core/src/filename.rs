//! Filename rules shared with the existing Go backend.

mod api;
mod date;
mod template;
pub use api::build_filename_json;
pub use template::{build_filename, build_filename_checked};

pub const MAX_SANITIZED_FILENAME_BYTES: usize = 200;

/// Normalize a UTF-8 filename with the existing `SanitizeFilename` contract.
///
/// The limit applies to UTF-8 bytes, not characters. This does not normalize
/// Unicode, remove format characters, or preserve an extension separately.
pub fn sanitize_filename(filename: &str) -> String {
    let mut filtered = String::with_capacity(filename.len());
    for character in filename.chars() {
        if matches!(
            character,
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
        ) || character <= '\u{1f}'
        {
            filtered.push(' ');
        } else if !character.is_control() {
            filtered.push(character);
        }
    }

    let trimmed = filtered.trim().trim_matches(['.', ' ']);
    let mut normalized = String::with_capacity(trimmed.len());
    for word in trimmed.split_whitespace() {
        if !normalized.is_empty() {
            normalized.push(' ');
        }
        for character in word.chars() {
            if character != '_' || !normalized.ends_with('_') {
                normalized.push(character);
            }
        }
    }

    let mut sanitized = normalized.trim_matches(['_', ' ']);
    if sanitized.len() > MAX_SANITIZED_FILENAME_BYTES {
        let mut end = MAX_SANITIZED_FILENAME_BYTES;
        while !sanitized.is_char_boundary(end) {
            end -= 1;
        }
        sanitized = sanitized[..end]
            .trim_matches(['.', ' '])
            .trim()
            .trim_matches(['_', ' ']);
    }

    if sanitized.is_empty() {
        "Unknown".to_owned()
    } else {
        sanitized.to_owned()
    }
}

/// Sanitize a filename while preserving a token that was present in the raw
/// filename, such as a quality variant marker.
pub fn sanitize_filename_preserving_token(filename: &str, token: &str) -> String {
    let sanitized = sanitize_filename(filename);
    let token = token.trim();
    if token.is_empty() || !filename.contains(token) || sanitized.contains(token) {
        return sanitized;
    }

    let safe_token = sanitize_filename(token);
    let suffix = format!(" - {safe_token}");
    let prefix_limit = MAX_SANITIZED_FILENAME_BYTES.saturating_sub(suffix.len());
    if prefix_limit == 0 {
        return truncate_utf8_bytes(&safe_token, MAX_SANITIZED_FILENAME_BYTES).to_owned();
    }

    let raw_prefix = filename.replace(token, "");
    let raw_prefix = raw_prefix.trim_matches([' ', '_', '-']);
    let prefix = sanitize_filename(raw_prefix);
    let prefix = truncate_utf8_bytes(&prefix, prefix_limit)
        .trim_matches(['.', ' ', '_', '-'])
        .trim();
    if prefix.is_empty() || prefix == "Unknown" {
        return safe_token;
    }
    format!("{prefix}{suffix}")
}

fn truncate_utf8_bytes(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }

    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}
