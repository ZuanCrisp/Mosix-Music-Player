//! The player's existing LRC/TTML contract, parsed on the bounded data worker.
//! Milliseconds cross the bridge; playback timeline lookup stays in Flutter.
use base64::Engine;
use regex::{Captures, Regex};
use roxmltree::{Document, Node};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    sync::LazyLock,
};

const META_NS: &str = "http://www.w3.org/ns/ttml#metadata";
const XML_NS: &str = "http://www.w3.org/XML/1998/namespace";
const WS: &str = r"[\t\n\v\f\r \u{00a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]";
static LINE_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?\]").unwrap());
static WORD_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?>").unwrap());
static WHITE_SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("{WS}+")).unwrap());
static VOICE_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"(?i)^({WS}*(?:<[0-9]{{1,3}}:[0-9]{{1,2}}(?:[.:][0-9]{{1,3}})?>{WS}*)*)(v[1-9][0-9]*):[ \t]*")).unwrap()
});
static BACKGROUND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\[bg:(.*)\]$").unwrap());
static ID_TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$").unwrap()
});
static SUPPLEMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[x-(romaji-words|romaji|translation):([0-9]+):([^\]]*)\]$").unwrap()
});
static NEW_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\r\n|\r|\n").unwrap());
static WRITER_CREDIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?i)^Written{WS}+by{WS}*:{WS}*(.+)$")).unwrap());

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Word {
    time_ms: i64,
    end_ms: Option<i64>,
    text: String,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Voice {
    id: String,
    index: i64,
    is_group: bool,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Line {
    time_ms: i64,
    end_ms: Option<i64>,
    text: String,
    words: Vec<Word>,
    romanization: Option<String>,
    romanization_words: Vec<Word>,
    translation: Option<String>,
    voice: Option<Voice>,
    is_background: bool,
    vocal_group: Option<i64>,
}
#[derive(Default, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Parsed {
    synced: bool,
    word_synced: bool,
    lines: Vec<Line>,
    plain_text: String,
    writers: Option<String>,
    provider: Option<String>,
}

fn has_usable_timing(lines: &[Line]) -> bool {
    lines.iter().enumerate().any(|(index, line)| {
        !trim(&line.text).is_empty()
            && !(index + 1 == lines.len() && WRITER_CREDIT.is_match(trim(&line.text)))
            && (line.time_ms > 0
                || line.end_ms.is_some_and(|time| time > 0)
                || line.words.iter().any(|word| {
                    !trim(&word.text).is_empty()
                        && (word.time_ms > 0 || word.end_ms.is_some_and(|time| time > 0))
                }))
    })
}
impl Line {
    fn new(
        time_ms: i64,
        end_ms: Option<i64>,
        text: String,
        words: Vec<Word>,
        voice: Option<Voice>,
        background: bool,
        group: Option<i64>,
    ) -> Self {
        Self {
            time_ms,
            end_ms,
            text,
            words,
            voice,
            is_background: background,
            vocal_group: group,
            romanization: None,
            romanization_words: vec![],
            translation: None,
        }
    }
}

pub(crate) fn execute(
    request: &Value,
    bytes: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let raw = match bytes.filter(|b| !b.is_empty()) {
        Some(data) => std::str::from_utf8(data).map_err(|e| e.to_string())?,
        None => request["raw"].as_str().unwrap_or_default(),
    };
    let text = trim(raw);
    let mut parsed = if text.is_empty() {
        Parsed::default()
    } else {
        match if looks_ttml(text) {
            parse_ttml(text, check)?
        } else {
            None
        } {
            Some(parsed) if !parsed.lines.is_empty() => parsed,
            _ => parse_lrc(text, check)?,
        }
    };
    if !text.is_empty() {
        with_credits(text, &mut parsed)?;
    }
    check()?;
    serde_json::to_value(parsed).map_err(|e| e.to_string())
}

fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n'
            | '\u{000b}'
            | '\u{000c}'
            | '\r'
            | ' '
            | '\u{0085}'
            | '\u{00a0}'
            | '\u{1680}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    ) || ('\u{2000}'..='\u{200a}').contains(&c)
}
fn trim(s: &str) -> &str {
    s.trim_matches(whitespace)
}
fn trim_end(s: &str) -> &str {
    s.trim_end_matches(whitespace)
}
fn parse_int(s: &str) -> Option<i64> {
    let s = trim(s);
    let (negative, rest) = if let Some(s) = s.strip_prefix('-') {
        (true, s)
    } else {
        (false, s.strip_prefix('+').unwrap_or(s))
    };
    let unsigned = if rest.starts_with("0x") || rest.starts_with("0X") {
        i64::from_str_radix(&rest[2..], 16).ok()?
    } else {
        rest.parse::<i64>().ok()?
    };
    if negative {
        unsigned.checked_neg()
    } else {
        Some(unsigned)
    }
}
fn looks_ttml(s: &str) -> bool {
    let head = s.trim_start_matches(whitespace);
    head.starts_with("<?xml")
        || head.starts_with("<tt")
        || head.contains("<tt ")
        || head.contains("http://www.w3.org/ns/ttml")
}
fn duration(c: &Captures<'_>) -> i64 {
    let fraction = c
        .get(3)
        .map(|v| {
            format!("{v:0<3}", v = v.as_str())[..3]
                .parse::<i64>()
                .unwrap_or(0)
        })
        .unwrap_or(0);
    parse_int(&c[1]).unwrap_or(0) * 60_000 + parse_int(&c[2]).unwrap_or(0) * 1000 + fraction
}
fn vocal_text(content: &str) -> (String, Option<Voice>) {
    let Some(c) = VOICE_PREFIX.captures(content) else {
        return (content.into(), None);
    };
    let id = c[2].to_ascii_lowercase();
    let voice = Voice {
        index: parse_int(&id[1..]).unwrap_or(1) - 1,
        is_group: id == "v3",
        id,
    };
    (
        format!(
            "{}{}",
            WHITE_SPACE.replace_all(&c[1], ""),
            &content[c.get(0).unwrap().end()..]
        ),
        Some(voice),
    )
}
fn parse_words(content: &str) -> Vec<Word> {
    let matches: Vec<_> = WORD_TIME.captures_iter(content).collect();
    let mut words: Vec<Word> = Vec::new();
    for (i, c) in matches.iter().enumerate() {
        let time_ms = duration(c);
        let start = c.get(0).unwrap().end();
        let end = matches
            .get(i + 1)
            .map(|c| c.get(0).unwrap().start())
            .unwrap_or(content.len());
        let text = &content[start..end];
        if trim(text).is_empty() {
            if let Some(previous) = words.last_mut()
                && previous.end_ms.is_none()
                && time_ms >= previous.time_ms
            {
                previous.end_ms = Some(time_ms);
            }
        } else {
            words.push(Word {
                time_ms,
                end_ms: None,
                text: text.into(),
            });
        }
    }
    words
}
fn decode_supplement(encoded: &str) -> Option<String> {
    // Base64Decoder accepts URL-safe characters and %3D padding, but does
    // not synthesize missing padding or decode other percent escapes.
    let mut normalized = String::new();
    let bytes = encoded.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let byte = if bytes[index] == b'%' {
            let value = u8::from_str_radix(
                std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?,
                16,
            )
            .ok()?;
            if value != b'=' {
                return None;
            }
            index += 3;
            value
        } else {
            let value = bytes[index];
            index += 1;
            value
        };
        normalized.push(match byte {
            b'-' => '+',
            b'_' => '/',
            _ => char::from(byte),
        });
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(normalized)
        .ok()?;
    Some(trim(&String::from_utf8(bytes).ok()?).into())
}
fn romanization_words(raw: &str) -> Vec<Word> {
    let Ok(Value::Array(values)) = serde_json::from_str::<Value>(raw) else {
        return vec![];
    };
    let mut words: Vec<Word> = Vec::new();
    for value in values {
        let (Some(text), Some(start), Some(end)) = (
            value["text"].as_str(),
            value["startTimeMs"].as_i64(),
            value["endTimeMs"].as_i64(),
        ) else {
            return vec![];
        };
        if trim(text).is_empty()
            || start < 0
            || end < start
            || words.last().is_some_and(|w| w.time_ms > start)
        {
            return vec![];
        }
        words.push(Word {
            time_ms: start,
            end_ms: Some(end),
            text: text.into(),
        });
    }
    words
}
struct Supplements<T> {
    entries: Vec<(i64, T)>,
    seen: HashSet<i64>,
}
impl<T> Supplements<T> {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
            seen: HashSet::new(),
        }
    }
}
fn insert_first<T>(supplements: &mut Supplements<T>, time: i64, value: T) {
    if supplements.seen.insert(time) {
        supplements.entries.push((time, value));
    }
}
fn align<T: Clone>(lines: &[Line], supplements: Supplements<T>) -> HashMap<i64, T> {
    let mut matched: HashMap<i64, (i64, T)> = HashMap::new();
    for (time, value) in supplements.entries {
        let lo = lines.partition_point(|line| line.time_ms < time);
        let mut nearest = None;
        let mut distance = 11;
        for index in [lo.checked_sub(1), Some(lo)].into_iter().flatten() {
            let Some(line) = lines.get(index) else {
                continue;
            };
            let delta = line.time_ms.abs_diff(time);
            if delta < distance as u64 {
                nearest = Some(line.time_ms);
                distance = delta as i64;
            }
        }
        if let Some(nearest) = nearest
            && matched.get(&nearest).is_none_or(|(old, _)| distance < *old)
        {
            matched.insert(nearest, (distance, value));
        }
    }
    matched
        .into_iter()
        .map(|(key, (_, value))| (key, value))
        .collect()
}
fn shift(time: i64, offset: i64) -> i64 {
    time.saturating_sub(offset).max(0)
}
fn shift_words(words: &mut [Word], offset: i64) {
    if offset == 0 {
        return;
    }
    for word in words {
        word.time_ms = shift(word.time_ms, offset);
        word.end_ms = word.end_ms.map(|time| shift(time, offset));
    }
}
fn parse_lrc(text: &str, check: &dyn Fn() -> Result<(), String>) -> Result<Parsed, String> {
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

#[derive(Debug)]
struct Run {
    voice: Option<Voice>,
    background: bool,
    fragments: Vec<(String, Option<i64>, Option<i64>)>,
}
impl Run {
    fn add(&mut self, value: &str, begin: Option<i64>, end: Option<i64>) {
        let normalized = WHITE_SPACE.replace_all(value, " ");
        let text = if self
            .fragments
            .last()
            .is_none_or(|(text, _, _)| text.ends_with(' '))
        {
            normalized.trim_start_matches(whitespace)
        } else {
            &normalized
        };
        if text.is_empty() {
            return;
        }
        if let Some((previous, old_begin, old_end)) = self.fragments.last_mut()
            && (trim(text).is_empty() || (begin == *old_begin && end == *old_end))
        {
            previous.push_str(text);
            return;
        }
        self.fragments.push((text.into(), begin, end));
    }
    fn text(&self) -> String {
        trim(
            &self
                .fragments
                .iter()
                .map(|(text, _, _)| text.as_str())
                .collect::<String>(),
        )
        .into()
    }
    fn words(&self) -> Vec<Word> {
        if self.fragments.iter().any(|(_, begin, _)| begin.is_none()) {
            return vec![];
        }
        self.fragments
            .iter()
            .enumerate()
            .map(|(i, (text, begin, end))| Word {
                time_ms: begin.unwrap(),
                end_ms: end.filter(|end| *end >= begin.unwrap()),
                text: if i + 1 == self.fragments.len() {
                    trim_end(text).into()
                } else {
                    text.clone()
                },
            })
            .collect()
    }
}
fn voice_of(
    element: Node<'_, '_>,
    inherited: Option<Voice>,
    voices: &mut HashMap<String, Voice>,
    next: &mut i64,
) -> Option<Voice> {
    let Some(id) = element
        .attribute((META_NS, "agent"))
        .filter(|id| !id.is_empty())
    else {
        return inherited;
    };
    Some(
        voices
            .entry(id.into())
            .or_insert_with(|| {
                let voice = Voice {
                    id: id.into(),
                    index: *next,
                    is_group: id.eq_ignore_ascii_case("v3"),
                };
                *next += 1;
                voice
            })
            .clone(),
    )
}
fn rounded_ms(seconds: &str) -> Option<i64> {
    let seconds = trim(seconds).parse::<f64>().ok()?;
    let ms = seconds * 1000.0;
    if !ms.is_finite() || ms < i64::MIN as f64 || ms >= -(i64::MIN as f64) {
        return None;
    }
    Some(ms.round() as i64)
}
fn clock(value: Option<&str>) -> Option<i64> {
    let value = trim(value?);
    if let Some(seconds) = value.strip_suffix('s').filter(|_| !value.contains(':')) {
        return rounded_ms(seconds);
    }
    let parts: Vec<_> = value.split(':').collect();
    match parts.as_slice() {
        [hours, minutes, seconds] => parse_int(hours)?
            .checked_mul(3_600_000)?
            .checked_add(parse_int(minutes)?.checked_mul(60_000)?)?
            .checked_add(rounded_ms(seconds)?),
        [minutes, seconds] => parse_int(minutes)?
            .checked_mul(60_000)?
            .checked_add(rounded_ms(seconds)?),
        _ => None,
    }
}
#[allow(clippy::too_many_arguments)]
fn visit(
    node: Node<'_, '_>,
    paragraph: Node<'_, '_>,
    voice: Option<Voice>,
    background: bool,
    begin: Option<i64>,
    end: Option<i64>,
    voices: &mut HashMap<String, Voice>,
    next: &mut i64,
    runs: &mut Vec<Run>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    // Use a heap stack so a deeply nested span tree cannot exhaust the native
    // worker's call stack. Reverse pushes preserve the original document order.
    let mut pending = vec![(node, voice, background, begin, end)];
    while let Some((node, voice, background, begin, end)) = pending.pop() {
        check()?;
        if node.is_text() {
            let value = node.text().unwrap_or_default();
            if trim(value).is_empty() && runs.is_empty() {
                continue;
            }
            let index = runs.iter().position(|run| {
                run.voice.as_ref().map(|v| &v.id) == voice.as_ref().map(|v| &v.id)
                    && run.background == background
            });
            let index = match index {
                Some(index) => index,
                None => {
                    if trim(value).is_empty() {
                        continue;
                    }
                    runs.push(Run {
                        voice,
                        background,
                        fragments: vec![],
                    });
                    runs.len() - 1
                }
            };
            runs[index].add(value, begin, end);
        } else if node.is_element() {
            let voice = voice_of(node, voice, voices, next);
            let background = background || node.attribute((META_NS, "role")) == Some("x-bg");
            let begin = if node == paragraph {
                None
            } else {
                clock(node.attribute("begin"))
            }
            .or(begin);
            let end = if node == paragraph {
                None
            } else {
                clock(node.attribute("end"))
            }
            .or(end);
            for child in node.children().rev() {
                pending.push((child, voice.clone(), background, begin, end));
            }
        }
    }
    Ok(())
}
fn parse_ttml(
    text: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Parsed>, String> {
    crate::native_xml::check_depth(text)?;
    let normalized = xml_source(text, true);
    let Ok(doc) = Document::parse_with_options(
        &normalized,
        roxmltree::ParsingOptions {
            allow_dtd: true,
            ..Default::default()
        },
    ) else {
        return Ok(None);
    };
    let elements: Vec<_> = doc.descendants().filter(Node::is_element).collect();
    let paragraphs: Vec<_> = elements
        .iter()
        .copied()
        .filter(|n| n.tag_name().name() == "p")
        .collect();
    if paragraphs.is_empty() {
        return Ok(None);
    }
    let mut voices = HashMap::new();
    let mut next = 0;
    for agent in elements.iter().filter(|node| {
        node.tag_name().name() == "agent" && node.tag_name().namespace() == Some(META_NS)
    }) {
        let Some(id) = agent.attribute((XML_NS, "id")).filter(|id| !id.is_empty()) else {
            continue;
        };
        let group = agent.attribute("type") == Some("group") || id.eq_ignore_ascii_case("v3");
        voices.insert(
            id.into(),
            Voice {
                id: id.into(),
                index: next,
                is_group: group,
            },
        );
        if !group {
            next += 1;
        }
    }
    let (mut lines, mut plain, mut saw_words, mut next_group) =
        (Vec::<Line>::new(), Vec::new(), false, 0);
    for p in paragraphs {
        check()?;
        let begin = clock(p.attribute("begin"));
        let end = clock(p.attribute("end"));
        let mut voice = None;
        let ancestors: Vec<_> = p.ancestors().skip(1).filter(Node::is_element).collect();
        for ancestor in ancestors.into_iter().rev() {
            voice = voice_of(ancestor, voice, &mut voices, &mut next);
        }
        let mut runs = Vec::new();
        visit(
            p,
            p,
            voice,
            false,
            None,
            None,
            &mut voices,
            &mut next,
            &mut runs,
            check,
        )?;
        let mut lead_groups = Vec::new();
        for (i, run) in runs.iter().enumerate() {
            if !run.background && !run.text().is_empty() {
                lead_groups.push((i, next_group));
                next_group += 1;
            }
        }
        for (i, run) in runs.iter().enumerate() {
            let text = run.text();
            if text.is_empty() {
                continue;
            }
            plain.push(text.clone());
            let words = run.words();
            let Some(begin) = (if runs.len() == 1 {
                begin
            } else {
                words.first().map(|word| word.time_ms).or(begin)
            }) else {
                continue;
            };
            saw_words |= !words.is_empty();
            let lead = if run.background {
                lead_groups
                    .iter()
                    .find(|(index, _)| {
                        runs[*index].voice.as_ref().map(|v| &v.id)
                            == run.voice.as_ref().map(|v| &v.id)
                    })
                    .or(lead_groups.first())
                    .map(|(index, _)| *index)
            } else {
                Some(i)
            };
            let group = lead
                .and_then(|index| {
                    lead_groups
                        .iter()
                        .find(|(i, _)| *i == index)
                        .map(|(_, group)| *group)
                })
                .or_else(|| {
                    if run.background {
                        lines.last().and_then(|line| line.vocal_group)
                    } else {
                        None
                    }
                });
            let end = if runs.len() == 1 {
                end
            } else {
                words.last().and_then(|word| word.end_ms).or(end)
            };
            lines.push(Line::new(
                begin,
                end,
                text,
                words,
                run.voice.clone(),
                run.background,
                group,
            ));
        }
    }
    lines.sort_by_key(|line| line.time_ms);
    let synced = has_usable_timing(&lines);
    Ok(Some(Parsed {
        synced,
        word_synced: synced && saw_words,
        lines,
        plain_text: plain.join("\n"),
        ..Parsed::default()
    }))
}

fn xml_source(input: &str, drop_cdata: bool) -> String {
    // Dart's default entity mapping leaves bare '&' and unknown references
    // literal, including entities declared in a DOCTYPE. Escape those before
    // using the stricter XML reader; never resolve external resources.
    let mut result = String::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        let tail = &input[index..];
        let opaque = if tail.starts_with("<![CDATA[") {
            Some(("]]>", drop_cdata))
        } else if tail.starts_with("<!--") {
            Some(("-->", false))
        } else if tail.starts_with("<?") {
            Some(("?>", false))
        } else {
            None
        };
        if let Some((ending, drop)) = opaque {
            if let Some(end) = tail.find(ending) {
                let end = end + ending.len();
                if !drop {
                    result.push_str(&tail[..end]);
                }
                index += end;
                continue;
            }
            // A missing terminator is a syntax error; preserve it for the
            // parser without repeatedly scanning the remainder of the input.
            result.push_str(tail);
            break;
        }
        if tail.starts_with("<!DOCTYPE") {
            if let Some(end) = crate::native_xml::markup_end(tail, true) {
                result.push_str(&tail[..end]);
                index += end;
                continue;
            }
            result.push_str(tail);
            break;
        }
        let character = tail.chars().next().unwrap();
        if character == '&' {
            let ending = tail[1..]
                .bytes()
                .position(|byte| byte == b';' || !(byte.is_ascii_alphanumeric() || byte == b'#'));
            let entity = ending
                .filter(|position| tail.as_bytes()[position + 1] == b';')
                .map(|position| &tail[1..position + 1]);
            let known = entity.is_some_and(|name| {
                if matches!(name, "amp" | "lt" | "gt" | "apos" | "quot") { return true; }
                let number = if let Some(hex) = name.strip_prefix("#x") { u32::from_str_radix(hex, 16).ok() }
                    else { name.strip_prefix('#').and_then(|number| number.parse::<u32>().ok()) };
                number.is_some_and(|value| matches!(value, 9 | 10 | 13 | 0x20..=0xd7ff | 0xe000..=0xfffd | 0x10000..=0x10ffff))
            });
            if known {
                result.push('&');
            } else {
                result.push_str("&amp;");
            }
        } else {
            result.push(character);
        }
        index += character.len_utf8();
    }
    result
}

fn with_credits(raw: &str, lyrics: &mut Parsed) -> Result<(), String> {
    let tag = |name: &str| {
        Regex::new(&format!(r"(?im)^\[{name}:([^\]\r\n]*)\]{WS}*$"))
            .unwrap()
            .captures(raw)
            .map(|c| trim(&c[1]).to_string())
    };
    let mut writers = tag("au");
    let mut provider = tag("x-provider");
    let credit = tag("by").unwrap_or_default();
    if provider.is_none()
        && let Some(c) = Regex::new(&format!(r"(?i)\bvia{WS}+([^\(]+)"))
            .unwrap()
            .captures(&credit)
    {
        provider = Some(
            Regex::new(&format!(r"(?i){WS}+API$"))
                .unwrap()
                .replace(trim(&c[1]), "")
                .into(),
        );
    }
    if provider.is_none() {
        provider = Regex::new(&format!(r"(?i)\(source:{WS}*([^\)]+)\)"))
            .unwrap()
            .captures(&credit)
            .map(|c| trim(&c[1]).into());
    }
    provider = provider.map(|value| {
        Regex::new(r"(?i)^extension:")
            .unwrap()
            .replace(&value, "")
            .into()
    });
    if looks_ttml(raw) {
        crate::native_xml::check_depth(raw)?;
        let normalized = xml_source(raw, false);
        match Document::parse_with_options(
            &normalized,
            roxmltree::ParsingOptions {
                allow_dtd: true,
                ..Default::default()
            },
        ) {
            Ok(doc) => {
                let mut names: Vec<String> = Vec::new();
                for node in doc
                    .descendants()
                    .filter(|node| node.is_element() && node.tag_name().name() == "songwriter")
                {
                    let name = node
                        .descendants()
                        .filter(Node::is_text)
                        .filter_map(|node| node.text())
                        .collect::<String>();
                    let name = trim(&name);
                    if !name.is_empty() && !names.iter().any(|old| old == name) {
                        names.push(name.into());
                    }
                }
                if !names.is_empty() {
                    writers = Some(names.join(", "));
                }
            }
            // XmlTagException/XmlNamespaceException propagate in the existing
            // parser; syntax-only XmlParserException falls back to plain text.
            Err(
                error @ (roxmltree::Error::UnclosedRootNode
                | roxmltree::Error::UnexpectedCloseTag(..)
                | roxmltree::Error::UnknownNamespace(..)),
            ) => return Err(error.to_string()),
            Err(_) => {}
        }
    }
    if let Some(line) = lyrics.lines.last()
        && let Some(c) = WRITER_CREDIT.captures(trim(&line.text))
    {
        if writers.is_none() {
            writers = Some(trim(&c[1]).into());
        }
        lyrics.lines.pop();
        lyrics.plain_text = lyrics
            .lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
    } else if lyrics.lines.is_empty() {
        let (text, footer) = lyrics
            .plain_text
            .rsplit_once('\n')
            .unwrap_or(("", &lyrics.plain_text));
        if let Some(c) = WRITER_CREDIT.captures(trim(footer)) {
            if writers.is_none() {
                writers = Some(trim(&c[1]).into());
            }
            lyrics.plain_text = text.into();
        }
    }
    lyrics.writers = writers.filter(|s| !s.is_empty());
    lyrics.provider = provider.filter(|s| !s.is_empty());
    if !lyrics.synced {
        lyrics.lines.clear();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_dart_parser_goldens() {
        let fixtures: Value = serde_json::from_str(include_str!(
            "../../../../test/fixtures/native_lyrics_parsers.json"
        ))
        .unwrap();
        for fixture in fixtures.as_array().unwrap() {
            let actual = execute(&fixture["request"], None, &|| Ok(())).unwrap();
            assert_eq!(actual, fixture["expected"], "{}", fixture["name"]);
        }
    }
    #[test]
    fn cancellation_stops_before_result_publication() {
        assert_eq!(
            execute(&serde_json::json!({"raw":"[00:01]Line"}), None, &|| Err(
                "cancelled".into()
            ))
            .unwrap_err(),
            "cancelled"
        );
    }
    #[test]
    fn malformed_structural_ttml_remains_an_error() {
        for raw in [
            "<tt><body><p>Unclosed",
            "<tt><p>Mismatch</tt>",
            "<tt><m:p>Unknown namespace</m:p></tt>",
        ] {
            assert!(execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).is_err());
        }
    }
    #[test]
    fn deeply_nested_vocals_preserve_timing_and_document_order() {
        std::thread::Builder::new().stack_size(512 << 10).spawn(|| {
                let depth = 12; // Including tt/body/p and each word: the 16-level limit.
        let raw = format!(
            "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><p begin=\"00:01.000\" end=\"00:03.000\">{}<span begin=\"00:01.000\">First </span><span begin=\"00:02.000\">second</span>{}</p></body></tt>",
            "<span>".repeat(depth),
            "</span>".repeat(depth),
        );
        let parsed = execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap();
        assert_eq!(parsed["lines"][0]["text"], "First second");
        assert_eq!(parsed["lines"][0]["words"][0]["timeMs"], 1000);
        assert_eq!(parsed["lines"][0]["words"][1]["timeMs"], 2000);
        }).unwrap().join().unwrap();
    }
    #[test]
    fn pathological_ttml_depth_is_rejected_before_recursive_tokenization() {
        let raw = format!(
            "<tt><body><p>{}Line{}</p></body></tt>",
            "<span>".repeat(10_000),
            "</span>".repeat(10_000),
        );
        assert_eq!(
            execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap_err(),
            "XML nesting exceeds 16 elements"
        );
    }
    #[test]
    fn depth_guard_ignores_opaque_markup_and_quoted_tag_boundaries() {
        let opaque = "<span>".repeat(1_000);
        let raw = format!(
            "<?xml version=\"1.0\"?><!DOCTYPE tt [<!-- ]> {opaque} --> <!ENTITY markup \"{opaque}\">]><tt><!--{opaque}--><body><p begin='1s' end='2s' data=\">\"><![CDATA[{opaque}]]><span data='>'>Line</span></p></body></tt>"
        );
        crate::native_xml::check_depth(&raw).unwrap();
        let parsed = execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap();
        assert_eq!(parsed["plainText"], "Line");
    }
}
