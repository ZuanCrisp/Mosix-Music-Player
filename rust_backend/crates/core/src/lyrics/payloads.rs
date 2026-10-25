//! Parsing and formatting of provider lyric payloads (PAX, Apple, proxy, and KPOE syllable formats).

use super::{LyricsResponse, LyricsWord, json, lrc};
use crate::json::{field_name, lenient_deserialize};
use regex::Regex;
use serde::Serialize;
use serde_json::value::RawValue;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

mod ttml;
pub use ttml::ttml_lyrics;

#[derive(Clone, Debug, Default, Serialize)]
pub struct PaxDetail {
    pub text: String,
    pub part: bool,
    pub timestamp: Option<isize>,
    pub endtime: Option<isize>,
}
lenient_deserialize!(PaxDetail {
    "text" => text, "part" => part, "timestamp" => timestamp, "endtime" => endtime,
});

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaxLine {
    pub text: Option<Vec<PaxDetail>>,
    pub timestamp: isize,
    pub opposite_turn: bool,
    pub background: bool,
    pub background_text: Option<Vec<PaxDetail>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background_lines: Option<Vec<PaxLine>>,
    pub endtime: isize,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub agent: String,
}
lenient_deserialize!(PaxLine {
    "text" => text, "timestamp" => timestamp, "oppositeturn" => opposite_turn,
    "background" => background, "backgroundtext" => background_text, "endtime" => endtime,
    "backgroundlines" => background_lines,
    "agent" => agent,
});

#[derive(Default)]
struct AppleAgent {
    id: String,
    kind: String,
}
lenient_deserialize!(AppleAgent { "id" => id, "type" => kind, });

#[derive(Default)]
struct AppleMetadata {
    agents: Option<Vec<AppleAgent>>,
}
lenient_deserialize!(AppleMetadata { "agents" => agents, });

#[derive(Default)]
struct ApplePayload {
    kind: String,
    content: Option<Vec<PaxLine>>,
    elrc: String,
    elrc_multi_person: String,
    plain: String,
    ttml_content: String,
    metadata: Option<AppleMetadata>,
}
lenient_deserialize!(ApplePayload {
    "type" => kind, "content" => content, "elrc" => elrc,
    "elrcmultiperson" => elrc_multi_person, "plain" => plain, "ttmlcontent" => ttml_content,
    "metadata" => metadata,
});

static APPLE_VOCAL_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?\]\s*(v[1-9][0-9]*):")
        .unwrap()
});

