//! Bounded, seek-based implementation of Go's FLAC/MP4 quality probe.

mod audio;
pub mod hires;
pub(crate) mod mp4;

pub(crate) use audio::{adts_quality, is_adts_frame, mp3_quality, ogg_quality, riff_quality};

use serde::Serialize;
use std::io::{Read, Seek, SeekFrom};

#[derive(Debug, Default, PartialEq, Serialize)]
pub struct AudioQuality {
    pub bit_depth: i64,
    pub sample_rate: i64,
    pub total_samples: i64,
    pub duration: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub bitrate: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub codec: String,
}

fn is_zero(value: &i64) -> bool {
    *value == 0
}

pub fn probe_quality(
    file: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AudioQuality, String> {
    check()?;
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut marker = read_go::<4>(file).map_err(|e| format!("failed to read marker: {e}"))?;
    if &marker[..3] == b"ID3" {
        // Some taggers put an ID3v2 tag in front of the FLAC stream.
        let mut header = [0; 10];
        header[..4].copy_from_slice(&marker);
        header[4..].copy_from_slice(&read_go::<6>(file)?);
        if let Some(length) = crate::tags::v2_tag_length(&header) {
            file.seek(SeekFrom::Start(length))
                .map_err(|e| e.to_string())?;
            marker = read_go::<4>(file).map_err(|e| format!("failed to read marker: {e}"))?;
        }
    }
    if &marker == b"fLaC" {
        let header = read_go::<4>(file).map_err(|e| format!("failed to read header: {e}"))?;
        if header[0] & 0x7f != 0 {
            return Err("first block is not STREAMINFO".into());
        }
        let info = read_go::<34>(file).map_err(|e| format!("failed to read STREAMINFO: {e}"))?;
        return Ok(flac_quality(&info));
    }
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let header = read_go::<8>(file).map_err(|e| format!("failed to read header: {e}"))?;
    if &header[4..] == b"ftyp" {
        return probe_mp4_quality(file, check);
    }
    Err("unsupported file format (not FLAC or M4A)".into())
}

/// MP4-family descriptor paths may lack an ftyp box, as in Go's GetM4AQuality.
pub fn probe_mp4_quality(
    file: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AudioQuality, String> {
    mp4::probe(file, check)
}

fn flac_quality(info: &[u8; 34]) -> AudioQuality {
    let packed = u64::from_be_bytes(info[10..18].try_into().expect("STREAMINFO fields"));
    let rate = (packed >> 44) as i64;
    let samples = (packed & ((1 << 36) - 1)) as i64;
    AudioQuality {
        bit_depth: ((packed >> 36) & 31) as i64 + 1,
        sample_rate: rate,
        total_samples: samples,
        duration: if rate > 0 { samples / rate } else { 0 },
        codec: "flac".into(),
        ..AudioQuality::default()
    }
}

// Go's marker/STREAMINFO reader accepts a file that ends inside the buffer and
// leaves the rest zero-initialized. Preserve that for truncated files, but keep
// reading after a short read: a provider or FUSE descriptor may return fewer
// bytes than asked while more follow, and zeros would then be real quality.
fn read_go<const N: usize>(file: &mut impl Read) -> Result<[u8; N], String> {
    let mut bytes = [0; N];
    let mut length = 0;
    while length < N {
        match file.read(&mut bytes[length..]) {
            Ok(0) => break,
            Ok(count) => length += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    if length == 0 {
        Err("EOF".into())
    } else {
        Ok(bytes)
    }
}

fn read_at<const N: usize>(file: &mut (impl Read + Seek), offset: u64) -> Result<[u8; N], String> {
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| e.to_string())?;
    let mut bytes = [0; N];
    file.read_exact(&mut bytes).map_err(|e| {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            "EOF".into()
        } else {
            e.to_string()
        }
    })?;
    Ok(bytes)
}
