pub(super) mod ac4;

use super::{Fields, MAX_TAG_BYTES, Section, bytes, seek};
use crate::matching::uppercase;
use crate::media::mp4::{Atom, Reader};
use regex::Regex;
use std::cell::Cell;
use std::collections::BTreeSet;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::sync::LazyLock;

type Check<'a> = &'a dyn Fn() -> Result<(), String>;

struct Location {
    ilst: Atom,
    ancestors: Vec<Atom>,
}

pub(super) fn edit(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    check: Check<'_>,
) -> Result<Vec<Section>, String> {
    let mut section = load(source, b"moov", check)?.ok_or("moov not found")?;
    let data = &mut section.data;
    let location = ensure_ilst(data, section.start, check)?;
    let mut drop = BTreeSet::new();
    let mut appended = Vec::new();
    for (field, kind) in [
        ("title", b"\xa9nam"),
        ("artist", b"\xa9ART"),
        ("album", b"\xa9alb"),
        ("album_artist", b"aART"),
        ("date", b"\xa9day"),
        ("genre", b"\xa9gen"),
        ("composer", b"\xa9wrt"),
        ("comment", b"\xa9cmt"),
        ("copyright", b"cprt"),
        ("lyrics", b"\xa9lyr"),
    ] {
        if let Some(value) = fields.get(field) {
            drop.insert(*kind);
            if field == "genre" {
                drop.insert(*b"gnre");
            }
            if !value.trim().is_empty() {
                appended.extend(value_atom(kind, 1, value.as_bytes()));
            }
        }
    }
    let mut remove_names = BTreeSet::new();
    for (field, name) in [
        ("isrc", "ISRC"),
        ("label", "LABEL"),
        ("album_type", "RELEASETYPE"),
        ("upc", "BARCODE"),
    ] {
        if let Some(value) = fields.get(field) {
            remove_names.insert(name.to_owned());
            if !value.trim().is_empty() {
                appended.extend(freeform(name, value.trim()));
            }
        }
    }
    if fields.contains_key("label") {
        remove_names.insert("ORGANIZATION".into());
    }
    if fields.contains_key("lyrics") {
        remove_names.extend(["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS"].map(str::to_owned));
    }
    for (field, kind, data_type) in [("explicit", b"rtng", 21), ("compilation", b"cpil", 22)] {
        if let Some(value) = fields.get(field) {
            drop.insert(*kind);
            if matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "explicit"
            ) {
                appended.extend(value_atom(kind, data_type, &[1]));
            }
        }
    }
    let replay_gain = replay_gain(fields);
    if !replay_gain.is_empty() {
        // Replace the entire group, or explicitly clear it when all four
        // ReplayGain fields are supplied empty (including derived Sound Check).
        remove_names.extend(
            [
                "REPLAYGAIN_TRACK_GAIN",
                "REPLAYGAIN_TRACK_PEAK",
                "REPLAYGAIN_ALBUM_GAIN",
                "REPLAYGAIN_ALBUM_PEAK",
                "ITUNNORM",
            ]
            .map(str::to_owned),
        );
        for (name, value) in replay_gain {
            if !value.is_empty() {
                appended.extend(freeform(&name, &value));
            }
        }
    }
    let edit_track = fields.contains_key("track_number") || fields.contains_key("track_total");
    let edit_disc = fields.contains_key("disc_number") || fields.contains_key("disc_total");
    if cover.is_some() {
        drop.insert(*b"covr");
    }
    let mut body = Vec::new();
    let mut track = (0, 0);
    let mut disc = (0, 0);
    for child in children(data, location.ilst.payload, location.ilst.end, check)? {
        let keep = if drop.contains(&child.kind) {
            false
        } else if child.kind == *b"trkn" {
            track = index_pair(data, child, check)?;
            !edit_track
        } else if child.kind == *b"disk" {
            disc = index_pair(data, child, check)?;
            !edit_disc
        } else if child.kind == *b"----" {
            !remove_names.contains(&uppercase(&freeform_name(data, child, check)?))
        } else {
            true
        };
        if keep {
            body.extend_from_slice(&data[child.start as usize..child.end as usize]);
        }
    }
    for (edited, current, field, total, kind) in [
        (edit_track, track, "track_number", "track_total", b"trkn"),
        (edit_disc, disc, "disc_number", "disc_total", b"disk"),
    ] {
        if edited {
            let number = fields.get(field).map_or(current.0, |v| positive(v));
            let total = fields.get(total).map_or(current.1, |v| positive(v));
            if number > 0 {
                let mut pair = vec![0; if kind == b"disk" { 6 } else { 8 }];
                pair[2..4].copy_from_slice(&(number as u16).to_be_bytes());
                pair[4..6].copy_from_slice(&(total as u16).to_be_bytes());
                appended.extend(value_atom(kind, 0, &pair));
            }
        }
    }
    if let Some(cover) = cover {
        appended.extend(value_atom(
            b"covr",
            if cover.starts_with(b"\x89PNG") {
                14
            } else {
                13
            },
            cover,
        ));
    }
    if body.len() + appended.len() > MAX_TAG_BYTES {
        return Err("MP4 metadata exceeds 64 MiB".into());
    }
    body.extend(appended);
    replace(
        data,
        location.ilst.start,
        location.ilst.end,
        &build(b"ilst", &body),
        &location.ancestors,
        section.start,
        check,
    )?;
    Ok(vec![section])
}

