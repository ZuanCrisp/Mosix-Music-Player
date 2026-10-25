//! Apple's TTML lyric documents, as served by lrc.red and BetterLyrics. They
//! are read into the first-party line structure so that both share a single
//! eLRC formatter, including vocal sides and backing groups.
use super::{AppleAgent, AppleMetadata, ApplePayload, PaxDetail, PaxLine, format_apple_payload};
use crate::lyrics::LyricsResponse;
use roxmltree::{Document, Node};
use std::collections::{BTreeMap, HashMap};

const META_NS: &str = "http://www.w3.org/ns/ttml#metadata";
const XML_NS: &str = "http://www.w3.org/XML/1998/namespace";

pub fn ttml_lyrics(
    raw: &str,
    provider: &str,
    source: &str,
    multi_person: bool,
    word_timing: bool,
) -> Result<LyricsResponse, String> {
    crate::xml::check_depth(raw)?;
    let document = Document::parse(raw).map_err(|error| format!("invalid TTML lyrics: {error}"))?;
    let root = document.root_element();
    if root.tag_name().name() != "tt" {
        return Err("not a TTML lyrics document".into());
    }
    let mut keys = HashMap::new();
    let payload = payload(root, &mut keys);
    let text = format_apple_payload(&payload, "TTML lyrics", multi_person, word_timing)?;
    let mut lyrics = LyricsResponse::from_text(&text, provider, source);
    if lyrics.sync_type == "LINE_SYNCED" {
        let romanization = supplement(root, &keys, "transliteration", |lang| {
            lang.split('-')
                .any(|part| part.eq_ignore_ascii_case("Latn"))
        });
        let translation = supplement(root, &keys, "translation", |lang| {
            lang.split('-')
                .next()
                .is_some_and(|part| part.eq_ignore_ascii_case("en"))
        });
        for line in lyrics.lines.iter_mut().flatten() {
            if let Some(text) = romanization.get(&line.start_time_ms) {
                line.romanization = Some(text.clone());
            }
            if let Some(text) = translation.get(&line.start_time_ms) {
                line.translation = Some(text.clone());
            }
        }
    }
    Ok(lyrics)
}

fn payload(root: Node<'_, '_>, keys: &mut HashMap<String, i64>) -> ApplePayload {
    let agents = root
        .descendants()
        .filter(|node| node.has_tag_name((META_NS, "agent")))
        .filter_map(|node| {
            Some(AppleAgent {
                id: node.attribute((XML_NS, "id"))?.into(),
                kind: node.attribute("type").unwrap_or_default().into(),
            })
        })
        .collect();
    let (mut content, mut line_timed) = (Vec::new(), false);
    for paragraph in root
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "p")
    {
        let (mut lead, mut background) = (Vec::new(), Vec::new());
        collect(paragraph, &mut lead, &mut background, false);
        let begin = clock(paragraph.attribute("begin"));
        line_timed |= begin.is_some();
        let start = begin.or_else(|| first_time(&lead)).unwrap_or_default();
        let end = clock(paragraph.attribute("end"))
            .or_else(|| last_time(&lead))
            .unwrap_or(start);
        if let Some(key) = attribute(paragraph, "key") {
            keys.insert(key.into(), start);
        }
        let agent = paragraph
            .attribute((META_NS, "agent"))
            .unwrap_or_default()
            .to_owned();
        let background_lines = (!background.is_empty()).then(|| {
            vec![PaxLine {
                timestamp: first_time(&background).unwrap_or(start) as isize,
                endtime: last_time(&background).unwrap_or(end) as isize,
                text: Some(background),
                ..PaxLine::default()
            }]
        });
        content.push(PaxLine {
            text: Some(lead),
            timestamp: start as isize,
            endtime: end as isize,
            opposite_turn: agent.eq_ignore_ascii_case("v2"),
            background_lines,
            agent,
            ..PaxLine::default()
        });
    }
    content.sort_by_key(|line| line.timestamp);
    let word_timed = content.iter().any(|line| {
        line.text
            .iter()
            .flatten()
            .any(|detail| detail.timestamp.is_some())
    });
    ApplePayload {
        kind: match (word_timed, line_timed) {
            (true, _) => "Syllable",
            (false, true) => "Line",
            (false, false) => "Unsynced",
        }
        .into(),
        content: Some(content),
        metadata: Some(AppleMetadata {
            agents: Some(agents),
        }),
        ..ApplePayload::default()
    }
}

