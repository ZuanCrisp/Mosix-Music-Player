//! Typed built-in search schemas, retaining Go field folding and null behavior.

use crate::json::lenient_deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub struct Artist {
    pub name: String,
}
lenient_deserialize!(Artist { "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct SpotifySong {
    pub track_id: String,
    pub name: String,
    pub artist_name: String,
    pub duration: String,
}
lenient_deserialize!(SpotifySong { "trackid" => track_id, "name" => name, "artistname" => artist_name, "duration" => duration, });

#[derive(Clone, Debug, Default)]
pub struct YouTubeSong {
    pub video_id: String,
    pub title: String,
    pub author: String,
    pub duration: String,
}
lenient_deserialize!(YouTubeSong { "videoid" => video_id, "title" => title, "author" => author, "duration" => duration, });

#[derive(Clone, Debug, Default)]
pub struct NeteaseSong {
    pub name: String,
    pub id: i64,
    pub artists: Option<Vec<Artist>>,
}
lenient_deserialize!(NeteaseSong { "name" => name, "id" => id, "artists" => artists, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseResults {
    pub songs: Option<Vec<NeteaseSong>>,
    pub song_count: isize,
}
lenient_deserialize!(NeteaseResults { "songs" => songs, "songcount" => song_count, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseSearch {
    pub result: NeteaseResults,
    pub code: isize,
    pub message: String,
    pub msg: String,
}
lenient_deserialize!(NeteaseSearch { "result" => result, "code" => code, "message" => message, "msg" => msg, });
#[derive(Clone, Debug, Default)]
pub struct LyricField {
    pub lyric: String,
}
lenient_deserialize!(LyricField { "lyric" => lyric, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseLyrics {
    pub lrc: Option<LyricField>,
    pub tlyric: Option<LyricField>,
    pub romalrc: Option<LyricField>,
    pub code: isize,
}
lenient_deserialize!(NeteaseLyrics { "lrc" => lrc, "tlyric" => tlyric, "romalrc" => romalrc, "code" => code, });

#[derive(Clone, Debug, Default)]
pub struct AppleSongId {
    pub id: String,
}
lenient_deserialize!(AppleSongId { "id" => id, });
#[derive(Clone, Debug, Default)]
pub struct AppleSongs {
    pub data: Option<Vec<AppleSongId>>,
}
lenient_deserialize!(AppleSongs { "data" => data, });
#[derive(Clone, Debug, Default)]
pub struct AppleResults {
    pub songs: Option<AppleSongs>,
}
lenient_deserialize!(AppleResults { "songs" => songs, });
#[derive(Clone, Debug, Default)]
pub struct AppleAttributes {
    pub name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration_in_millis: isize,
}
lenient_deserialize!(AppleAttributes { "name" => name, "artistname" => artist_name, "albumname" => album_name, "durationinmillis" => duration_in_millis, });
#[derive(Clone, Debug, Default)]
pub struct AppleSong {
    pub attributes: AppleAttributes,
}
lenient_deserialize!(AppleSong { "attributes" => attributes, });
#[derive(Clone, Debug, Default)]
pub struct AppleResources {
    pub songs: Option<BTreeMap<String, AppleSong>>,
}
lenient_deserialize!(AppleResources { "songs" => songs, });
#[derive(Clone, Debug, Default)]
pub struct AppleSearch {
    pub results: AppleResults,
    pub resources: Option<AppleResources>,
}
lenient_deserialize!(AppleSearch { "results" => results, "resources" => resources, });

#[derive(Clone, Debug, Default)]
pub struct QqSong {
    pub mid: String,
    pub id: i64,
    pub name: String,
    pub interval: isize,
    pub singer: Option<Vec<Artist>>,
}
lenient_deserialize!(QqSong { "mid" => mid, "id" => id, "name" => name, "interval" => interval, "singer" => singer, });
#[derive(Clone, Debug, Default)]
pub struct QqSongDetail {
    pub code: isize,
    pub data: Option<Vec<QqSong>>,
}
lenient_deserialize!(QqSongDetail { "code" => code, "data" => data, });
/// Search suggestions carry IDs as strings and singers joined by `/`.
#[derive(Clone, Debug, Default)]
pub struct QqSuggestion {
    pub id: String,
    pub mid: String,
    pub name: String,
    pub singer: String,
}
lenient_deserialize!(QqSuggestion { "id" => id, "mid" => mid, "name" => name, "singer" => singer, });
#[derive(Clone, Debug, Default)]
pub struct QqSuggestedSongs {
    pub itemlist: Option<Vec<QqSuggestion>>,
}
lenient_deserialize!(QqSuggestedSongs { "itemlist" => itemlist, });
#[derive(Clone, Debug, Default)]
pub struct QqSuggestionData {
    pub song: QqSuggestedSongs,
}
lenient_deserialize!(QqSuggestionData { "song" => song, });
#[derive(Clone, Debug, Default)]
pub struct QqSearch {
    pub code: isize,
    pub data: QqSuggestionData,
}
lenient_deserialize!(QqSearch { "code" => code, "data" => data, });
#[derive(Clone, Debug, Default)]
pub struct QqLyrics {
    pub retcode: isize,
    pub code: isize,
    pub lyric: String,
}
lenient_deserialize!(QqLyrics { "retcode" => retcode, "code" => code, "lyric" => lyric, });

#[derive(Clone, Debug, Default)]
pub struct KugouSong {
    pub id: String,
    pub accesskey: String,
    pub song: String,
    pub singer: String,
    pub duration: f64,
}
lenient_deserialize!(KugouSong { "id" => id, "accesskey" => accesskey, "song" => song, "singer" => singer, "duration" => duration, });
#[derive(Clone, Debug, Default)]
pub struct KugouSearch {
    pub status: isize,
    pub errcode: isize,
    pub errmsg: String,
    pub candidates: Option<Vec<KugouSong>>,
}
lenient_deserialize!(KugouSearch { "status" => status, "errcode" => errcode, "errmsg" => errmsg, "candidates" => candidates, });
#[derive(Clone, Debug, Default)]
pub struct KugouLyrics {
    pub status: isize,
    pub error_code: isize,
    pub info: String,
    pub content: String,
}
lenient_deserialize!(KugouLyrics { "status" => status, "error_code" => error_code, "info" => info, "content" => content, });

#[derive(Clone, Debug, Default)]
pub struct GeniusSong {
    pub title: String,
    pub artist_names: String,
    pub primary_artist_names: String,
    pub url: String,
}
lenient_deserialize!(GeniusSong { "title" => title, "artist_names" => artist_names, "primary_artist_names" => primary_artist_names, "url" => url, });
#[derive(Clone, Debug, Default)]
pub struct GeniusHit {
    pub kind: String,
    pub result: GeniusSong,
}
lenient_deserialize!(GeniusHit { "type" => kind, "result" => result, });
#[derive(Clone, Debug, Default)]
pub struct GeniusSection {
    pub hits: Option<Vec<GeniusHit>>,
}
lenient_deserialize!(GeniusSection { "hits" => hits, });
#[derive(Clone, Debug, Default)]
pub struct GeniusResults {
    pub sections: Option<Vec<GeniusSection>>,
}
lenient_deserialize!(GeniusResults { "sections" => sections, });
#[derive(Clone, Debug, Default)]
pub struct GeniusSearch {
    pub response: GeniusResults,
}
lenient_deserialize!(GeniusSearch { "response" => response, });
