use super::{LyricsLine, LyricsResponse, lrc, matching};
use serde::Serialize;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LrcLibResponse {
    pub id: isize,
    pub name: String,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration: f64,
    pub instrumental: bool,
    pub plain_lyrics: String,
    pub synced_lyrics: String,
}

super::json::go_deserialize!(LrcLibResponse {
    "id" => id, "name" => name, "trackname" => track_name,
    "artistname" => artist_name, "albumname" => album_name, "duration" => duration,
    "instrumental" => instrumental, "plainlyrics" => plain_lyrics,
    "syncedlyrics" => synced_lyrics,
});

impl LrcLibResponse {
    pub fn track_name(&self) -> &str {
        if self.track_name.trim().is_empty() {
            self.name.trim()
        } else {
            self.track_name.trim()
        }
    }

    pub fn matches(&self, query: &str, track: &str, artist: &str, duration: f64) -> bool {
        if !matching::duration_matches(self.duration, duration) {
            return false;
        }
        if !track.trim().is_empty() || !artist.trim().is_empty() {
            return matching::titles_match(self.track_name(), track, false)
                && matching::artists_match(&self.artist_name, artist);
        }
        let query = matching::normalize_loose_artist(query);
        let track = matching::normalize_loose_artist(&matching::simplify_track(self.track_name()));
        let artist = matching::normalize_loose_artist(&matching::primary_artist(&self.artist_name));
        matching::contains_words(&query, &track) && matching::contains_words(&query, &artist)
    }

    pub fn into_lyrics(&self) -> LyricsResponse {
        let mut result = LyricsResponse {
            instrumental: self.instrumental,
            plain_lyrics: self.plain_lyrics.clone(),
            provider: "LRCLIB".into(),
            ..LyricsResponse::default()
        };
        if !self.synced_lyrics.is_empty() {
            result.lines = lrc::parse_synced(&self.synced_lyrics);
            result.sync_type = "LINE_SYNCED".into();
        } else if !self.plain_lyrics.is_empty() {
            result.sync_type = "UNSYNCED".into();
            let lines: Vec<_> = self
                .plain_lyrics
                .split('\n')
                .filter(|line| !line.trim().is_empty())
                .map(|line| LyricsLine {
                    words: line.into(),
                    ..LyricsLine::default()
                })
                .collect();
            result.lines = (!lines.is_empty()).then_some(lines);
        }
        result.normalize_timing();
        result
    }
}

pub fn select<'a>(
    results: &'a [LrcLibResponse],
    query: &str,
    track: &str,
    artist: &str,
    duration: f64,
) -> Option<&'a LrcLibResponse> {
    let mut synced = None;
    let mut plain = None;
    for result in results {
        if !result.matches(query, track, artist, duration) {
            continue;
        }
        if !result.synced_lyrics.is_empty() && synced.is_none() {
            synced = Some(result);
        } else if !result.plain_lyrics.is_empty() && plain.is_none() {
            plain = Some(result);
        }
    }
    synced.or(plain)
}
