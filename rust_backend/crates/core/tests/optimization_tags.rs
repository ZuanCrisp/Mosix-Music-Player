use spotiflac_core::tags::{
    AudioMetadata, extract_cover, read_audio_tags, read_library_metadata,
    read_library_metadata_with_cover,
};
use std::cell::Cell;
use std::io::{self, Cursor, Read, Seek, SeekFrom};

struct CountingReader {
    source: Cursor<Vec<u8>>,
    read_calls: usize,
    bytes_read: usize,
    seek_calls: usize,
}

impl CountingReader {
    fn new(data: Vec<u8>) -> Self {
        Self {
            source: Cursor::new(data),
            read_calls: 0,
            bytes_read: 0,
            seek_calls: 0,
        }
    }
}

impl Read for CountingReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.read_calls += 1;
        let count = self.source.read(buffer)?;
        self.bytes_read += count;
        Ok(count)
    }
}

impl Seek for CountingReader {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.seek_calls += 1;
        self.source.seek(position)
    }
}

fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut result = ((body.len() + 8) as u32).to_be_bytes().to_vec();
    result.extend(kind);
    result.extend(body);
    result
}

fn data_atom(value: &[u8]) -> Vec<u8> {
    let mut body = vec![0; 8];
    body.extend(value);
    atom(b"data", &body)
}

fn text_item(kind: &[u8; 4], value: &str) -> Vec<u8> {
    atom(kind, &data_atom(value.as_bytes()))
}

fn pair_item(kind: &[u8; 4], first: u16, second: u16) -> Vec<u8> {
    let mut value = vec![0, 0];
    value.extend(first.to_be_bytes());
    value.extend(second.to_be_bytes());
    atom(kind, &data_atom(&value))
}

fn flag_item(kind: &[u8; 4]) -> Vec<u8> {
    atom(kind, &data_atom(&[0, 0, 0, 1]))
}

fn freeform_item() -> Vec<u8> {
    let mut name = vec![0; 4];
    name.extend(b"ISRC");
    let mut body = atom(b"name", &name);
    body.extend(data_atom(b"EXAMPLE123456"));
    atom(b"----", &body)
}

fn dense_m4a() -> Vec<u8> {
    let mut ilst = Vec::new();
    for (kind, value) in [
        (*b"\xa9nam", "Dense title"),
        (*b"\xa9ART", "Dense artist"),
        (*b"\xa9alb", "Dense album"),
        (*b"aART", "Dense album artist"),
        (*b"\xa9day", "2026"),
        (*b"\xa9gen", "Example"),
        (*b"\xa9wrt", "Example composer"),
        (*b"\xa9cmt", "Example comment"),
        (*b"cprt", "Example copyright"),
        (*b"\xa9lyr", "Example lyrics"),
    ] {
        ilst.extend(text_item(&kind, value));
    }
    ilst.extend(pair_item(b"trkn", 3, 12));
    ilst.extend(pair_item(b"disk", 1, 2));
    ilst.extend(flag_item(b"rtng"));
    ilst.extend(flag_item(b"cpil"));
    ilst.extend(freeform_item());
    for index in 0..96_u8 {
        ilst.extend(atom(b"free", &[index; 8]));
    }

    let mut meta_body = vec![0; 4];
    meta_body.extend(atom(b"ilst", &ilst));
    let mut moov_body = atom(b"free", &[0; 16]);
    moov_body.extend(atom(b"meta", &meta_body));
    let mut result = atom(b"ftyp", &[0; 24]);
    result.extend(atom(b"moov", &moov_body));
    result.extend(atom(b"mdat", &vec![0; 4 << 20]));
    result
}

fn assert_dense_metadata(metadata: AudioMetadata) {
    assert_eq!(metadata.title, "Dense title");
    assert_eq!(metadata.artist, "Dense artist");
    assert_eq!(metadata.album, "Dense album");
    assert_eq!(metadata.album_artist, "Dense album artist");
    assert_eq!(metadata.date, "2026");
    assert_eq!(metadata.year, "2026");
    assert_eq!(metadata.genre, "Example");
    assert_eq!(metadata.composer, "Example composer");
    assert_eq!(metadata.comment, "Example comment");
    assert_eq!(metadata.copyright, "Example copyright");
    assert_eq!(metadata.lyrics, "Example lyrics");
    assert_eq!((metadata.track_number, metadata.total_tracks), (3, 12));
    assert_eq!((metadata.disc_number, metadata.total_discs), (1, 2));
    assert_eq!(metadata.isrc, "EXAMPLE123456");
    assert_eq!(metadata.album_type, "compilation");
    assert!(metadata.explicit);
}