/// The proxy's oppositeTurn flag can turn a group agent into the second
/// singer. Recover the original roles while retaining every eLRC word time,
/// space and backing part. Group vocals use the primary side, as in TTML.
fn apple_vocal_sides(text: &str, payload: &ApplePayload) -> String {
    let agents = payload
        .metadata
        .as_ref()
        .and_then(|metadata| metadata.agents.as_deref())
        .unwrap_or_default();
    let mut voices = BTreeMap::new();
    let mut person = 0;
    for agent in agents {
        let voice = match (agent.id.to_ascii_lowercase().as_str(), agent.kind.as_str()) {
            ("v1", _) | ("v3", _) | (_, "group") => 1,
            ("v2", _) => {
                person = person.max(2);
                2
            }
            (_, "person") => {
                person += 1;
                person
            }
            _ => continue,
        };
        if agent.id.eq_ignore_ascii_case("v1") {
            person = person.max(1);
        }
        voices.insert(agent.id.as_str(), format!("v{voice}"));
    }
    let lines = payload.content.as_deref().unwrap_or_default();
    // A proxy may omit agent declarations but retain standard IDs on lines.
    // Correct oppositeTurn before it turns a V3 collaboration into V2.
    for line in lines {
        let voice = match line.agent.to_ascii_lowercase().as_str() {
            "v1" | "v3" => "v1",
            "v2" => "v2",
            _ => continue,
        };
        voices
            .entry(line.agent.as_str())
            .or_insert_with(|| voice.into());
    }
    if voices.is_empty() || lines.is_empty() {
        return text.into();
    }
    text.lines()
        .map(|line| {
            let Some(captures) = APPLE_VOCAL_LINE.captures(line) else {
                return line.to_owned();
            };
            let fraction = captures.get(3).map_or(0, |value| {
                value.as_str().parse::<i64>().unwrap() * 10_i64.pow(3 - value.as_str().len() as u32)
            });
            let start = captures[1].parse::<i64>().unwrap() * 60_000
                + captures[2].parse::<i64>().unwrap() * 1000
                + fraction;
            // Proxy eLRC may round to centiseconds; prefer an exact match.
            let source = lines
                .iter()
                .filter(|source| !source.agent.is_empty())
                .min_by_key(|source| (source.timestamp as i64 - start).abs())
                .filter(|source| (source.timestamp as i64 - start).abs() <= 10);
            let Some(source) = source else {
                return line.to_owned();
            };
            let Some(voice) = voices.get(source.agent.as_str()) else {
                return line.to_owned();
            };
            let distance = (source.timestamp as i64 - start).abs();
            if lines.iter().any(|other| {
                (other.timestamp as i64 - start).abs() == distance
                    && voices.get(other.agent.as_str()) != Some(voice)
            }) {
                // Simultaneous independent lines cannot be identified by time
                // alone. Retain their supplied labels rather than swapping them.
                return line.to_owned();
            }
            let prefix = captures.get(4).unwrap();
            let mut corrected = line.to_owned();
            corrected.replace_range(prefix.range(), voice);
            corrected
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Default)]
struct ProxyPayload {
    kind: String,
    content: Option<Vec<PaxLine>>,
    lyrics: Option<Vec<PaxLine>>,
    lyrics_text: String,
    plain_lyrics: String,
}
lenient_deserialize!(ProxyPayload {
    "type" => kind, "content" => content, "lyrics" => lyrics,
    "lyrics_text" => lyrics_text, "plain_lyrics" => plain_lyrics,
});

fn append_detail(output: &mut String, details: &[PaxDetail], word_timing: bool) {
    let mut last_start = String::new();
    for detail in details {
        if word_timing && let Some(time) = detail.timestamp {
            let start = format!("<{}>", lrc::timestamp_inline(time as i64));
            if start != last_start {
                output.push_str(&start);
                last_start = start;
            }
        }
        output.push_str(&detail.text);
        if !detail.part {
            output.push(' ');
        }
        if word_timing && let Some(time) = detail.endtime {
            output.push_str(&format!("<{}>", lrc::timestamp_inline(time as i64)));
        }
    }
}

pub fn format_pax_content(
    kind: &str,
    lines: &[PaxLine],
    multi_person: bool,
    word_timing: bool,
) -> String {
    let mut output = String::new();
    for (index, line) in lines.iter().enumerate() {
        if index > 0 {
            output.push('\n');
        }
        if field_name(kind) == "syllable" {
            output.push_str(&lrc::timestamp(line.timestamp as i64));
            if multi_person {
                output.push_str(if line.opposite_turn { "v2:" } else { "v1:" });
            }
            append_detail(
                &mut output,
                line.text.as_deref().unwrap_or_default(),
                word_timing,
            );
            if line.background
                && multi_person
                && let Some(background) = line
                    .background_text
                    .as_ref()
                    .filter(|lines| !lines.is_empty())
            {
                output.push_str("\n[bg:");
                append_detail(&mut output, background, word_timing);
                output.push(']');
            }
        } else if let Some(text) = line.text.as_ref().and_then(|text| text.first()) {
            output.push_str(&lrc::timestamp(line.timestamp as i64));
            output.push_str(&text.text);
        }
    }
    output.trim().into()
}

/// The first-party service's exported eLRC flattens backing vocals into lead
/// lines. Read its v1 JSON instead to preserve background groups and exact
/// word boundaries, including adjacent syllables and line-only lyrics.
pub fn format_zarz_lrc_apple(
    raw: &str,
    multi_person: bool,
    word_timing: bool,
) -> Result<String, String> {
    let payload: ApplePayload =
        json::decode(raw).map_err(|error| format!("invalid Zarz-LRC response: {error}"))?;
    format_apple_payload(&payload, "Zarz-LRC", multi_person, word_timing)
}

/// Shared by every source that exposes Apple's own line structure, either as
/// first-party JSON or as the TTML document it is derived from.
fn format_apple_payload(
    payload: &ApplePayload,
    label: &str,
    multi_person: bool,
    word_timing: bool,
) -> Result<String, String> {
    let kind = field_name(&payload.kind);
    if kind == "unsynced" && !payload.plain.trim().is_empty() {
        return Ok(payload.plain.trim().into());
    }
    if !matches!(kind.as_str(), "syllable" | "line" | "unsynced") {
        return Err(format!("unsupported {label} sync type"));
    }
    let lines = payload
        .content
        .as_deref()
        .ok_or_else(|| format!("missing {label} content"))?;
    let timed = kind != "unsynced";
    let words = word_timing && kind == "syllable";
    let mut output = String::new();
    for line in lines {
        let details = line.text.as_deref().unwrap_or_default();
        if !details.iter().any(|detail| !detail.text.trim().is_empty()) {
            continue;
        }
        if !output.is_empty() {
            output.push('\n');
        }
        if timed {
            output.push_str(&lrc::timestamp(line.timestamp as i64));
            if multi_person {
                output.push_str(if line.opposite_turn { "v2:" } else { "v1:" });
            }
        }
        append_detail(&mut output, details, words);
        if timed && multi_person {
            for background in line.background_lines.as_deref().unwrap_or_default() {
                let details = background.text.as_deref().unwrap_or_default();
                if !details.iter().any(|detail| !detail.text.trim().is_empty()) {
                    continue;
                }
                output.push_str("\n[bg:");
                // Group bounds retain backing timing even in line-only mode.
                output.push_str(&format!(
                    "<{}>",
                    lrc::timestamp_inline(background.timestamp as i64)
                ));
                append_detail(&mut output, details, words);
                output.push_str(&format!(
                    "<{}>]",
                    lrc::timestamp_inline(background.endtime as i64)
                ));
            }
        }
    }
    Ok(if timed && multi_person {
        apple_vocal_sides(output.trim(), payload)
    } else {
        output.trim().into()
    })
}

pub fn format_apple(raw: &str, multi_person: bool, word_timing: bool) -> Result<String, String> {
    if let Ok(Some(value)) = json::decode::<Option<String>>(raw)
        && !value.trim().is_empty()
    {
        return Ok(value.trim().into());
    }
    if let Ok(value) = json::decode::<ApplePayload>(raw)
        && (value.content.is_some()
            || [
                &value.elrc_multi_person,
                &value.elrc,
                &value.plain,
                &value.ttml_content,
            ]
            .iter()
            .any(|value| !value.trim().is_empty()))
    {
        if word_timing && multi_person && !value.elrc_multi_person.trim().is_empty() {
            return Ok(apple_vocal_sides(value.elrc_multi_person.trim(), &value));
        }
        if word_timing && !value.elrc.trim().is_empty() {
            return Ok(if multi_person {
                apple_vocal_sides(value.elrc.trim(), &value)
            } else {
                value.elrc.trim().into()
            });
        }
        let content = value.content.as_deref().unwrap_or_default();
        if !value.plain.trim().is_empty() && content.is_empty() {
            return Ok(value.plain.trim().into());
        }
        if content.is_empty() {
            return Err("unsupported apple music lyrics payload".into());
        }
        let text = format_pax_content(&value.kind, content, multi_person, word_timing);
        return Ok(if multi_person {
            apple_vocal_sides(&text, &value)
        } else {
            text
        });
    }
    if let Ok(Some(lines)) = json::decode::<Option<Vec<PaxLine>>>(raw)
        && !lines.is_empty()
    {
        return Ok(format_pax_content(
            "Syllable",
            &lines,
            multi_person,
            word_timing,
        ));
    }
    Err("failed to parse pax lyrics response".into())
}

/// Attach optional Apple text to the actual output lines once. The proxy's
/// eLRC can round in either direction, so metadata timestamps need not be
/// identical to the selected line timestamps. Exact matches win collisions.
pub fn apple_supplements(raw: &str, lyrics: &mut LyricsResponse) {
    if lyrics.sync_type != "LINE_SYNCED" {
        return;
    }
    #[derive(Default)]
    struct Payload {
        metadata: Option<Box<RawValue>>,
    }
    lenient_deserialize!(Payload { "metadata" => metadata, });

    let metadata = json::decode::<Payload>(raw)
        .ok()
        .and_then(|payload| payload.metadata)
        .and_then(|raw| json::decode::<serde_json::Value>(raw.get()).ok());
    let Some(metadata) = metadata else { return };
    let starts: BTreeSet<_> = lyrics
        .lines()
        .iter()
        .map(|line| line.start_time_ms)
        .collect();
    let language = metadata["language"].as_str().unwrap_or_default();
    let romanization =
        apple_supplement_lines(&metadata["transliterations"], &starts, language, |lang| {
            lang.split('-')
                .any(|part| part.eq_ignore_ascii_case("Latn"))
        });
    let translation = apple_supplement_lines(&metadata["translations"], &starts, "en", |lang| {
        lang.split('-')
            .next()
            .is_some_and(|part| part.eq_ignore_ascii_case("en"))
    });
    for line in lyrics.lines.iter_mut().flatten() {
        if let Some(supplement) = romanization.get(&line.start_time_ms) {
            line.romanization = Some(supplement.text.clone());
            line.romanization_words = supplement.words.clone();
        }
        line.translation = translation
            .get(&line.start_time_ms)
            .map(|line| line.text.clone());
    }
}

struct AppleSupplement {
    text: String,
    words: Option<Vec<LyricsWord>>,
}

// Spans are syllables, not necessarily words: "utsu" + "kushii" must remain
// joined. Recover spaces from the full text instead of adding one per span.
fn apple_supplement_words(text: &str, spans: &serde_json::Value) -> Option<Vec<LyricsWord>> {
    let mut words: Vec<LyricsWord> = Vec::new();
    let mut cursor = 0;
    for span in spans.as_array()? {
        let part = span["text"].as_str()?.trim();
        if part.is_empty() {
            continue;
        }
        let start = span["begin"].as_i64()?;
        let end = span["end"].as_i64()?;
        if start < 0 || end < start || words.last().is_some_and(|word| word.start_time_ms > start) {
            return None;
        }
        let offset = text[cursor..].find(part)?;
        let gap = &text[cursor..cursor + offset];
        if !gap.chars().all(char::is_whitespace) {
            return None;
        }
        if let Some(previous) = words.last_mut() {
            previous.text.push_str(gap);
        }
        words.push(LyricsWord {
            text: part.into(),
            start_time_ms: start,
            end_time_ms: end,
        });
        cursor += offset + part.len();
    }
    if words.is_empty() || !text[cursor..].trim().is_empty() {
        return None;
    }
    Some(words)
}

fn apple_supplement_lines(
    groups: &serde_json::Value,
    starts: &BTreeSet<i64>,
    language: &str,
    accepts_language: impl Fn(&str) -> bool,
) -> BTreeMap<i64, AppleSupplement> {
    let mut best = BTreeMap::new();
    let mut best_rank = (false, 0);
    for group in groups.as_array().into_iter().flatten() {
        let Some(lang) = group["lang"].as_str().filter(|lang| accepts_language(lang)) else {
            continue;
        };
        let mut matched: BTreeMap<i64, (u64, AppleSupplement)> = BTreeMap::new();
        for line in group["lines"].as_array().into_iter().flatten() {
            let (Some(time), Some(text)) = (line["timestamp"].as_i64(), line["text"].as_str())
            else {
                continue;
            };
            if time < 0 || text.trim().is_empty() {
                continue;
            }
            let Some(&start) = starts
                .range(time.saturating_sub(10)..=time.saturating_add(10))
                .min_by_key(|&&start| (start.abs_diff(time), start))
            else {
                continue;
            };
            let distance = start.abs_diff(time);
            if matched.get(&start).is_none_or(|(old, _)| distance < *old) {
                let text = text.trim();
                matched.insert(
                    start,
                    (
                        distance,
                        AppleSupplement {
                            text: text.into(),
                            words: apple_supplement_words(text, &line["spans"]),
                        },
                    ),
                );
            }
        }
        // Prefer the song's language, then coverage. Empty or malformed
        // optional groups never suppress a usable later alternative.
        let same_language = lang
            .split('-')
            .next()
            .unwrap_or_default()
            .eq_ignore_ascii_case(language.split('-').next().unwrap_or_default());
        let rank = (same_language, matched.len());
        if !matched.is_empty() && (best.is_empty() || rank > best_rank) {
            best_rank = rank;
            best = matched
                .into_iter()
                .map(|(start, (_, text))| (start, text))
                .collect();
        }
    }
    best
}

/// Failure strings describe unavailable proxy payloads, not an absent track.
pub fn parse_proxy(
    raw: &str,
    provider: &str,
    multi_person: bool,
) -> Result<LyricsResponse, String> {
    if let Ok(value) = json::decode::<Option<String>>(raw) {
        let value = value.unwrap_or_default();
        if value.trim().is_empty() {
            return Err(format!("{provider} returned empty lyrics"));
        }
        return Ok(LyricsResponse::from_text(value.trim(), provider, provider));
    }
    // Go checks these aliases through json.RawMessage. An unused number may
    // exceed float64's range without invalidating an otherwise usable payload.
    if let Ok(value) = json::decode::<BTreeMap<String, Box<RawValue>>>(raw) {
        for key in ["lyrics", "lyric", "lyrics_text", "plain_lyrics"] {
            if let Some(text) = value
                .get(key)
                .and_then(|value| json::decode::<Option<String>>(value.get()).ok().flatten())
                .filter(|value| !value.trim().is_empty())
            {
                return Ok(LyricsResponse::from_text(text.trim(), provider, provider));
            }
        }
    }
    if let Ok(value) = json::decode::<ProxyPayload>(raw) {
        let content = value.content.as_deref().unwrap_or_default();
        let lyrics = value.lyrics.as_deref().unwrap_or_default();
        let text = if !value.lyrics_text.trim().is_empty() {
            Some(value.lyrics_text)
        } else if !lyrics.is_empty() {
            Some(format_pax_content("Syllable", lyrics, multi_person, true))
        } else if !content.is_empty() {
            Some(format_pax_content(
                if value.kind.is_empty() {
                    "Syllable"
                } else {
                    &value.kind
                },
                content,
                multi_person,
                true,
            ))
        } else if !value.plain_lyrics.trim().is_empty() {
            Some(value.plain_lyrics)
        } else {
            None
        };
        if let Some(text) = text {
            return Ok(LyricsResponse::from_text(&text, provider, provider));
        }
    }
    let raw = raw.trim();
    if !raw.is_empty() && !raw.starts_with(['{', '[']) {
        return Ok(LyricsResponse::from_text(raw, provider, provider));
    }
    if json::decode::<Box<RawValue>>(raw).is_ok() {
        return Err(format!(
            "{provider} returned a response without usable lyrics"
        ));
    }
    Err(format!("failed to decode {provider} lyrics response"))
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KpoeSyllable {
    pub text: String,
    pub time: f64,
    pub duration: f64,
    pub is_background: bool,
}
lenient_deserialize!(KpoeSyllable {
    "text" => text, "time" => time, "duration" => duration, "isbackground" => is_background,
});

#[derive(Clone, Debug, Default, Serialize)]
pub struct KpoeLine {
    pub time: f64,
    pub duration: f64,
    pub text: String,
    pub syllabus: Option<Vec<KpoeSyllable>>,
}
lenient_deserialize!(KpoeLine {
    "time" => time, "duration" => duration, "text" => text, "syllabus" => syllabus,
});

#[derive(Clone, Debug, Default, Serialize)]
pub struct KpoeResponse {
    #[serde(rename = "type")]
    pub kind: String,
    pub lyrics: Option<Vec<KpoeLine>>,
}
lenient_deserialize!(KpoeResponse { "type" => kind, "lyrics" => lyrics, });

pub fn format_kpoe(response: &KpoeResponse, multi_person: bool, word_timing: bool) -> String {
    let words = matches!(field_name(&response.kind).as_str(), "word" | "syllable");
    let mut lines = Vec::new();
    let append = |details: &[&KpoeSyllable]| {
        let mut result = String::new();
        for detail in details {
            result.push_str(&format!(
                "<{}>{}",
                lrc::timestamp_inline(detail.time as i64),
                detail.text
            ));
        }
        result
    };
    for line in response.lyrics.as_deref().unwrap_or_default() {
        let syllabus = line.syllabus.as_deref().unwrap_or_default();
        let timestamp = lrc::timestamp(line.time as i64);
        if words && word_timing && !syllabus.is_empty() {
            let (mut main, mut background): (Vec<_>, Vec<_>) =
                syllabus.iter().partition(|detail| !detail.is_background);
            if main.is_empty() {
                main = syllabus.iter().collect();
                background.clear();
            }
            let mut output = format!("{timestamp}{}", append(&main));
            if multi_person && !background.is_empty() {
                output.push_str(&format!("\n[bg:{}]", append(&background)));
            }
            lines.push(output);
        } else {
            let text = if line.text.trim().is_empty() && !syllabus.is_empty() {
                syllabus
                    .iter()
                    .map(|detail| detail.text.as_str())
                    .collect::<String>()
            } else {
                line.text.clone()
            };
            if !text.trim().is_empty() {
                lines.push(format!("{timestamp}{}", text.trim()));
            }
        }
    }
    lines.join("\n").trim().into()
}

#[cfg(test)]
mod tests;
