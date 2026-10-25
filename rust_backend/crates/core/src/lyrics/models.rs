//! Typed built-in search schemas, retaining Go field folding and null behavior.

use super::json::go_deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub struct Artist {
    pub name: String,
}
go_deserialize!(Artist { "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct SpotifySong {
    pub track_id: String,
    pub name: String,
    pub artist_name: String,
    pub duration: String,
}
go_deserialize!(SpotifySong { "trackid" => track_id, "name" => name, "artistname" => artist_name, "duration" => duration, });

#[derive(Clone, Debug, Default)]
pub struct YouTubeSong {
    pub video_id: String,
    pub title: String,
    pub author: String,
    pub duration: String,
}
go_deserialize!(YouTubeSong { "videoid" => video_id, "title" => title, "author" => author, "duration" => duration, });

#[derive(Clone, Debug, Default)]
pub struct NeteaseSong {
    pub name: String,
    pub id: i64,
    pub artists: Option<Vec<Artist>>,
}
go_deserialize!(NeteaseSong { "name" => name, "id" => id, "artists" => artists, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseResults {
    pub songs: Option<Vec<NeteaseSong>>,
    pub song_count: isize,
}
go_deserialize!(NeteaseResults { "songs" => songs, "songcount" => song_count, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseSearch {
    pub result: NeteaseResults,
    pub code: isize,
    pub message: String,
    pub msg: String,
}
go_deserialize!(NeteaseSearch { "result" => result, "code" => code, "message" => message, "msg" => msg, });
#[derive(Clone, Debug, Default)]
pub struct LyricField {
    pub lyric: String,
}
go_deserialize!(LyricField { "lyric" => lyric, });
#[derive(Clone, Debug, Default)]
pub struct NeteaseLyrics {
    pub lrc: Option<LyricField>,
    pub tlyric: Option<LyricField>,
    pub romalrc: Option<LyricField>,
    pub code: isize,
}
go_deserialize!(NeteaseLyrics { "lrc" => lrc, "tlyric" => tlyric, "romalrc" => romalrc, "code" => code, });

#[derive(Clone, Debug, Default)]
pub struct AppleSongId {
    pub id: String,
}
go_deserialize!(AppleSongId { "id" => id, });
#[derive(Clone, Debug, Default)]
pub struct AppleSongs {
    pub data: Option<Vec<AppleSongId>>,
}
go_deserialize!(AppleSongs { "data" => data, });
#[derive(Clone, Debug, Default)]
pub struct AppleResults {
    pub songs: Option<AppleSongs>,
}
go_deserialize!(AppleResults { "songs" => songs, });
#[derive(Clone, Debug, Default)]
pub struct AppleAttributes {
    pub name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration_in_millis: isize,
}
go_deserialize!(AppleAttributes { "name" => name, "artistname" => artist_name, "albumname" => album_name, "durationinmillis" => duration_in_millis, });
#[derive(Clone, Debug, Default)]
pub struct AppleSong {
    pub attributes: AppleAttributes,
}
go_deserialize!(AppleSong { "attributes" => attributes, });
#[derive(Clone, Debug, Default)]
pub struct AppleResources {
    pub songs: Option<BTreeMap<String, AppleSong>>,
}
go_deserialize!(AppleResources { "songs" => songs, });
#[derive(Clone, Debug, Default)]
pub struct AppleSearch {
    pub results: AppleResults,
    pub resources: Option<AppleResources>,
}
go_deserialize!(AppleSearch { "results" => results, "resources" => resources, });

#[derive(Clone, Debug, Default)]
pub struct QqSong {
    pub mid: String,
    pub id: i64,
    pub name: String,
    pub interval: isize,
    pub singer: Option<Vec<Artist>>,
}
go_deserialize!(QqSong { "mid" => mid, "id" => id, "name" => name, "interval" => interval, "singer" => singer, });
#[derive(Clone, Debug, Default)]
pub struct QqSongs {
    pub list: Option<Vec<QqSong>>,
}
go_deserialize!(QqSongs { "list" => list, });
#[derive(Clone, Debug, Default)]
pub struct QqData {
    pub song: QqSongs,
}
go_deserialize!(QqData { "song" => song, });
#[derive(Clone, Debug, Default)]
pub struct QqSearch {
    pub code: isize,
    pub data: QqData,
}
go_deserialize!(QqSearch { "code" => code, "data" => data, });
#[derive(Clone, Debug, Default)]
pub struct QqLyrics {
    pub retcode: isize,
    pub code: isize,
    pub lyric: String,
}
go_deserialize!(QqLyrics { "retcode" => retcode, "code" => code, "lyric" => lyric, });

#[derive(Clone, Debug, Default)]
pub struct KugouSong {
    pub id: String,
    pub accesskey: String,
    pub song: String,
    pub singer: String,
    pub duration: f64,
}
go_deserialize!(KugouSong { "id" => id, "accesskey" => accesskey, "song" => song, "singer" => singer, "duration" => duration, });
#[derive(Clone, Debug, Default)]
pub struct KugouSearch {
    pub status: isize,
    pub errcode: isize,
    pub errmsg: String,
    pub candidates: Option<Vec<KugouSong>>,
}
go_deserialize!(KugouSearch { "status" => status, "errcode" => errcode, "errmsg" => errmsg, "candidates" => candidates, });
#[derive(Clone, Debug, Default)]
pub struct KugouLyrics {
    pub status: isize,
    pub error_code: isize,
    pub info: String,
    pub content: String,
}
go_deserialize!(KugouLyrics { "status" => status, "error_code" => error_code, "info" => info, "content" => content, });

#[derive(Clone, Debug, Default)]
pub struct GeniusSong {
    pub title: String,
    pub artist_names: String,
    pub primary_artist_names: String,
    pub url: String,
}
go_deserialize!(GeniusSong { "title" => title, "artist_names" => artist_names, "primary_artist_names" => primary_artist_names, "url" => url, });
#[derive(Clone, Debug, Default)]
pub struct GeniusHit {
    pub kind: String,
    pub result: GeniusSong,
}
go_deserialize!(GeniusHit { "type" => kind, "result" => result, });
#[derive(Clone, Debug, Default)]
pub struct GeniusSection {
    pub hits: Option<Vec<GeniusHit>>,
}
go_deserialize!(GeniusSection { "hits" => hits, });
#[derive(Clone, Debug, Default)]
pub struct GeniusResults {
    pub sections: Option<Vec<GeniusSection>>,
}
go_deserialize!(GeniusResults { "sections" => sections, });
#[derive(Clone, Debug, Default)]
pub struct GeniusSearch {
    pub response: GeniusResults,
}
go_deserialize!(GeniusSearch { "response" => response, });
