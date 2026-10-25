use super::Parsed;
use super::text::{WS, looks_ttml, trim};
use super::ttml::xml_source;
use regex::Regex;
use roxmltree::{Document, Node};
use std::sync::LazyLock;

pub(super) static WRITER_CREDIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?i)^Written{WS}+by{WS}*:{WS}*(.+)$")).unwrap());
static AU_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?im)^\[au:([^\]\r\n]*)\]{WS}*$")).unwrap());
static PROVIDER_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?im)^\[x-provider:([^\]\r\n]*)\]{WS}*$")).unwrap());
static BY_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?im)^\[by:([^\]\r\n]*)\]{WS}*$")).unwrap());
static VIA_CREDIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?i)\bvia{WS}+([^\(]+)")).unwrap());
static API_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?i){WS}+API$")).unwrap());
static SOURCE_CREDIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"(?i)\(source:{WS}*([^\)]+)\)")).unwrap());
static EXTENSION_PREFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^extension:").unwrap());

pub(super) fn with_credits(raw: &str, lyrics: &mut Parsed) -> Result<(), String> {
    let tag = |pattern: &Regex| pattern.captures(raw).map(|c| trim(&c[1]).to_string());
    let mut writers = tag(&AU_TAG);
    let mut provider = tag(&PROVIDER_TAG);
    let credit = tag(&BY_TAG).unwrap_or_default();
    if provider.is_none()
        && let Some(c) = VIA_CREDIT.captures(&credit)
    {
        provider = Some(API_SUFFIX.replace(trim(&c[1]), "").into());
    }
    if provider.is_none() {
        provider = SOURCE_CREDIT.captures(&credit).map(|c| trim(&c[1]).into());
    }
    provider = provider.map(|value| EXTENSION_PREFIX.replace(&value, "").into());
    if looks_ttml(raw) {
        mornye_core::xml::check_depth(raw)?;
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
