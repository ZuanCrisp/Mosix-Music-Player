use super::*;
use std::{cell::Cell, fs, io::Cursor};
use tempfile::TempDir;

fn metadata(version: u64, data: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "magic": "spotiflac-backup", "format_version": version,
        "app_version": "5.1.0", "history_count": 1, "data": data,
    }))
    .unwrap()
}

fn fixture(entries: &[(&str, &[u8])]) -> (TempDir, Value) {
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("backup.sflb");
    let mut zip = ZipWriter::new(File::create(&input).unwrap());
    for (name, bytes) in entries {
        zip.start_file(
            *name,
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
        )
        .unwrap();
        zip.write_all(bytes).unwrap();
    }
    zip.finish().unwrap();
    let temporary = dir.path().join("temporary");
    fs::create_dir(&temporary).unwrap();
    let request = json!({"input_path": input, "temporary_directory": temporary});
    (dir, request)
}

#[test]
fn native_archive_round_trip_preserves_payloads_and_selective_categories() {
    for version in [2, 3] {
        for history in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path();
            fs::write(
                root.join("metadata.json"),
                metadata(
                    version,
                    json!({
                        "settings": {"theme": "mornye"},
                        "collections": {"playlists": [{"id": "a", "name": "音楽"}]},
                        "playlist_covers": {"a": {"file": "covers/a.jpg", "ext": ".jpg"}},
                        "profile": {"name": "Listener", "photo": PHOTO_ENTRY},
                        "extensions": {"items": [{"id": "provider"}]},
                    }),
                ),
            )
            .unwrap();
            let payload = vec![71; BUFFER_SIZE + 17];
            fs::write(root.join("history.ndjson"), b"{\"id\":\"track\"}\n").unwrap();
            fs::write(root.join("a.jpg"), &payload).unwrap();
            fs::write(root.join("avatar.png"), b"photo bytes").unwrap();
            let mut files = vec![
                json!({"name": "metadata.json", "path": root.join("metadata.json")}),
                json!({"name": "covers/a.jpg", "path": root.join("a.jpg"), "store": true}),
                json!({"name": PHOTO_ENTRY, "path": root.join("avatar.png"), "store": true}),
            ];
            if history {
                files.push(json!({"name": "history.ndjson", "path": root.join("history.ndjson")}));
            }
            let output = root.join("output.sflb");
            assert_eq!(
                write(&json!({"output_path": output, "files": files}), &|| Ok(())).unwrap()["published"],
                true
            );
            let request = json!({"input_path": output, "temporary_directory": root});
            if version == 2 && !history {
                assert!(read(&request, &|| Ok(())).is_err());
                continue;
            }
            let result = read(&request, &|| Ok(())).unwrap();
            assert_eq!(
                fs::read(result["playlist_covers"]["a"]["path"].as_str().unwrap()).unwrap(),
                payload
            );
            assert_eq!(
                fs::read(result["profile_photo_path"].as_str().unwrap()).unwrap(),
                b"photo bytes"
            );
            assert_eq!(result["history_path"].is_string(), history);
            let envelope: Value = serde_json::from_slice(
                &fs::read(result["metadata_path"].as_str().unwrap()).unwrap(),
            )
            .unwrap();
            assert_eq!(
                envelope["data"]["collections"]["playlists"][0]["name"],
                "音楽"
            );
            fs::remove_dir_all(result["temporary_directory_path"].as_str().unwrap()).unwrap();
        }
    }
}

#[test]
fn cancelled_write_removes_only_its_partial_output() {
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("input");
    let output = dir.path().join("output");
    fs::write(&input, vec![7; BUFFER_SIZE * 4]).unwrap();
    let calls = Cell::new(0);
    let check = || {
        calls.set(calls.get() + 1);
        if calls.get() >= 3 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    };
    let request =
        json!({"output_path": output, "files": [{"name": "history.ndjson", "path": input}]});
    assert!(write(&request, &check).is_err());
    assert!(!output.exists());
    assert!(input.exists());
    fs::write(&output, b"existing backup").unwrap();
    assert!(write(&request, &|| Ok(())).is_err());
    assert_eq!(fs::read(output).unwrap(), b"existing backup");
}

