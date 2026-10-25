use super::{Atom, Check, Fields, MAX_TAG_BYTES, Section, atom, build, children, find, freeform};
use super::{load, meta, replace, seek, value_atom};
use crate::tags::CheckedReader;
use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::fmt;
use std::io::{BufReader, ErrorKind, Read, Seek, SeekFrom};

struct Location {
    ancestors: Vec<Atom>,
    entry: Atom,
}

fn locate(data: &[u8], check: Check<'_>) -> Result<Option<Location>, String> {
    let moov = atom(data, 0, data.len() as u64, check)?;
    for track in children(data, moov.payload, moov.end, check)?
        .into_iter()
        .filter(|a| a.kind == *b"trak")
    {
        let mut ancestors = vec![moov, track];
        for kind in [b"mdia", b"minf", b"stbl", b"stsd"] {
            let parent = *ancestors.last().unwrap();
            let Some(child) = find(data, parent.payload, parent.end, kind, check)? else {
                break;
            };
            ancestors.push(child);
        }
        if ancestors.len() == 6 {
            let stsd = ancestors[5];
            if let Some(entry) = find(data, stsd.payload + 8, stsd.end, b"ac-4", check)? {
                return Ok(Some(Location { ancestors, entry }));
            }
        }
    }
    Ok(None)
}

fn audio_header(data: &[u8], entry: Atom) -> Result<(u16, u64), String> {
    let base = entry.payload as usize;
    if entry.payload + 10 > entry.end {
        return Err("malformed ac-4 sample entry".into());
    }
    let version = u16::from_be_bytes(data[base + 8..base + 10].try_into().unwrap());
    let length = match version {
        1 => 44,
        2 => 64,
        _ => 28,
    };
    if entry.payload + length > entry.end {
        return Err("malformed ac-4 sample entry".into());
    }
    Ok((version, length))
}

pub(in super::super) fn config<R: Read + Seek>(
    source: &mut (impl Read + Seek),
    reference: impl FnOnce() -> Result<R, String>,
    check: Check<'_>,
) -> Result<Vec<Section>, String> {
    seek(source, SeekFrom::Start(0))?;
    let mut head = [0; 8];
    match source.read_exact(&mut head) {
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(Vec::new()),
        Err(error) => return Err(error.to_string()),
        Ok(()) => {}
    }
    if !head[4..].iter().all(|byte| (0x20..=0x7e).contains(byte)) {
        return Ok(Vec::new());
    }
    let Some(mut section) = load(source, b"moov", check)? else {
        return Ok(Vec::new());
    };
    let ftyp = load(source, b"ftyp", check)?;
    let Some(mut location) = locate(&section.data, check)? else {
        return Ok(Vec::new());
    };
    let mut sections = Vec::new();
    if let Some(mut ftyp) = ftyp {
        let header = atom(&ftyp.data, 0, ftyp.data.len() as u64, check)?;
        let base = header.payload as usize;
        let mut changed = false;
        if base + 4 <= ftyp.data.len() && &ftyp.data[base..base + 4] != b"mp42" {
            ftyp.data[base..base + 4].copy_from_slice(b"mp42");
            changed = true;
        }
        let brands_start = ftyp.data.len().min(base + 8);
        for brand in ftyp.data[brands_start..].as_chunks_mut::<4>().0 {
            check()?;
            if brand == b"qt  " {
                brand.copy_from_slice(b"isom");
                changed = true;
            }
        }
        if changed {
            sections.push(ftyp);
        }
    }
    let data = &mut section.data;
    let (version, _) = audio_header(data, location.entry)?;
    if version == 1 {
        let base = location.entry.payload;
        data[base as usize + 8..base as usize + 10].fill(0);
        location.ancestors.push(location.entry);
        replace(
            data,
            base + 28,
            base + 44,
            &[],
            &location.ancestors,
            section.start,
            check,
        )?;
        location = locate(data, check)?.ok_or("ac-4 entry lost during normalization")?;
    }
    let (_, header) = audio_header(data, location.entry)?;
    let position = location.entry.payload + header;
    if find(data, position, location.entry.end, b"dac4", check)?.is_none() {
        check()?;
        let mut reference = reference()?;
        let mut reference = BufReader::new(CheckedReader {
            reader: &mut reference,
            check,
        });
        let reference = load(&mut reference, b"moov", check)?.ok_or("source has no moov")?;
        let moov = atom(&reference.data, 0, reference.data.len() as u64, check)?;
        let mut config = None;
        // Encrypted sample entries can contain dac4 below opaque enca headers.
        for start in moov.payload..moov.end.saturating_sub(7) {
            if start % 4096 == 0 {
                check()?;
            }
            let index = start as usize;
            if &reference.data[index + 4..index + 8] == b"dac4" {
                // A signature match is only a candidate. Malformed candidates
                // are skipped, but cancellation always propagates.
                if let Ok(found) = atom(&reference.data, start, moov.end, &|| Ok(())) {
                    config = Some(found);
                    break;
                }
            }
        }
        check()?;
        let config = config.ok_or("dac4 not found in source")?;
        location.ancestors.push(location.entry);
        replace(
            data,
            position,
            position,
            &reference.data[config.start as usize..config.end as usize],
            &location.ancestors,
            section.start,
            check,
        )?;
    }
    sections.push(section);
    Ok(sections)
}

