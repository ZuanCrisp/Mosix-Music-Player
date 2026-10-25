use super::date;
use regex::{Captures, Regex};
use serde_json::{Map, Value};
use std::sync::LazyLock;

static NUMBERS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\{(track|disc|playlist_position|playlistPosition|position):([0-9]+)\}").unwrap()
});
static DATES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\{date:([^{}]+)\}").unwrap());
static EMPTY_GROUP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[[\t\n\f\r ]*\]|\([\t\n\f\r ]*\)").unwrap());
static DANGLING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\t\n\f\r ]*[-_|][\t\n\f\r ]*([\]\)])").unwrap());
static REPEATED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[\t\n\f\r ]*[-–—_|][\t\n\f\r ]*(?:[-–—_|][\t\n\f\r ]*)+").unwrap()
});

/// Expand the legacy filename template without sanitizing its result. Path
/// publication applies sanitization separately, as in the existing backend.
pub fn build_filename(template: &str, metadata: &Map<String, Value>) -> String {
    build_filename_checked(template, metadata, usize::MAX, &|| Ok(()))
        .expect("unlimited filename expansion")
}

pub fn build_filename_checked(
    template: &str,
    metadata: &Map<String, Value>,
    limit: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    let budget = Budget { limit, check };
    check()?;
    let template = if template.is_empty() {
        "{artist} - {title}"
    } else {
        template
    };
    let numbers = budget.replace(template, &NUMBERS, |capture: &Captures<'_>| {
        let key = match &capture[1] {
            "playlistPosition" | "position" => "playlist_position",
            key => key,
        };
        Ok(capture[2]
            .parse::<isize>()
            .map(|width| padded(integer(metadata, key), width))
            .unwrap_or_default())
    })?;
    let date = ["date", "release_date", "year"]
        .into_iter()
        .map(|key| string(metadata, key))
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    let mut result = budget.replace(&numbers, &DATES, |capture| {
        date::format(&date, &capture[1], limit, check)
    })?;
    let mut year = string(metadata, "year");
    if year.is_empty() {
        year = crate::text::utf8(&date.as_bytes()[..date.len().min(4)]);
    }
    let track = integer(metadata, "track");
    let disc = integer(metadata, "disc");
    let position = integer(metadata, "playlist_position");
    let mut placeholders = vec![
        ("title", string(metadata, "title")),
        ("artist", string(metadata, "artist")),
        ("album", string(metadata, "album")),
        ("track", padded(track, 2)),
        ("track_raw", padded(track, 1)),
        ("disc", padded(disc, 1)),
        ("disc_raw", padded(disc, 1)),
        ("playlist_position", padded(position, 2)),
        ("playlist position", padded(position, 2)),
        ("playlistPosition", padded(position, 2)),
        ("position", padded(position, 2)),
        ("playlist_position_raw", padded(position, 1)),
        ("year", year),
        ("date", date),
        ("quality", string(metadata, "quality")),
        ("quality_variant", string(metadata, "quality_variant")),
        ("isrc", string(metadata, "isrc")),
        ("provider", string(metadata, "provider")),
        ("platform", string(metadata, "provider")),
        ("provider_id", string(metadata, "provider_id")),
        ("id", string(metadata, "provider_id")),
    ];
    // Go's map iteration permits several outcomes when a metadata value itself
    // contains another placeholder. Use a stable order from that allowed set.
    placeholders.sort_unstable_by_key(|(key, _)| *key);
    let mut cleanup = false;
    for (key, value) in placeholders {
        let placeholder = format!("{{{key}}}");
        if value.is_empty()
            && matches!(key, "isrc" | "provider" | "platform" | "provider_id" | "id")
            && result.contains(&placeholder)
        {
            cleanup = true;
        }
        result = budget.literal(&result, &placeholder, &value)?;
    }
    if cleanup {
        let groups = budget.replace(&result, &EMPTY_GROUP, |_| Ok(String::new()))?;
        let dangling = budget.replace(&groups, &DANGLING, |capture| Ok(capture[1].into()))?;
        let repeated = budget.replace(&dangling, &REPEATED, |_| Ok(" - ".into()))?;
        result = repeated
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .trim_matches([' ', '-', '–', '—', '_', '|'])
            .into();
    }
    check()?;
    Ok(result)
}

struct Budget<'a> {
    limit: usize,
    check: &'a dyn Fn() -> Result<(), String>,
}

impl Budget<'_> {
    fn push(&self, output: &mut String, value: &str) -> Result<(), String> {
        (self.check)()?;
        if value.len() > self.limit.saturating_sub(output.len()) {
            return Err("filename result exceeds output limit".into());
        }
        output.push_str(value);
        Ok(())
    }

    fn replace(
        &self,
        input: &str,
        pattern: &Regex,
        replacement: impl Fn(&Captures<'_>) -> Result<String, String>,
    ) -> Result<String, String> {
        let mut output = String::new();
        let mut offset = 0;
        for capture in pattern.captures_iter(input) {
            let matched = capture.get(0).unwrap();
            self.push(&mut output, &input[offset..matched.start()])?;
            self.push(&mut output, &replacement(&capture)?)?;
            offset = matched.end();
        }
        self.push(&mut output, &input[offset..])?;
        Ok(output)
    }

    fn literal(&self, input: &str, pattern: &str, value: &str) -> Result<String, String> {
        let mut output = String::new();
        let mut offset = 0;
        for (start, _) in input.match_indices(pattern) {
            self.push(&mut output, &input[offset..start])?;
            self.push(&mut output, value)?;
            offset = start + pattern.len();
        }
        self.push(&mut output, &input[offset..])?;
        Ok(output)
    }
}

fn string(metadata: &Map<String, Value>, key: &str) -> String {
    match metadata.get(key) {
        Some(Value::String(value)) => value.trim().into(),
        Some(Value::Number(value)) => value
            .as_i64()
            .map(|value| value.to_string())
            .unwrap_or_else(|| (value.as_f64().unwrap_or(0.0) as isize).to_string()),
        _ => String::new(),
    }
}

fn integer(metadata: &Map<String, Value>, key: &str) -> isize {
    let aliases: &[&str] = match key {
        "track" => &["track_number"],
        "disc" => &["disc_number"],
        "playlist_position" => &["playlistPosition", "playlist position", "position"],
        _ => &[],
    };
    std::iter::once(key)
        .chain(aliases.iter().copied())
        .find_map(|key| match metadata.get(key) {
            Some(Value::String(value)) => value.trim().parse::<isize>().ok(),
            Some(Value::Number(value)) => Some(
                value
                    .as_i64()
                    .map(|value| value as isize)
                    .unwrap_or_else(|| value.as_f64().unwrap_or(0.0) as isize),
            ),
            _ => None,
        })
        .unwrap_or(0)
}

fn padded(number: isize, width: isize) -> String {
    if number <= 0 || width <= 0 {
        return String::new();
    }
    // Go's fmt accepts widths through one million; Rust's formatter has a lower limit.
    if width > 1_000_000 {
        return format!("%!(BADWIDTH){number}");
    }
    let digits = number.to_string();
    let width = width as usize;
    let mut output = String::with_capacity(width.max(digits.len()));
    output.extend(std::iter::repeat_n('0', width.saturating_sub(digits.len())));
    output.push_str(&digits);
    output
}
