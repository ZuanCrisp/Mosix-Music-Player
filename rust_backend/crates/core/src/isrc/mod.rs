//! Duplicate detection retains Go's cache and format-specific ISRC contracts.

mod cache;
mod native_files;
pub use cache::{FileStamp, IndexCache, IndexFiles};
pub use native_files::NativeFiles;

use std::io::{Read, Seek, SeekFrom};

pub fn supported(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "flac" | "mp3" | "m4a" | "ogg" | "opus"
            )
        })
}

pub fn read_isrc(
    reader: &mut (impl Read + Seek),
    format: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    let interrupted = std::cell::RefCell::new(None);
    let checked = || {
        let result = check();
        if let Err(error) = &result {
            *interrupted.borrow_mut() = Some(error.clone());
        }
        result
    };
    checked()?;
    let value = if format == "flac" {
        read_flac(reader, &checked).unwrap_or_default()
    } else if matches!(format, "mp3" | "m4a" | "ogg" | "opus") {
        crate::tags::read_audio_tags(reader, format, &checked)
            .map(|metadata| metadata.isrc.trim().to_owned())
            .unwrap_or_default()
    } else {
        String::new()
    };
    if let Some(error) = interrupted.into_inner() {
        return Err(error);
    }
    check()?;
    Ok(value)
}

fn read_flac(
    reader: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    reader.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut header = [0; 4];
    reader.read_exact(&mut header).map_err(|e| e.to_string())?;
    if &header != b"fLaC" {
        return Ok(String::new());
    }
    loop {
        check()?;
        reader.read_exact(&mut header).map_err(|e| e.to_string())?;
        let length = u32::from_be_bytes([0, header[1], header[2], header[3]]);
        if header[0] & 0x7f == 4 {
            return comment_isrc(reader, length, check);
        }
        if header[0] & 0x80 != 0 {
            return Ok(String::new());
        }
        reader
            .seek(SeekFrom::Current(i64::from(length)))
            .map_err(|e| e.to_string())?;
    }
}

fn comment_isrc(
    reader: &mut (impl Read + Seek),
    mut remaining: u32,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    fn integer(reader: &mut impl Read, remaining: &mut u32) -> Result<u32, String> {
        *remaining = remaining.checked_sub(4).ok_or("truncated FLAC comment")?;
        let mut bytes = [0; 4];
        reader.read_exact(&mut bytes).map_err(|e| e.to_string())?;
        Ok(u32::from_le_bytes(bytes))
    }

    // The old reader rejected an incomplete block even when its first field
    // contained ISRC. Validate its extent before skipping irrelevant bytes.
    check()?;
    let start = reader.stream_position().map_err(|e| e.to_string())?;
    let size = reader.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
    if size.saturating_sub(start) < u64::from(remaining) {
        return Err("truncated FLAC comment block".into());
    }
    reader
        .seek(SeekFrom::Start(start))
        .map_err(|e| e.to_string())?;
    let vendor = integer(reader, &mut remaining)?;
    remaining = remaining
        .checked_sub(vendor)
        .ok_or("truncated FLAC vendor")?;
    reader
        .seek(SeekFrom::Current(i64::from(vendor)))
        .map_err(|e| e.to_string())?;
    let count = integer(reader, &mut remaining)?;
    for _ in 0..count {
        check()?;
        let length = integer(reader, &mut remaining)?;
        remaining = remaining
            .checked_sub(length)
            .ok_or("truncated FLAC field")?;
        // Accepted ISRC keys are four ASCII characters, except that long s
        // may replace S. Six bytes cover the longest accepted key and '='.
        let mut prefix = [0; 6];
        let prefix_len = (length as usize).min(prefix.len());
        reader
            .read_exact(&mut prefix[..prefix_len])
            .map_err(|e| e.to_string())?;
        if let Some(equal) = prefix[..prefix_len].iter().position(|byte| *byte == b'=')
            && std::str::from_utf8(&prefix[..equal])
                .ok()
                .is_some_and(isrc_key)
        {
            let mut value = Vec::with_capacity(length as usize - equal - 1);
            value.extend_from_slice(&prefix[equal + 1..prefix_len]);
            let tail = length as usize - prefix_len;
            value.resize(value.len() + tail, 0);
            let offset = prefix_len - equal - 1;
            for chunk in value[offset..].chunks_mut(64 * 1024) {
                check()?;
                reader.read_exact(chunk).map_err(|e| e.to_string())?;
            }
            return Ok(crate::text::utf8(&value).trim().to_owned());
        }
        reader
            .seek(SeekFrom::Current(i64::from(length) - prefix_len as i64))
            .map_err(|e| e.to_string())?;
    }
    Ok(String::new())
}

