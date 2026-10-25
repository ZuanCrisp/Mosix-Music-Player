use spotiflac_core::tags::{embed_flac_metadata, read_audio_tags, rewrite_audio_tags};
use std::collections::BTreeMap;
use std::io::Cursor;

const PAYLOAD: &[u8] = b"\xff\xf8\x12\x34unchanged audio payload";
const CREDITS: &str = "Artist A, Artist B & Artist C";

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

fn tagged(format: &str, mode: &str) -> (String, String) {
    let fields = BTreeMap::from([
        ("title".into(), "Example".into()),
        ("artist".into(), CREDITS.into()),
        ("album_artist".into(), CREDITS.into()),
        ("artist_tag_mode".into(), mode.into()),
    ]);
    let mut output = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(source(format)),
        &mut output,
        format,
        &fields,
        None,
        &|| Ok(()),
    )
    .unwrap();
    let tags = read_audio_tags(&mut Cursor::new(&output), format, &|| Ok(())).unwrap();
    (tags.artist, tags.album_artist)
}

#[test]
fn primary_mode_keeps_only_the_first_artist_in_every_native_writer() {
    for format in ["flac", "mp3", "m4a", "opus", "ape", "wav", "aiff"] {
        assert_eq!(
            tagged(format, "primary"),
            ("Artist A".into(), "Artist A".into()),
            "{format}"
        );
        // Mode values are matched like split_vorbis: trimmed, any case.
        assert_eq!(tagged(format, " Primary ").0, "Artist A", "{format}");
        assert_eq!(
            tagged(format, "joined"),
            (CREDITS.into(), CREDITS.into()),
            "{format}"
        );
    }
}

#[test]
fn primary_mode_applies_to_flac_download_embedding() {
    let fields = BTreeMap::from([
        ("TITLE".into(), "Example".into()),
        ("ARTIST".into(), "Calle 24, Chino Pacas".into()),
        ("ALBUMARTIST".into(), "Calle 24 feat. Chino Pacas".into()),
    ]);
    let mut output = Vec::new();
    embed_flac_metadata(
        &mut Cursor::new(source("flac")),
        &mut output,
        &fields,
        "primary",
        None,
        &|| Ok(()),
    )
    .unwrap();
    let tags = read_audio_tags(&mut Cursor::new(&output), "flac", &|| Ok(())).unwrap();
    assert_eq!(tags.artist, "Calle 24");
    assert_eq!(tags.album_artist, "Calle 24");
    assert!(output.ends_with(PAYLOAD));
    let comments = String::from_utf8_lossy(&output);
    assert_eq!(
        comments.matches("ARTIST=").count(),
        2,
        "one ARTIST, one ALBUMARTIST"
    );
}
