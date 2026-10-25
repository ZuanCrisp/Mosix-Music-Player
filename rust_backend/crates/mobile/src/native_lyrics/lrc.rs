use super::text::{
    LINE_TIME, Supplements, WORD_TIME, align, decode_supplement, duration, insert_first, parse_int,
    parse_words, romanization_words, shift, shift_words, trim, trim_end, vocal_text,
};
use super::{Line, Parsed, has_usable_timing};
use regex::Regex;
use std::sync::LazyLock;

static BACKGROUND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\[bg:(.*)\]$").unwrap());
static ID_TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$").unwrap()
});
static SUPPLEMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[x-(romaji-words|romaji|translation):([0-9]+):([^\]]*)\]$").unwrap()
});
static NEW_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\r\n|\r|\n").unwrap());

pub(super) fn parse_lrc(
    text: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Parsed, String> {
    let mut parsed: Vec<Line> = Vec::new();
    let mut plain = Vec::new();
    let (mut romaji, mut romaji_words, mut translation) =
        (Supplements::new(), Supplements::new(), Supplements::new());
    let (mut saw_timestamp, mut saw_words, mut offset) = (false, false, 0);
    for raw in NEW_LINE.split(text) {
        check()?;
        let mut line = trim_end(raw);
        if trim(line).is_empty() {
            continue;
        }
        let background = BACKGROUND.captures(trim(line));
        if let Some(ref c) = background {
            line = trim(c.get(1).unwrap().as_str());
        }
        if let Some(c) = SUPPLEMENT.captures(trim(line)) {
            if let (Some(time), Some(value)) = (parse_int(&c[2]), decode_supplement(&c[3]))
                && !value.is_empty()
            {
                match c[1].to_ascii_lowercase().as_str() {
                    "romaji-words" => {
                        let words = romanization_words(&value);
                        if !words.is_empty() {
                            insert_first(&mut romaji_words, time, words);
                        }
                    }
                    "romaji" => insert_first(&mut romaji, time, value),
                    _ => insert_first(&mut translation, time, value),
                }
            }
            continue;
        }
        if let Some(c) = ID_TAG.captures(trim(line)) {
            if c[1].eq_ignore_ascii_case("offset") {
                offset =
                    parse_int(&line[line.find(':').unwrap() + 1..].replace(']', "")).unwrap_or(0);
            }
            continue;
        }
        let times: Vec<_> = LINE_TIME.captures_iter(line).collect();
        if times.is_empty() {
            let (content, voice) = vocal_text(trim(line));
            let clean = trim(&WORD_TIME.replace_all(&content, "")).to_string();
            plain.push(clean.clone());
            if background.is_some() && !parsed.is_empty() && !clean.is_empty() {
                let words = parse_words(&content);
                let previous = parsed.last().unwrap();
                let time = words.first().map(|w| w.time_ms).unwrap_or(previous.time_ms);
                let end = words.last().and_then(|w| w.end_ms).or(previous.end_ms);
                let voice = voice.or_else(|| previous.voice.clone());
                saw_words |= !words.is_empty();
                parsed.push(Line::new(
                    time,
                    end,
                    clean,
                    words,
                    voice,
                    true,
                    previous.vocal_group,
                ));
            }
            continue;
        }
        saw_timestamp = true;
        let (content, voice) =
            vocal_text(trim(&line[times.last().unwrap().get(0).unwrap().end()..]));
        let words = parse_words(&content);
        saw_words |= !words.is_empty();
        let clean = trim(&WORD_TIME.replace_all(&content, "")).to_string();
        plain.push(clean.clone());
        for time in times {
            let background = background.is_some();
            let previous = parsed.last();
            let line_voice = voice.clone().or_else(|| {
                if background {
                    previous.and_then(|line| line.voice.clone())
                } else {
                    None
                }
            });
            let group = if background {
                previous.and_then(|line| line.vocal_group)
            } else {
                Some(parsed.len() as i64)
            };
            parsed.push(Line::new(
                duration(&time),
                words.last().and_then(|w| w.end_ms),
                clean.clone(),
                words.clone(),
                line_voice,
                background,
                group,
            ));
        }
    }
    let plain_text = plain
        .into_iter()
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if !saw_timestamp {
        return Ok(Parsed {
            plain_text,
            ..Parsed::default()
        });
    }
    // All-zero provider placeholders are plain lyrics. Validate before offsets
    // so a negative offset cannot turn them into apparently useful timing.
    let synced = has_usable_timing(&parsed);
    parsed.sort_by_key(|line| line.time_ms);
    let romaji = align(&parsed, romaji);
    let romaji_words = align(&parsed, romaji_words);
    let translation = align(&parsed, translation);
    if offset != 0 || !romaji.is_empty() || !translation.is_empty() {
        for line in &mut parsed {
            check()?;
            line.romanization = romaji.get(&line.time_ms).cloned();
            let words = romaji_words.get(&line.time_ms).cloned().unwrap_or_default();
            if line.romanization.as_deref()
                == Some(
                    words
                        .iter()
                        .map(|w| w.text.as_str())
                        .collect::<String>()
                        .as_str(),
                )
            {
                line.romanization_words = words;
            }
            line.translation = translation.get(&line.time_ms).cloned();
            line.time_ms = shift(line.time_ms, offset);
            line.end_ms = line.end_ms.map(|time| shift(time, offset));
            shift_words(&mut line.words, offset);
            shift_words(&mut line.romanization_words, offset);
        }
    }
    Ok(Parsed {
        synced,
        word_synced: synced && saw_words,
        lines: parsed,
        plain_text,
        ..Parsed::default()
    })
}
