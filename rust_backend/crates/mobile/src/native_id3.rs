//! Compatibility byte operations used only by the FFmpeg fallback. These keep
//! unsupported ID3 headers unchanged instead of broadening the tag writer.
use base64::Engine;
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) fn execute(
    request: &Value,
    _bytes: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let path = request["file_path"]
        .as_str()
        .ok_or("Missing byte-operation file path")?;
    match request["operation"].as_str().unwrap_or_default() {
        "write_id3v23_lyrics" => {
            let lyrics = request["lyrics"].as_str().ok_or("Missing lyrics")?;
            write_lyrics(Path::new(path), lyrics, check)
                .map(|updated| json!({"updated": updated, "committed": updated}))
        }
        "build_metadata_picture" => {
            let data = fs::read(path).map_err(|e| e.to_string())?;
            let lower_path = path.to_lowercase();
            let png = data.len() >= 8 && data.starts_with(&[0x89, 0x50, 0x4e, 0x47]);
            let mime = if lower_path.ends_with(".png")
                || (!lower_path.ends_with(".jpg") && !lower_path.ends_with(".jpeg") && png)
            {
                "image/png"
            } else {
                "image/jpeg"
            };
            let length = u32::try_from(data.len()).map_err(|_| "Artwork is too large")?;
            let mut picture = Vec::with_capacity(32 + mime.len() + data.len());
            picture.extend_from_slice(&3_u32.to_be_bytes());
            picture.extend_from_slice(&(mime.len() as u32).to_be_bytes());
            picture.extend_from_slice(mime.as_bytes());
            picture.extend_from_slice(&[0; 20]);
            picture.extend_from_slice(&length.to_be_bytes());
            picture.extend_from_slice(&data);
            check()?;
            Ok(json!({"picture": base64::engine::general_purpose::STANDARD.encode(picture)}))
        }
        _ => Err("Unknown byte-operation".into()),
    }
}

fn write_lyrics(
    path: &Path,
    lyrics: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    let mut input = fs::File::open(path).map_err(|e| e.to_string())?;
    let size = input.metadata().map_err(|e| e.to_string())?.len();
    let mut header = [0; 10];
    let read = input.read(&mut header).map_err(|e| e.to_string())?;
    let mut audio_offset = 0;
    let updated = if read >= 10 && &header[..3] == b"ID3" {
        let Some(tag_size) = synchsafe(&header[6..10]) else {
            return Ok(false);
        };
        if header[3] != 3
            || header[5] & (0x80 | 0x40 | 0x20) != 0
            || tag_size > 32 << 20
            || tag_size as u64 + 10 > size
        {
            return Ok(false);
        }
        let mut payload = vec![0; tag_size];
        input.read_exact(&mut payload).map_err(|e| e.to_string())?;
        audio_offset = tag_size as u64 + 10;
        make_tag(&payload, lyrics)
    } else {
        make_tag(&[], lyrics)
    };
    let parent = path.parent().ok_or("Missing audio parent directory")?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let staging = parent.join(format!(".spotiflac-lyrics-{}-{nonce}", std::process::id()));
    fs::create_dir(&staging).map_err(|e| e.to_string())?;
    let output_path = staging.join("audio.mp3");
    let result = (|| {
        let mut output = fs::File::create(&output_path).map_err(|e| e.to_string())?;
        output.write_all(&updated).map_err(|e| e.to_string())?;
        input
            .seek(SeekFrom::Start(audio_offset))
            .map_err(|e| e.to_string())?;
        let mut buffer = [0; 64 * 1024];
        loop {
            check()?;
            let read = input.read(&mut buffer).map_err(|e| e.to_string())?;
            if read == 0 {
                break;
            }
            output
                .write_all(&buffer[..read])
                .map_err(|e| e.to_string())?;
        }
        output.sync_all().map_err(|e| e.to_string())?;
        drop(output);
        check()?;
        fs::rename(&output_path, path).map_err(|e| e.to_string())?;
        Ok(true)
    })();
    let _ = fs::remove_dir_all(staging);
    result
}

fn synchsafe(bytes: &[u8]) -> Option<usize> {
    if bytes.len() != 4 || bytes.iter().any(|byte| byte & 0x80 != 0) {
        return None;
    }
    Some(
        bytes
            .iter()
            .fold(0, |value, byte| value << 7 | usize::from(*byte)),
    )
}

