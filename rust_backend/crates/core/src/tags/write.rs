//! Streaming metadata rewrites. The native owner supplies a separate staged
//! output and publishes it only after this operation succeeds and is synced.

mod ape;
mod id3;
mod mp4;
mod ogg;
mod riff;

pub(super) use id3::cover as embedded_cover;

use super::{CheckedReader, bytes, exact, pair, seek};
use crate::matching::{lowercase, uppercase};
use regex::Regex;
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufReader, Cursor, Read, Seek, SeekFrom, Write};
use std::sync::LazyLock;

type Fields = BTreeMap<String, String>;
const MAX_TAG_BYTES: usize = 64 * 1024 * 1024;

fn clears_replay_gain(fields: &Fields) -> bool {
    [
        "replaygain_track_gain",
        "replaygain_track_peak",
        "replaygain_album_gain",
        "replaygain_album_peak",
    ]
    .iter()
    .all(|key| {
        fields
            .get(*key)
            .is_some_and(|value| value.trim().is_empty())
    })
}

struct Section {
    start: u64,
    end: u64,
    data: Vec<u8>,
}

pub fn rewrite_audio_tags(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    format: &str,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    check()?;
    validate_fields(fields)?;
    let fields = &*artist_mode_fields(fields);
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    seek(&mut source, SeekFrom::Start(0))?;
    if matches!(format, "wav" | "aiff" | "aif" | "aifc") {
        let sections = riff::edit(&mut source, format != "wav", fields, cover, check)?;
        return write_sections(&mut source, output, sections, check);
    }
    let cover = cover.filter(|data| !data.is_empty());
    if matches!(format, "ogg" | "opus") {
        return ogg::rewrite(&mut source, output, fields, cover, check);
    }
    if matches!(format, "ape" | "wv" | "mpc") {
        let section = ape::edit(&mut source, fields, cover, check)?;
        return write_sections(&mut source, output, vec![section], check);
    }
    if matches!(format, "m4a" | "mp4" | "m4b") {
        let sections = mp4::edit(&mut source, fields, cover, check)?;
        return write_sections(&mut source, output, sections, check);
    }
    let (head, audio_start) = match format {
        "flac" => flac_header(&mut source, fields, cover, None, check)?,
        "mp3" => id3::header(&mut source, fields, cover, check)?,
        _ => return Err(format!("unsupported tag writer: {format}")),
    };
    write_sections(
        &mut source,
        output,
        vec![Section {
            start: 0,
            end: audio_start,
            data: head,
        }],
        check,
    )
}

/// Edit FLAC tags, leaving output untouched when the complete metadata header
/// is already identical. The native owner can then discard its staging file.
pub fn rewrite_flac_tags_if_changed(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    validate_fields(fields)?;
    let fields = &*artist_mode_fields(fields);
    // Read only metadata and the frame sync needed for validation. A buffered
    // reader here would also pull audio into memory on the no-op path.
    let mut source = CheckedReader {
        reader: source,
        check,
    };
    seek(&mut source, SeekFrom::Start(0))?;
    let (data, end) = flac_header(
        &mut source,
        fields,
        cover.filter(|bytes| !bytes.is_empty()),
        None,
        check,
    )?;
    if data.len() as u64 == end {
        seek(&mut source, SeekFrom::Start(0))?;
        let mut buffer = [0; 65536];
        let mut unchanged = true;
        for expected in data.chunks(buffer.len()) {
            exact(&mut source, &mut buffer[..expected.len()])?;
            if buffer[..expected.len()] != *expected {
                unchanged = false;
                break;
            }
        }
        check()?;
        if unchanged {
            return Ok(false);
        }
    }
    write_sections(
        &mut source,
        output,
        vec![Section {
            start: 0,
            end,
            data,
        }],
        check,
    )?;
    Ok(true)
}

/// Embed canonical Vorbis keys without clearing empty values or removing
/// legacy aliases. This is the enrichment contract, distinct from the editor.
pub fn embed_flac_metadata(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    artist_tag_mode: &str,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    check()?;
    validate_fields(fields)?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    seek(&mut source, SeekFrom::Start(0))?;
    let (data, end) = flac_header(
        &mut source,
        fields,
        cover.filter(|data| !data.is_empty()),
        Some(artist_tag_mode),
        check,
    )?;
    write_sections(
        &mut source,
        output,
        vec![Section {
            start: 0,
            end,
            data,
        }],
        check,
    )
}