fn load(
    source: &mut (impl Read + Seek),
    kind: &[u8; 4],
    check: Check<'_>,
) -> Result<Option<Section>, String> {
    let size = seek(source, SeekFrom::End(0))?;
    let mut reader = Reader {
        file: source,
        size,
        check,
    };
    let mut start = 0;
    for _ in 0..65536 {
        if start + 8 > size {
            return Ok(None);
        }
        let atom = reader.atom(start, size)?;
        if atom.end > size {
            return Err("MP4 atom extends past end of file".into());
        }
        if &atom.kind == kind {
            let length = atom.end - atom.start;
            if length > MAX_TAG_BYTES as u64 {
                return Err("MP4 metadata exceeds 64 MiB".into());
            }
            seek(reader.file, SeekFrom::Start(start))?;
            return Ok(Some(Section {
                start,
                end: atom.end,
                data: bytes(reader.file, length as usize)?,
            }));
        }
        start = atom.end;
    }
    Err("MP4 atom count exceeds 65536".into())
}

fn atom(data: &[u8], start: u64, end: u64, check: Check<'_>) -> Result<Atom, String> {
    let mut source = Cursor::new(data);
    let atom = Reader {
        file: &mut source,
        size: data.len() as u64,
        check,
    }
    .atom(start, end)?;
    if atom.end > end || atom.end > data.len() as u64 {
        return Err("MP4 atom extends past parent".into());
    }
    Ok(atom)
}

fn children(data: &[u8], mut start: u64, end: u64, check: Check<'_>) -> Result<Vec<Atom>, String> {
    let mut result = Vec::new();
    while start + 8 <= end {
        if result.len() >= 65536 {
            return Err("MP4 atom count exceeds 65536".into());
        }
        let child = atom(data, start, end, check)?;
        start = child.end;
        result.push(child);
    }
    Ok(result)
}

fn find(
    data: &[u8],
    mut start: u64,
    end: u64,
    kind: &[u8; 4],
    check: Check<'_>,
) -> Result<Option<Atom>, String> {
    for _ in 0..65536 {
        if start + 8 > end {
            return Ok(None);
        }
        let child = atom(data, start, end, check)?;
        if &child.kind == kind {
            return Ok(Some(child));
        }
        start = child.end;
    }
    Err("MP4 atom count exceeds 65536".into())
}

