use spotiflac_core::tags::{
    extract_cover, read_audio_tags, rewrite_audio_tags, rewrite_m4a_freeform,
};
use std::collections::BTreeMap;
use std::io::Cursor;

const PAYLOAD: &[u8] = b"\xff\xf8\x12\x34unchanged audio payload";
const COVER: &[u8] = b"\xff\xd8\xff\xd9";
const GAIN_FIELDS: [&str; 4] = [
    "replaygain_track_gain",
    "replaygain_track_peak",
    "replaygain_album_gain",
    "replaygain_album_peak",
];

fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    [
        ((body.len() + 8) as u32).to_be_bytes().as_slice(),
        kind,
        body,
    ]
    .concat()
}

fn ogg_page(packet: &[u8], sequence: u32, flags: u8) -> Vec<u8> {
    let mut header = vec![0; 27];
    header[..4].copy_from_slice(b"OggS");
    header[5] = flags;
    header[14..18].copy_from_slice(&1_u32.to_le_bytes());
    header[18..22].copy_from_slice(&sequence.to_le_bytes());
    header[26] = 1;
    header.push(packet.len() as u8);
    header.extend(packet);
    header
}

fn source(format: &str) -> Vec<u8> {
    match format {
        "flac" => [b"fLaC\x80\0\0\x22".as_slice(), &[0; 34], PAYLOAD].concat(),
        "mp3" | "ape" => PAYLOAD.to_vec(),
        "m4a" => [
            atom(b"ftyp", b"M4A \0\0\0\0"),
            atom(b"moov", &[]),
            atom(b"mdat", PAYLOAD),
        ]
        .concat(),
        "opus" => [
            ogg_page(b"OpusHead\x01\x02\0\0\x80\xbb\0\0\0\0\0", 0, 2),
            ogg_page(b"OpusTags\0\0\0\0\0\0\0\0", 1, 0),
            ogg_page(PAYLOAD, 2, 4),
        ]
        .concat(),
        "wav" | "aiff" => {
            let aiff = format == "aiff";
            let mut body = if aiff { b"AIFFSSND" } else { b"WAVEdata" }.to_vec();
            let length = PAYLOAD.len() as u32;
            body.extend(if aiff {
                length.to_be_bytes()
            } else {
                length.to_le_bytes()
            });
            body.extend(PAYLOAD);
            if length % 2 == 1 {
                body.push(0);
            }
            let length = body.len() as u32;
            [
                if aiff { b"FORM" } else { b"RIFF" }.as_slice(),
                &if aiff {
                    length.to_be_bytes()
                } else {
                    length.to_le_bytes()
                },
                &body,
            ]
            .concat()
        }
        _ => unreachable!(),
    }
}

#[test]
fn removal_preserves_audio_artwork_and_other_metadata_in_native_containers() {
    for format in ["flac", "mp3", "m4a", "opus", "ape", "wav", "aiff"] {
        let fields = BTreeMap::from([
            ("title".into(), "Preserved title".into()),
            ("artist".into(), "Preserved artist".into()),
            ("lyrics".into(), "Preserved lyrics".into()),
            ("cover_path".into(), "cover.jpg".into()),
            (GAIN_FIELDS[0].into(), "-6.00 dB".into()),
            (GAIN_FIELDS[1].into(), "0.950000".into()),
            (GAIN_FIELDS[2].into(), "-4.00 dB".into()),
            (GAIN_FIELDS[3].into(), "0.980000".into()),
        ]);
        let empty = GAIN_FIELDS.map(|key| (key.into(), String::new())).into();
        let mut tagged = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(source(format)),
            &mut tagged,
            format,
            &fields,
            Some(COVER),
            &|| Ok(()),
        )
        .unwrap();
        let before = read_audio_tags(&mut Cursor::new(&tagged), format, &|| Ok(())).unwrap();
        assert!(!before.replay_gain_track_gain.is_empty(), "{format}");
        assert!(!before.replay_gain_album_gain.is_empty(), "{format}");

        for freeform in [false, true] {
            if freeform && format != "m4a" {
                continue;
            }
            let mut removed = Vec::new();
            if freeform {
                assert!(
                    rewrite_m4a_freeform(
                        &mut Cursor::new(&tagged),
                        &mut removed,
                        &empty,
                        true,
                        &|| Ok(()),
                    )
                    .unwrap()
                );
            } else {
                rewrite_audio_tags(
                    &mut Cursor::new(&tagged),
                    &mut removed,
                    format,
                    &empty,
                    None,
                    &|| Ok(()),
                )
                .unwrap();
            }
            let after = read_audio_tags(&mut Cursor::new(&removed), format, &|| Ok(())).unwrap();
            assert!(after.replay_gain_track_gain.is_empty(), "{format}");
            assert!(after.replay_gain_track_peak.is_empty(), "{format}");
            assert!(after.replay_gain_album_gain.is_empty(), "{format}");
            assert!(after.replay_gain_album_peak.is_empty(), "{format}");
            let mut expected = before.clone();
            expected.replay_gain_track_gain.clear();
            expected.replay_gain_track_peak.clear();
            expected.replay_gain_album_gain.clear();
            expected.replay_gain_album_peak.clear();
            assert_eq!(after, expected, "{format}");
            if matches!(format, "flac" | "mp3" | "m4a" | "opus") {
                assert_eq!(
                    extract_cover(&mut Cursor::new(&removed), format, &|| Ok(()))
                        .unwrap()
                        .data,
                    COVER,
                    "{format}"
                );
            } else {
                assert!(
                    removed.windows(COVER.len()).any(|part| part == COVER),
                    "{format}"
                );
            }
            assert_eq!(
                removed
                    .windows(PAYLOAD.len())
                    .filter(|part| *part == PAYLOAD)
                    .count(),
                1,
                "{format}"
            );
            for tag in [
                "REPLAYGAIN_",
                "R128_TRACK_GAIN",
                "R128_ALBUM_GAIN",
                "ITUNNORM",
            ] {
                assert!(
                    !String::from_utf8_lossy(&removed)
                        .to_uppercase()
                        .contains(tag),
                    "{format}: {tag}"
                );
            }
        }
    }
}

