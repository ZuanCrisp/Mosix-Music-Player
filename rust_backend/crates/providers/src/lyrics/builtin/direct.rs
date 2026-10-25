use super::*;
use crate::lyrics::http;
use base64::{
    Engine, alphabet,
    engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig},
};
use html5ever::tendril::TendrilSink;
use scraper::{Html, HtmlTreeSink, Node};
use spotiflac_core::lyrics::lrc;

fn base64_text(text: &str, raw: bool) -> Result<String, LyricsError> {
    // Go accepts nonzero padding bits and ignores CR/LF, but not other spaces.
    let input: Vec<_> = text
        .bytes()
        .filter(|byte| !matches!(byte, b'\r' | b'\n'))
        .collect();
    let padding = if raw {
        base64::engine::DecodePaddingMode::RequireNone
    } else {
        base64::engine::DecodePaddingMode::RequireCanonical
    };
    let engine = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_allow_trailing_bits(true)
            .with_decode_padding_mode(padding),
    );
    engine
        .decode(input)
        .map(|bytes| text_from_bytes(&bytes))
        .map_err(|error| LyricsError::Unavailable(format!("invalid base64 lyrics: {error}")))
}

impl BuiltinLyricsClient {
    fn direct_body(
        &self,
        endpoint: &str,
        params: Params,
        qq: bool,
        check: &Check<'_>,
    ) -> Result<Vec<u8>, LyricsError> {
        let mut get = Request::new(endpoint);
        get.params = params;
        get.max_bytes = 2 << 20;
        get.unavailable_errors = true;
        if qq {
            get.headers
                .insert("Referer".into(), "https://y.qq.com/".into());
            get.headers
                .insert("User-Agent".into(), http::BROWSER_UA.into());
        }
        let response = self.http.get(get, check)?;
        if text_from_bytes(&response.body).trim().is_empty() {
            return Err(LyricsError::Unavailable("empty response".into()));
        }
        Ok(response.body)
    }