fn validate_fields(fields: &Fields) -> Result<(), String> {
    if fields
        .iter()
        .try_fold(0usize, |total, (key, value)| {
            total.checked_add(key.len())?.checked_add(value.len())
        })
        .is_none_or(|length| length > MAX_TAG_BYTES)
    {
        return Err("tag edit fields exceed 64 MiB".into());
    }
    Ok(())
}

/// Rewrite only existing M4A freeform tags. False means a no-op and no output
/// was written, so the native owner can discard its staging file immediately.
pub fn rewrite_m4a_freeform(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    replay_gain_only: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    validate_fields(fields)?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::edit_freeform(&mut source, fields, replay_gain_only, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

/// Normalize an AC-4 container and lazily open its original configuration source.
pub fn rewrite_ac4_config<R: Read + Seek>(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    reference: impl FnOnce() -> Result<R, String>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::ac4::config(&mut source, reference, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

/// Replace AC-4 metadata; false means no output, and the cover is read only for AC-4.
pub fn rewrite_ac4_metadata(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    metadata_json: &str,
    cover: impl FnOnce() -> Result<Option<Vec<u8>>, String>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::ac4::metadata(&mut source, metadata_json, cover, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

fn write_optional_sections(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    sections: Vec<Section>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    if sections.is_empty() {
        check()?;
        return Ok(false);
    }
    write_sections(source, output, sections, check)?;
    Ok(true)
}

fn write_sections(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    mut sections: Vec<Section>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    sections.sort_by_key(|section| section.start);
    let mut position = 0;
    for section in &sections {
        if section.start < position || section.end < section.start {
            return Err("overlapping or invalid file sections".into());
        }
        position = section.end;
    }
    seek(source, SeekFrom::Start(0))?;
    position = 0;
    for section in sections {
        copy(source, output, Some(section.start - position), check)?;
        for chunk in section.data.chunks(65536) {
            check()?;
            output.write_all(chunk).map_err(|error| error.to_string())?;
        }
        seek(source, SeekFrom::Start(section.end))?;
        position = section.end;
    }
    copy(source, output, None, check)
}

fn copy(
    source: &mut impl Read,
    output: &mut impl Write,
    mut remaining: Option<u64>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    let mut buffer = [0; 65536];
    loop {
        check()?;
        let limit = remaining.map_or(buffer.len(), |n| n.min(buffer.len() as u64) as usize);
        if limit == 0 {
            break;
        }
        let count = source
            .read(&mut buffer[..limit])
            .map_err(|error| error.to_string())?;
        if count == 0 {
            if remaining.is_some() {
                return Err("unexpected EOF while copying audio".into());
            }
            break;
        }
        output
            .write_all(&buffer[..count])
            .map_err(|error| error.to_string())?;
        remaining = remaining.map(|n| n - count as u64);
    }
    check()
}

fn flac_header(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    embed_mode: Option<&str>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(Vec<u8>, u64), String> {
    if bytes(source, 4)? != b"fLaC" {
        return Err("fLaC head incorrect".into());
    }
    let mut blocks = Vec::new();
    let mut total = 0;
    loop {
        check()?;
        if blocks.len() >= 65536 {
            return Err("FLAC metadata block count exceeds 65536".into());
        }
        let h = bytes(source, 4)?;
        let length = u32::from_be_bytes([0, h[1], h[2], h[3]]) as usize;
        total += length + 4;
        if total > MAX_TAG_BYTES {
            return Err("FLAC metadata exceeds 64 MiB".into());
        }
        let kind = h[0] & 0x7f;
        let data = if kind == 6 && cover.is_some() {
            // Replacement artwork discards every old picture. Still read its
            // complete payload to retain truncation checks without retaining it.
            discard_bytes(source, length, check)?;
            Vec::new()
        } else {
            bytes(source, length)?
        };
        blocks.push((kind, data));
        if h[0] & 0x80 != 0 {
            break;
        }
    }
    let audio_start = seek(source, SeekFrom::Current(0))?;
    let sync = bytes(source, 2)?;
    if sync[0] != 0xff || sync[1] >> 2 != 0x3e {
        return Err("frames do not begin with sync code".into());
    }
    let index = blocks.iter().position(|(kind, _)| *kind == 4);
    let (vendor, mut comments) = if let Some(index) = index {
        parse_comments(&blocks[index].1)?
    } else {
        (b"SpotiFLAC".to_vec(), Vec::new())
    };
    if let Some(mode) = embed_mode {
        for (key, value) in fields.iter().filter(|(_, value)| !value.is_empty()) {
            if matches!(key.as_str(), "ARTIST" | "ALBUMARTIST") {
                let values = if mode.trim().eq_ignore_ascii_case("split_vorbis") {
                    split_artists(value)
                } else if primary_artist_mode(mode) {
                    vec![primary_artist(value)]
                } else {
                    vec![value.clone()]
                };
                if !values.is_empty() {
                    set_comment(&mut comments, key, "");
                    for value in values.iter().filter(|value| !value.trim().is_empty()) {
                        comments.push(format!("{key}={value}").into_bytes());
                    }
                }
            } else {
                set_comment(&mut comments, key, value);
            }
        }
    } else {
        edit_comments(&mut comments, fields);
    }
    let mut data = Vec::new();
    put_string(&mut data, &vendor);
    data.extend((comments.len() as u32).to_le_bytes());
    for comment in comments {
        put_string(&mut data, &comment);
    }
    if let Some(index) = index {
        blocks[index].1 = data;
    } else {
        blocks.push((4, data));
    }
    if let Some(cover) = cover {
        blocks.retain(|(kind, _)| *kind != 6);
        if let Some(picture) = picture(cover, check)? {
            blocks.push((6, picture));
        }
    }
    let mut head = b"fLaC".to_vec();
    let count = blocks.len();
    for (index, (kind, data)) in blocks.into_iter().enumerate() {
        if head.len() + data.len() + 4 > MAX_TAG_BYTES {
            return Err("FLAC metadata exceeds 64 MiB".into());
        }
        if data.len() > 0xff_ffff {
            return Err("FLAC metadata block exceeds 24-bit size".into());
        }
        head.push(kind | if index + 1 == count { 0x80 } else { 0 });
        head.extend(&(data.len() as u32).to_be_bytes()[1..]);
        head.extend(data);
    }
    Ok((head, audio_start))
}

fn discard_bytes(
    source: &mut impl Read,
    length: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    let mut buffer = [0; 65536];
    let mut offset = 0;
    while offset < length {
        check()?;
        let count = source
            .read(&mut buffer[..(length - offset).min(65536)])
            .map_err(|error| error.to_string())?;
        if count == 0 {
            return Err(if offset == 0 { "EOF" } else { "unexpected EOF" }.into());
        }
        offset += count;
    }
    Ok(())
}

fn parse_comments(data: &[u8]) -> Result<(Vec<u8>, Vec<Vec<u8>>), String> {
    fn string(reader: &mut Cursor<&[u8]>) -> Result<Vec<u8>, String> {
        let mut length = [0; 4];
        exact(reader, &mut length)?;
        let length = u32::from_le_bytes(length) as usize;
        if length
            > reader
                .get_ref()
                .len()
                .saturating_sub(reader.position() as usize)
        {
            return Err("truncated Vorbis comment".into());
        }
        bytes(reader, length)
    }
    let mut reader = Cursor::new(data);
    let vendor = string(&mut reader)?;
    let mut count = [0; 4];
    exact(&mut reader, &mut count)?;
    let mut comments = Vec::new();
    for _ in 0..u32::from_le_bytes(count) {
        comments.push(string(&mut reader)?);
    }
    Ok((vendor, comments))
}

fn put_string(output: &mut Vec<u8>, data: &[u8]) {
    output.extend((data.len() as u32).to_le_bytes());
    output.extend(data);
}

fn comment_key(value: &[u8]) -> String {
    value
        .iter()
        .position(|value| *value == b'=')
        .filter(|index| *index > 0)
        .map(|index| uppercase(&String::from_utf8_lossy(&value[..index])))
        .unwrap_or_default()
}

fn set_comment(comments: &mut Vec<Vec<u8>>, key: &str, value: &str) {
    comments.retain(|comment| comment_key(comment) != key);
    if !value.is_empty() {
        comments.push(format!("{key}={value}").into_bytes());
    }
}

fn get_comment(comments: &[Vec<u8>], key: &str) -> String {
    comments
        .iter()
        .find(|comment| comment_key(comment) == key)
        .map(|comment| String::from_utf8_lossy(&comment[key.len() + 1..]).into_owned())
        .unwrap_or_default()
}

fn edit_comments(comments: &mut Vec<Vec<u8>>, fields: &Fields) {
    for (field, key) in [
        ("title", "TITLE"),
        ("album", "ALBUM"),
        ("date", "DATE"),
        ("isrc", "ISRC"),
        ("genre", "GENRE"),
        ("label", "ORGANIZATION"),
        ("copyright", "COPYRIGHT"),
        ("composer", "COMPOSER"),
        ("comment", "COMMENT"),
        ("explicit", "ITUNESADVISORY"),
        ("album_type", "RELEASETYPE"),
        ("upc", "BARCODE"),
        ("barcode", "BARCODE"),
        ("compilation", "COMPILATION"),
        ("replaygain_track_gain", "REPLAYGAIN_TRACK_GAIN"),
        ("replaygain_track_peak", "REPLAYGAIN_TRACK_PEAK"),
        ("replaygain_album_gain", "REPLAYGAIN_ALBUM_GAIN"),
        ("replaygain_album_peak", "REPLAYGAIN_ALBUM_PEAK"),
    ] {
        if let Some(value) = fields.get(field) {
            set_comment(comments, key, value);
        }
    }
    for (field, aliases) in [
        ("label", &["LABEL", "PUBLISHER"][..]),
        ("date", &["YEAR"][..]),
    ] {
        if fields.contains_key(field) {
            for key in aliases {
                set_comment(comments, key, "");
            }
        }
    }
    for (field, key) in [("artist", "ARTIST"), ("album_artist", "ALBUMARTIST")] {
        if let Some(value) = fields.get(field) {
            set_comment(comments, key, "");
            let values = if fields
                .get("artist_tag_mode")
                .is_some_and(|mode| mode.trim().eq_ignore_ascii_case("split_vorbis"))
            {
                split_artists(value)
            } else {
                vec![value.clone()]
            };
            for value in values {
                if !value.trim().is_empty() {
                    comments.push(format!("{key}={value}").into_bytes());
                }
            }
            if field == "album_artist" {
                for alias in ["ALBUM ARTIST", "ALBUM_ARTIST"] {
                    set_comment(comments, alias, "");
                }
            }
        }
    }
    for (field, total, key, alias) in [
        ("track_number", "track_total", "TRACKNUMBER", "TRACK"),
        ("disc_number", "disc_total", "DISCNUMBER", "DISC"),
    ] {
        if fields.contains_key(field) || fields.contains_key(total) {
            let mut current = pair(&get_comment(comments, key));
            if current == (0, 0) {
                current = pair(&get_comment(comments, alias));
            }
            set_comment(comments, key, &edit_index(current, fields, field, total));
            set_comment(comments, alias, "");
        }
    }
    if let Some(value) = fields.get("lyrics") {
        set_comment(comments, "SYNCEDLYRICS", "");
        set_comment(comments, "LYRICS", value);
        set_comment(comments, "UNSYNCEDLYRICS", value);
    }
}

fn edit_index(
    (mut number, mut total): (i64, i64),
    fields: &Fields,
    key: &str,
    total_key: &str,
) -> String {
    if let Some(value) = fields.get(key) {
        number = value.trim().parse::<i64>().unwrap_or(0);
    }
    if let Some(value) = fields.get(total_key) {
        total = value.trim().parse::<i64>().unwrap_or(0);
    }
    if number <= 0 {
        String::new()
    } else if total > 0 {
        format!("{number}/{total}")
    } else {
        number.to_string()
    }
}

fn metadata_fields(metadata: &super::AudioMetadata, fields: &Fields) -> Fields {
    let mut result = Fields::new();
    for (field, current) in [
        ("title", &metadata.title),
        ("artist", &metadata.artist),
        ("album", &metadata.album),
        ("album_artist", &metadata.album_artist),
        ("date", &metadata.date),
        ("genre", &metadata.genre),
        ("composer", &metadata.composer),
        ("label", &metadata.label),
        ("copyright", &metadata.copyright),
        ("isrc", &metadata.isrc),
        ("lyrics", &metadata.lyrics),
        ("comment", &metadata.comment),
        ("album_type", &metadata.album_type),
        ("upc", &metadata.upc),
        ("replaygain_track_gain", &metadata.replay_gain_track_gain),
        ("replaygain_track_peak", &metadata.replay_gain_track_peak),
        ("replaygain_album_gain", &metadata.replay_gain_album_gain),
        ("replaygain_album_peak", &metadata.replay_gain_album_peak),
    ] {
        result.insert(field.into(), fields.get(field).unwrap_or(current).clone());
    }
    static INTEGER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[+-]?[0-9]+").unwrap());
    for (field, current) in [
        ("track_number", metadata.track_number),
        ("track_total", metadata.total_tracks),
        ("disc_number", metadata.disc_number),
        ("disc_total", metadata.total_discs),
    ] {
        let value = fields.get(field).map_or(current, |value| {
            INTEGER
                .find(value.trim())
                .and_then(|n| n.as_str().parse::<isize>().ok())
                .unwrap_or(0) as i64
        });
        result.insert(field.into(), value.to_string());
    }
    let explicit = fields
        .get("explicit")
        .map_or(metadata.explicit, |value| super::truthy(value));
    result.insert("explicit".into(), if explicit { "1" } else { "" }.into());
    let compilation = result["album_type"]
        .trim()
        .eq_ignore_ascii_case("compilation");
    result.insert(
        "compilation".into(),
        if compilation { "1" } else { "" }.into(),
    );
    result
}

fn primary_artist_mode(mode: &str) -> bool {
    mode.trim().eq_ignore_ascii_case("primary")
}

/// The first credited artist, or the trimmed value when nothing separates it.
/// Dart and Kotlin share this exact separator set so every writer agrees;
/// Vorbis split mode also recognizes these featured-credit variants.
fn primary_artist(value: &str) -> String {
    static SEPARATOR: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\s*[,;&]\s*|\s+x\s+|\s+(?:feat(?:uring|ured|ure)?|ft|with)\.?(?:\s+|$)")
            .unwrap()
    });
    let value = value.trim();
    SEPARATOR
        .split(value)
        .map(str::trim)
        .find(|part| !part.is_empty())
        .unwrap_or(value)
        .to_owned()
}

/// Applies the "primary" artist tag mode to editor fields before any format
/// writer runs, so ID3, MP4, APE, RIFF and Vorbis all store the same name.
fn artist_mode_fields(fields: &Fields) -> Cow<'_, Fields> {
    if !fields
        .get("artist_tag_mode")
        .is_some_and(|mode| primary_artist_mode(mode))
    {
        return Cow::Borrowed(fields);
    }
    let mut fields = fields.clone();
    for key in ["artist", "album_artist"] {
        if let Some(value) = fields.get_mut(key)
            && !value.trim().is_empty()
        {
            *value = primary_artist(value);
        }
    }
    Cow::Owned(fields)
}

fn split_artists(value: &str) -> Vec<String> {
    static SPLIT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?i)\s*(?:,|;|&|\bx\b)\s*|\s+\b(?:feat(?:uring|ured|ure)?|ft|with)\.?(?:\s+|$)",
        )
        .unwrap()
    });
    let value = value.trim();
    if value.is_empty() {
        return Vec::new();
    }
    let mut seen = BTreeSet::new();
    let mut result: Vec<String> = SPLIT
        .split(value)
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .filter(|part| seen.insert(lowercase(part)))
        .map(str::to_owned)
        .collect();
    if result.is_empty() {
        result.push(value.into());
    }
    result
}

