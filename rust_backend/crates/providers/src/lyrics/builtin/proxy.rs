use super::*;
use crate::lyrics::http;
use spotiflac_core::lyrics::{decode_document, payloads};
use spotiflac_core::matching::lowercase;

pub(super) fn spotify_id(raw: &str) -> String {
    let mut raw = raw.trim();
    if lowercase(raw).starts_with("deezer:") {
        return String::new();
    }
    if lowercase(raw).starts_with("spotify:") {
        raw = raw.rsplit(':').next().unwrap_or_default();
    }
    if raw.contains("spotify.com/track/") {
        raw = raw.split("/track/").nth(1).unwrap_or_default();
    }
    raw = raw.split('?').next().unwrap_or_default().trim();
    if raw.len() == 22 && raw.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        raw.into()
    } else {
        String::new()
    }
}

pub(super) fn deezer_id(raw: &str) -> String {
    let mut raw = raw.trim();
    if lowercase(raw).starts_with("deezer:") {
        raw = raw[7..].trim();
    }
    if raw.contains("deezer.com/") {
        raw = raw.rsplit('/').next().unwrap_or_default();
    }
    raw = raw.split('?').next().unwrap_or_default().trim();
    if raw.parse::<i64>().is_ok() {
        raw.into()
    } else {
        String::new()
    }
}

impl BuiltinLyricsClient {
    pub(super) fn spotify(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let mut id = spotify_id(&request.spotify_id);
        if id.is_empty() {
            let query = format!("{} {}", request.track, request.artist);
            if query.trim().is_empty() {
                return Err(LyricsError::NotFound("empty search query".into()));
            }
            let raw = self.proxy_body(
                "https://lyrics.paxsenix.org/spotify/search",
                pairs(&[("q", query.trim())]),
                check,
            )?;
            let songs: Option<Vec<models::SpotifySong>> =
                http::decode(raw.as_bytes(), false, check)?;
            let songs = songs.unwrap_or_default();
            let selected = select(&songs, request, |song| {
                let duration = matching::clock_duration(&song.duration);
                (
                    song.name.clone(),
                    song.artist_name.clone(),
                    duration,
                    matches(&song.name, &song.artist_name, duration, request),
                )
            })
            .filter(|song| !song.track_id.trim().is_empty())
            .ok_or_else(|| LyricsError::NotFound("no songs found on spotify".into()))?;
            id = selected.track_id.trim().into();
        }
        let raw = self.proxy_body(
            "https://lyrics.paxsenix.org/spotify/lyrics",
            pairs(&[("id", &id)]),
            check,
        )?;
        payloads::parse_proxy(&raw, "Spotify", false).map_err(LyricsError::Unavailable)
    }

    pub(super) fn deezer(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let mut id = deezer_id(&request.spotify_id);
        if id.is_empty() {
            let spotify = spotify_id(&request.spotify_id);
            if spotify.is_empty() {
                return Err(LyricsError::NotFound(
                    "deezer provider needs a deezer id or spotify id".into(),
                ));
            }
            id = deezer_id(&self.resolver.deezer_id_from_spotify(&spotify, check)?);
        }
        if id.is_empty() {
            return Err(LyricsError::Other("deezer id unavailable".into()));
        }
        let raw = self.proxy_body(
            "https://lyrics.paxsenix.org/deezer/lyrics",
            pairs(&[("id", &id)]),
            check,
        )?;
        payloads::parse_proxy(&raw, "Deezer", true).map_err(LyricsError::Unavailable)
    }

