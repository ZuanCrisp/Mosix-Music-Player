use super::{
    Check, Metadata, Resolution, Resolver, ResolverError, add_source, check_active, urls, useful,
};
use super::{http::ResolverHttp, rate::RateLimiter};
use html5ever::tendril::TendrilSink;
use scraper::{Html, HtmlTreeSink};
use serde::de::DeserializeOwned;
use spotiflac_core::{lyrics, resolver as models};
use spotiflac_network::{NetworkService, url::UrlParts};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

const CHAIN_DEADLINE: &str = "platform resolver deadline exceeded";

pub struct ResolverOptions {
    pub endpoints: BTreeMap<String, String>,
    pub request_timeout: Duration,
    pub chain_timeout: Duration,
    /// Song.link Web, UniTune, MusicBrainz, Squigly, respectively.
    pub rate_limits: [(usize, Duration); 4],
}

impl Default for ResolverOptions {
    fn default() -> Self {
        Self {
            endpoints: BTreeMap::new(),
            request_timeout: Duration::from_secs(6),
            chain_timeout: Duration::from_secs(12),
            rate_limits: [
                (20, Duration::from_secs(60)),
                (30, Duration::from_secs(60)),
                (1, Duration::from_secs(1)),
                (18, Duration::from_secs(60)),
            ],
        }
    }
}

pub struct PlatformResolverChain {
    http: ResolverHttp,
    rates: [RateLimiter; 4],
    timeout: Duration,
}

impl PlatformResolverChain {
    pub fn new(network: &Arc<NetworkService>) -> Self {
        Self::with_options(network, ResolverOptions::default()).expect("default resolver options")
    }

    /// Configuration belongs to a native owner, never to JavaScript input.
    pub fn with_options(
        network: &Arc<NetworkService>,
        options: ResolverOptions,
    ) -> Result<Self, ResolverError> {
        if options.request_timeout.is_zero()
            || options.chain_timeout.is_zero()
            || options
                .rate_limits
                .iter()
                .any(|(max, window)| *max == 0 || window.is_zero())
        {
            return Err(ResolverError::Failed(
                "resolver limits must be positive".into(),
            ));
        }
        Ok(Self {
            http: ResolverHttp::new(network, options.endpoints, options.request_timeout)?,
            rates: options
                .rate_limits
                .map(|(max, window)| RateLimiter::new(max, window)),
            timeout: options.chain_timeout,
        })
    }

    pub fn resolve_one(
        &self,
        provider: &str,
        input: &str,
        hint: &Metadata,
        check: &Check<'_>,
    ) -> Result<Resolution, ResolverError> {
        check_active(check)?;
        if input.len() > 64 << 10 || hint.title.len() + hint.artist.len() > 64 << 10 {
            return Err(ResolverError::Failed("resolver input exceeds limit".into()));
        }
        match provider {
            "songlink" => self.songlink(input, check),
            "unitune" => self.unitune(input, check),
            "musicbrainz" => self.musicbrainz(hint, check),
            "squigly" => self.squigly(input, check),
            _ => Err(ResolverError::Failed("unknown resolver".into())),
        }
    }

    fn songlink(&self, input: &str, check: &Check<'_>) -> Result<Resolution, ResolverError> {
        if urls::direct(urls::platform(input), input).is_empty() {
            return Err(ResolverError::Failed("unsupported source URL".into()));
        }
        self.rates[0].wait(check)?;
        let response = self.http.request(
            &format!("https://song.link/{}", urls::path_escape(input)),
            None,
            true,
            check,
        )?;
        let hostname = UrlParts::parse(&response.url)
            .map(|url| url.hostname.to_ascii_lowercase())
            .unwrap_or_default();
        if !matches!(
            hostname.as_str(),
            "song.link" | "album.link" | "artist.link" | "odesli.co" | "www.odesli.co"
        ) {
            return Err(ResolverError::Failed(
                "web page redirected to an unexpected host".into(),
            ));
        }
        songlink_html(&response.body, input, check)
    }