    pub(super) fn qqmusic(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} {}", request.track, request.artist);
        if query.trim().is_empty() {
            return Err(LyricsError::NotFound("empty search query".into()));
        }
        let params = pairs(&[
            ("format", "json"),
            ("inCharset", "utf8"),
            ("outCharset", "utf8"),
            ("platform", "yqq.json"),
            ("new_json", "1"),
            ("w", query.trim()),
            ("p", "1"),
            ("n", "20"),
            ("t", "0"),
            ("aggr", "1"),
            ("cr", "1"),
            ("catZhida", "1"),
            ("lossless", "1"),
            ("flag_qc", "0"),
            ("remoteplace", "txt.yqq.center"),
            ("needNewCode", "0"),
        ]);
        let response: models::QqSearch = http::decode(
            &self.direct_body(
                "https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
                params,
                true,
                check,
            )?,
            false,
            check,
        )?;
        if response.code != 0 {
            return Err(LyricsError::Unavailable(format!(
                "QQ Music search returned code {}",
                response.code
            )));
        }
        let songs = response.data.song.list.unwrap_or_default();
        let selected = select(&songs, request, |song| {
            let artist = artists(song.singer.as_deref().unwrap_or_default());
            let duration = song.interval as f64;
            let allowed = matches(&song.name, &artist, duration, request);
            (song.name.clone(), artist, duration, allowed)
        })
        .filter(|song| !song.mid.trim().is_empty())
        .ok_or_else(|| LyricsError::NotFound("no matching song found on QQ Music".into()))?;
        let params = pairs(&[
            ("format", "json"),
            ("inCharset", "utf8"),
            ("outCharset", "utf-8"),
            ("notice", "0"),
            ("platform", "yqq.json"),
            ("needNewCode", "0"),
            ("songmid", &selected.mid),
            ("songid", &selected.id.to_string()),
        ]);
        let response: models::QqLyrics = http::decode(
            &self.direct_body(
                "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                params,
                true,
                check,
            )?,
            false,
            check,
        )?;
        if response.code != 0 || response.retcode != 0 {
            return Err(LyricsError::Unavailable(format!(
                "QQ Music lyrics returned code {}",
                response.code
            )));
        }
        let raw = response.lyric.trim();
        if raw.is_empty() {
            return Err(LyricsError::NotFound(
                "QQ Music returned empty lyrics".into(),
            ));
        }
        let text = if raw.starts_with('[') {
            raw.into()
        } else {
            base64_text(raw, false).or_else(|_| base64_text(raw, true))?
        };
        from_text(&text, "QQ Music", "QQ Music Direct")
    }

    pub(super) fn kugou(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} - {}", request.artist, request.track);
        let rounded = (request.duration * 1000.0).round();
        let milliseconds =
            if !rounded.is_finite() || rounded >= -(i64::MIN as f64) || rounded < i64::MIN as f64 {
                i64::MIN
            } else {
                rounded as i64
            };
        let params = pairs(&[
            ("ver", "1"),
            ("man", "yes"),
            ("client", "pc"),
            ("keyword", query.trim()),
            ("duration", &milliseconds.to_string()),
            ("hash", ""),
        ]);
        let response: models::KugouSearch = http::decode(
            &self.direct_body("https://lyrics.kugou.com/search", params, false, check)?,
            false,
            check,
        )?;
        if response.status != 200 || (response.errcode != 0 && response.errcode != 200) {
            return Err(LyricsError::Unavailable(
                if response.errmsg.trim().is_empty() {
                    format!("status {}/error {}", response.status, response.errcode)
                } else {
                    response.errmsg.trim().into()
                },
            ));
        }
        let songs = response.candidates.unwrap_or_default();
        let song = select(&songs, request, |song| {
            let duration = song.duration / 1000.0;
            (
                song.song.clone(),
                song.singer.clone(),
                duration,
                matches(&song.song, &song.singer, duration, request),
            )
        })
        .filter(|song| !song.id.trim().is_empty() && !song.accesskey.trim().is_empty())
        .ok_or_else(|| LyricsError::NotFound("no matching song found on kugou".into()))?;
        let params = pairs(&[
            ("ver", "1"),
            ("client", "pc"),
            ("id", &song.id),
            ("accesskey", &song.accesskey),
            ("fmt", "lrc"),
            ("charset", "utf8"),
        ]);
        let response: models::KugouLyrics = http::decode(
            &self.direct_body("https://lyrics.kugou.com/download", params, false, check)?,
            false,
            check,
        )?;
        if response.status != 200 || response.error_code != 0 {
            return Err(LyricsError::Unavailable(
                if response.info.trim().is_empty() {
                    format!("status {}/error {}", response.status, response.error_code)
                } else {
                    response.info.trim().into()
                },
            ));
        }
        from_text(
            &base64_text(&response.content, false)?,
            "Kugou",
            "Kugou Direct",
        )
    }

    pub(super) fn genius(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} {}", request.track, request.artist);
        if query.trim().is_empty() {
            return Err(LyricsError::NotFound("empty search query".into()));
        }
        let raw = self.proxy_body(
            "https://genius.com/api/search/multi",
            pairs(&[("q", query.trim()), ("per_page", "5")]),
            check,
        )?;
        let response: models::GeniusSearch = http::decode(raw.as_bytes(), false, check)?;
        let mut best = None;
        let mut best_score = -1;
        for section in response.response.sections.unwrap_or_default() {
            for hit in section.hits.unwrap_or_default() {
                let song = hit.result;
                if hit.kind != "song" || song.url.trim().is_empty() {
                    continue;
                }
                let artist = if song.primary_artist_names.trim().is_empty() {
                    &song.artist_names
                } else {
                    &song.primary_artist_names
                };
                if !matches(&song.title, artist, 0.0, request) {
                    continue;
                }
                let score = matching::score(
                    &song.title,
                    artist,
                    0.0,
                    &request.track,
                    &request.artist,
                    request.duration,
                );
                if score > best_score {
                    best = Some(song.url.trim().to_owned());
                    best_score = score;
                }
            }
        }
        let url = best.ok_or_else(|| LyricsError::NotFound("no songs found on genius".into()))?;
        let mut get = Request::new(&url);
        get.max_bytes = 8 << 20;
        get.unavailable_errors = true;
        get.headers = pairs(&[
            ("Accept", "text/html,application/xhtml+xml"),
            ("Accept-Language", "en-US,en;q=0.9"),
            ("User-Agent", http::BROWSER_UA),
        ]);
        let text = genius_text(&text_from_bytes(&self.http.get(get, check)?.body), check)?;
        from_text(&text, "Genius", "Genius Direct")
    }
}