#[test]
fn cancelled_extraction_discards_the_entire_staging_directory() {
    let meta = metadata(3, json!({}));
    let history = vec![7; BUFFER_SIZE * 4];
    let (_dir, request) = fixture(&[("metadata.json", &meta), ("history.ndjson", &history)]);
    let calls = Cell::new(0);
    let check = || {
        calls.set(calls.get() + 1);
        if calls.get() >= 4 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    };
    assert!(read(&request, &check).is_err());
    assert_eq!(
        fs::read_dir(request["temporary_directory"].as_str().unwrap())
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn invalid_profile_or_missing_photo_leaves_no_staging() {
    for profile in [
        Value::Null,
        json!({"name": 4}),
        json!({"name": "Listener", "photo": "../outside"}),
        json!({"name": "Listener", "photo": PHOTO_ENTRY}),
    ] {
        let meta = metadata(3, json!({"profile": profile}));
        let (_dir, request) = fixture(&[("metadata.json", &meta)]);
        assert!(read(&request, &|| Ok(())).is_err());
        assert_eq!(
            fs::read_dir(request["temporary_directory"].as_str().unwrap())
                .unwrap()
                .count(),
            0
        );
    }
}

#[test]
fn unreferenced_and_foreign_entries_are_never_extracted() {
    let meta = metadata(
        3,
        json!({"playlist_covers": {
            "foreign": {"file": "../escape.jpg"}, "bad": {"file": "covers/../escape.jpg"},
            "good": {"file": "covers/a.jpg", "ext": "../../bad"},
        }}),
    );
    let (dir, request) = fixture(&[
        ("metadata.json", &meta),
        ("../escape.jpg", b"foreign"),
        ("covers/../escape.jpg", b"foreign"),
        ("covers/a.jpg", b"cover"),
        ("ignored", b"ignored"),
    ]);
    let result = read(&request, &|| Ok(())).unwrap();
    let covers = result["playlist_covers"].as_object().unwrap();
    assert_eq!(covers.len(), 1);
    assert_eq!(covers["good"]["ext"], ".jpg");
    assert_eq!(
        fs::read_dir(result["temporary_directory_path"].as_str().unwrap())
            .unwrap()
            .count(),
        2
    );
    assert!(!dir.path().join("escape.jpg").exists());
}

#[test]
fn corrupt_compressed_payload_is_rejected_and_cleaned_up() {
    let meta = metadata(3, json!({}));
    let history = b"unique-history-payload";
    let (_dir, request) = fixture(&[("metadata.json", &meta), ("history.ndjson", history)]);
    let path = request["input_path"].as_str().unwrap();
    let mut bytes = fs::read(path).unwrap();
    let position = bytes
        .windows(history.len())
        .position(|v| v == history)
        .unwrap();
    bytes[position] ^= 1;
    fs::write(path, bytes).unwrap();
    assert!(read(&request, &|| Ok(())).is_err());
    assert_eq!(
        fs::read_dir(request["temporary_directory"].as_str().unwrap())
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn oversize_declared_history_is_rejected_before_extraction() {
    let meta = metadata(3, json!({}));
    let (_dir, request) = fixture(&[("metadata.json", &meta), ("history.ndjson", b"history")]);
    let path = request["input_path"].as_str().unwrap();
    let mut bytes = fs::read(path).unwrap();
    let positions = bytes
        .windows(4)
        .enumerate()
        .filter_map(|(i, v)| (v == b"PK\x01\x02").then_some(i))
        .collect::<Vec<_>>();
    bytes[positions[1] + 24..positions[1] + 28]
        .copy_from_slice(&((MAX_HISTORY_BYTES + 1) as u32).to_le_bytes());
    fs::write(path, bytes).unwrap();
    assert!(read(&request, &|| Ok(())).is_err());
    assert_eq!(
        fs::read_dir(request["temporary_directory"].as_str().unwrap())
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn cover_manifest_order_and_extension_match_flutter() {
    let entries = ordered_covers(
        br#"{"data":{"playlist_covers":{"z":{"file":"covers/z"},"a":{"file":"covers/a"}}}}"#,
    )
    .unwrap();
    assert_eq!(
        entries
            .iter()
            .map(|entry| entry.0.as_str())
            .collect::<Vec<_>>(),
        ["z", "a"]
    );
    let duplicates = ordered_covers(
        br#"{"data":{"playlist_covers":{"z":{"file":"old"},"a":{},"z":{"file":"new"}}}}"#,
    )
    .unwrap();
    assert_eq!(duplicates.len(), 2);
    assert_eq!(duplicates[0], ("z".to_string(), json!({"file": "new"})));
    assert_eq!(cover_extension(&json!(".jpeg")), ".jpeg");
    assert_eq!(cover_extension(&json!(".JPG")), ".jpg");
    assert_eq!(cover_extension(&Value::Null), ".jpg");
    assert_eq!(
        ordered_covers(br#"{"data":{"playlist_covers":[]}}"#)
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn unsafe_or_missing_write_entry_cannot_publish_partial_archive() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source");
    fs::write(&source, b"bytes").unwrap();
    for name in ["../escape", "/escape", "covers/../escape", "covers\\escape"] {
        let output = dir.path().join("output");
        assert!(
            write(
                &json!({"output_path": output, "files": [{"name": name, "path": source}]}),
                &|| Ok(())
            )
            .is_err()
        );
        assert!(!output.exists());
    }
    // Files produced by Rust are standard ZIPs, with ordinary deflate/store.
    let output = dir.path().join("valid");
    write(
        &json!({"output_path": output, "files": [{"name": "history.ndjson", "path": source}]}),
        &|| Ok(()),
    )
    .unwrap();
    let mut zip = ZipArchive::new(Cursor::new(fs::read(output).unwrap())).unwrap();
    assert_eq!(
        zip.by_name("history.ndjson").unwrap().compression(),
        CompressionMethod::Deflated
    );
}