fn locate_meta(
    data: &[u8],
    meta: Atom,
    quicktime: bool,
    check: Check<'_>,
) -> Result<Option<Atom>, String> {
    let cancelled = Cell::new(false);
    let guard = || {
        let result = check();
        if result.is_err() {
            cancelled.set(true);
        }
        result
    };
    let iso = find(data, meta.payload + 4, meta.end, b"ilst", &guard);
    if !quicktime || cancelled.get() || iso.as_ref().is_ok_and(Option::is_some) {
        return iso;
    }
    find(data, meta.payload, meta.end, b"ilst", check)
}

fn locate(data: &[u8], quicktime: bool, check: Check<'_>) -> Result<Option<Location>, String> {
    let moov = atom(data, 0, data.len() as u64, check)?;
    if moov.kind != *b"moov" {
        return Err("moov not found".into());
    }
    if let Some(udta) = find(data, moov.payload, moov.end, b"udta", check)?
        && let Some(meta) = find(data, udta.payload, udta.end, b"meta", check)?
        && let Some(ilst) = locate_meta(data, meta, quicktime, check)?
    {
        return Ok(Some(Location {
            ilst,
            ancestors: vec![moov, udta, meta],
        }));
    }
    if let Some(meta) = find(data, moov.payload, moov.end, b"meta", check)?
        && let Some(ilst) = locate_meta(data, meta, quicktime, check)?
    {
        return Ok(Some(Location {
            ilst,
            ancestors: vec![moov, meta],
        }));
    }
    Ok(None)
}

fn meta(body: &[u8]) -> Vec<u8> {
    let mut handler = vec![0; 25];
    handler[8..12].copy_from_slice(b"mdir");
    handler[12..16].copy_from_slice(b"appl");
    let mut payload = vec![0; 4];
    payload.extend(build(b"hdlr", &handler));
    payload.extend(build(b"ilst", body));
    build(b"meta", &payload)
}

fn ensure_ilst(data: &mut Vec<u8>, base: u64, check: Check<'_>) -> Result<Location, String> {
    if let Some(location) = locate(data, false, check)? {
        return Ok(location);
    }
    let moov = atom(data, 0, data.len() as u64, check)?;
    let mut ancestors = vec![moov];
    let (position, inserted) =
        if let Some(udta) = find(data, moov.payload, moov.end, b"udta", check)? {
            ancestors.push(udta);
            if let Some(meta) = find(data, udta.payload, udta.end, b"meta", check)? {
                ancestors.push(meta);
                (meta.end, build(b"ilst", &[]))
            } else {
                (udta.end, meta(&[]))
            }
        } else {
            (moov.end, build(b"udta", &meta(&[])))
        };
    replace(data, position, position, &inserted, &ancestors, base, check)?;
    locate(data, false, check)?.ok_or_else(|| "failed to create ilst".into())
}

fn replace(
    data: &mut Vec<u8>,
    start: u64,
    end: u64,
    replacement: &[u8],
    ancestors: &[Atom],
    base: u64,
    check: Check<'_>,
) -> Result<(), String> {
    check()?;
    let delta = replacement.len() as i64 - (end - start) as i64;
    if (data.len() as u64)
        .checked_add_signed(delta)
        .is_none_or(|n| n > MAX_TAG_BYTES as u64)
    {
        return Err("MP4 metadata exceeds 64 MiB".into());
    }
    data.splice(start as usize..end as usize, replacement.iter().copied());
    for ancestor in ancestors {
        grow(data, *ancestor, delta)?;
    }
    shift_offsets(data, base + start, delta, check)
}

fn grow(data: &mut [u8], atom: Atom, delta: i64) -> Result<(), String> {
    let size = (atom.end - atom.start)
        .checked_add_signed(delta)
        .ok_or("invalid resized MP4 atom")?;
    let start = atom.start as usize;
    if atom.payload - atom.start == 16 {
        data[start..start + 4].copy_from_slice(&1_u32.to_be_bytes());
        data[start + 8..start + 16].copy_from_slice(&size.to_be_bytes());
    } else {
        let size = u32::try_from(size).map_err(|_| "MP4 atom too large for 32-bit header")?;
        data[start..start + 4].copy_from_slice(&size.to_be_bytes());
    }
    Ok(())
}

