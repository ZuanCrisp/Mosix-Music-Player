//! TTML document parsing into timed lyric lines, words, and voices.

use super::text::{WHITE_SPACE, parse_int, trim, trim_end, whitespace};
use super::{Line, Parsed, Voice, Word, has_usable_timing};
use roxmltree::{Document, Node};
use std::collections::HashMap;

const META_NS: &str = "http://www.w3.org/ns/ttml#metadata";
const XML_NS: &str = "http://www.w3.org/XML/1998/namespace";

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
pub(super) fn parse_ttml(
    text: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Parsed>, String> {
    mornye_core::xml::check_depth(text)?;
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

pub(super) fn xml_source(input: &str, drop_cdata: bool) -> String {
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
            if let Some(end) = mornye_core::xml::markup_end(tail, true) {
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