fn isrc_key(key: &str) -> bool {
    // EqualFold accepts long s but not dotless i; uppercasing alone differs.
    key.chars().count() == 4
        && key.chars().zip("ISRC".chars()).all(|(actual, expected)| {
            actual.eq_ignore_ascii_case(&expected) || (actual == 'ſ' && expected == 'S')
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn flac(comments: &[&[u8]]) -> Vec<u8> {
        let mut payload = 7_u32.to_le_bytes().to_vec();
        payload.extend_from_slice(b"Example");
        payload.extend_from_slice(&(comments.len() as u32).to_le_bytes());
        for comment in comments {
            payload.extend_from_slice(&(comment.len() as u32).to_le_bytes());
            payload.extend_from_slice(comment);
        }
        let mut bytes = b"fLaC\x84".to_vec();
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes()[1..]);
        bytes.extend(payload);
        bytes
    }

    #[test]
    fn streaming_comments_preserve_first_isrc_alias_and_utf8_contracts() {
        for (comments, expected) in [
            (
                vec![
                    b"TITLE=Example".as_slice(),
                    b"ISRC=  example  ",
                    b"ISRC=second",
                ],
                "example",
            ),
            (vec![b"ISRC=".as_slice(), b"ISRC=second"], ""),
            (vec!["IſRC=long-s".as_bytes()], "long-s"),
            (vec!["ıSRC=wrong".as_bytes(), b"isrc=correct"], "correct"),
            (vec![b"ISRC=\xffx".as_slice()], "\u{fffd}x"),
            (
                vec![b"ISRCX=wrong".as_slice(), b"LONGKEYISRC=wrong", b"ISRC"],
                "",
            ),
        ] {
            assert_eq!(
                read_isrc(&mut Cursor::new(flac(&comments)), "flac", &|| Ok(())).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn incomplete_block_and_malformed_field_lengths_remain_empty() {
        let bytes = flac(&[b"ISRC=example", b"TITLE=Example"]);
        for end in 0..bytes.len() {
            assert_eq!(
                read_isrc(&mut Cursor::new(&bytes[..end]), "flac", &|| Ok(())).unwrap(),
                ""
            );
        }
        for offset in [8, 23] {
            let mut invalid = bytes.clone();
            invalid[offset..offset + 4].copy_from_slice(&u32::MAX.to_le_bytes());
            assert_eq!(
                read_isrc(&mut Cursor::new(invalid), "flac", &|| Ok(())).unwrap(),
                ""
            );
        }
    }

    #[test]
    fn irrelevant_large_fields_are_skipped_and_reads_observe_cancellation() {
        struct Counted {
            source: Cursor<Vec<u8>>,
            bytes: usize,
        }
        impl Read for Counted {
            fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
                let count = self.source.read(bytes)?;
                self.bytes += count;
                Ok(count)
            }
        }
        impl Seek for Counted {
            fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
                self.source.seek(from)
            }
        }
        let unrelated = vec![b'x'; 2 << 20];
        let mut source = Counted {
            source: Cursor::new(flac(&[&unrelated, b"ISRC=example"])),
            bytes: 0,
        };
        assert_eq!(
            read_isrc(&mut source, "flac", &|| Ok(())).unwrap(),
            "example"
        );
        assert!(source.bytes < 128, "read {} irrelevant bytes", source.bytes);
        let checks = AtomicUsize::new(0);
        assert_eq!(
            read_isrc(&mut source, "flac", &|| {
                if checks.fetch_add(1, Ordering::SeqCst) >= 3 {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            }),
            Err("cancelled".into())
        );
    }
}
