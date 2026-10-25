use super::*;
use std::cell::Cell;
use tempfile::TempDir;

struct Fixture {
    directory: TempDir,
    db: Connection,
    request: Value,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let library = directory.path().join("local_library.db");
        let history = directory.path().join("history.db");
        let db = Connection::open(&library).unwrap();
        let example = encode(&track("schema", "/music/schema.flac"), "source").unwrap();
        let definitions = example
            .keys()
            .map(|column| {
                let kind = match column.as_str() {
                    "id" => "TEXT PRIMARY KEY",
                    "file_path" => "TEXT UNIQUE",
                    "file_mod_time"
                    | "sort_added"
                    | "audio_metadata_scan_version"
                    | "explicit"
                    | "has_lyrics"
                    | "has_replaygain" => "INTEGER",
                    _ => "TEXT",
                };
                format!("{column} {kind}")
            })
            .collect::<Vec<_>>()
            .join(",");
        db.execute_batch(&format!("PRAGMA journal_mode=WAL; PRAGMA user_version=17;
            CREATE TABLE library({definitions});
            CREATE TABLE library_sources(id TEXT PRIMARY KEY,path TEXT,enabled INTEGER);
            INSERT INTO library_sources VALUES('source','/music',1),('other','/other',1);
            CREATE TABLE library_path_keys(item_id TEXT,path_key TEXT,PRIMARY KEY(item_id,path_key));
            CREATE INDEX library_path_key_index ON library_path_keys(path_key);
            CREATE VIRTUAL TABLE library_search_fts USING fts5(search_text,content='library',content_rowid='rowid',tokenize='trigram');
            CREATE TRIGGER library_fts_ai AFTER INSERT ON library BEGIN INSERT INTO library_search_fts(rowid,search_text) VALUES(new.rowid,new.search_text); END;
            CREATE TRIGGER library_fts_ad AFTER DELETE ON library BEGIN INSERT INTO library_search_fts(library_search_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text); END;" )).unwrap();
        let history_db = Connection::open(&history).unwrap();
        history_db.execute_batch("CREATE TABLE history_path_keys(item_id TEXT,path_key TEXT); CREATE INDEX history_key_index ON history_path_keys(path_key);").unwrap();
        let request = json!({"operation":"library_full_import","library_path":library.to_str().unwrap(),"history_path":history.to_str().unwrap(),"source_id":"source","expected_source_path":"/music","platform":"ios","error_count":0});
        Self {
            directory,
            db,
            request,
        }
    }

    fn add(&self, id: &str, path: &str, source: &str) {
        let values = encode(&track(id, path), source).unwrap();
        let columns = values.keys().cloned().collect::<Vec<_>>();
        self.db
            .execute(
                &format!(
                    "INSERT INTO library({}) VALUES({})",
                    columns.join(","),
                    vec!["?"; columns.len()].join(",")
                ),
                params_from_iter(columns.iter().map(|key| sql_value(&values[key]).unwrap())),
            )
            .unwrap();
        for key in path_keys::build(path, false).unwrap() {
            self.db
                .execute(
                    "INSERT INTO library_path_keys VALUES(?,?)",
                    params![id, key],
                )
                .unwrap();
        }
    }

    fn scan(
        &self,
        rows: &[Value],
        expected: u64,
        errors: u64,
        check: Check<'_>,
    ) -> Result<Value, String> {
        let path = self.directory.path().join("scan.ndjson");
        let mut output = File::create(&path).unwrap();
        for row in rows {
            writeln!(output, "{row}").unwrap();
        }
        let mut request = self.request.clone();
        request["ndjson_path"] = path.to_str().unwrap().into();
        request["expected_count"] = expected.into();
        request["error_count"] = errors.into();
        execute(&request, check)
    }

    fn ids(&self) -> Vec<String> {
        self.db
            .prepare("SELECT id FROM library ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }
}

fn track(id: &str, path: &str) -> Value {
    json!({"id":id,"trackName":format!("Track {id}"),"artistName":"Artist","albumName":"Album","albumArtist":null,"filePath":path,"scannedAt":"2026-10-06T12:00:00.000Z","fileModTime":1770000000000_i64,"isrc":"USAAA2600001","hasReplayGain":false,"replaygain_track_gain":"-4.5 dB"})
}

#[test]
fn private_incremental_manifest_retains_selected_paths_and_order() {
    let fixture = Fixture::new();
    let mut request = fixture.request.clone();
    request["operation"] = "library_incremental_import".into();
    request["retain_removed_paths"] = true.into();
    request["delta"] =
        json!({"files":[],"removedUris":["/z","/a","/z"],"deletedPaths":["/ignored"]});
    execute(&request, &|| Ok(())).unwrap();
    let paths = fixture
        .db
        .prepare("SELECT path FROM native_library_removed_paths ORDER BY ordinal")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(paths, ["/z", "/a", "/z"]);
    request["delta"] = json!({"scanned":[],"deletedPaths":["/fallback"]});
    execute(&request, &|| Ok(())).unwrap();
    let path: String = fixture
        .db
        .query_row("SELECT path FROM native_library_removed_paths", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(path, "/fallback");
    request["delta"] = json!({"files":[],"removedUris":[]});
    execute(&request, &|| Ok(())).unwrap();
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM native_library_removed_paths",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}

#[test]
fn invalid_private_removal_manifest_rolls_back_rows_and_manifest() {
    let fixture = Fixture::new();
    fixture.add("old", "/music/old.flac", "source");
    let mut request = fixture.request.clone();
    request["operation"] = "library_incremental_import".into();
    request["retain_removed_paths"] = true.into();
    request["delta"] =
        json!({"files":[track("new","/music/new.flac")],"removedUris":["/music/old.flac",42]});
    assert!(
        execute(&request, &|| Ok(()))
            .unwrap_err()
            .contains("must be a string")
    );
    assert_eq!(fixture.ids(), ["old"]);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name='native_library_removed_paths'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}

#[test]
fn production_dart_row_and_path_codec_parity() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../test/fixtures/native_library_contract.json"
    ))
    .unwrap();
    for entry in fixture["rows"].as_array().unwrap() {
        assert_eq!(
            Value::Object(encode(&entry["input"], "source").unwrap()),
            entry["expected"],
            "row {:?}",
            entry["input"]
        );
    }
    let mut mismatches = Vec::new();
    for entry in fixture["paths"].as_array().unwrap() {
        let keys = path_keys::build(entry["input"].as_str().unwrap(), false).unwrap();
        let expected = entry["expected"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect::<std::collections::BTreeSet<_>>();
        if keys != expected {
            mismatches.push(format!(
                "path {:?}: extra {:?}, missing {:?}",
                entry["input"],
                keys.difference(&expected).collect::<Vec<_>>(),
                expected.difference(&keys).collect::<Vec<_>>()
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn cancellation_during_atomic_swap_rolls_back_rows_keys_and_fts() {
    let fixture = Fixture::new();
    fixture.add("old", "/music/old.flac", "source");
    let calls = Cell::new(0);
    let check = || {
        calls.set(calls.get() + 1);
        if calls.get() == 8 {
            Err("cancelled during swap".into())
        } else {
            Ok(())
        }
    };
    assert!(
        fixture
            .scan(&[track("new", "/music/new.flac")], 1, 0, &check)
            .is_err()
    );
    assert_eq!(calls.get(), 8);
    assert_eq!(fixture.ids(), ["old"]);
    assert!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM library_path_keys WHERE item_id='old'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap()
            > 0
    );
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM library_search_fts WHERE library_search_fts MATCH ?",
                ["old"],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
}

#[test]
fn external_wal_writer_can_publish_while_native_scan_stages_temp_rows() {
    let fixture = Fixture::new();
    fixture.add("other", "/other/track.flac", "other");
    let path = fixture.request["library_path"].as_str().unwrap().to_owned();
    let calls = Cell::new(0);
    let thread = std::cell::RefCell::new(None);
    let check = || {
        calls.set(calls.get() + 1);
        if calls.get() == 305 {
            let (sender, receiver) = std::sync::mpsc::channel();
            let path = path.clone();
            let handle = std::thread::spawn(move || {
                let db = Connection::open(path).unwrap();
                db.busy_timeout(Duration::from_secs(2)).unwrap();
                db.execute_batch("BEGIN IMMEDIATE;UPDATE library_sources SET path='/writer-kept' WHERE id='other';").unwrap();
                sender.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(50));
                db.execute_batch("COMMIT").unwrap();
            });
            *thread.borrow_mut() = Some(handle);
            receiver.recv_timeout(Duration::from_secs(3)).unwrap();
        }
        Ok(())
    };
    let rows = (0..300)
        .map(|i| track(&format!("new-{i}"), &format!("/music/{i}.flac")))
        .collect::<Vec<_>>();
    fixture.scan(&rows, 300, 0, &check).unwrap();
    thread.into_inner().unwrap().join().unwrap();
    assert_eq!(fixture.ids().len(), 301);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT path FROM library_sources WHERE id='other'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
        "/writer-kept"
    );
}

#[test]
fn spilled_incremental_json_is_consumed_without_deleting_adapter_file() {
    let fixture = Fixture::new();
    let path = fixture.directory.path().join("delta.json");
    fs::write(&path,json!({"files":[track("new","/music/new.flac")],"removedUris":[],"skippedCount":3,"totalFiles":4}).to_string()).unwrap();
    let mut request = fixture.request.clone();
    request["operation"] = "library_incremental_import".into();
    request["delta_path"] = path.to_str().unwrap().into();
    let result = execute(&request, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["new"]);
    assert_eq!(result["skippedCount"], 3);
    assert!(path.exists());
}

#[test]
fn full_swap_excludes_downloads_and_preserves_other_source_and_fts() {
    let fixture = Fixture::new();
    fixture.add("old", "/music/old.flac", "source");
    fixture.add("other", "/other/track.flac", "other");
    let history = Connection::open(fixture.request["history_path"].as_str().unwrap()).unwrap();
    history
        .execute(
            "INSERT INTO history_path_keys VALUES('downloaded','/music/downloaded')",
            [],
        )
        .unwrap();
    let result = fixture
        .scan(
            &[
                track("new", "/music/new.flac"),
                track("downloaded", "/music/downloaded.opus"),
            ],
            2,
            0,
            &|| Ok(()),
        )
        .unwrap();
    assert_eq!(result["inserted"], 1);
    assert_eq!(result["skipped"], 1);
    assert_eq!(fixture.ids(), ["new", "other"]);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM library_search_fts WHERE library_search_fts MATCH ?",
                ["new"],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM library_search_fts WHERE library_search_fts MATCH ?",
                ["old"],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}

#[test]
fn invalid_rows_count_mismatch_and_cancel_never_replace_existing_index() {
    for failure in ["invalid", "count", "cancel"] {
        let fixture = Fixture::new();
        fixture.add("old", "/music/old.flac", "source");
        let mut rows = (0..650)
            .map(|index| track(&format!("row-{index}"), &format!("/music/{index}.flac")))
            .collect::<Vec<_>>();
        if failure == "invalid" {
            rows[640]["id"] = Value::Null;
        }
        let calls = Cell::new(0);
        let check = || {
            calls.set(calls.get() + 1);
            if failure == "cancel" && calls.get() > 640 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        };
        assert!(
            fixture
                .scan(&rows, if failure == "count" { 649 } else { 650 }, 0, &check)
                .is_err()
        );
        assert_eq!(fixture.ids(), ["old"]);
    }
}

#[test]
fn partial_scan_preserves_unreadable_rows_and_empty_success_clears_only_source() {
    let fixture = Fixture::new();
    fixture.add("unreadable", "/music/unreadable.flac", "source");
    fixture.add("old-id", "/music/changed.flac", "source");
    fixture.add("other", "/other/track.flac", "other");
    fixture
        .scan(&[track("new-id", "/music/changed.flac")], 1, 1, &|| Ok(()))
        .unwrap();
    assert_eq!(fixture.ids(), ["new-id", "other", "unreadable"]);
    fixture.scan(&[], 0, 1, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["new-id", "other", "unreadable"]);
    fixture.scan(&[], 0, 0, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["other"]);
}

#[test]
fn concurrent_source_edit_aborts_native_swap_without_overwriting_other_writer() {
    let fixture = Fixture::new();
    fixture.add("old", "/music/old.flac", "source");
    let writer = Connection::open(fixture.request["library_path"].as_str().unwrap()).unwrap();
    let changed = Cell::new(false);
    let check = || {
        if !changed.replace(true) {
            writer
                .execute(
                    "UPDATE library_sources SET path='/changed' WHERE id='source'",
                    [],
                )
                .unwrap();
        }
        Ok(())
    };
    assert!(
        fixture
            .scan(&[track("new", "/music/new.flac")], 1, 0, &check)
            .is_err()
    );
    assert_eq!(fixture.ids(), ["old"]);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT path FROM library_sources WHERE id='source'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
        "/changed"
    );
}

#[test]
fn incremental_deletes_only_its_source_and_reconciles_existing_downloads() {
    let fixture = Fixture::new();
    fixture.add("old", "/music/old.flac", "source");
    fixture.add("download", "/music/download.flac", "source");
    fixture.add("other", "/other/track.flac", "other");
    let history = Connection::open(fixture.request["history_path"].as_str().unwrap()).unwrap();
    history
        .execute(
            "INSERT INTO history_path_keys VALUES('h','/music/download')",
            [],
        )
        .unwrap();
    let mut request = fixture.request.clone();
    request["operation"] = "library_incremental_import".into();
    request["delta"] = json!({"scanned":[track("new","/music/new.flac")],"deletedPaths":["/music/old.flac","/other/track.flac"],"skippedCount":10,"totalFiles":11});
    let result = execute(&request, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["new", "other"]);
    assert_eq!(result["skipped"], 1);
    assert_eq!(result["deleted_count"], 1);
}

#[test]
fn snapshot_keeps_legacy_sentinel_and_backfills_only_current_missing_timestamps() {
    let fixture = Fixture::new();
    fixture.add("legacy", "/music/legacy.flac", "source");
    fixture.add("saf", "content://provider/document/song.flac", "source");
    fixture.add("current", "/music/current.flac", "source");
    fixture
        .db
        .execute(
            "UPDATE library SET file_mod_time=0,audio_metadata_scan_version=3 WHERE id='legacy'",
            [],
        )
        .unwrap();
    fixture
        .db
        .execute("UPDATE library SET file_mod_time=0 WHERE id='saf'", [])
        .unwrap();
    let mut request = fixture.request.clone();
    request["operation"] = "library_snapshot".into();
    request["snapshot_path"] = fixture
        .directory
        .path()
        .join("snapshot.tsv")
        .to_str()
        .unwrap()
        .into();
    request["backfilled_mod_times"] = json!({"content://provider/document/song.flac":1700000000000_i64,"/music/legacy.flac":1900000000000_i64});
    let result = execute(&request, &|| Ok(())).unwrap();
    assert_eq!(result["count"], 3);
    assert_eq!(result["backfilled_count"], 1);
    let snapshot = fs::read_to_string(request["snapshot_path"].as_str().unwrap()).unwrap();
    assert!(snapshot.contains("-1\t/music/legacy.flac\n"));
    assert!(snapshot.contains("1700000000000\tcontent://provider/document/song.flac\n"));
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT file_mod_time FROM library WHERE id='legacy'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
    assert!(
        execute(&request, &|| Ok(())).is_err(),
        "snapshot must not overwrite an existing output"
    );
}

#[test]
fn mapper_preserves_null_artist_flags_and_replaygain_contract() {
    let mut row = track("full", "/music/full.flac");
    row["explicit"] = json!(1);
    row["albumArtist"] = json!("");
    row["metadataFromFilename"] = json!(true);
    let mapped = encode(&row, "nas").unwrap();
    assert_eq!(mapped.len(), 39);
    assert_eq!(mapped["explicit"], 1);
    assert_eq!(mapped["has_replaygain"], 1);
    assert_eq!(mapped["audio_metadata_scan_version"], 0);
    assert_eq!(mapped["album_artist_norm"], "");
    assert_eq!(mapped["search_text"], "track full artist album artist");
}