#[derive(Default)]
struct Metadata(Fields);

impl<'de> Deserialize<'de> for Metadata {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct Strings;
        impl<'de> Visitor<'de> for Strings {
            type Value = Metadata;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("AC-4 metadata object")
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut result = Metadata::default();
                while let Some((key, value)) = map.next_entry::<String, serde_json::Value>()? {
                    // Go retains prior string values on null/type errors and
                    // continues decoding later fields; duplicate keys are ordered.
                    if let serde_json::Value::String(value) = value {
                        result.0.insert(key.to_ascii_lowercase(), value);
                    }
                }
                Ok(result)
            }
        }
        decoder.deserialize_map(Strings)
    }
}

pub(in super::super) fn metadata(
    source: &mut (impl Read + Seek),
    metadata_json: &str,
    cover: impl FnOnce() -> Result<Option<Vec<u8>>, String>,
    check: Check<'_>,
) -> Result<Vec<Section>, String> {
    let Some(mut section) = load(source, b"moov", check)? else {
        return Ok(Vec::new());
    };
    if locate(&section.data, check)?.is_none() {
        return Ok(Vec::new());
    }
    if metadata_json.len() > MAX_TAG_BYTES {
        return Err("tag edit fields exceed 64 MiB".into());
    }
    let metadata: Metadata =
        serde_json::from_str(&crate::text::json_surrogates(metadata_json)).unwrap_or_default();
    let value = |name: &str| metadata.0.get(name).map(String::as_str).unwrap_or("");
    let mut body = Vec::new();
    for (field, kind) in [
        ("title", b"\xa9nam"),
        ("artist", b"\xa9ART"),
        ("album", b"\xa9alb"),
        ("albumartist", b"aART"),
        ("date", b"\xa9day"),
        ("genre", b"\xa9gen"),
        ("composer", b"\xa9wrt"),
        ("copyright", b"cprt"),
        ("lyrics", b"\xa9lyr"),
    ] {
        if !value(field).trim().is_empty() {
            body.extend(value_atom(kind, 1, value(field).as_bytes()));
        }
    }
    for (number, total, kind) in [
        ("tracknumber", "totaltracks", b"trkn"),
        ("discnumber", "totaldiscs", b"disk"),
    ] {
        let number = value(number).trim().parse::<isize>().unwrap_or(0);
        if number > 0 {
            let total = value(total).trim().parse::<isize>().unwrap_or(0);
            let mut pair = [0; 8];
            pair[2..4].copy_from_slice(&(number as u16).to_be_bytes());
            pair[4..6].copy_from_slice(&(total as u16).to_be_bytes());
            body.extend(value_atom(kind, 0, &pair));
        }
    }
    for (field, name) in [("isrc", "ISRC"), ("label", "LABEL")] {
        if !value(field).trim().is_empty() {
            body.extend(freeform(name, value(field).trim()));
        }
    }
    check()?;
    if let Some(cover) = cover()?.filter(|cover| !cover.is_empty()) {
        if body.len().saturating_add(cover.len()) > MAX_TAG_BYTES {
            return Err("MP4 metadata exceeds 64 MiB".into());
        }
        let kind = if cover.len() >= 8 && cover.starts_with(b"\x89PNG") {
            14
        } else {
            13
        };
        body.extend(value_atom(b"covr", kind, &cover));
    }
    let data = &mut section.data;
    let moov = atom(data, 0, data.len() as u64, check)?;
    let (start, end) = find(data, moov.payload, moov.end, b"udta", check)?
        .map_or((moov.end, moov.end), |udta| (udta.start, udta.end));
    // The AC-4 helper replaces the whole udta, matching Go's finalization path.
    replace(
        data,
        start,
        end,
        &build(b"udta", &meta(&body)),
        &[moov],
        section.start,
        check,
    )?;
    Ok(vec![section])
}
