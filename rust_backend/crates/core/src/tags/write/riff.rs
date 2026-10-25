use super::{Fields, Section, bytes, id3, metadata_fields, seek};
use crate::tags::{file::ObservedReader, read_audio_tags};
use std::io::{Cursor, Read, Seek, SeekFrom};

pub(super) fn edit(
    source: &mut (impl Read + Seek),
    aiff: bool,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<Section>, String> {
    let mut observed = ObservedReader {
        file: source,
        check,
        failure: None,
    };
    let metadata = read_audio_tags(&mut observed, if aiff { "aiff" } else { "wav" }, &|| Ok(()))
        .unwrap_or_default();
    if let Some(error) = observed.failure {
        return Err(error);
    }
    let source = observed.file;
    let length = seek(source, SeekFrom::End(0))?;
    seek(source, SeekFrom::Start(0))?;
    let header = bytes(source, 12)?;
    if &header[..4] != if aiff { b"FORM" } else { b"RIFF" } {
        return Err("unexpected container magic".into());
    }
    let mut sections = Vec::new();
    let mut start = 12_u64;
    let mut body_size = 4_u64;
    let mut embedded_cover = None;
    let remove_gain_only = fields.len() == 4 && super::clears_replay_gain(fields);
    for _ in 0..65536 {
        check()?;
        if start + 8 > length {
            break;
        }
        seek(source, SeekFrom::Start(start))?;
        let header = bytes(source, 8)?;
        let size = if aiff {
            u32::from_be_bytes(header[4..].try_into().unwrap())
        } else {
            u32::from_le_bytes(header[4..].try_into().unwrap())
        };
        let end = start + 8 + u64::from(size) + u64::from(size & 1);
        if header[..4].eq_ignore_ascii_case(b"id3 ") {
            if remove_gain_only {
                // Edit the existing ID3 frames so unknown tags and all artwork
                // survive removal, instead of rebuilding from parsed metadata.
                if size as usize > super::MAX_TAG_BYTES || end > length {
                    return Err("invalid RIFF ID3 chunk size".into());
                }
                let (tag, _) = id3::header(
                    &mut Cursor::new(bytes(source, size as usize)?),
                    fields,
                    None,
                    check,
                )?;
                let tag_size = tag.len() as u32;
                let mut chunk = header[..4].to_vec();
                chunk.extend(if aiff {
                    tag_size.to_be_bytes()
                } else {
                    tag_size.to_le_bytes()
                });
                chunk.extend(tag);
                if tag_size & 1 == 1 {
                    chunk.push(0);
                }
                body_size += chunk.len() as u64;
                sections.push(Section {
                    start,
                    end,
                    data: chunk,
                });
                start = end;
                continue;
            }
            if cover.is_none()
                && size > 0
                && size <= 16 * 1024 * 1024
                && end <= length
                && matches!(&header[..4], b"ID3 " | b"id3 ")
            {
                embedded_cover = id3::cover(&bytes(source, size as usize)?);
            }
            sections.push(Section {
                start,
                end: end.min(length),
                data: Vec::new(),
            });
        } else {
            if end > length {
                return Err("unexpected EOF while copying audio".into());
            }
            body_size += end - start;
        }
        start = end;
    }
    if start + 8 <= length {
        return Err("RIFF chunk count exceeds 65536".into());
    }
    if remove_gain_only {
        let size = u32::try_from(body_size).map_err(|_| "RIFF container exceeds 32-bit size")?;
        sections.push(Section {
            start: 4,
            end: 8,
            data: if aiff {
                size.to_be_bytes()
            } else {
                size.to_le_bytes()
            }
            .to_vec(),
        });
        return Ok(sections);
    }
    let cover_path = fields.get("cover_path").map(|p| p.trim()).unwrap_or("");
    if !cover_path.is_empty() && cover.is_none() {
        return Err("read cover art: file not found".into());
    }
    if cover.is_some_and(|cover| cover.is_empty()) {
        return Err("cover art is empty".into());
    }
    let cover = if let Some(cover) = cover {
        let mime = if cover.len() >= 8 && cover.starts_with(b"\x89PNG") {
            "image/png"
        } else if cover.len() >= 12 && &cover[..4] == b"RIFF" && &cover[8..12] == b"WEBP" {
            "image/webp"
        } else if cover.starts_with(b"GIF87a") || cover.starts_with(b"GIF89a") {
            "image/gif"
        } else {
            match std::path::Path::new(cover_path)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
                .as_str()
            {
                "png" => "image/png",
                "webp" => "image/webp",
                "gif" => "image/gif",
                _ => "image/jpeg",
            }
        };
        Some((cover, mime))
    } else {
        embedded_cover
            .as_ref()
            .map(|(data, mime)| (data.as_slice(), mime.as_str()))
    };
    let tag = id3::fresh(&metadata_fields(&metadata, fields), cover, check)?;
    let tag_size = tag.len() as u32;
    let mut chunk = if aiff {
        b"ID3 ".to_vec()
    } else {
        b"id3 ".to_vec()
    };
    chunk.extend(if aiff {
        tag_size.to_be_bytes()
    } else {
        tag_size.to_le_bytes()
    });
    chunk.extend(tag);
    if tag_size & 1 == 1 {
        chunk.push(0)
    }
    body_size += chunk.len() as u64;
    let size = u32::try_from(body_size).map_err(|_| "RIFF container exceeds 32-bit size")?;
    sections.push(Section {
        start: 4,
        end: 8,
        data: if aiff {
            size.to_be_bytes()
        } else {
            size.to_le_bytes()
        }
        .to_vec(),
    });
    // Go drops an incomplete trailing chunk header, then appends the new ID3.
    sections.push(Section {
        start: start.min(length),
        end: length,
        data: chunk,
    });
    Ok(sections)
}
