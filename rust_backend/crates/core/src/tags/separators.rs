use regex::Regex;
use std::sync::LazyLock;

pub(super) fn valid_separator(value: &str) -> bool {
    !value.is_empty()
        && value.encode_utf16().count() <= 16
        && !value.chars().any(|ch| ch <= '\u{1f}' || ch == '\u{7f}')
}

/// Format provider lists without splitting band-name ampersands or slashes.
pub fn format_metadata_tag_value(value: &str, separator: &str) -> String {
    if !valid_separator(separator) {
        return value.to_owned();
    }
    static LIST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*[,;]\s*").unwrap());
    LIST.split(value)
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(separator)
}