#[test]
fn partial_empty_m4a_updates_do_not_remove_existing_gain() {
    let fields = BTreeMap::from([(GAIN_FIELDS[0].into(), "-6.00 dB".into())]);
    let mut tagged = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(source("m4a")),
        &mut tagged,
        "m4a",
        &fields,
        None,
        &|| Ok(()),
    )
    .unwrap();
    let mut output = Vec::new();
    let empty = BTreeMap::from([(GAIN_FIELDS[0].into(), String::new())]);
    assert!(
        !rewrite_m4a_freeform(
            &mut Cursor::new(&tagged),
            &mut output,
            &empty,
            true,
            &|| Ok(())
        )
        .unwrap()
    );
    assert!(output.is_empty());
}

#[test]
fn removal_can_clear_the_last_ape_tags() {
    let fields = BTreeMap::from([(GAIN_FIELDS[0].into(), "-6.00 dB".into())]);
    let mut tagged = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(PAYLOAD),
        &mut tagged,
        "ape",
        &fields,
        None,
        &|| Ok(()),
    )
    .unwrap();
    let empty = GAIN_FIELDS.map(|key| (key.into(), String::new())).into();
    let mut id3v1 = b"TAGPreserved legacy title".to_vec();
    id3v1.resize(128, 0);
    for suffix in [b"".as_slice(), id3v1.as_slice()] {
        let input = [tagged.as_slice(), suffix].concat();
        let mut removed = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(&input),
            &mut removed,
            "ape",
            &empty,
            None,
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(removed, [PAYLOAD, suffix].concat());
    }
}

#[test]
fn riff_removal_preserves_unrecognized_id3_frames() {
    // A private ID3 frame that is deliberately absent from AudioMetadata.
    let private = b"private-owner\0preserved bytes";
    let mut frame = b"PRIV\0\0\0".to_vec();
    frame.push(private.len() as u8);
    frame.extend([0, 0]);
    frame.extend(private);
    let mut tag = b"ID3\x04\0\0\0\0\0".to_vec();
    tag.push(frame.len() as u8);
    tag.extend(frame);
    for format in ["wav", "aiff"] {
        let aiff = format == "aiff";
        let mut input = source(format);
        input.extend(b"ID3 ");
        let size = tag.len() as u32;
        input.extend(if aiff {
            size.to_be_bytes()
        } else {
            size.to_le_bytes()
        });
        input.extend(&tag);
        if size & 1 == 1 {
            input.push(0);
        }
        let size = (input.len() - 8) as u32;
        input[4..8].copy_from_slice(&if aiff {
            size.to_be_bytes()
        } else {
            size.to_le_bytes()
        });
        let empty = GAIN_FIELDS.map(|key| (key.into(), String::new())).into();
        let mut removed = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(&input),
            &mut removed,
            format,
            &empty,
            None,
            &|| Ok(()),
        )
        .unwrap();
        assert!(
            removed.windows(private.len()).any(|part| part == private),
            "{format}"
        );
        assert!(
            removed.windows(PAYLOAD.len()).any(|part| part == PAYLOAD),
            "{format}"
        );
    }
}
