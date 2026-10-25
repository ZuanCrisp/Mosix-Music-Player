use mornye_core::tags::{embed_flac_metadata, extract_cover, read_audio_tags, rewrite_audio_tags};
use std::collections::BTreeMap;
use std::io::Cursor;

const PAYLOAD: &[u8] = b"\xff\xf8\x12\x34unchanged audio payload";
const CREDITS: &str = "Artist A, Artist B & Artist C";

#[test]
fn high_resolution_artwork_replaces_embedded_thumbnails_without_changing_audio() {
    let image = |size| {
        let mut output = Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(size, size)
            .write_to(&mut output, image::ImageFormat::Png)
            .unwrap();
        output.into_inner()
    };
    let thumbnail = image(300);
    let full_size = image(1200);
    let fields = BTreeMap::from([("title".into(), "Example".into())]);
    for format in ["flac", "mp3", "m4a", "opus", "ogg", "wav", "aiff"] {
        let original = source(if format == "ogg" { "opus" } else { format });
        let mut low_resolution = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(original),
            &mut low_resolution,
            format,
            &fields,
            Some(&thumbnail),
            &|| Ok(()),
        )
        .unwrap();
        let mut output = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(low_resolution),
            &mut output,
            format,
            &fields,
            Some(&full_size),
            &|| Ok(()),
        )
        .unwrap();
        let cover = extract_cover(&mut Cursor::new(&output), format, &|| Ok(())).unwrap();
        assert_eq!(cover.data.len(), full_size.len(), "{format}");
        assert_eq!(cover.data, full_size, "{format}");
        let decoded = image::load_from_memory(&cover.data).unwrap();
        assert_eq!(
            (decoded.width(), decoded.height()),
            (1200, 1200),
            "{format}"
        );
        assert_eq!(
            read_audio_tags(&mut Cursor::new(&output), format, &|| Ok(()))
                .unwrap()
                .title,
            "Example"
        );
        assert!(
            output.windows(PAYLOAD.len()).any(|chunk| chunk == PAYLOAD),
            "{format}"
        );
    }
}

#[test]
fn custom_separators_round_trip_all_tag_writers_without_touching_audio() {
    for format in ["flac", "mp3", "m4a", "opus", "ape", "wav", "aiff"] {
        let fields = BTreeMap::from([
            ("title".into(), "Title, unchanged".into()),
            ("artist".into(), "A, B".into()),
            ("album_artist".into(), "C; D".into()),
            ("composer".into(), "E, F".into()),
            ("genre".into(), "Rock, Pop".into()),
            ("artist_tag_mode".into(), "split_vorbis".into()),
            ("artist_separator".into(), " / ".into()),
            ("album_artist_separator".into(), "; ".into()),
            ("composer_separator".into(), " | ".into()),
            ("genre_separator".into(), "; ".into()),
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
        let metadata = read_audio_tags(&mut Cursor::new(&output), format, &|| Ok(())).unwrap();
        assert_eq!(metadata.artist, "A / B", "{format}");
        assert_eq!(metadata.album_artist, "C; D", "{format}");
        assert_eq!(metadata.composer, "E | F", "{format}");
        assert_eq!(metadata.genre, "Rock; Pop", "{format}");
        assert_eq!(metadata.title, "Title, unchanged", "{format}");
        assert!(
            output.windows(PAYLOAD.len()).any(|chunk| chunk == PAYLOAD),
            "{format}"
        );
        assert!(
            !output
                .windows(b"_separator".len())
                .any(|chunk| chunk == b"_separator")
        );
    }
}

#[test]
fn download_embed_honors_separators_and_primary_artist_mode() {
    for mode in ["joined", "split_vorbis", "primary"] {
        let fields = BTreeMap::from([
            ("ARTIST".into(), "A, B".into()),
            ("COMPOSER".into(), "C, D".into()),
            ("artist_separator".into(), " / ".into()),
            ("composer_separator".into(), "; ".into()),
        ]);
        let mut output = Vec::new();
        embed_flac_metadata(
            &mut Cursor::new(source("flac")),
            &mut output,
            &fields,
            mode,
            None,
            &|| Ok(()),
        )
        .unwrap();
        let metadata = read_audio_tags(&mut Cursor::new(&output), "flac", &|| Ok(())).unwrap();
        assert_eq!(
            metadata.artist,
            if mode == "primary" { "A" } else { "A / B" }
        );
        assert_eq!(metadata.composer, "C; D");
        assert!(output.ends_with(PAYLOAD));
        assert!(
            !output
                .windows(b"_separator".len())
                .any(|chunk| chunk == b"_separator")
        );
    }
}

#[test]
fn separator_preferences_decode_without_changing_download_names() {
    let request = mornye_core::downloads::DownloadRequest::parse(
        r#"{"artist_name":"A, B","metadata_separators":{"artist":" / ","genre":"; "}}"#,
    )
    .unwrap();
    assert_eq!(request.artist_name, "A, B");
    assert_eq!(
        request.metadata_separators.as_ref().unwrap()["artist"],
        " / "
    );
    let restored =
        mornye_core::downloads::DownloadRequest::parse(&serde_json::to_string(&request).unwrap())
            .unwrap();
    assert_eq!(restored.metadata_separators, request.metadata_separators);
    assert!(
        mornye_core::downloads::DownloadRequest::parse("{}")
            .unwrap()
            .metadata_separators
            .is_none()
    );
}

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