/// Spans are syllables: whitespace between them, not the span boundary,
/// marks the end of a word. Roles other than backing vocals are not sung.
fn collect(
    node: Node<'_, '_>,
    lead: &mut Vec<PaxDetail>,
    background: &mut Vec<PaxDetail>,
    in_background: bool,
) {
    for child in node.children() {
        let target = if in_background {
            &mut *background
        } else {
            &mut *lead
        };
        if child.is_text() {
            push(target, child.text().unwrap_or_default(), None, None);
            continue;
        }
        if !child.is_element() {
            continue;
        }
        match child.attribute((META_NS, "role")) {
            Some("x-bg") => collect(child, lead, background, true),
            Some(_) => {}
            None if child.children().any(|node| node.is_element()) => {
                collect(child, lead, background, in_background);
            }
            None => {
                let text: String = child
                    .descendants()
                    .filter_map(|node| node.text().filter(|_| node.is_text()))
                    .collect();
                push(
                    target,
                    &text,
                    clock(child.attribute("begin")),
                    clock(child.attribute("end")),
                );
            }
        }
    }
}

fn push(target: &mut Vec<PaxDetail>, text: &str, begin: Option<i64>, end: Option<i64>) {
    if text.starts_with(char::is_whitespace)
        && let Some(previous) = target.last_mut()
    {
        previous.part = false;
    }
    let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if words.is_empty() {
        return;
    }
    target.push(PaxDetail {
        text: words,
        part: !text.ends_with(char::is_whitespace),
        timestamp: begin.map(|time| time as isize),
        endtime: end.map(|time| time as isize),
    });
}

fn first_time(details: &[PaxDetail]) -> Option<i64> {
    details
        .iter()
        .find_map(|detail| detail.timestamp)
        .map(|time| time as i64)
}

fn last_time(details: &[PaxDetail]) -> Option<i64> {
    details
        .iter()
        .rev()
        .find_map(|detail| detail.endtime)
        .map(|time| time as i64)
}

/// Vendor attributes such as `itunes:key` and `lrc:key` differ only in prefix.
fn attribute<'a>(node: Node<'a, '_>, name: &str) -> Option<&'a str> {
    node.attributes()
        .find(|attribute| attribute.name() == name)
        .map(|attribute| attribute.value())
}

/// TTML clock values: `12.5`, `1:02.345`, `00:01:02.345` or `12.5s`.
fn clock(value: Option<&str>) -> Option<i64> {
    let value = value?.trim();
    let value = value.strip_suffix('s').unwrap_or(value);
    let parts: Vec<_> = value.split(':').collect();
    if parts.len() > 3 {
        return None;
    }
    let (last, units) = parts.split_last()?;
    let mut seconds: f64 = last.parse().ok()?;
    for (unit, scale) in units.iter().rev().zip([60.0, 3600.0]) {
        seconds += unit.parse::<u32>().ok()? as f64 * scale;
    }
    (seconds.is_finite() && seconds >= 0.0).then(|| (seconds * 1000.0).round() as i64)
}

