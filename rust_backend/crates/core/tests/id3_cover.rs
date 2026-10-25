use image::{DynamicImage, ImageFormat};
use mornye_core::tags::extract_cover;
use std::io::Cursor;

fn picture_tag(image: &[u8], version: u8, encoding: u8, description: &[u8]) -> Vec<u8> {
    let mut picture = vec![encoding];
    picture.extend(if version == 2 {
        b"JPG\x03".as_slice()
    } else {
        b"image/jpeg\0\x03".as_slice()
    });
    picture.extend(description);
    picture.extend(image);
    let mut frame = if version == 2 {
        b"PIC".to_vec()
    } else {
        b"APIC".to_vec()
    };
    if version == 2 {
        frame.extend(&(picture.len() as u32).to_be_bytes()[1..]);
    } else {
        frame.extend((picture.len() as u32).to_be_bytes());
        frame.extend([0, 0]);
    }
    frame.extend(picture);
    let mut tag = vec![b'I', b'D', b'3', version, 0, 0];
    tag.extend([
        (frame.len() >> 21 & 127) as u8,
        (frame.len() >> 14 & 127) as u8,
        (frame.len() >> 7 & 127) as u8,
        (frame.len() & 127) as u8,
    ]);
    tag.extend(frame);
    tag
}

fn container(tag: &[u8], format: &str) -> Vec<u8> {
    if format == "mp3" {
        return tag.to_vec();
    }
    let aiff = format == "aiff";
    let mut chunk = if aiff { b"ID3 " } else { b"id3 " }.to_vec();
    let length = tag.len() as u32;
    chunk.extend(if aiff {
        length.to_be_bytes()
    } else {
        length.to_le_bytes()
    });
    chunk.extend(tag);
    if !tag.len().is_multiple_of(2) {
        chunk.push(0);
    }
    let length = (chunk.len() + 4) as u32;
    let mut data = if aiff { b"FORM" } else { b"RIFF" }.to_vec();
    data.extend(if aiff {
        length.to_be_bytes()
    } else {
        length.to_le_bytes()
    });
    data.extend(if aiff { b"AIFF" } else { b"WAVE" });
    data.extend(chunk);
    data
}

#[test]
fn extracts_decodable_id3_pictures_with_padding_and_aligned_utf16_descriptions() {
    let mut jpeg = Cursor::new(Vec::new());
    DynamicImage::new_rgb8(3, 2)
        .write_to(&mut jpeg, ImageFormat::Jpeg)
        .unwrap();
    let jpeg = jpeg.into_inner();
    for version in [2, 3] {
        for (encoding, description) in [
            (0, b"Album cover\0".as_slice()),
            (0, b"Album cover\0\0".as_slice()),
            (3, b"\0\0\0".as_slice()),
            (1, b"\xff\xfeA\0\0\0".as_slice()),
            (2, b"\0A\0\0".as_slice()),
        ] {
            let tag = picture_tag(&jpeg, version, encoding, description);
            for format in ["mp3", "wav", "aiff"] {
                let cover = extract_cover(
                    &mut Cursor::new(container(&tag, format)),
                    format,
                    &|| Ok(()),
                )
                .unwrap();
                assert_eq!(
                    cover.data, jpeg,
                    "{format}, ID3v2.{version}, encoding {encoding}"
                );
                let decoded = image::load_from_memory(&cover.data).unwrap();
                assert_eq!((decoded.width(), decoded.height()), (3, 2));
            }
        }
    }
}

#[test]
fn does_not_strip_arbitrary_bytes_or_unrecognized_image_data() {
    for image in [b"\0not an image".as_slice(), b"junk\xff\xd8\xff".as_slice()] {
        let tag = picture_tag(image, 3, 0, b"\0");
        let cover = extract_cover(&mut Cursor::new(tag), "mp3", &|| Ok(())).unwrap();
        assert_eq!(cover.data, image);
    }
}