    fn unitune(&self, input: &str, check: &Check<'_>) -> Result<Resolution, ResolverError> {
        self.rates[1].wait(check)?;
        let body = self
            .http
            .request(
                &format!(
                    "https://api.unitune.art/v1-alpha.1/links?url={}",
                    urls::query_escape(input)
                ),
                None,
                false,
                check,
            )?
            .body;
        let payload: models::UniTune = decode(&body, false, check)?;
        let mut result = Resolution::default();
        for (platform, link) in payload.links.0 {
            check_active(check)?;
            let canonical = urls::canonical(&platform);
            let direct = urls::direct(canonical, &link.url);
            if !direct.is_empty() {
                result.links.insert(canonical.into(), direct);
            }
        }
        // Go's unspecified map iteration can choose any entity if its ID is
        // missing. Rust uses the first sorted key for deterministic fallback.
        if let Some(entity) = payload
            .entities
            .0
            .get(&payload.entity_id)
            .or_else(|| payload.entities.0.values().next())
        {
            result.metadata = Metadata {
                title: entity.title.clone(),
                artist: entity.artist.clone(),
            };
        }
        if result.links.is_empty() && result.metadata.title.is_empty() {
            return Err(ResolverError::Failed(
                "API returned no direct platform links or metadata".into(),
            ));
        }
        Ok(result)
    }

    fn musicbrainz(&self, hint: &Metadata, check: &Check<'_>) -> Result<Resolution, ResolverError> {
        let (title, artist) = (hint.title.trim(), hint.artist.trim());
        if title.is_empty() || artist.is_empty() {
            return Err(ResolverError::Failed(
                "title and artist metadata are required".into(),
            ));
        }
        let escape = |value: &str| value.replace('\\', "\\\\").replace('"', "\\\"");
        let query = format!(
            "recording:\"{}\" AND artist:\"{}\"",
            escape(title),
            escape(artist)
        );
        self.rates[2].wait(check)?;
        let body = self
            .http
            .request(
                &format!(
                    "https://musicbrainz.org/ws/2/recording?fmt=json&limit=5&query={}",
                    urls::query_escape(&query)
                ),
                None,
                false,
                check,
            )?
            .body;
        let payload: models::Recordings = decode(&body, false, check)?;
        let mut id = String::new();
        for candidate in payload.recordings.unwrap_or_default() {
            check_active(check)?;
            let found = candidate
                .artists
                .as_deref()
                .unwrap_or_default()
                .first()
                .map(|artist| artist.name.as_str())
                .unwrap_or_default();
            if candidate.score >= 90
                && lyrics::matching::normalize_title(&candidate.title)
                    == lyrics::matching::normalize_title(title)
                && models::artists_match(artist, found)
            {
                id = candidate.id;
                break;
            }
        }
        if id.is_empty() {
            return Err(ResolverError::Failed("no verified recording match".into()));
        }
        self.rates[2].wait(check)?;
        let body = self
            .http
            .request(
                &format!(
                    "https://musicbrainz.org/ws/2/recording/{}?fmt=json&inc=url-rels+isrcs",
                    urls::path_escape(&id)
                ),
                None,
                false,
                check,
            )?
            .body;
        let payload: models::Relations = decode(&body, false, check)?;
        let mut result = Resolution {
            metadata: hint.clone(),
            ..Resolution::default()
        };
        for relation in payload.relations.unwrap_or_default() {
            check_active(check)?;
            let platform = urls::platform(&relation.url.resource);
            let direct = urls::direct(platform, &relation.url.resource);
            if !direct.is_empty() {
                result.links.entry(platform.into()).or_insert(direct);
            }
        }
        if result.links.is_empty() {
            return Err(ResolverError::Failed(
                "recording has no supported platform relations".into(),
            ));
        }
        Ok(result)
    }

    fn squigly(&self, input: &str, check: &Check<'_>) -> Result<Resolution, ResolverError> {
        self.rates[3].wait(check)?;
        let body = serde_json::to_string(&BTreeMap::from([("url", input)]))
            .unwrap()
            .replace('&', "\\u0026")
            .replace('<', "\\u003c")
            .replace('>', "\\u003e")
            .replace('\u{2028}', "\\u2028")
            .replace('\u{2029}', "\\u2029");
        let created: models::Created = decode(
            &self
                .http
                .request("https://squigly.link/api/create", Some(body), false, check)?
                .body,
            false,
            check,
        )?;
        let page = created.full_url.trim();
        let parsed = UrlParts::parse(page)
            .filter(|url| url.scheme == "https" && url.hostname == "squigly.link")
            .ok_or_else(|| {
                ResolverError::Failed("create endpoint returned an invalid page URL".into())
            })?;
        // Preserve encoded paths and query ordering in the page URL.
        let response = self
            .http
            .request(&parsed.display_url(), None, true, check)?;
        const MARKER: &[u8] = b"window.__SQUIGLY_LINK__ =";
        let offset = response
            .body
            .windows(MARKER.len())
            .position(|value| value == MARKER)
            .ok_or_else(|| {
                ResolverError::Failed("result page contains no resolver payload".into())
            })?;
        let payload: models::Page = decode(&response.body[offset + MARKER.len()..], true, check)?;
        let mut result = Resolution {
            metadata: Metadata {
                title: if payload.data.title.is_empty() {
                    created.title
                } else {
                    payload.data.title
                },
                artist: if payload.data.artist.is_empty() {
                    created.artist
                } else {
                    payload.data.artist
                },
            },
            ..Resolution::default()
        };
        for (platform, service) in payload.data.services.0 {
            check_active(check)?;
            if let Some(service) = service {
                let platform = urls::canonical(&platform);
                let direct = urls::direct(platform, &service.url);
                if !direct.is_empty() {
                    result.links.insert(platform.into(), direct);
                }
            }
        }
        if result.links.is_empty() {
            return Err(ResolverError::Failed(
                "result page returned no direct platform links".into(),
            ));
        }
        Ok(result)
    }
}

