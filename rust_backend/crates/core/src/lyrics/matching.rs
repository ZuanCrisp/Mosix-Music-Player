use crate::matching::lowercase;
use regex::Regex;
use std::borrow::Cow;
use std::sync::LazyLock;
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;

static SIMPLIFY: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"\s*\(feat\.?.*?\)",
        r"\s*\(ft\.?.*?\)",
        r"\s*\(featuring.*?\)",
        r"\s*\(with.*?\)",
        r"\s*-\s*Remaster(ed)?.*$",
        r"\s*-\s*\d{4}\s*Remaster.*$",
        r"\s*\(Remaster(ed)?.*?\)",
        r"\s*\(Deluxe.*?\)",
        r"\s*\(Bonus.*?\)",
        r"\s*\(Live.*?\)",
        r"\s*\(Acoustic.*?\)",
        r"\s*\(Radio Edit\)",
        r"\s*\(Single Version\)",
    ]
    .iter()
    .map(|pattern| {
        // Go's Perl character classes are ASCII even with Unicode case folding.
        Regex::new(&format!(
            "(?i){}",
            pattern
                .replace(r"\s", r"[\t\n\f\r ]")
                .replace(r"\d", "[0-9]")
        ))
        .unwrap()
    })
    .collect()
});
static INSTRUMENTAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:^|[\t\n\f\r \[(\-])(?:instrumental|inst\.?)(?:[\t\n\f\r \])]|$)").unwrap()
});

fn normalized(value: &str, artist: bool) -> String {
    use GeneralCategory::*;
    let lower = lowercase(value.trim());
    let mut output = String::with_capacity(lower.len());
    let characters: Box<dyn Iterator<Item = char>> = if artist {
        Box::new(lower.nfd())
    } else {
        Box::new(lower.chars())
    };
    for ch in characters {
        match get_general_category(ch) {
            UppercaseLetter | LowercaseLetter | TitlecaseLetter | ModifierLetter | OtherLetter
            | DecimalNumber | LetterNumber | OtherNumber => match (artist, ch) {
                (true, 'đ') => output.push_str("dj"),
                (true, 'ß') => output.push_str("ss"),
                (true, 'æ') => output.push_str("ae"),
                (true, 'œ') => output.push_str("oe"),
                _ => output.push(ch),
            },
            _ if ch.is_whitespace()
                || matches!(ch, '/' | '\\' | '_' | '-' | '|' | '.' | '&' | '+') =>
            {
                output.push(' ')
            }
            _ => {}
        }
    }
    output.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn normalize_title(value: &str) -> String {
    normalized(value, false)
}

pub fn normalize_loose_artist(value: &str) -> String {
    normalized(value, true)
}

pub fn simplify_track(value: &str) -> String {
    let mut output = value.to_owned();
    for pattern in SIMPLIFY.iter() {
        if let Cow::Owned(replaced) = pattern.replace_all(&output, "") {
            output = replaced;
        }
    }
    let normalized = normalize_title(output.trim());
    if normalized.is_empty() {
        output.trim().into()
    } else {
        normalized
    }
}

pub fn primary_artist(value: &str) -> String {
    let lowered = lowercase(value);
    for separator in [
        ", ",
        "; ",
        " & ",
        " feat. ",
        " ft. ",
        " featuring ",
        " with ",
    ] {
        if let Some(index) = lowered.find(separator)
            && index > 0
        {
            // Go slices the original by the lowercased byte offset. Preserve
            // replacement bytes if a lowercase mapping changed its UTF-8 width.
            return crate::text::utf8(&value.as_bytes()[..index.min(value.len())])
                .trim()
                .into();
        }
    }
    value.trim().into()
}

pub fn contains_words(value: &str, sequence: &str) -> bool {
    let value: Vec<_> = value.split_whitespace().collect();
    let sequence: Vec<_> = sequence.split_whitespace().collect();
    !sequence.is_empty() && value.windows(sequence.len()).any(|words| words == sequence)
}

pub fn titles_match(candidate: &str, expected: &str, decorated: bool) -> bool {
    let candidate = lowercase(simplify_track(candidate).trim());
    let expected = lowercase(simplify_track(expected).trim());
    !candidate.is_empty()
        && !expected.is_empty()
        && (candidate == expected || (decorated && contains_words(&candidate, &expected)))
}

pub fn artists_match(candidate: &str, expected: &str) -> bool {
    let expected = normalize_loose_artist(&primary_artist(expected));
    if expected.is_empty() {
        return true;
    }
    let candidate = normalize_loose_artist(&primary_artist(candidate));
    let mut candidate_words: Vec<_> = candidate.split_whitespace().collect();
    let mut expected_words: Vec<_> = expected.split_whitespace().collect();
    candidate_words.sort_unstable();
    expected_words.sort_unstable();
    candidate_words == expected_words
}

pub fn duration_matches(candidate: f64, expected: f64) -> bool {
    candidate <= 0.0 || expected <= 0.0 || (candidate - expected).abs() <= 10.0
}

pub fn artist_in_title(candidate: &str, artist: &str) -> bool {
    let expected = normalize_loose_artist(&primary_artist(artist));
    contains_words(&normalize_loose_artist(candidate), &expected)
}

pub fn is_likely_instrumental(title: &str) -> bool {
    INSTRUMENTAL.is_match(title.trim())
}

pub fn score(
    candidate_title: &str,
    candidate_artist: &str,
    candidate_duration: f64,
    title: &str,
    artist: &str,
    duration: f64,
) -> i32 {
    let title = lowercase(simplify_track(title).trim());
    let candidate_title = lowercase(simplify_track(candidate_title).trim());
    let artist = lowercase(primary_artist(artist).trim());
    let candidate_artist = lowercase(primary_artist(candidate_artist).trim());
    let component = |candidate: &str, expected: &str, weight| {
        if candidate == expected {
            weight
        } else if candidate.contains(expected) || expected.contains(candidate) {
            weight / 2
        } else {
            0
        }
    };
    component(&candidate_title, &title, 50)
        + component(&candidate_artist, &artist, 60)
        + if duration > 0.0
            && candidate_duration > 0.0
            && (candidate_duration - duration).abs() <= 10.0
        {
            20
        } else {
            0
        }
}

pub fn clock_duration(value: &str) -> f64 {
    let mut total = 0_isize;
    if value.trim().is_empty() {
        return 0.0;
    }
    for part in value.trim().split(':') {
        let Ok(value) = part.trim().parse::<isize>() else {
            return 0.0;
        };
        total = total.wrapping_mul(60).wrapping_add(value);
    }
    total as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simplify_and_primary_artist_keep_go_order_and_offsets() {
        assert_eq!(simplify_track("Song (feat. Guest) (Live)"), "song");
        assert_eq!(
            primary_artist("First with Guest, Second"),
            "First with Guest"
        );
        // '&' wins before 'with'; Go applies its lowercased byte offset to the
        // original string even when lowercasing changes the UTF-8 width.
        assert_eq!(
            primary_artist("İ Artist with Guest & Other"),
            "İ Artist with Gues"
        );
    }
}
