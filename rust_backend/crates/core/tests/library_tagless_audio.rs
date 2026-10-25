use mornye_core::tags::{read_library_metadata, rewrite_audio_tags};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, Cursor, Read, Seek, SeekFrom};

fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    [
        ((body.len() + 8) as u32).to_be_bytes().as_slice(),
        kind,
        body,
    ]
    .concat()
}

fn m4a(genre: Option<&str>) -> Vec<u8> {
    let mut entry = [0; 28];
    entry[24..26].copy_from_slice(&44_100_u16.to_be_bytes());
    let mut movie = atom(b"mp4a", &entry);
    if let Some(genre) = genre {
        movie.extend(atom(
            b"meta",
            &[
                &[0; 4],
                atom(
                    b"ilst",
                    &atom(
                        b"\xa9gen",
                        &atom(b"data", &[&[0; 8], genre.as_bytes()].concat()),
                    ),
                )
                .as_slice(),
            ]
            .concat(),
        ));
    }
    [
        atom(b"ftyp", b"isom\0\0\0\0"),
        atom(b"moov", &movie),
        atom(b"mdat", &[0; 256]),
    ]
    .concat()
}

fn mp3() -> Vec<u8> {
    // MPEG-1 Layer III, 128 kbps, 44.1 kHz. No ID3v1/v2 tags.
    let mut frame = vec![0; 417];
    frame[..4].copy_from_slice(&[0xff, 0xfb, 0x90, 0]);
    frame.repeat(100)
}

fn flac() -> Vec<u8> {
    let mut data = b"fLaC\x80\0\0\x22".to_vec();
    let mut info = [0; 34];
    let packed = (44_100_u64 << 44) | (1_u64 << 41) | (15_u64 << 36) | 44_100;
    info[10..18].copy_from_slice(&packed.to_be_bytes());
    data.extend(info);
    data.extend([0xff, 0xf8]);
    data
}

fn scan(data: Vec<u8>, path: &str, hint: &str) -> Value {
    read_library_metadata(&mut Cursor::new(data), path, hint, "scan", 0, &|| Ok(())).unwrap()
}

#[test]
fn readable_untagged_audio_uses_the_display_name_without_workspace_guesses() {
    for (extension, data) in [("m4a", m4a(None)), ("mp3", mp3()), ("flac", flac())] {
        let hint = format!("Title - Artist.{extension}");
        for path in [
            "/proc/self/fd/42".to_owned(),
            format!("/cache/native-media-work/staged.{extension}"),
        ] {
            let metadata = scan(data.clone(), &path, &hint);
            assert_eq!(metadata["trackName"], "Title - Artist", "{extension}");
            assert_eq!(metadata["artistName"], "Unknown Artist");
            assert_eq!(metadata["albumName"], "Unknown Album");
            assert_eq!(metadata["sampleRate"], 44_100);
            assert!(metadata.get("metadataFromFilename").is_none());
            assert!(metadata.get("metadataReadError").is_none());
        }
    }
}

#[test]
fn m4a_with_only_genre_keeps_its_tags_without_requiring_a_title() {
    let metadata = scan(m4a(Some("Rock")), "/proc/self/fd/42", "Song.m4a");
    assert_eq!(metadata["genre"], "Rock");
    assert_eq!(metadata["trackName"], "Song");
    assert!(metadata.get("metadataFromFilename").is_none());
}

#[test]
fn mp3_with_only_album_keeps_its_tags_without_requiring_title_or_artist() {
    let mut tagged = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(mp3()),
        &mut tagged,
        "mp3",
        &BTreeMap::from([("album".into(), "Album".into())]),
        None,
        &|| Ok(()),
    )
    .unwrap();
    let metadata = scan(tagged, "/proc/self/fd/42", "Song.mp3");
    assert_eq!(metadata["albumName"], "Album");
    assert!(metadata.get("metadataFromFilename").is_none());
}

#[test]
fn invalid_audio_remains_rejected_and_exposes_the_parser_failure() {
    for extension in ["flac", "mp3", "m4a"] {
        let metadata = scan(
            vec![0; 256],
            "/proc/self/fd/42",
            &format!("Song.{extension}"),
        );
        assert_eq!(metadata["metadataFromFilename"], true, "{extension}");
        assert!(!metadata["metadataReadError"].as_str().unwrap().is_empty());
    }
}

struct RevokedAudio(Cursor<Vec<u8>>);

impl Read for RevokedAudio {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "revoked document",
        ))
    }
}

impl Seek for RevokedAudio {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.0.seek(position)
    }
}

#[test]
fn io_failure_and_cancellation_never_become_tagless_success() {
    let error = read_library_metadata(
        &mut RevokedAudio(Cursor::new(mp3())),
        "/proc/self/fd/42",
        "Song.mp3",
        "scan",
        0,
        &|| Ok(()),
    )
    .unwrap_err();
    assert!(error.contains("revoked document"));
    assert_eq!(
        read_library_metadata(
            &mut Cursor::new(m4a(None)),
            "/proc/self/fd/42",
            "Song.m4a",
            "scan",
            0,
            &|| Err("cancelled".into()),
        )
        .unwrap_err(),
        "cancelled"
    );
}
