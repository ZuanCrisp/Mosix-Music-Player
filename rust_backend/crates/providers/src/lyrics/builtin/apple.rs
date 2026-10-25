use super::*;
use crate::lyrics::http;
use regex::Regex;
use spotiflac_core::lyrics::payloads;
use std::sync::{LazyLock, MutexGuard, TryLockError};
use std::time::Duration;

static INDEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"/assets/index~[^"' <]+\.js"#).unwrap());
static TOKEN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+").unwrap());

impl BuiltinLyricsClient {
    fn lock_apple_token<'a>(
        &'a self,
        check: &Check<'_>,
    ) -> Result<MutexGuard<'a, String>, LyricsError> {
        loop {
            check().map_err(LyricsError::Cancelled)?;
            match self.apple_token.try_lock() {
                Ok(guard) => return Ok(guard),
                Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(25)),
                Err(TryLockError::Poisoned(_)) => {
                    return Err(LyricsError::Other("apple token cache poisoned".into()));
                }
            }
        }
    }

    fn apple_token(&self, check: &Check<'_>) -> Result<String, LyricsError> {
        let mut token = self.lock_apple_token(check)?;
        if !token.is_empty() {
            return Ok(token.clone());
        }
        let mut page = Request::new("https://beta.music.apple.com");
        page.headers = pairs(&[("User-Agent", http::BROWSER_UA)]);
        page.timeout = Duration::from_secs(20);
        let html = text_from_bytes(&self.http.get(page, check)?.body);
        let index = INDEX
            .find(&html)
            .ok_or_else(|| LyricsError::Other("apple music index script not found".into()))?;
        let url = format!("https://beta.music.apple.com{}", index.as_str());
        let mut script = Request::new(&url);
        script.headers = pairs(&[("User-Agent", http::BROWSER_UA)]);
        script.timeout = Duration::from_secs(20);
        let javascript = text_from_bytes(&self.http.get(script, check)?.body);
        let found = TOKEN
            .find(&javascript)
            .ok_or_else(|| LyricsError::Other("apple music token not found".into()))?;
        check().map_err(LyricsError::Cancelled)?;
        *token = found.as_str().into();
        Ok(token.clone())
    }

    fn apple_search(
        &self,
        token: &str,
        query: &str,
        check: &Check<'_>,
    ) -> Result<Option<models::AppleSearch>, LyricsError> {
        let mut get = Request::new("https://amp-api.music.apple.com/v1/catalog/us/search");
        get.timeout = Duration::from_secs(20);
        get.allowed = &[200, 401];
        get.params = pairs(&[
            ("term", query),
            ("types", "songs"),
            ("limit", "25"),
            ("l", "en-US"),
            ("platform", "web"),
            ("format[resources]", "map"),
            ("include[songs]", "artists"),
            ("extend", "artistUrl"),
        ]);
        get.headers = pairs(&[
            ("Authorization", &format!("Bearer {token}")),
            ("Origin", "https://music.apple.com"),
            ("Referer", "https://music.apple.com/"),
            (
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0",
            ),
            ("Accept", "application/json"),
            ("Accept-Language", "en-US,en;q=0.5"),
            ("x-apple-renewal", "true"),
        ]);
        let response = self.http.get(get, check)?;
        if response.status == 401 {
            return Ok(None);
        }
        http::decode(&response.body, true, check).map(Some)
    }

    pub(super) fn apple(
        &self,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        let query = format!("{} {}", request.track, request.artist);
        if query.trim().is_empty() {
            return Err(LyricsError::NotFound("empty search query".into()));
        }
        let token = self.apple_token(check)?;
        let mut search = self.apple_search(&token, query.trim(), check)?;
        if search.is_none() {
            // A delayed 401 must not discard a newer token obtained by another
            // lookup. Refresh remains coalesced by the token cache mutex.
            let mut cached = self.lock_apple_token(check)?;
            if *cached == token {
                cached.clear();
            }
            drop(cached);
            search = self.apple_search(&self.apple_token(check)?, query.trim(), check)?;
        }
        let search = search
            .ok_or_else(|| LyricsError::Other("apple music catalog search unauthorized".into()))?;
        let songs = search
            .results
            .songs
            .and_then(|songs| songs.data)
            .unwrap_or_default();
        let resources = search
            .resources
            .and_then(|resources| resources.songs)
            .unwrap_or_default();
        let results: Vec<_> = songs
            .iter()
            .filter_map(|song| {
                resources
                    .get(&song.id)
                    .map(|data| (&song.id, &data.attributes))
            })
            .collect();
        let selected = select(&results, request, |(_, song)| {
            let duration = song.duration_in_millis as f64 / 1000.0;
            (
                song.name.clone(),
                song.artist_name.clone(),
                duration,
                matches(&song.name, &song.artist_name, duration, request),
            )
        })
        .filter(|(id, _)| !id.trim().is_empty())
        .ok_or_else(|| LyricsError::NotFound("no songs found on apple music".into()))?;
        let mut get = Request::new("https://lyrics.paxsenix.org/apple-music/lyrics");
        get.timeout = Duration::from_secs(20);
        get.params = pairs(&[("id", selected.0.trim())]);
        let raw = text_from_bytes(&self.http.get(get, check)?.body);
        let raw = raw.trim();
        if raw.is_empty() {
            return Err(LyricsError::Other(
                "empty lyrics response from apple music".into(),
            ));
        }
        if let Some(message) = errors::detect_payload(raw) {
            return Err(LyricsError::classified(
                errors::classify_payload(0, &message),
                format!("apple music proxy returned non-lyric payload: {message}"),
            ));
        }
        let text = match payloads::format_apple(
            raw,
            request.options.multi_person_word_by_word,
            request.options.apple_elrc_word_sync,
        ) {
            Ok(text) => text,
            Err(error) if raw.starts_with(['{', '[']) => return Err(LyricsError::Other(error)),
            Err(_) => raw.into(),
        };
        let mut lyrics = from_text(&text, "Apple Music", "Apple Music")?;
        payloads::apple_supplements(raw, &mut lyrics);
        Ok(lyrics)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Resolver;
    impl TrackResolver for Resolver {
        fn deezer_id_from_spotify(&self, _: &str, _: &Check<'_>) -> Result<String, LyricsError> {
            unreachable!("token test must not resolve tracks")
        }
    }

    #[test]
    fn waiting_for_another_token_refresh_remains_cancellable() {
        let network = NetworkService::new().unwrap();
        let client = BuiltinLyricsClient::new(&network, "", Arc::new(Resolver));
        let _held = client.apple_token.lock().unwrap();
        let calls = AtomicUsize::new(0);
        let result = client.apple_token(&|| {
            if calls.fetch_add(1, Ordering::AcqRel) >= 2 {
                Err("cancel token waiter".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(
            result,
            Err(LyricsError::Cancelled("cancel token waiter".into()))
        );
        assert_eq!(calls.load(Ordering::Acquire), 3);
    }
}