fn cover_mime(data: &[u8]) -> &'static str {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if data.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "image/gif"
    } else if data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

fn picture(
    original: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Vec<u8>>, String> {
    let mut resized = None;
    if original.len() > 16_000_000 {
        let Ok(image) = image::ImageReader::new(Cursor::new(original))
            .with_guessed_format()
            .map_err(|e| e.to_string())?
            .decode()
        else {
            return Ok(None);
        };
        for quality in [90, 80, 70, 60] {
            check()?;
            let mut encoded = Vec::new();
            if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, quality)
                .encode_image(&image.to_rgb8())
                .is_ok()
                && encoded.len() <= 16_000_000
            {
                resized = Some(encoded);
                break;
            }
        }
        if resized.is_none() {
            for dimension in [1500, 1200, 1000, 800] {
                check()?;
                let scaled = image
                    .resize(dimension, dimension, image::imageops::FilterType::Nearest)
                    .to_rgb8();
                let mut encoded = Vec::new();
                if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, 85)
                    .encode_image(&scaled)
                    .is_ok()
                    && encoded.len() <= 16_000_000
                {
                    resized = Some(encoded);
                    break;
                }
            }
        }
        if resized.is_none() {
            return Ok(None);
        }
    }
    check()?;
    let data = resized.as_deref().unwrap_or(original);
    let mime = cover_mime(data);
    let dimensions = image::ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .into_dimensions()
        .ok();
    let (width, height, depth) = dimensions.map_or((0, 0, 0), |(w, h)| {
        (
            w,
            h,
            match mime {
                "image/png" => 32,
                "image/jpeg" => 24,
                _ => 0,
            },
        )
    });
    let mut result = 3_u32.to_be_bytes().to_vec();
    for value in [mime.as_bytes(), b"Front Cover"] {
        result.extend((value.len() as u32).to_be_bytes());
        result.extend(value);
    }
    for value in [width, height, depth, 0, data.len() as u32] {
        result.extend(value.to_be_bytes());
    }
    result.extend(data);
    Ok(Some(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io;
    use std::rc::Rc;

    struct CountingReader {
        data: Cursor<Vec<u8>>,
        bytes_read: Rc<Cell<usize>>,
    }

    impl Read for CountingReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let count = self.data.read(buffer)?;
            self.bytes_read.set(self.bytes_read.get() + count);
            Ok(count)
        }
    }

    impl Seek for CountingReader {
        fn seek(&mut self, offset: SeekFrom) -> io::Result<u64> {
            self.data.seek(offset)
        }
    }

    /// Shared with the Dart and Kotlin primary-artist tests; keep in sync.
    #[test]
    fn split_artist_credits_recognize_variants_without_splitting_band_words() {
        assert_eq!(
            split_artists("One Featured Two; Three"),
            vec!["One", "Two", "Three"]
        );
        assert_eq!(split_artists("One feature Two"), vec!["One", "Two"]);
        assert_eq!(
            split_artists("Florence and the Machine"),
            vec!["Florence and the Machine"]
        );
        assert_eq!(
            split_artists("Artist Without Fear"),
            vec!["Artist Without Fear"]
        );
    }

    #[test]
    fn primary_artist_uses_the_shared_separator_set() {
        for (input, expected) in [
            ("Calle 24, Chino Pacas", "Calle 24"),
            ("Calle 24 & Chino Pacas", "Calle 24"),
            ("Artist A; Artist B", "Artist A"),
            ("Artist A feat. Artist B", "Artist A"),
            ("Artist A Feat Artist B", "Artist A"),
            ("Artist A ft. Artist B", "Artist A"),
            ("Artist A featuring Artist B", "Artist A"),
            ("Artist A featured Artist B", "Artist A"),
            ("Artist A feature Artist B", "Artist A"),
            ("Artist A with Artist B", "Artist A"),
            ("Artist A x Artist B", "Artist A"),
            ("Artist A X Artist B", "Artist A"),
            (" , Artist A, Artist B", "Artist A"),
            ("Malcolm X", "Malcolm X"),
            ("Artist Without Fear", "Artist Without Fear"),
            ("Maxx", "Maxx"),
            ("AC/DC", "AC/DC"),
            ("  Various Artists  ", "Various Artists"),
            ("", ""),
        ] {
            assert_eq!(primary_artist(input), expected, "{input:?}");
        }
    }

    fn editable_flac() -> (Vec<u8>, usize, Fields) {
        let mut comments = Vec::new();
        put_string(&mut comments, b"SpotiFLAC");
        comments.extend(2_u32.to_le_bytes());
        put_string(&mut comments, b"CUSTOM=preserve");
        put_string(&mut comments, b"TITLE=Example");
        let blocks = [
            (0, vec![0; 34]),
            (1, vec![0; 16]),
            (4, comments),
            (6, picture(b"original cover", &|| Ok(())).unwrap().unwrap()),
        ];
        let mut input = b"fLaC".to_vec();
        for (index, (kind, data)) in blocks.iter().enumerate() {
            input.push(kind | if index + 1 == blocks.len() { 0x80 } else { 0 });
            input.extend(&(data.len() as u32).to_be_bytes()[1..]);
            input.extend(data);
        }
        let audio_start = input.len();
        input.extend([0xff, 0xf8]);
        input.resize(audio_start + 1024 * 1024, 0x55);
        let fields = Fields::from([("title".into(), "Example".into())]);
        (input, audio_start, fields)
    }

    #[test]
    fn unchanged_flac_tags_do_not_copy_audio_or_write_output() {
        for cover in [None, Some(b"original cover".as_slice())] {
            let (input, audio_start, fields) = editable_flac();
            let bytes_read = Rc::new(Cell::new(0));
            let mut source = CountingReader {
                data: Cursor::new(input),
                bytes_read: bytes_read.clone(),
            };
            let mut output = Vec::new();
            assert!(
                !rewrite_flac_tags_if_changed(
                    &mut source,
                    &mut output,
                    &fields,
                    cover,
                    &|| Ok(()),
                )
                .unwrap()
            );
            assert!(output.is_empty());
            // One header parse, two frame-sync bytes, one exact comparison.
            assert_eq!(bytes_read.get(), audio_start * 2 + 2);
        }
    }

    #[test]
    fn changed_flac_tags_match_full_rewrite_and_preserve_audio() {
        let (input, audio_start, _) = editable_flac();
        for (title, cover) in [
            ("Changed", None), // Equal-length header with different bytes.
            ("A longer title", None),
            ("Example", Some(b"different artwork".as_slice())),
        ] {
            let fields = Fields::from([("title".into(), title.into())]);
            let mut expected = Vec::new();
            rewrite_audio_tags(
                &mut Cursor::new(&input),
                &mut expected,
                "flac",
                &fields,
                cover,
                &|| Ok(()),
            )
            .unwrap();
            let mut output = Vec::new();
            assert!(
                rewrite_flac_tags_if_changed(
                    &mut Cursor::new(&input),
                    &mut output,
                    &fields,
                    cover,
                    &|| Ok(()),
                )
                .unwrap()
            );
            assert_eq!(output, expected);
            assert!(output.ends_with(&input[audio_start..]));
        }
    }

    #[test]
    fn unchanged_flac_still_validates_frames_and_observes_cancellation() {
        let (input, audio_start, fields) = editable_flac();
        let bytes_read = Rc::new(Cell::new(0));
        let mut source = CountingReader {
            data: Cursor::new(input.clone()),
            bytes_read: bytes_read.clone(),
        };
        let mut output = Vec::new();
        let error = rewrite_flac_tags_if_changed(&mut source, &mut output, &fields, None, &|| {
            if bytes_read.get() >= audio_start + 2 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();
        assert_eq!(error, "cancelled");
        assert!(output.is_empty());

        let mut invalid = input;
        invalid[audio_start] = 0;
        assert!(
            rewrite_flac_tags_if_changed(
                &mut Cursor::new(invalid),
                &mut output,
                &fields,
                None,
                &|| Ok(()),
            )
            .unwrap_err()
            .contains("sync code")
        );
        assert!(output.is_empty());
    }

    fn flac_with_pictures(lengths: &[usize]) -> (Vec<u8>, usize) {
        let mut comments = Vec::new();
        put_string(&mut comments, b"Example vendor");
        comments.extend(1_u32.to_le_bytes());
        put_string(&mut comments, b"CUSTOM=preserve");
        let mut blocks = vec![
            (0, vec![0; 34]),
            (2, b"unknown block".to_vec()),
            (4, comments),
        ];
        blocks.extend(lengths.iter().map(|length| (6, vec![0x55; *length])));
        let mut input = b"fLaC".to_vec();
        for (index, (kind, data)) in blocks.iter().enumerate() {
            input.push(kind | if index + 1 == blocks.len() { 0x80 } else { 0 });
            input.extend(&(data.len() as u32).to_be_bytes()[1..]);
            input.extend(data);
        }
        let audio_start = input.len();
        input.extend([0xff, 0xf8, 0x12, 0x34, 0x56]);
        (input, audio_start)
    }

    #[test]
    fn replacement_flac_artwork_preserves_other_blocks_and_audio() {
        let (input, audio_start) = flac_with_pictures(&[131_073, 262_145]);
        let (without_pictures, _) = flac_with_pictures(&[]);
        let cover = Some(b"replacement artwork".as_slice());
        for embed in [false, true] {
            let fields = Fields::from([(
                if embed { "TITLE" } else { "title" }.into(),
                "Changed title".into(),
            )]);
            let rewrite = |data: &[u8], cover| {
                let mut output = Vec::new();
                if embed {
                    embed_flac_metadata(
                        &mut Cursor::new(data),
                        &mut output,
                        &fields,
                        "",
                        cover,
                        &|| Ok(()),
                    )
                    .unwrap();
                } else {
                    rewrite_audio_tags(
                        &mut Cursor::new(data),
                        &mut output,
                        "flac",
                        &fields,
                        cover,
                        &|| Ok(()),
                    )
                    .unwrap();
                }
                output
            };
            let output = rewrite(&input, cover);
            assert_eq!(output, rewrite(&without_pictures, cover));
            assert!(output.ends_with(&input[audio_start..]));
            let retained = rewrite(&input, None);
            assert!(
                retained
                    .windows(131_073)
                    .any(|bytes| bytes == [0x55; 131_073])
            );
            assert!(retained.ends_with(&input[audio_start..]));
        }
    }

    #[test]
    fn discarded_flac_picture_preserves_eof_and_cancellation() {
        let (input, audio_start) = flac_with_pictures(&[131_073]);
        let picture_start = audio_start - 131_073;
        let fields = Fields::new();
        for available in [0, 1, 65536, 65537, 131_072] {
            let truncated = &input[..picture_start + available];
            let mut expected = Vec::new();
            let error = rewrite_audio_tags(
                &mut Cursor::new(truncated),
                &mut expected,
                "flac",
                &fields,
                None,
                &|| Ok(()),
            )
            .unwrap_err();
            let mut output = Vec::new();
            assert_eq!(
                rewrite_audio_tags(
                    &mut Cursor::new(truncated),
                    &mut output,
                    "flac",
                    &fields,
                    Some(b"replacement artwork"),
                    &|| Ok(()),
                )
                .unwrap_err(),
                error
            );
            assert!(output.is_empty());
        }
        let bytes_read = Rc::new(Cell::new(0));
        let mut source = CountingReader {
            data: Cursor::new(input),
            bytes_read: bytes_read.clone(),
        };
        let mut output = Vec::new();
        assert_eq!(
            rewrite_flac_tags_if_changed(
                &mut source,
                &mut output,
                &fields,
                Some(b"replacement artwork"),
                &|| {
                    if bytes_read.get() >= picture_start + 65536 {
                        Err("cancelled".into())
                    } else {
                        Ok(())
                    }
                },
            )
            .unwrap_err(),
            "cancelled"
        );
        assert!(bytes_read.get() < audio_start);
        assert!(output.is_empty());
    }

    #[test]
    fn discarded_flac_pictures_still_count_toward_metadata_limit() {
        let (input, _) = flac_with_pictures(&vec![0; 65534]);
        let mut output = Vec::new();
        assert_eq!(
            rewrite_audio_tags(
                &mut Cursor::new(input),
                &mut output,
                "flac",
                &Fields::new(),
                Some(b"replacement artwork"),
                &|| Ok(()),
            )
            .unwrap_err(),
            "FLAC metadata block count exceeds 65536"
        );
        assert!(output.is_empty());
    }

    #[test]
    fn oversized_flac_cover_reencodes_or_omits_invalid_image() {
        let image = image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            3,
            2,
            image::Rgba([30, 60, 90, 255]),
        ));
        let mut encoded = Cursor::new(Vec::new());
        image
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let mut cover = encoded.into_inner();
        // Valid PNG with trailing data forces the same size fallback as a
        // large artwork file without an expensive image-generation fixture.
        cover.resize(16_000_001, 0);
        let block = picture(&cover, &|| Ok(())).unwrap().unwrap();
        let mut reader = Cursor::new(block);
        let mut number = || {
            let mut value = [0; 4];
            reader.read_exact(&mut value).unwrap();
            u32::from_be_bytes(value)
        };
        assert_eq!(number(), 3);
        assert_eq!(number(), 10);
        assert_eq!(bytes(&mut reader, 10).unwrap(), b"image/jpeg");
        assert_eq!(bytes(&mut reader, 4).unwrap(), 11_u32.to_be_bytes());
        assert_eq!(bytes(&mut reader, 11).unwrap(), b"Front Cover");
        assert_eq!(bytes(&mut reader, 4).unwrap(), 3_u32.to_be_bytes());
        assert_eq!(bytes(&mut reader, 4).unwrap(), 2_u32.to_be_bytes());
        assert_eq!(bytes(&mut reader, 4).unwrap(), 24_u32.to_be_bytes());
        assert_eq!(bytes(&mut reader, 4).unwrap(), [0; 4]);
        let length = u32::from_be_bytes(bytes(&mut reader, 4).unwrap().try_into().unwrap());
        assert!(length < 16_000_000);
        let jpeg = bytes(&mut reader, length as usize).unwrap();
        assert_eq!(
            image::ImageReader::new(Cursor::new(jpeg))
                .with_guessed_format()
                .unwrap()
                .into_dimensions()
                .unwrap(),
            (3, 2)
        );
        cover.fill(0);
        assert!(picture(&cover, &|| Ok(())).unwrap().is_none());
        assert_eq!(
            picture(b"small cover", &|| Err("cancelled".into())).unwrap_err(),
            "cancelled"
        );
    }
}
