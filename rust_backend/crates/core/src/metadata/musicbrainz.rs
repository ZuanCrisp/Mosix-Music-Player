//! Recording metadata and formatting used by the native MusicBrainz getters.

mod case_data;
mod casing;

use crate::lyrics::json::go_deserialize;
use crate::matching::lowercase;
use std::collections::BTreeSet;

#[derive(Clone, Debug, Default)]
pub struct Tag {
    pub count: isize,
    pub name: String,
}
go_deserialize!(Tag { "count" => count, "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct ArtistCredit {
    pub name: String,
    pub joinphrase: String,
}
go_deserialize!(ArtistCredit { "name" => name, "joinphrase" => joinphrase, });

#[derive(Clone, Debug, Default)]
pub struct Release {
    pub title: String,
    pub artist_credit: Option<Vec<ArtistCredit>>,
}
go_deserialize!(Release { "title" => title, "artist-credit" => artist_credit, });

#[derive(Clone, Debug, Default)]
pub struct Recording {
    pub tags: Option<Vec<Tag>>,
    pub releases: Option<Vec<Release>>,
}
go_deserialize!(Recording { "tags" => tags, "releases" => releases, });

#[derive(Clone, Debug, Default)]
pub struct Response {
    pub recordings: Option<Vec<Recording>>,
}
go_deserialize!(Response { "recordings" => recordings, });

pub fn genre(tags: &[Tag]) -> String {
    let mut seen = BTreeSet::new();
    let mut max_count = -1;
    let mut best = String::new();
    for tag in tags {
        let name = tag.name.trim();
        if name.is_empty() || !seen.insert(lowercase(name)) {
            continue;
        }
        if tag.count > max_count {
            max_count = tag.count;
            best = casing::title(name);
        }
    }
    best
}

pub fn artist_credit(credits: &[ArtistCredit]) -> String {
    let mut output = String::new();
    for credit in credits {
        let name = credit.name.trim();
        if !name.is_empty() {
            output.push_str(name);
            output.push_str(&credit.joinphrase);
        }
    }
    output.trim().into()
}

pub fn album_artist(releases: &[Release], album_name: &str) -> String {
    let album = lowercase(album_name.trim());
    if !album.is_empty() {
        for release in releases {
            if lowercase(release.title.trim()) == album {
                let artist = artist_credit(release.artist_credit.as_deref().unwrap_or_default());
                if !artist.is_empty() {
                    return artist;
                }
            }
        }
    }
    releases
        .iter()
        .map(|release| artist_credit(release.artist_credit.as_deref().unwrap_or_default()))
        .find(|artist| !artist.is_empty())
        .unwrap_or_default()
}

impl Response {
    pub fn genre(&self, isrc: &str) -> Result<String, String> {
        let first = self
            .recordings
            .as_deref()
            .unwrap_or_default()
            .first()
            .ok_or_else(|| format!("no recordings found for ISRC: {isrc}"))?;
        let value = genre(first.tags.as_deref().unwrap_or_default());
        if value.is_empty() {
            Err(format!("no MusicBrainz genre tags found for ISRC: {isrc}"))
        } else {
            Ok(value)
        }
    }

    pub fn album_artist(&self, isrc: &str, album: &str) -> Result<String, String> {
        self.recordings
            .as_deref()
            .unwrap_or_default()
            .iter()
            .map(|recording| album_artist(recording.releases.as_deref().unwrap_or_default(), album))
            .find(|artist| !artist.is_empty())
            .ok_or_else(|| format!("no MusicBrainz album artist found for ISRC: {isrc}"))
    }
}