#[test]
fn dense_mp4_reuses_buffered_reads_across_metadata_seeks() {
    let mut reader = CountingReader::new(dense_m4a());
    assert_dense_metadata(read_audio_tags(&mut reader, "m4a", &|| Ok(())).unwrap());
    assert!(
        reader.bytes_read < 64 << 10,
        "{} bytes read",
        reader.bytes_read
    );
    assert!(reader.read_calls <= 8, "{} reads", reader.read_calls);
    assert!(reader.seek_calls <= 8, "{} seeks", reader.seek_calls);
}

#[test]
fn dense_mp4_supports_a_descriptor_position_and_rejects_malformed_eof_and_cancel() {
    let data = dense_m4a();
    let mut descriptor = Cursor::new(data);
    descriptor.set_position(descriptor.get_ref().len() as u64);
    assert_dense_metadata(read_audio_tags(&mut descriptor, "m4a", &|| Ok(())).unwrap());

    let mut malformed = CountingReader::new(b"not an mp4".to_vec());
    assert!(read_audio_tags(&mut malformed, "m4a", &|| Ok(())).is_err());

    let mut truncated = dense_m4a();
    truncated.truncate(64);
    let mut eof = CountingReader::new(truncated);
    let error = read_audio_tags(&mut eof, "m4a", &|| Ok(())).unwrap_err();
    assert!(
        error.contains("EOF") || error.contains("not found"),
        "{error}"
    );
    assert!(eof.bytes_read < 64 << 10, "{} bytes read", eof.bytes_read);

    let checks = Cell::new(0);
    let mut canceled = CountingReader::new(dense_m4a());
    let error = read_audio_tags(&mut canceled, "m4a", &|| {
        let count = checks.get();
        checks.set(count + 1);
        if count >= 3 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    })
    .unwrap_err();
    assert_eq!(error, "cancelled");
    assert!(checks.get() > 3);
}

fn flac_block(kind: u8, last: bool, data: &[u8]) -> Vec<u8> {
    let mut result = vec![kind | (if last { 0x80 } else { 0 })];
    let length = (data.len() as u32).to_be_bytes();
    result.extend_from_slice(&length[1..]);
    result.extend_from_slice(data);
    result
}

fn flac_streaminfo() -> Vec<u8> {
    let mut info = vec![0; 34];
    info[..2].copy_from_slice(&4096_u16.to_be_bytes());
    info[2..4].copy_from_slice(&4096_u16.to_be_bytes());
    let packed = (44_100_u64 << 44) | (1_u64 << 41) | (15_u64 << 36) | 44_100;
    info[10..18].copy_from_slice(&packed.to_be_bytes());
    info
}

fn flac_comments(items: &[&str]) -> Vec<u8> {
    let mut result = 0_u32.to_le_bytes().to_vec();
    result.extend_from_slice(&(items.len() as u32).to_le_bytes());
    for item in items {
        result.extend_from_slice(&(item.len() as u32).to_le_bytes());
        result.extend_from_slice(item.as_bytes());
    }
    result
}

fn flac_picture(kind: u32, mime: &[u8], data: &[u8]) -> Vec<u8> {
    let mut result = kind.to_be_bytes().to_vec();
    result.extend_from_slice(&(mime.len() as u32).to_be_bytes());
    result.extend_from_slice(mime);
    result.extend_from_slice(&0_u32.to_be_bytes());
    result.extend_from_slice(&[0; 16]);
    result.extend_from_slice(&(data.len() as u32).to_be_bytes());
    result.extend_from_slice(data);
    result
}

