use super::{AudioMetadata, pair, truthy, utf8};
use crate::matching::{lowercase, uppercase};

pub(super) fn parse(data: &[u8], max_comment: usize) -> Vec<(String, String)> {
    let Some(length) = data.get(..4) else {
        return vec![];
    };
    let vendor = u32::from_le_bytes(length.try_into().unwrap()) as usize;
    let Some(end) = vendor.checked_add(8) else {
        return vec![];
    };
    let Some(count) = data.get(end - 4..end) else {
        return vec![];
    };
    let count = u32::from_le_bytes(count.try_into().unwrap());
    let mut offset = end;
    let mut items = Vec::new();
    let count = if max_comment == usize::MAX {
        count
    } else {
        count.min(100)
    };
    for _ in 0..count {
        let Some(length) = data.get(offset..offset.saturating_add(4)) else {
            break;
        };
        let length = u32::from_le_bytes(length.try_into().unwrap()) as usize;
        offset += 4;
        let Some(value) = data.get(offset..offset.saturating_add(length)) else {
            break;
        };
        offset += length;
        if length <= max_comment
            && let Some(index) = value.iter().position(|value| *value == b'=')
        {
            items.push((utf8(&value[..index]), utf8(&value[index + 1..])));
        }
    }
    items
}

fn joined<'a>(items: impl Iterator<Item = &'a str>) -> String {
    let mut seen = std::collections::BTreeSet::new();
    items
        .map(str::trim)
        .filter(|value| !value.is_empty() && seen.insert(lowercase(value)))
        .collect::<Vec<_>>()
        .join(", ")
}

pub(super) fn flac(metadata: &mut AudioMetadata, items: &[(String, String)]) {
    let all = |name: &'static str| {
        items
            .iter()
            .filter(move |(key, _)| key.len() == name.len() && uppercase(key) == name)
            .map(|(_, value)| value.as_str())
    };
    let get = |name| all(name).next().unwrap_or("").to_owned();
    metadata.title = get("TITLE");
    metadata.artist = joined(all("ARTIST"));
    metadata.album = get("ALBUM");
    metadata.album_artist = ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"]
        .into_iter()
        .map(|name| joined(all(name)))
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    metadata.date = get("DATE");
    if metadata.date.is_empty() {
        metadata.date = get("YEAR");
    }
    metadata.isrc = get("ISRC");
    metadata.lyrics = ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS"]
        .into_iter()
        .map(get)
        .find(|value| !value.trim().is_empty())
        .unwrap_or_default();
    for (names, target, total) in [
        (
            ["TRACKNUMBER", "TRACK"],
            &mut metadata.track_number,
            &mut metadata.total_tracks,
        ),
        (
            ["DISCNUMBER", "DISC"],
            &mut metadata.disc_number,
            &mut metadata.total_discs,
        ),
    ] {
        for (index, name) in names.into_iter().enumerate() {
            if index == 1 && *target != 0 {
                break;
            }
            let value = get(name);
            if !value.is_empty() {
                (*target, *total) = pair(&value);
            }
        }
    }
    metadata.genre = get("GENRE");
    metadata.label = ["ORGANIZATION", "LABEL", "PUBLISHER"]
        .into_iter()
        .map(get)
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    metadata.copyright = get("COPYRIGHT");
    metadata.composer = get("COMPOSER");
    metadata.comment = get("COMMENT");
    metadata.explicit = truthy(&get("ITUNESADVISORY"));
    metadata.album_type = get("RELEASETYPE");
    if metadata.album_type.is_empty() && truthy(&get("COMPILATION")) {
        metadata.album_type = "compilation".into();
    }
    metadata.upc = get("BARCODE");
    if metadata.upc.is_empty() {
        metadata.upc = get("UPC");
    }
    metadata.replay_gain_track_gain = get("REPLAYGAIN_TRACK_GAIN");
    metadata.replay_gain_track_peak = get("REPLAYGAIN_TRACK_PEAK");
    metadata.replay_gain_album_gain = get("REPLAYGAIN_ALBUM_GAIN");
    metadata.replay_gain_album_peak = get("REPLAYGAIN_ALBUM_PEAK");
}