impl Resolver for PlatformResolverChain {
    fn resolve(
        &self,
        input: &str,
        hint: &Metadata,
        check: &Check<'_>,
    ) -> Result<Resolution, ResolverError> {
        resolve_chain(input, hint, check, self.timeout, |provider, hint, check| {
            self.resolve_one(provider, input, hint, check)
        })
    }
}

fn resolve_chain(
    input: &str,
    hint: &Metadata,
    check: &Check<'_>,
    timeout: Duration,
    mut resolve: impl FnMut(&str, &Metadata, &Check<'_>) -> Result<Resolution, ResolverError>,
) -> Result<Resolution, ResolverError> {
    if input.len() > 64 << 10 || hint.title.len() + hint.artist.len() > 64 << 10 {
        return Err(ResolverError::Failed("resolver input exceeds limit".into()));
    }
    let started = Instant::now();
    let bounded = || {
        check()?;
        if started.elapsed() >= timeout {
            Err(CHAIN_DEADLINE.into())
        } else {
            Ok(())
        }
    };
    let mut result = Resolution {
        metadata: hint.clone(),
        ..Resolution::default()
    };
    let mut errors = Vec::new();
    for (provider, name) in [
        ("songlink", "Song.link Web"),
        ("unitune", "UniTune"),
        ("musicbrainz", "MusicBrainz"),
        ("squigly", "Squigly"),
    ] {
        match resolve(provider, &result.metadata, &bounded) {
            Ok(resolved) => {
                for (platform, link) in resolved.links {
                    let direct = urls::direct(&platform, &link);
                    if !direct.is_empty() {
                        result.links.entry(platform).or_insert(direct);
                    }
                }
                if result.metadata.title.is_empty() {
                    result.metadata.title = resolved.metadata.title.trim().into();
                }
                if result.metadata.artist.is_empty() {
                    result.metadata.artist = resolved.metadata.artist.trim().into();
                }
                if useful(&result.links) {
                    break;
                }
            }
            Err(ResolverError::Cancelled(message)) if message == CHAIN_DEADLINE => {
                // The chain's own deadline ends fallback work, but must not
                // discard links already found. Caller cancellation and
                // transport policy changes still invalidate the operation.
                check_active(check)?;
                errors.push(format!("{name}: {message}"));
                break;
            }
            Err(error @ ResolverError::Cancelled(_)) => return Err(error),
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }
    check_active(check)?;
    add_source(&mut result.links, input);
    if !result.links.is_empty() {
        return Ok(result);
    }
    Err(ResolverError::Failed(errors.join("\n")))
}

fn decode<T: DeserializeOwned>(
    bytes: &[u8],
    streaming: bool,
    check: &Check<'_>,
) -> Result<T, ResolverError> {
    check_active(check)?;
    let value = if streaming {
        lyrics::decode_response(bytes)
    } else {
        lyrics::decode_document(bytes)
    };
    check_active(check)?;
    value.map_err(|error| ResolverError::Failed(error.to_string()))
}

pub fn songlink_html(
    bytes: &[u8],
    input: &str,
    check: &Check<'_>,
) -> Result<Resolution, ResolverError> {
    check_active(check)?;
    if bytes.len() > 8 << 20 {
        return Err(ResolverError::Failed("HTML input exceeds limit".into()));
    }
    let text = lyrics::text_from_bytes(bytes);
    let mut parser =
        html5ever::parse_document(HtmlTreeSink::new(Html::new_document()), Default::default());
    let mut start = 0;
    while start < text.len() {
        check_active(check)?;
        let end = text.floor_char_boundary((start + 4096).min(text.len()));
        parser.process(text[start..end].into());
        start = end;
        if parser.tokenizer.sink.sink.0.borrow().tree.nodes().len() > 100_000 {
            return Err(ResolverError::Failed("HTML node limit exceeded".into()));
        }
    }
    let html = parser.finish();
    let mut result = Resolution::default();
    for node in html.tree.root().descendants() {
        check_active(check)?;
        if let Some(element) = node.value().as_element()
            && element.name() == "a"
            && let Some(href) = element.attr("href")
        {
            let platform = urls::platform(href);
            let direct = urls::direct(platform, href);
            if !direct.is_empty() {
                result.links.entry(platform.into()).or_insert(direct);
            }
        }
    }
    add_source(&mut result.links, input);
    if result.links.len() < 2 {
        return Err(ResolverError::Failed(
            "web page returned no cross-platform links".into(),
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    #[test]
    fn chain_keeps_web_links_when_a_later_resolver_times_out() {
        let mut calls = Vec::new();
        let source = "https://open.spotify.com/track/source";
        let result = resolve_chain(
            source,
            &Metadata::default(),
            &|| Ok(()),
            Duration::from_millis(10),
            |provider, _, check| {
                calls.push(provider.to_owned());
                if provider == "songlink" {
                    return songlink_html(
                        br#"<a href="https://music.amazon.com/tracks/EXAMPLE?x=1&amp;y=2">Track</a>"#,
                        source,
                        &|| Ok(()),
                    );
                }
                // Exercise the same deadline check used while waiting for an
                // upstream request or a rate-limit slot, without live servers.
                std::thread::sleep(Duration::from_millis(10));
                check_active(check)?;
                panic!("fallback should have reached the chain deadline");
            },
        )
        .unwrap();
        assert_eq!(calls, ["songlink", "unitune"]);
        let availability = super::super::availability::from_links("source", &result.links);
        assert!(availability.amazon);
        assert_eq!(
            availability.amazon_url,
            "https://music.amazon.com/tracks/EXAMPLE?x=1&y=2"
        );
        assert_eq!(result.links["spotify"], source);
    }

    #[test]
    fn chain_deadline_keeps_source_but_cancellation_discards_partial_links() {
        let source = "https://open.spotify.com/track/source";
        let result = resolve_chain(
            source,
            &Metadata::default(),
            &|| Ok(()),
            Duration::ZERO,
            |_, _, check| {
                check_active(check)?;
                unreachable!()
            },
        )
        .unwrap();
        assert_eq!(
            result.links,
            BTreeMap::from([("spotify".into(), source.into())])
        );

        for message in ["request cancelled", "network policy changed"] {
            let cancelled = AtomicBool::new(false);
            let mut calls = 0;
            let result = resolve_chain(
                source,
                &Metadata::default(),
                &|| {
                    if cancelled.load(Ordering::Acquire) {
                        Err(message.into())
                    } else {
                        Ok(())
                    }
                },
                Duration::ZERO,
                |_, _, _| {
                    calls += 1;
                    if calls == 1 {
                        return Ok(Resolution {
                            links: BTreeMap::from([(
                                "amazonMusic".into(),
                                "https://music.amazon.com/tracks/EXAMPLE".into(),
                            )]),
                            ..Resolution::default()
                        });
                    }
                    if message == "request cancelled" {
                        cancelled.store(true, Ordering::Release);
                        Err(ResolverError::Cancelled(CHAIN_DEADLINE.into()))
                    } else {
                        Err(ResolverError::Cancelled(message.into()))
                    }
                },
            );
            assert_eq!(calls, 2);
            assert_eq!(result, Err(ResolverError::Cancelled(message.into())));
        }
    }

    #[test]
    fn html_parsing_is_cancellable_and_bounds_bytes_and_nodes() {
        let checks = AtomicUsize::new(0);
        let html = "<a>Example</a>".repeat(20_000);
        assert!(matches!(
            songlink_html(html.as_bytes(), "", &|| {
                if checks.fetch_add(1, Ordering::AcqRel) >= 3 {
                    Err("cancel parser".into())
                } else {
                    Ok(())
                }
            }),
            Err(ResolverError::Cancelled(_))
        ));
        assert!(songlink_html(&vec![b' '; (8 << 20) + 1], "", &|| Ok(())).is_err());
        assert!(
            matches!(songlink_html("<i></i>".repeat(100_001).as_bytes(), "", &|| Ok(())),
            Err(ResolverError::Failed(message)) if message == "HTML node limit exceeded")
        );
    }
}