/// The best covering group of head translations or transliterations, keyed
/// by the start of the line each `text for=` entry refers to.
fn supplement(
    root: Node<'_, '_>,
    keys: &HashMap<String, i64>,
    group: &str,
    accepts_language: impl Fn(&str) -> bool,
) -> BTreeMap<i64, String> {
    let mut best = BTreeMap::new();
    for node in root
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == group)
    {
        if !node
            .attribute((XML_NS, "lang"))
            .is_some_and(&accepts_language)
        {
            continue;
        }
        let lines: BTreeMap<_, _> = node
            .children()
            .filter(|node| node.is_element() && node.tag_name().name() == "text")
            .filter_map(|text| {
                let start = *keys.get(text.attribute("for")?)?;
                let value: String = text
                    .descendants()
                    .filter_map(|node| node.text().filter(|_| node.is_text()))
                    .collect();
                let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
                (!value.is_empty()).then_some((start, value))
            })
            .collect();
        if lines.len() > best.len() {
            best = lines;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEAD: &str = r#"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="ko">"#;

    fn lyrics(body: &str, multi_person: bool, word_timing: bool) -> LyricsResponse {
        ttml_lyrics(
            &format!("{HEAD}{body}</tt>"),
            "Provider",
            "Source",
            multi_person,
            word_timing,
        )
        .unwrap()
    }

    #[test]
    fn syllables_join_inside_words_and_keep_word_times() {
        let body = r#"<body><div><p begin="1.000" end="3.000" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.500">long</span> <span begin="1.500" end="2.000">e</span><span begin="2.000" end="3.000">nough</span></p></div></body>"#;
        let line = lyrics(body, false, false);
        assert_eq!(line.sync_type, "LINE_SYNCED");
        assert_eq!(line.lines()[0].start_time_ms, 1000);
        assert_eq!(line.lines()[0].words, "long enough");
        let text = format_apple_payload(
            &payload(
                Document::parse(&format!("{HEAD}{body}</tt>"))
                    .unwrap()
                    .root_element(),
                &mut HashMap::new(),
            ),
            "TTML lyrics",
            false,
            true,
        )
        .unwrap();
        assert_eq!(
            text,
            "[00:01.00]<00:01.00>long <00:01.50><00:01.50>e<00:02.00><00:02.00>nough<00:03.00>"
        );
    }

    #[test]
    fn duet_sides_and_background_groups_follow_apple_formatting() {
        let body = r#"<head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/><ttm:agent type="group" xml:id="v1000"/></metadata></head><body><div><p begin="1.000" end="2.000" ttm:agent="v1"><span begin="1.000" end="2.000">First</span></p><p begin="3.000" end="5.000" ttm:agent="v2"><span ttm:role="x-bg"><span begin="3.000" end="3.500">(Yes)</span></span> <span begin="3.200" end="5.000">Second</span></p><p begin="6.000" end="7.000" ttm:agent="v1000"><span begin="6.000" end="7.000">Both</span></p></div></body>"#;
        let text = format_apple_payload(
            &payload(
                Document::parse(&format!("{HEAD}{body}</tt>"))
                    .unwrap()
                    .root_element(),
                &mut HashMap::new(),
            ),
            "TTML lyrics",
            true,
            false,
        )
        .unwrap();
        assert_eq!(
            text,
            "[00:01.00]v1:First\n[00:03.00]v2:Second\n[bg:<00:03.00>(Yes)<00:03.50>]\n[00:06.00]v1:Both"
        );
    }

    #[test]
    fn line_timed_documents_and_head_translations() {
        let body = r#"<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation xml:lang="en-US"><text for="L1">Oppa is Gangnam style</text></translation></translations><transliterations><transliteration xml:lang="ko-Latn"><text for="L1"><span>oppan</span> <span>gangnam</span></text></transliteration></transliterations></iTunesMetadata></metadata></head><body><div><p begin="00:00:01.250" end="00:00:03.000" itunes:key="L1">오빤 강남 스타일</p><p begin="00:00:03.000" end="00:00:04.000" itunes:key="L2">Eh</p></div></body>"#;
        let result = lyrics(body, false, true);
        assert_eq!(result.sync_type, "LINE_SYNCED");
        let first = &result.lines()[0];
        assert_eq!(first.start_time_ms, 1250);
        assert_eq!(first.words, "오빤 강남 스타일");
        assert_eq!(first.translation.as_deref(), Some("Oppa is Gangnam style"));
        assert_eq!(first.romanization.as_deref(), Some("oppan gangnam"));
        assert_eq!(result.lines()[1].translation, None);
    }

    #[test]
    fn clock_values_and_invalid_documents() {
        assert_eq!(clock(Some("27.395")), Some(27_395));
        assert_eq!(clock(Some("3:21.570")), Some(201_570));
        assert_eq!(clock(Some("01:00:00.5")), Some(3_600_500));
        assert_eq!(clock(Some("12.5s")), Some(12_500));
        assert_eq!(clock(Some("-1")), None);
        assert_eq!(clock(Some("a:1")), None);
        assert!(ttml_lyrics("<html/>", "P", "S", true, true).is_err());
        assert!(ttml_lyrics("not xml", "P", "S", true, true).is_err());
        let deep = format!("{}{}", "<span>".repeat(64), "</span>".repeat(64));
        assert!(ttml_lyrics(&format!("{HEAD}{deep}</tt>"), "P", "S", true, true).is_err());
    }
}