    pub(super) fn youtube(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} {}", request.track, request.artist);
        if query.trim().is_empty() {
            return Err(LyricsError::NotFound("empty search query".into()));
        }
        let raw = self.proxy_body(
            "https://lyrics.paxsenix.org/youtube/search",
            pairs(&[("q", query.trim())]),
            check,
        )?;
        let songs: Option<Vec<models::YouTubeSong>> = http::decode(raw.as_bytes(), false, check)?;
        let songs = songs.unwrap_or_default();
        let selected = select(&songs, request, |song| {
            let duration = matching::clock_duration(&song.duration);
            let allowed = matching::titles_match(&song.title, &request.track, true)
                && (matching::artists_match(&song.author, &request.artist)
                    || matching::artist_in_title(&song.title, &request.artist))
                && matching::duration_matches(duration, request.duration);
            (song.title.clone(), song.author.clone(), duration, allowed)
        })
        .filter(|song| !song.video_id.trim().is_empty())
        .ok_or_else(|| LyricsError::NotFound("no songs found on youtube".into()))?;
        let raw = self.proxy_body(
            "https://lyrics.paxsenix.org/youtube/lyrics",
            pairs(&[("id", selected.video_id.trim())]),
            check,
        )?;
        payloads::parse_proxy(&raw, "YouTube", false).map_err(LyricsError::Unavailable)
    }

    pub(super) fn netease(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} {}", request.track, request.artist);
        if query.trim().is_empty() {
            return Err(LyricsError::NotFound("empty search query".into()));
        }
        let headers = pairs(&[
            ("Accept", "application/json"),
            ("Accept-Language", "en-US,en;q=0.9"),
            ("Cache-Control", "max-age=0"),
        ]);
        let mut search = Request::new("https://lyrics.paxsenix.org/netease/search");
        search.params = pairs(&[("q", &query)]);
        search.headers = headers.clone();
        let body = self.http.get(search, check)?.body;
        let response: models::NeteaseSearch = http::decode(&body, true, check)?;
        if response.code != 0 && response.code != 200 {
            let message = if !response.message.trim().is_empty() {
                response.message.trim()
            } else if !response.msg.trim().is_empty() {
                response.msg.trim()
            } else {
                "unexpected response code"
            };
            return Err(LyricsError::Unavailable(format!(
                "netease search unavailable: code {}: {message}",
                response.code
            )));
        }
        let songs = response.result.songs.unwrap_or_default();
        if response.result.song_count == 0 || songs.is_empty() {
            return Err(LyricsError::NotFound("no songs found on netease".into()));
        }
        let song = select(&songs, request, |song| {
            let artist = artists(song.artists.as_deref().unwrap_or_default());
            let allowed = matches(&song.name, &artist, 0.0, request);
            (song.name.clone(), artist, 0.0, allowed)
        })
        .filter(|song| song.id != 0)
        .ok_or_else(|| LyricsError::NotFound("no matching songs found on netease".into()))?;
        let mut get = Request::new("https://lyrics.paxsenix.org/netease/lyrics");
        get.params = pairs(&[("id", &song.id.to_string())]);
        get.headers = headers;
        let response: models::NeteaseLyrics =
            http::decode(&self.http.get(get, check)?.body, true, check)?;
        let mut text = response
            .lrc
            .filter(|line| !line.lyric.trim().is_empty())
            .ok_or_else(|| LyricsError::NotFound("no lyrics available on netease".into()))?
            .lyric;
        for (include, lines) in [
            (request.options.include_translation_netease, response.tlyric),
            (
                request.options.include_romanization_netease,
                response.romalrc,
            ),
        ] {
            if include
                && let Some(lines) = lines
                && !lines.lyric.trim().is_empty()
            {
                text.push_str("\n\n");
                text.push_str(&lines.lyric);
            }
        }
        from_text(&text, "Netease", "Netease")
            .map_err(|_| LyricsError::Other("netease returned empty lyrics".into()))
    }

    fn musixmatch_payload(
        &self,
        request: &SearchRequest,
        kind: &str,
        language: &str,
        check: &Check<'_>,
    ) -> Result<String, LyricsError> {
        if request.track.trim().is_empty() || request.artist.trim().is_empty() {
            return Err(LyricsError::NotFound("empty track or artist name".into()));
        }
        let mut get = Request::new("https://lyrics.paxsenix.org/musixmatch/lyrics");
        get.allowed = &[];
        get.params = pairs(&[
            ("t", &request.track),
            ("a", &request.artist),
            ("type", kind),
            ("format", "lrc"),
        ]);
        if request.duration > 0.0 {
            let rounded = request.duration.round();
            let duration = if rounded >= -(isize::MIN as f64) {
                isize::MIN
            } else {
                rounded as isize
            };
            get.params.insert("d".into(), duration.to_string());
        }
        if !language.trim().is_empty() {
            get.params.insert("l".into(), lowercase(language.trim()));
        }
        let response = self.http.get(get, check)?;
        let text = text_from_bytes(&response.body);
        let text = text.trim();
        if response.status != 200 {
            let kind = errors::detect_payload(text).map_or_else(
                || errors::http_status(response.status),
                |message| errors::classify_payload(response.status, &message),
            );
            return Err(LyricsError::classified(
                kind,
                format!("musixmatch proxy returned HTTP {}", response.status),
            ));
        }
        if let Ok(decoded) = decode_document::<Option<String>>(&response.body) {
            let decoded = decoded.unwrap_or_default();
            if decoded.trim().is_empty() {
                return Err(LyricsError::Other("empty musixmatch lyrics payload".into()));
            }
            return Ok(decoded.trim().into());
        }
        if let Some(message) = errors::detect_payload(text) {
            return Err(LyricsError::classified(
                errors::classify_payload(0, &message),
                message,
            ));
        }
        if !text.is_empty() && !text.starts_with('{') {
            return Ok(text.into());
        }
        Err(LyricsError::Other(
            "failed to decode musixmatch response".into(),
        ))
    }

    pub(super) fn musixmatch(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let language = lowercase(request.options.musixmatch_language.trim());
        if !language.is_empty() {
            match self.musixmatch_payload(request, "translate", &language, check) {
                Ok(text) => {
                    if let Ok(lyrics) =
                        from_text(&text, "Musixmatch", &format!("Musixmatch ({language})"))
                    {
                        return Ok(lyrics);
                    }
                }
                Err(error @ LyricsError::Cancelled(_)) => return Err(error),
                _ => {}
            }
        }
        from_text(
            &self.musixmatch_payload(request, "word", "", check)?,
            "Musixmatch",
            "Musixmatch",
        )
    }

    pub fn lyrics_plus(
        &self,
        request: &SearchRequest,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        if request.track.trim().is_empty() || request.artist.trim().is_empty() {
            return Err(LyricsError::Other(
                "lyricsplus: missing track or artist".into(),
            ));
        }
        let mut last = LyricsError::NotFound("lyricsplus: no lyrics found".into());
        for endpoint in [
            "https://lyricsplus.prjktla.workers.dev/v2/lyrics/get",
            "https://lyricsplus.binimum.org/v2/lyrics/get",
        ] {
            match self.lyrics_plus_server(endpoint, request, isrc, check) {
                Ok(lyrics) if lyrics.has_usable_text() => return Ok(lyrics),
                Err(error @ LyricsError::Cancelled(_)) => return Err(error),
                Err(error) => last = error,
                _ => {}
            }
        }
        Err(last)
    }

    fn lyrics_plus_server(
        &self,
        endpoint: &str,
        request: &SearchRequest,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let mut get = Request::new(endpoint);
        get.allowed = &[200, 404];
        get.params = pairs(&[("title", &request.track), ("artist", &request.artist)]);
        if request.duration > 0.0 {
            get.params
                .insert("duration".into(), format!("{:.3}", request.duration));
        }
        if !isrc.trim().is_empty() {
            get.params.insert("isrc".into(), isrc.trim().into());
        }
        let response = self.http.get(get, check)?;
        if response.status == 404 {
            if !isrc.trim().is_empty() {
                return self.lyrics_plus_server(endpoint, request, "", check);
            }
            return Err(LyricsError::NotFound("lyrics not found".into()));
        }
        let payload: payloads::KpoeResponse = http::decode(&response.body, true, check)?;
        if payload.lyrics.as_ref().is_none_or(Vec::is_empty) {
            return Err(LyricsError::Other("lyricsplus returned no lines".into()));
        }
        let text = payloads::format_kpoe(
            &payload,
            request.options.multi_person_word_by_word,
            request.options.apple_elrc_word_sync,
        );
        if text.trim().is_empty() {
            return Err(LyricsError::Other(
                "lyricsplus produced empty lyrics".into(),
            ));
        }
        Ok(LyricsResponse::from_text(&text, "LyricsPlus", "LyricsPlus"))
    }
}