pub(super) fn apply(metadata: &mut AudioMetadata, key: &str, value: &str, ape: bool) {
    let key = uppercase(if ape { key.trim() } else { key });
    let value = if ape { value.trim() } else { value };
    if ape && value.is_empty() {
        return;
    }
    match key.as_str() {
        "TITLE" => metadata.title = value.into(),
        "ARTIST" => metadata.artist = value.into(),
        "ALBUM" => metadata.album = value.into(),
        "ALBUMARTIST" | "ALBUM ARTIST" => metadata.album_artist = value.into(),
        "ALBUM_ARTIST" if !ape => metadata.album_artist = value.into(),
        "DATE" | "YEAR" => {
            if ape {
                if key == "YEAR" {
                    metadata.year = value.into();
                } else {
                    metadata.date = value.into();
                }
            } else {
                metadata.date = value.into();
                if value.len() >= 4 {
                    metadata.year = utf8(&value.as_bytes()[..4]);
                }
            }
        }
        "GENRE" => metadata.genre = value.into(),
        "TRACK" | "TRACKNUMBER" => (metadata.track_number, metadata.total_tracks) = pair(value),
        "DISC" | "DISCNUMBER" => (metadata.disc_number, metadata.total_discs) = pair(value),
        "ISRC" => metadata.isrc = value.into(),
        "COMPOSER" => metadata.composer = value.into(),
        "COMMENT" => metadata.comment = value.into(),
        "DESCRIPTION" if !ape => metadata.comment = value.into(),
        "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if metadata.lyrics.is_empty() => {
            metadata.lyrics = value.into()
        }
        "LABEL" | "PUBLISHER" => metadata.label = value.into(),
        "ORGANIZATION" if !ape => metadata.label = value.into(),
        "COPYRIGHT" => metadata.copyright = value.into(),
        "ITUNESADVISORY" => metadata.explicit = truthy(value),
        "RELEASETYPE" => metadata.album_type = value.into(),
        "BARCODE" | "UPC" => metadata.upc = value.into(),
        "COMPILATION" if truthy(value) && metadata.album_type.is_empty() => {
            metadata.album_type = "compilation".into()
        }
        "REPLAYGAIN_TRACK_GAIN" => metadata.replay_gain_track_gain = value.into(),
        "REPLAYGAIN_TRACK_PEAK" => metadata.replay_gain_track_peak = value.into(),
        "REPLAYGAIN_ALBUM_GAIN" => metadata.replay_gain_album_gain = value.into(),
        "REPLAYGAIN_ALBUM_PEAK" => metadata.replay_gain_album_peak = value.into(),
        "R128_TRACK_GAIN" | "R128_ALBUM_GAIN" if !ape => {
            let target = if key == "R128_TRACK_GAIN" {
                &mut metadata.replay_gain_track_gain
            } else {
                &mut metadata.replay_gain_album_gain
            };
            if target.is_empty()
                && let Ok(value) = value.trim().parse::<i16>()
            {
                *target = format!("{:.2} dB", f64::from(value) / 256.0 + 5.0);
            }
        }
        _ => {}
    }
}

pub(super) fn ape_key(key: &str) -> bool {
    matches!(
        uppercase(key.trim()).as_str(),
        "TITLE"
            | "ARTIST"
            | "ALBUM"
            | "ALBUMARTIST"
            | "ALBUM ARTIST"
            | "GENRE"
            | "YEAR"
            | "DATE"
            | "TRACK"
            | "TRACKNUMBER"
            | "DISC"
            | "DISCNUMBER"
            | "ISRC"
            | "LYRICS"
            | "UNSYNCEDLYRICS"
            | "SYNCEDLYRICS"
            | "LABEL"
            | "PUBLISHER"
            | "COPYRIGHT"
            | "COMPOSER"
            | "COMMENT"
            | "ITUNESADVISORY"
            | "RELEASETYPE"
            | "BARCODE"
            | "UPC"
            | "COMPILATION"
            | "REPLAYGAIN_TRACK_GAIN"
            | "REPLAYGAIN_TRACK_PEAK"
            | "REPLAYGAIN_ALBUM_GAIN"
            | "REPLAYGAIN_ALBUM_PEAK"
    )
}

pub(super) fn ogg(items: &[(String, String)]) -> AudioMetadata {
    let mut metadata = AudioMetadata::default();
    let mut artists = Vec::new();
    let mut album_artists = Vec::new();
    for (key, value) in items {
        match uppercase(key).as_str() {
            "ARTIST" => artists.push(value.as_str()),
            "ALBUMARTIST" | "ALBUM_ARTIST" | "ALBUM ARTIST" => album_artists.push(value.as_str()),
            _ => apply(&mut metadata, key, value, false),
        }
    }
    if !artists.is_empty() {
        metadata.artist = joined(artists.into_iter());
    }
    if !album_artists.is_empty() {
        metadata.album_artist = joined(album_artists.into_iter());
    }
    metadata
}