fn make_tag(payload: &[u8], lyrics: &str) -> Vec<u8> {
    let mut preserved = Vec::with_capacity(payload.len());
    let mut offset = 0;
    while offset + 10 <= payload.len() {
        let id = &payload[offset..offset + 4];
        if !id
            .iter()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        {
            break;
        }
        let size = u32::from_be_bytes(
            payload[offset + 4..offset + 8]
                .try_into()
                .expect("frame size"),
        ) as usize;
        if size == 0 || size > payload.len() - offset - 10 {
            break;
        }
        if id != b"USLT" {
            preserved.extend_from_slice(&payload[offset..offset + 10 + size]);
        }
        offset += 10 + size;
    }
    let mut lyrics_payload = vec![1, b'e', b'n', b'g', 0xff, 0xfe, 0, 0, 0xff, 0xfe];
    for unit in lyrics.encode_utf16() {
        lyrics_payload.extend_from_slice(&unit.to_le_bytes());
    }
    preserved.extend_from_slice(b"USLT");
    preserved.extend_from_slice(&(lyrics_payload.len() as u32).to_be_bytes());
    preserved.extend_from_slice(&[0, 0]);
    preserved.extend_from_slice(&lyrics_payload);
    let mut tag = vec![b'I', b'D', b'3', 3, 0, 0];
    tag.extend(
        (0..4)
            .rev()
            .map(|index| ((preserved.len() >> (index * 7)) & 0x7f) as u8),
    );
    tag.extend(preserved);
    tag
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uslt_bytes_preserve_utf16_bom_language_and_surrogate_pairs() {
        let result = make_tag(&[], "A😀");
        assert_eq!(&result[..6], &[b'I', b'D', b'3', 3, 0, 0]);
        assert_eq!(&result[10..14], b"USLT");
        assert_eq!(
            &result[20..],
            &[
                1, b'e', b'n', b'g', 0xff, 0xfe, 0, 0, 0xff, 0xfe, 65, 0, 0x3d, 0xd8, 0, 0xde
            ]
        );
        assert_eq!(synchsafe(&result[6..10]).unwrap(), result.len() - 10);
    }

    #[test]
    fn lyric_replacement_preserves_other_frames_and_audio_tail() {
        let directory = std::env::temp_dir().join(format!("native-id3-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("track.mp3");
        let frame = [b'T', b'I', b'T', b'2', 0, 0, 0, 2, 0, 0, 0, b'A'];
        let initial = make_tag(&frame, "Old");
        let mut original = initial.clone();
        original.extend([0xff, 0xfb, 1, 2, 3]);
        fs::write(&path, original).unwrap();
        assert!(write_lyrics(&path, "New", &|| Ok(())).unwrap());
        let result = fs::read(&path).unwrap();
        assert_eq!(&result[10..22], &frame);
        assert_eq!(&result[result.len() - 5..], &[0xff, 0xfb, 1, 2, 3]);
        let mut unsupported = result.clone();
        unsupported[3] = 4;
        fs::write(&path, &unsupported).unwrap();
        assert!(!write_lyrics(&path, "Other", &|| Ok(())).unwrap());
        assert_eq!(fs::read(&path).unwrap(), unsupported);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn cancellation_during_audio_copy_leaves_original_and_no_staging() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("track.mp3");
        let original = vec![0x55; 256 * 1024];
        fs::write(&path, &original).unwrap();
        let calls = std::cell::Cell::new(0);
        let check = || {
            let count = calls.get() + 1;
            calls.set(count);
            if count == 3 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        };
        assert_eq!(write_lyrics(&path, "New", &check).unwrap_err(), "cancelled");
        assert_eq!(fs::read(path).unwrap(), original);
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn artwork_block_has_exact_mime_header_and_preserves_large_payloads() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cover.bin");
        let image = [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0x42];
        fs::write(&path, image).unwrap();
        let request = json!({"operation":"build_metadata_picture", "file_path": path});
        let result = execute(&request, None, &|| Ok(())).unwrap();
        let block = base64::engine::general_purpose::STANDARD
            .decode(result["picture"].as_str().unwrap())
            .unwrap();
        assert_eq!(&block[..8], &[0, 0, 0, 3, 0, 0, 0, 9]);
        assert_eq!(&block[8..17], b"image/png");
        assert_eq!(&block[17..37], &[0; 20]);
        assert_eq!(&block[37..41], &[0, 0, 0, 9]);
        assert_eq!(&block[41..], &image);
        fs::File::create(&path)
            .unwrap()
            .set_len((4 << 20) + 1)
            .unwrap();
        let result = execute(&request, None, &|| Ok(())).unwrap();
        let block = base64::engine::general_purpose::STANDARD
            .decode(result["picture"].as_str().unwrap())
            .unwrap();
        assert_eq!(&block[8..18], b"image/jpeg");
        assert_eq!(
            u32::from_be_bytes(block[38..42].try_into().unwrap()),
            (4 << 20) + 1
        );
        assert_eq!(block.len() - 42, (4 << 20) + 1);
    }
}