fn shift_offsets(
    data: &mut [u8],
    position: u64,
    delta: i64,
    check: Check<'_>,
) -> Result<(), String> {
    if delta == 0 {
        return Ok(());
    }
    let moov = atom(data, 0, data.len() as u64, check)?;
    for track in children(data, moov.payload, moov.end, check)?
        .into_iter()
        .filter(|atom| atom.kind == *b"trak")
    {
        let mut parent = Some(track);
        for kind in [b"mdia", b"minf", b"stbl"] {
            parent = match parent {
                Some(p) => find(data, p.payload, p.end, kind, check)?,
                None => None,
            };
        }
        let Some(parent) = parent else {
            continue;
        };
        for (kind, width) in [(b"stco", 4), (b"co64", 8)] {
            let Some(table) = find(data, parent.payload, parent.end, kind, check)? else {
                continue;
            };
            if table.payload + 8 > table.end {
                continue;
            }
            let begin = table.payload as usize;
            let count = u32::from_be_bytes(data[begin + 4..begin + 8].try_into().unwrap()) as usize;
            for offset in (begin + 8..table.end as usize).step_by(width).take(count) {
                check()?;
                if offset + width > table.end as usize {
                    break;
                }
                let value = if width == 4 {
                    u32::from_be_bytes(data[offset..offset + 4].try_into().unwrap()) as u64
                } else {
                    u64::from_be_bytes(data[offset..offset + 8].try_into().unwrap())
                };
                if value >= position {
                    let shifted = value
                        .checked_add_signed(delta)
                        .ok_or("MP4 chunk offset overflow")?;
                    if width == 4 {
                        let shifted =
                            u32::try_from(shifted).map_err(|_| "MP4 stco offset overflow")?;
                        data[offset..offset + 4].copy_from_slice(&shifted.to_be_bytes());
                    } else {
                        data[offset..offset + 8].copy_from_slice(&shifted.to_be_bytes());
                    }
                }
            }
        }
    }
    Ok(())
}

fn build(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
    result.extend(kind);
    result.extend(payload);
    result
}

fn value_atom(kind: &[u8; 4], data_type: u32, value: &[u8]) -> Vec<u8> {
    let mut payload = data_type.to_be_bytes().to_vec();
    payload.extend([0; 4]);
    payload.extend(value);
    build(kind, &build(b"data", &payload))
}

fn freeform(name: &str, value: &str) -> Vec<u8> {
    let mut body = build(b"mean", b"\0\0\0\0com.apple.iTunes");
    let mut name_payload = vec![0; 4];
    name_payload.extend(name.as_bytes());
    body.extend(build(b"name", &name_payload));
    let mut value_payload = vec![0, 0, 0, 1, 0, 0, 0, 0];
    value_payload.extend(value.as_bytes());
    body.extend(build(b"data", &value_payload));
    build(b"----", &body)
}

fn freeform_name(data: &[u8], parent: Atom, check: Check<'_>) -> Result<String, String> {
    let Some(name) = find(data, parent.payload, parent.end, b"name", check)? else {
        return Ok(String::new());
    };
    if name.payload + 4 >= name.end {
        return Ok(String::new());
    }
    Ok(
        String::from_utf8_lossy(&data[name.payload as usize + 4..name.end as usize])
            .trim_end_matches('\0')
            .trim()
            .into(),
    )
}

fn index_pair(data: &[u8], parent: Atom, check: Check<'_>) -> Result<(i64, i64), String> {
    let Some(value) = find(data, parent.payload, parent.end, b"data", check)? else {
        return Ok((0, 0));
    };
    if value.payload + 14 > value.end {
        return Ok((0, 0));
    }
    let start = value.payload as usize + 8;
    Ok((
        u16::from_be_bytes(data[start + 2..start + 4].try_into().unwrap()) as i64,
        u16::from_be_bytes(data[start + 4..start + 6].try_into().unwrap()) as i64,
    ))
}

