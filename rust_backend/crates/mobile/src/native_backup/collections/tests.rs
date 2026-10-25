use super::*;
use std::{cell::Cell, io::Write};
use tempfile::TempDir;

struct Fixture {
    _directory: TempDir,
    db: Connection,
    request: Value,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library_collections.db");
        let db = Connection::open(&path).unwrap();
        db.execute_batch(
            "PRAGMA user_version=2; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
             CREATE TABLE wishlist_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
             CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
             CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY,artist_json TEXT NOT NULL,added_at TEXT NOT NULL);
             CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
             CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key),FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE);
             INSERT INTO wishlist_tracks VALUES('kept','{}','old');
             CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('kept');",
        ).unwrap();
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../../test/fixtures/collection_restore_contract.json"
        ))
        .unwrap();
        let commands = fixture["commands"].as_array().unwrap();
        let input = directory.path().join("commands.ndjson");
        let mut file = File::create(&input).unwrap();
        for command in commands {
            writeln!(file, "{command}").unwrap();
        }
        let request = json!({
            "collections_path":path,"ndjson_path":input,"expected_count":commands.len()
        });
        Self {
            _directory: directory,
            db,
            request,
        }
    }

    fn keys(&self) -> Vec<String> {
        self.db
            .prepare("SELECT track_key FROM wishlist_tracks ORDER BY rowid")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }
}

#[test]
fn dart_codec_duplicates_dates_artwork_and_cascades_survive_native_restore() {
    let fixture = Fixture::new();
    let result = import(&fixture.request, &|| Ok(())).unwrap();
    assert_eq!(result["committed"], true);
    assert_eq!(result["command_count"], 9);
    assert_eq!(fixture.keys(), ["example:1"]);
    let playlist: (String, String, String, String) = fixture
        .db
        .query_row(
            "SELECT name,cover_image_path,created_at,updated_at FROM playlists WHERE id='p'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(
        playlist,
        (
            "最新".into(),
            "/covers/a.jpg".into(),
            "2026-09-01".into(),
            "2026-09-01".into()
        )
    );
    let members: Vec<(String, String, String)> = fixture
        .db
        .prepare("SELECT track_key,track_json,added_at FROM playlist_tracks ORDER BY rowid")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(
        members,
        [(
            "example:1".into(),
            "{\"id\":\"last\"}".into(),
            "2026-10-03".into()
        )]
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT value FROM unrelated", [], |row| row
                .get::<_, String>(0))
            .unwrap(),
        "kept"
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT artist_json FROM favorite_artists", [], |row| row
                .get::<_, String>(
                0
            ))
            .unwrap(),
        "{\"key\":\"example:artist\",\"name\":\"İstanbul\",\"extra\":true}"
    );
}

#[test]
fn cancellation_at_every_precommit_checkpoint_preserves_live_collections() {
    let fixture = Fixture::new();
    let calls = Cell::new(0);
    import(&fixture.request, &|| {
        calls.set(calls.get() + 1);
        Ok(())
    })
    .unwrap();
    for cancel_at in 1..=calls.get() {
        let fixture = Fixture::new();
        let current = Cell::new(0);
        let result = import(&fixture.request, &|| {
            current.set(current.get() + 1);
            if current.get() == cancel_at {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert!(result.is_err(), "checkpoint {cancel_at}");
        assert_eq!(fixture.keys(), ["kept"], "checkpoint {cancel_at}");
    }
}

#[test]
fn truncated_malformed_unknown_and_orphaned_commands_never_wipe_live_rows() {
    for mutation in 0..5 {
        let mut fixture = Fixture::new();
        let path = fixture.request["ndjson_path"].as_str().unwrap();
        match mutation {
            0 => fixture.request["expected_count"] = json!(10),
            1 => {
                std::fs::write(path, "{broken\n").unwrap();
            }
            2 => {
                std::fs::write(path, "{\"kind\":\"unknown\",\"values\":{}}\n").unwrap();
                fixture.request["expected_count"] = json!(1);
            }
            3 => {
                std::fs::write(
                    path,
                    "{\"kind\":\"wishlist\",\"values\":{\"track_key\":null}}\n",
                )
                .unwrap();
                fixture.request["expected_count"] = json!(1);
            }
            _ => {
                std::fs::write(path, "{\"kind\":\"playlist_track\",\"values\":{\"playlist_id\":\"missing\",\"track_key\":\"x\",\"track_json\":\"{}\",\"added_at\":\"now\"}}\n").unwrap();
                fixture.request["expected_count"] = json!(1);
            }
        }
        assert!(import(&fixture.request, &|| Ok(())).is_err());
        assert_eq!(fixture.keys(), ["kept"]);
    }
}

#[test]
fn empty_restore_clears_categories_and_wrong_schema_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.db.execute_batch("PRAGMA user_version=3").unwrap();
    assert!(import(&fixture.request, &|| Ok(())).is_err());
    assert_eq!(fixture.keys(), ["kept"]);
    fixture.db.execute_batch("PRAGMA user_version=2").unwrap();
    std::fs::write(fixture.request["ndjson_path"].as_str().unwrap(), "").unwrap();
    fixture.request["expected_count"] = json!(0);
    assert_eq!(
        import(&fixture.request, &|| Ok(())).unwrap()["committed"],
        true
    );
    assert!(fixture.keys().is_empty());
}

#[test]
fn staging_does_not_hold_main_wal_writer_and_publication_is_atomic() {
    let fixture = Fixture::new();
    let calls = Cell::new(0);
    let changed = Cell::new(false);
    import(&fixture.request, &|| {
        calls.set(calls.get() + 1);
        // The staging transaction has already inserted TEMP rows here.
        if calls.get() == 16 {
            changed.set(true);
            let writer =
                Connection::open(fixture.request["collections_path"].as_str().unwrap()).unwrap();
            writer
                .execute("UPDATE unrelated SET value='external writer'", [])
                .unwrap();
        }
        Ok(())
    })
    .unwrap();
    assert!(changed.get());
    assert_eq!(
        fixture
            .db
            .query_row("SELECT value FROM unrelated", [], |row| row
                .get::<_, String>(0))
            .unwrap(),
        "external writer"
    );
}