fn flac_file(pictures: &[Vec<u8>]) -> Vec<u8> {
    let comments = flac_comments(&[
        "TITLE=Dense FLAC",
        "ARTIST=Example Artist",
        "ALBUM=Example Album",
        "ALBUMARTIST=Example Album Artist",
        "DATE=2026",
        "TRACKNUMBER=2/9",
        "DISCNUMBER=1/2",
        "GENRE=Example",
        "ISRC=EXAMPLE123456",
        "RELEASETYPE=album",
    ]);
    let mut result = b"fLaC".to_vec();
    result.extend(flac_block(0, false, &flac_streaminfo()));
    result.extend(flac_block(4, false, &comments));
    for picture in pictures {
        result.extend(flac_block(6, false, picture));
    }
    result.extend(flac_block(1, true, &[0; 8]));
    result.extend_from_slice(&[0xff, 0xf8]);
    result.extend_from_slice(&[0; 32]);
    result
}

fn valid_flac() -> Vec<u8> {
    flac_file(&[
        flac_picture(2, b"image/jpeg", b"\xff\xd8secondary"),
        flac_picture(3, b"image/png", b"\x89PNG\r\nfront-cover"),
    ])
}

#[test]
fn flac_combined_metadata_and_cover_match_separate_reads_with_less_io() {
    let data = valid_flac();
    let path = "/music/Example Album/Example Artist - Dense FLAC.flac";

    let mut metadata_reader = CountingReader::new(data.clone());
    let expected_metadata = read_library_metadata(
        &mut metadata_reader,
        path,
        "",
        "2026-09-14T00:00:00Z",
        42,
        &|| Ok(()),
    )
    .unwrap();
    let mut cover_reader = CountingReader::new(data.clone());
    let expected_cover = extract_cover(&mut cover_reader, "flac", &|| Ok(())).unwrap();

    let mut combined_reader = CountingReader::new(data);
    let (actual_metadata, actual_cover) = read_library_metadata_with_cover(
        &mut combined_reader,
        path,
        "",
        "2026-09-14T00:00:00Z",
        42,
        &|| Ok(()),
    )
    .unwrap();

    assert_eq!(actual_metadata, expected_metadata);
    assert_eq!(actual_metadata["trackName"], "Dense FLAC");
    assert_eq!(actual_metadata["artistName"], "Example Artist");
    assert_eq!(actual_metadata["bitDepth"], 16);
    assert_eq!(actual_metadata["sampleRate"], 44_100);
    assert_eq!(actual_metadata["duration"], 1);
    let actual_cover = actual_cover.expect("front cover");
    assert_eq!(actual_cover.data.as_slice(), expected_cover.data.as_slice());
    assert_eq!(actual_cover.mime, expected_cover.mime);
    assert_eq!(actual_cover.data, b"\x89PNG\r\nfront-cover");
    assert_eq!(actual_cover.mime, "image/png");

    let separate_bytes = metadata_reader.bytes_read + cover_reader.bytes_read;
    assert!(
        combined_reader.bytes_read < separate_bytes,
        "combined {} vs separate {} bytes",
        combined_reader.bytes_read,
        separate_bytes
    );
    let separate_reads = metadata_reader.read_calls + cover_reader.read_calls;
    assert!(
        combined_reader.read_calls < separate_reads,
        "combined {} vs separate {} reads",
        combined_reader.read_calls,
        separate_reads
    );
}

#[test]
fn flac_combined_handles_bad_cover_metadata_eof_and_cancel() {
    let path = "Dense FLAC.flac";
    let mut bad_cover = Cursor::new(flac_file(&[vec![0; 4]]));
    let (metadata, cover) =
        read_library_metadata_with_cover(&mut bad_cover, path, "", "scan", 0, &|| Ok(())).unwrap();
    assert_eq!(metadata["trackName"], "Dense FLAC");
    assert_eq!(metadata["bitDepth"], 16);
    assert!(cover.is_none());

    let mut truncated = valid_flac();
    truncated.truncate(12);
    let (metadata, cover) =
        read_library_metadata_with_cover(&mut Cursor::new(truncated), path, "", "scan", 0, &|| {
            Ok(())
        })
        .unwrap();
    assert_eq!(metadata["metadataFromFilename"], true);
    assert!(metadata.get("bitDepth").is_none());
    assert!(cover.is_none());

    let checks = Cell::new(0);
    let mut canceled = Cursor::new(valid_flac());
    let error = read_library_metadata_with_cover(&mut canceled, path, "", "scan", 0, &|| {
        let count = checks.get();
        checks.set(count + 1);
        if count >= 4 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    })
    .unwrap_err();
    assert_eq!(error, "cancelled");
    assert!(checks.get() > 4);
}