fn positive(value: &str) -> i64 {
    value.trim().parse::<isize>().unwrap_or(0).max(0) as i64
}

fn replay_gain(fields: &Fields) -> Fields {
    let mut result: Fields = [
        "replaygain_track_gain",
        "replaygain_track_peak",
        "replaygain_album_gain",
        "replaygain_album_peak",
    ]
    .into_iter()
    .filter_map(|name| {
        fields
            .get(name)
            .map(|v| (name.to_owned(), v.trim().to_owned()))
    })
    .collect();
    // Preserve partial empty updates as no-ops; clearing the whole group is an
    // explicit request so ordinary metadata edits cannot discard normalization.
    if !super::clears_replay_gain(fields) {
        result.retain(|_, value| !value.is_empty());
    }
    static NUMBER: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"[+-]?[0-9]+(?:\.[0-9]+)?").unwrap());
    let gain = result
        .get("replaygain_track_gain")
        .and_then(|v| NUMBER.find(v))
        .and_then(|m| m.as_str().parse::<f64>().ok());
    let peak = result
        .get("replaygain_track_peak")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| v.is_nan() || *v > 0.0);
    if let (Some(gain), Some(peak)) = (gain, peak) {
        let clamp = |value: f64| -> i64 {
            let value = value.round();
            if !value.is_finite()
                || !(-9223372036854775808.0..9223372036854775808.0).contains(&value)
            {
                0
            } else {
                (value as i64).clamp(0, 65534)
            }
        };
        let g1 = clamp(10_f64.powf(gain / -10.0) * 1000.0);
        let g2 = clamp(10_f64.powf(gain / -10.0) * 2500.0);
        let peak = clamp(peak * 32768.0);
        result.insert(
            "iTunNORM".into(),
            [g1, g1, g2, g2, 0, 0, peak, peak, 0, 0]
                .map(|n| format!("{n:08X}"))
                .join(" "),
        );
    }
    result
}

pub(super) fn edit_freeform(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    replay_gain_only: bool,
    check: Check<'_>,
) -> Result<Vec<Section>, String> {
    let mut remove = BTreeSet::new();
    let values = if replay_gain_only {
        let values = replay_gain(fields);
        if values.is_empty() {
            return Ok(Vec::new());
        }
        remove.extend(
            [
                "REPLAYGAIN_TRACK_GAIN",
                "REPLAYGAIN_TRACK_PEAK",
                "REPLAYGAIN_ALBUM_GAIN",
                "REPLAYGAIN_ALBUM_PEAK",
                "ITUNNORM",
            ]
            .map(str::to_owned),
        );
        values
    } else {
        let mut values = Fields::new();
        for (field, name) in [("isrc", "ISRC"), ("label", "LABEL")] {
            if let Some(value) = fields.get(field) {
                remove.insert(name.to_owned());
                values.insert(name.to_owned(), value.trim().to_owned());
                if field == "label" {
                    remove.insert("ORGANIZATION".into());
                }
            }
        }
        if values.is_empty() {
            return Ok(Vec::new());
        }
        values
    };
    let mut section = load(source, b"moov", check)?.ok_or("moov not found")?;
    let data = &mut section.data;
    let Some(location) = locate(data, true, check)? else {
        return Ok(Vec::new());
    };
    let mut body = Vec::new();
    for child in children(data, location.ilst.payload, location.ilst.end, check)? {
        if child.kind != *b"----"
            || !remove.contains(&uppercase(&freeform_name(data, child, check)?))
        {
            body.extend_from_slice(&data[child.start as usize..child.end as usize]);
        }
    }
    for (name, value) in values {
        if !value.is_empty() {
            body.extend(freeform(&name, &value));
        }
        if body.len() > MAX_TAG_BYTES {
            return Err("MP4 metadata exceeds 64 MiB".into());
        }
    }
    replace(
        data,
        location.ilst.start,
        location.ilst.end,
        &build(b"ilst", &body),
        &location.ancestors,
        section.start,
        check,
    )?;
    Ok(vec![section])
}
