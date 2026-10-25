use super::{
    Fields, MAX_TAG_BYTES, copy, edit_comments, parse_comments, picture, put_string, seek,
    set_comment,
};
use crate::tags::containers::OggPage;
use base64::{Engine, engine::general_purpose::STANDARD};
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::LazyLock;

type Check<'a> = &'a dyn Fn() -> Result<(), String>;

fn read_page(source: &mut impl Read) -> Result<Option<OggPage>, String> {
    let page = OggPage::read(source)?;
    if page.as_ref().is_some_and(|page| page.header[4] != 0) {
        return Err("invalid ogg page".into());
    }
    Ok(page)
}

fn write_page(page: &OggPage, output: &mut impl Write, check: Check<'_>) -> Result<(), String> {
    check()?;
    let mut bytes = Vec::with_capacity(page.len());
    bytes.extend(page.header);
    bytes[22..26].fill(0);
    bytes[26] = page.segments.len() as u8;
    bytes.extend(&page.segments);
    bytes.extend(&page.data);
    static CRC: LazyLock<[u32; 256]> = LazyLock::new(|| {
        std::array::from_fn(|index| {
            let mut value = (index as u32) << 24;
            for _ in 0..8 {
                value = (value << 1)
                    ^ if value & 0x8000_0000 != 0 {
                        0x04c1_1db7
                    } else {
                        0
                    };
            }
            value
        })
    });
    let crc = bytes.iter().fold(0_u32, |crc, byte| {
        (crc << 8) ^ CRC[((crc >> 24) as u8 ^ byte) as usize]
    });
    bytes[22..26].copy_from_slice(&crc.to_le_bytes());
    output.write_all(&bytes).map_err(|error| error.to_string())
}

pub(super) fn rewrite(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: Check<'_>,
) -> Result<(), String> {
    let first = read_page(source)?.ok_or("ogg stream too short")?;
    let (opus, packet_count) = if first.data.starts_with(b"OpusHead") {
        (true, 2)
    } else if first.data.starts_with(b"\x01vorbis") {
        (false, 3)
    } else {
        return Err("unsupported ogg codec".into());
    };
    let serial = &first.header[14..18];
    let mut packets = Vec::new();
    let mut current = Vec::new();
    let mut page = first.clone();
    let mut header_bytes = 0;
    let mut header_pages = 0;
    loop {
        check()?;
        header_pages += 1;
        header_bytes += page.len();
        if header_bytes > MAX_TAG_BYTES {
            return Err("Ogg headers exceed 64 MiB".into());
        }
        if &page.header[14..18] != serial {
            return Err("multiplexed ogg streams are not supported".into());
        }
        let mut offset = 0;
        for (index, length) in page.segments.iter().copied().enumerate() {
            let end = offset + usize::from(length);
            current.extend_from_slice(&page.data[offset..end]);
            offset = end;
            if length < 255 {
                packets.push(std::mem::take(&mut current));
                if packets.len() == packet_count {
                    if index + 1 != page.segments.len() {
                        return Err("header packet shares a page with audio".into());
                    }
                    break;
                }
            }
        }
        if packets.len() == packet_count {
            break;
        }
        if header_pages >= 1024 {
            return Err("ogg header spans too many pages".into());
        }
        page = read_page(source)?.ok_or("incomplete ogg header packets")?;
    }
    let prefix: &[u8] = if opus { b"OpusTags" } else { b"\x03vorbis" };
    let body = packets[1]
        .strip_prefix(prefix)
        .ok_or("comment header not found")?;
    let (vendor, mut comments) = parse_comments(body)?;
    edit_comments(&mut comments, fields);
    if opus {
        opus_gain(&mut comments, fields)?;
    }
    if let Some(cover) = cover
        && let Some(picture) = picture(cover, check)?
    {
        set_comment(
            &mut comments,
            "METADATA_BLOCK_PICTURE",
            &STANDARD.encode(picture),
        );
    }
    let length = prefix.len()
        + 8
        + vendor.len()
        + comments
            .iter()
            .map(|comment| 4 + comment.len())
            .sum::<usize>()
        + usize::from(!opus);
    if length > MAX_TAG_BYTES {
        return Err("Ogg comments exceed 64 MiB".into());
    }
    let mut comment = prefix.to_vec();
    put_string(&mut comment, &vendor);
    comment.extend((comments.len() as u32).to_le_bytes());
    for value in comments {
        put_string(&mut comment, &value);
    }
    if !opus {
        comment.push(1);
    }
    packets[1] = comment;
    // Retain the BOS page (including OpusHead output gain) and the Vorbis
    // setup packet; only the comment/setup pages are repaginated.
    write_page(&first, output, check)?;
    let next_sequence = write_headers(&packets[1..], serial, output, check)?;
    if next_sequence as usize == header_pages {
        seek(source, SeekFrom::Start(header_bytes as u64))?;
        return copy(source, output, None, check);
    }
    let mut sequence = next_sequence;
    while let Some(mut page) = read_page(source)? {
        check()?;
        if &page.header[14..18] != serial {
            return Err("multiplexed ogg streams are not supported".into());
        }
        page.header[18..22].copy_from_slice(&sequence.to_le_bytes());
        sequence = sequence.wrapping_add(1);
        write_page(&page, output, check)?;
    }
    check()
}

fn write_headers(
    packets: &[Vec<u8>],
    serial: &[u8],
    output: &mut impl Write,
    check: Check<'_>,
) -> Result<u32, String> {
    let mut page = OggPage {
        header: [0; 27],
        segments: Vec::new(),
        data: Vec::new(),
    };
    page.header[..4].copy_from_slice(b"OggS");
    page.header[14..18].copy_from_slice(serial);
    let mut sequence = 1_u32;
    for packet in packets {
        let mut rest = packet.as_slice();
        loop {
            let count = rest.len().min(255);
            page.segments.push(count as u8);
            page.data.extend_from_slice(&rest[..count]);
            rest = &rest[count..];
            if page.segments.len() == 255 {
                page.header[18..22].copy_from_slice(&sequence.to_le_bytes());
                write_page(&page, output, check)?;
                sequence = sequence.wrapping_add(1);
                page.segments.clear();
                page.data.clear();
                page.header[5] = u8::from(count == 255);
            }
            if count < 255 {
                break;
            }
        }
    }
    if !page.segments.is_empty() {
        page.header[18..22].copy_from_slice(&sequence.to_le_bytes());
        write_page(&page, output, check)?;
        sequence = sequence.wrapping_add(1);
    }
    Ok(sequence)
}

fn opus_gain(comments: &mut Vec<Vec<u8>>, fields: &Fields) -> Result<(), String> {
    for (scope, upper) in [("track", "TRACK"), ("album", "ALBUM")] {
        let Some(raw) = fields.get(&format!("replaygain_{scope}_gain")) else {
            continue;
        };
        let raw = raw.trim();
        let value = if raw.is_empty() {
            String::new()
        } else {
            let db = raw.strip_suffix("dB").unwrap_or(raw).trim().parse::<f64>();
            let q = db.map(|db| ((db - 5.0) * 256.0).round());
            match q {
                Ok(q) if q.is_finite() && (-32768.0..=32767.0).contains(&q) => {
                    (q as i32).to_string()
                }
                _ => return Err(format!("invalid Opus {scope} ReplayGain: {raw:?}")),
            }
        };
        set_comment(comments, &format!("R128_{upper}_GAIN"), &value);
        set_comment(comments, &format!("REPLAYGAIN_{upper}_GAIN"), "");
        set_comment(comments, &format!("REPLAYGAIN_{upper}_PEAK"), "");
    }
    Ok(())
}