pub fn genius_text(text: &str, check: &Check<'_>) -> Result<String, LyricsError> {
    check().map_err(LyricsError::Cancelled)?;
    if text.len() > 8 << 20 {
        return Err(LyricsError::Unavailable(
            "Genius page exceeds input limit".into(),
        ));
    }
    let mut parser =
        html5ever::parse_document(HtmlTreeSink::new(Html::new_document()), Default::default());
    let mut start = 0;
    while start < text.len() {
        check().map_err(LyricsError::Cancelled)?;
        let end = text.floor_char_boundary((start + 4096).min(text.len()));
        parser.process(text[start..end].into());
        start = end;
        if parser.tokenizer.sink.sink.0.borrow().tree.nodes().len() > 100_000 {
            return Err(LyricsError::Unavailable(
                "Genius page exceeds HTML node limit".into(),
            ));
        }
    }
    let html = parser.finish();
    let mut found = false;
    let mut sections = Vec::new();
    let mut total = 0;
    for container in html.tree.root().descendants().filter(|node| {
        node.value().as_element().is_some_and(|element| {
            element.name() == "div" && element.attr("data-lyrics-container") == Some("true")
        })
    }) {
        found = true;
        let mut text = String::new();
        let mut stack = vec![container];
        while let Some(node) = stack.pop() {
            check().map_err(LyricsError::Cancelled)?;
            if node
                .value()
                .as_element()
                .is_some_and(|element| element.attr("data-exclude-from-selection") == Some("true"))
            {
                continue;
            }
            match node.value() {
                Node::Text(value) => text.push_str(&value.text),
                Node::Element(element) if element.name() == "br" => text.push('\n'),
                _ => stack.extend(node.children().rev()),
            }
            if text.len() + total > 8 << 20 {
                return Err(LyricsError::Unavailable(
                    "Genius lyrics exceed output limit".into(),
                ));
            }
        }
        let normalized = text.replace('\u{a0}', " ");
        let normalized = normalized.trim();
        if lrc::has_usable_content(normalized) {
            total += normalized.len() + 1;
            sections.push(normalized.to_owned());
        }
    }
    if !found {
        return Err(LyricsError::NotFound(
            "Genius page has no lyrics container".into(),
        ));
    }
    if sections.is_empty() {
        return Err(LyricsError::NotFound(
            "Genius page returned empty lyrics".into(),
        ));
    }
    Ok(sections.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn html_parsing_observes_cancellation_and_bounds_nodes_and_bytes() {
        let checks = AtomicUsize::new(0);
        let html = "<div>Example</div>".repeat(20_000);
        let result = genius_text(&html, &|| {
            if checks.fetch_add(1, Ordering::AcqRel) >= 3 {
                Err("cancel HTML parser".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(
            result,
            Err(LyricsError::Cancelled("cancel HTML parser".into()))
        );
        assert!(matches!(
            genius_text(&" ".repeat((8 << 20) + 1), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
        assert!(matches!(
            genius_text(&"<i></i>".repeat(100_001), &|| Ok(())),
            Err(LyricsError::Unavailable(_))
        ));
    }

    #[test]
    fn base64_keeps_go_padding_bits_linebreaks_and_raw_fallback() {
        assert_eq!(base64_text("Zh==\r\n", false).unwrap(), "f");
        assert_eq!(base64_text("Zh", true).unwrap(), "f");
        assert!(base64_text("Zh", false).is_err());
        assert!(base64_text("Z h==", false).is_err());
        assert!(base64_text("Zg==", true).is_err());
    }
}
