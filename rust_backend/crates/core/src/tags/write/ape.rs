use super::{Fields, MAX_TAG_BYTES, Section, bytes, edit_index, metadata_fields, seek};
use crate::matching::uppercase;
use crate::tags::{AudioMetadata, containers::ApeFooter};
use std::collections::BTreeSet;
use std::io::{Read, Seek, SeekFrom};

struct Item {
    key: Vec<u8>,
    value: Vec<u8>,
    flags: u32,
}

pub(super) fn edit(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Section, String> {
    let mut end = seek(source, SeekFrom::End(0))?;
    let mut start = end;
    let mut existing = None;
    for offset in [end.checked_sub(32), end.checked_sub(161).map(|_| end - 160)]
        .into_iter()
        .flatten()
    {
        check()?;
        let Some(footer) = ApeFooter::read(source, offset)? else {
            continue;
        };
        if start == end {
            let size = u64::from(footer.size) + if footer.flags & (1 << 31) != 0 { 32 } else { 0 };
            start = (offset + 32)
                .checked_sub(size)
                .ok_or("invalid APE tag size")?;
            if fields.len() == 4 && super::clears_replay_gain(fields) {
                // A legacy ID3v1 tag can follow the APE footer. Removing gain
                // must leave that unrelated metadata in place too.
                end = offset + 32;
            }
        }
        if existing.is_none()
            && let Ok(begin) = footer.items_start(offset)
        {
            let size = offset - begin;
            if size > MAX_TAG_BYTES as u64 {
                return Err("APE metadata exceeds 64 MiB".into());
            }
            seek(source, SeekFrom::Start(begin))?;
            let data = bytes(source, size as usize)?;
            existing = Some(parse_items(&data, footer.count));
        }
    }
    let metadata = metadata_fields(&AudioMetadata::default(), fields);
    let mut added = Vec::new();
    let mut remove = BTreeSet::new();
    for (field, key) in [
        ("title", "Title"),
        ("artist", "Artist"),
        ("album", "Album"),
        ("album_artist", "Album Artist"),
        ("genre", "Genre"),
        ("date", "Year"),
        ("isrc", "ISRC"),
        ("lyrics", "Lyrics"),
        ("label", "Label"),
        ("copyright", "Copyright"),
        ("composer", "Composer"),
        ("comment", "Comment"),
        ("explicit", "ITUNESADVISORY"),
        ("album_type", "RELEASETYPE"),
        ("upc", "BARCODE"),
        ("compilation", "COMPILATION"),
        ("replaygain_track_gain", "REPLAYGAIN_TRACK_GAIN"),
        ("replaygain_track_peak", "REPLAYGAIN_TRACK_PEAK"),
        ("replaygain_album_gain", "REPLAYGAIN_ALBUM_GAIN"),
        ("replaygain_album_peak", "REPLAYGAIN_ALBUM_PEAK"),
    ] {
        if fields.contains_key(field) {
            // Go's clear-date override names DATE; a newly emitted Year also
            // replaces YEAR, but clearing DATE alone leaves the old YEAR item.
            remove.insert(if field == "date" {
                "DATE".into()
            } else {
                uppercase(key)
            });
        }
        let value = &metadata[field];
        if !value.is_empty() {
            added.push(Item {
                key: key.as_bytes().to_vec(),
                value: value.as_bytes().to_vec(),
                flags: 0,
            });
        }
    }
    for (field, total, key) in [
        ("track_number", "track_total", "Track"),
        ("disc_number", "disc_total", "Disc"),
    ] {
        if fields.contains_key(field) {
            remove.insert(uppercase(key));
        }
        if fields.contains_key(field) || fields.contains_key(total) {
            remove.insert(format!("{}NUMBER", uppercase(key)));
        }
        let value = edit_index((0, 0), &metadata, field, total);
        if !value.is_empty() {
            added.push(Item {
                key: key.as_bytes().to_vec(),
                value: value.into_bytes(),
                flags: 0,
            });
        }
    }
    for (field, aliases) in [
        ("album_artist", &["ALBUMARTIST"][..]),
        ("label", &["PUBLISHER"][..]),
        ("lyrics", &["UNSYNCEDLYRICS", "SYNCEDLYRICS"][..]),
    ] {
        if fields.contains_key(field) {
            remove.extend(aliases.iter().map(|s| (*s).to_owned()));
        }
    }
    if fields
        .get("cover_path")
        .is_some_and(|path| !path.trim().is_empty())
    {
        remove.insert("COVER ART (FRONT)".into());
        if let Some(cover) = cover {
            let mut value = b"cover.jpg\0".to_vec();
            value.extend(cover);
            added.push(Item {
                key: b"Cover Art (Front)".to_vec(),
                value,
                flags: 2,
            });
        }
    }
    remove.extend(
        added
            .iter()
            .map(|item| uppercase(&String::from_utf8_lossy(&item.key))),
    );
    let mut items = existing.unwrap_or_default();
    items.retain(|item| !remove.contains(&uppercase(&String::from_utf8_lossy(&item.key))));
    items.extend(added);
    if items.is_empty() {
        if super::clears_replay_gain(fields) {
            return Ok(Section {
                start,
                end,
                data: Vec::new(),
            });
        }
        return Err("empty APE tag".into());
    }
    let mut body = Vec::new();
    let count = items.len() as u32;
    for item in items {
        check()?;
        if body.len() + 8 + item.key.len() + 1 + item.value.len() + 64 > MAX_TAG_BYTES {
            return Err("APE metadata exceeds 64 MiB".into());
        }
        body.extend((item.value.len() as u32).to_le_bytes());
        body.extend(item.flags.to_le_bytes());
        body.extend(item.key);
        body.push(0);
        body.extend(item.value);
    }
    let size = body.len() as u32 + 32;
    let header = |flags: u32| {
        let mut result = b"APETAGEX".to_vec();
        for value in [2000_u32, size, count, flags, 0, 0] {
            result.extend(value.to_le_bytes());
        }
        result
    };
    let mut data = header(0xa000_0000);
    data.extend(body);
    data.extend(header(0x8000_0000));
    Ok(Section { start, end, data })
}

fn parse_items(data: &[u8], count: u32) -> Vec<Item> {
    let mut items = Vec::new();
    let mut position = 0;
    for _ in 0..count {
        let Some(header) = data.get(position..position + 8) else {
            break;
        };
        let size = u32::from_le_bytes(header[..4].try_into().unwrap()) as usize;
        let flags = u32::from_le_bytes(header[4..].try_into().unwrap());
        position += 8;
        let Some(key_size) = data[position..].iter().position(|byte| *byte == 0) else {
            break;
        };
        let key = data[position..position + key_size].to_vec();
        position += key_size + 1;
        let Some(value) = data.get(position..position.saturating_add(size)) else {
            break;
        };
        position += size;
        items.push(Item {
            key,
            value: value.to_vec(),
            flags,
        });
    }
    items
}
