use super::*;
use std::{cell::Cell, fs};

struct Fixture {
    directory: tempfile::TempDir,
    db: Connection,
    request: Value,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library_collections.db");
        let db = Connection::open(&path).unwrap();
        db.execute_batch(r#"PRAGMA user_version=2; PRAGMA journal_mode=WAL;
          CREATE TABLE wishlist_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
          CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
          CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY,artist_json TEXT NOT NULL,added_at TEXT NOT NULL);
          CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
          CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key));
          INSERT INTO wishlist_tracks VALUES('first','{"id":"a"}','date');
          INSERT INTO wishlist_tracks VALUES('second','corrupt json','date');
          INSERT INTO loved_tracks VALUES('loved','[]','date');
          INSERT INTO favorite_artists VALUES('artist','{}','date');
          INSERT INTO playlists VALUES('p','音楽 🎵',NULL,'date','date');
          INSERT INTO playlists VALUES('custom','İstanbul','/cover.jpg','date','date');
          INSERT INTO playlists VALUES('empty','Empty','', 'date','date');
          INSERT INTO playlist_tracks VALUES('p','second','{"coverUrl":"first.jpg"}','date');
          INSERT INTO playlist_tracks VALUES('p','first','{"coverUrl":"second.jpg"}','date');
          INSERT INTO playlist_tracks VALUES('custom','custom','{}','date');"#).unwrap();
        let request = json!({"operation":"collections_snapshot","collections_path":path,
          "output_path":directory.path().join("snapshot.ndjson")});
        Self {
            directory,
            db,
            request,
        }
    }

    fn rows(&self) -> Vec<Value> {
        fs::read_to_string(self.request["output_path"].as_str().unwrap())
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn staged_files(&self) -> Vec<String> {
        fs::read_dir(self.directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_str().unwrap().to_owned())
            .filter(|name| !name.starts_with("library_collections.db"))
            .collect()
    }
}

#[test]
fn snapshot_preserves_nulls_previews_unicode_and_all_five_query_orders() {
    let fixture = Fixture::new();
    let result = execute(&fixture.request, &|| Ok(())).unwrap();
    assert_eq!(
        result["counts"],
        json!({"wishlist":2,"loved":1,"playlist":3,
        "membership":3,"artist":1})
    );
    assert_eq!(result["published"], true);
    assert_eq!(result["committed"], true);
    let rows = fixture.rows();
    assert_eq!(rows[0]["row"]["track_key"], "second");
    assert_eq!(rows[1]["row"]["track_key"], "first");
    let playlists = rows
        .iter()
        .filter(|row| row["kind"] == "playlist")
        .collect::<Vec<_>>();
    assert_eq!(
        playlists
            .iter()
            .map(|row| row["row"]["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["empty", "custom", "p"]
    );
    assert_eq!(playlists[0]["row"]["preview_track_json"], Value::Null);
    assert_eq!(playlists[1]["row"]["preview_track_json"], Value::Null);
    assert_eq!(
        playlists[2]["row"]["preview_track_json"],
        "{\"coverUrl\":\"first.jpg\"}"
    );
    assert_eq!(playlists[2]["row"]["name"], "音楽 🎵");
    let members = rows
        .iter()
        .filter(|row| row["kind"] == "membership")
        .collect::<Vec<_>>();
    assert_eq!(
        members
            .iter()
            .map(|row| row["row"]["track_key"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["custom", "second", "first"]
    );
    assert_eq!(members[0]["row"].as_object().unwrap().len(), 2);
}

#[test]
fn playlist_projection_is_bound_and_retains_ascending_date_rowid_order() {
    let mut fixture = Fixture::new();
    fixture.request["playlist_id"] = Value::from("p");
    let result = execute(&fixture.request, &|| Ok(())).unwrap();
    assert_eq!(result["counts"], json!({"playlist_track":2}));
    assert_eq!(
        fixture
            .rows()
            .iter()
            .map(|row| row["row"]["track_key"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["second", "first"]
    );
    let mut missing = Fixture::new();
    missing.request["playlist_id"] = Value::from("p' OR 1=1 --");
    assert_eq!(
        execute(&missing.request, &|| Ok(())).unwrap()["counts"],
        json!({"playlist_track":0})
    );
}

#[test]
fn cancellation_every_checkpoint_removes_staging_and_preserves_database() {
    let fixture = Fixture::new();
    let calls = Cell::new(0);
    execute(&fixture.request, &|| {
        calls.set(calls.get() + 1);
        Ok(())
    })
    .unwrap();
    for cancel_at in 1..=calls.get() {
        let fixture = Fixture::new();
        let current = Cell::new(0);
        let result = execute(&fixture.request, &|| {
            current.set(current.get() + 1);
            if current.get() == cancel_at {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert!(result.is_err(), "checkpoint {cancel_at}");
        assert!(fixture.staged_files().is_empty(), "checkpoint {cancel_at}");
        assert_eq!(
            fixture
                .db
                .query_row("SELECT COUNT(*) FROM wishlist_tracks", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            2
        );
    }
}

#[test]
fn schema_missing_database_and_existing_output_never_publish_or_overwrite() {
    for kind in 0..3 {
        let mut fixture = Fixture::new();
        match kind {
            0 => fixture.db.execute_batch("PRAGMA user_version=3").unwrap(),
            1 => {
                fixture.request["collections_path"] = Value::from(
                    fixture
                        .directory
                        .path()
                        .join("missing/library_collections.db")
                        .to_str()
                        .unwrap(),
                )
            }
            _ => fs::write(fixture.request["output_path"].as_str().unwrap(), "kept").unwrap(),
        }
        assert!(execute(&fixture.request, &|| Ok(())).is_err());
        if kind == 2 {
            assert_eq!(
                fs::read_to_string(fixture.request["output_path"].as_str().unwrap()).unwrap(),
                "kept"
            );
            assert_eq!(fixture.staged_files(), ["snapshot.ndjson"]);
        } else {
            assert!(fixture.staged_files().is_empty());
        }
    }
}

#[test]
fn all_queries_share_one_stable_wal_read_snapshot() {
    let fixture = Fixture::new();
    let calls = Cell::new(0);
    execute(&fixture.request, &|| {
        calls.set(calls.get() + 1);
        if calls.get() == 3 {
            fixture
                .db
                .execute("INSERT INTO loved_tracks VALUES('new','{}','date')", [])
                .unwrap();
        }
        Ok(())
    })
    .unwrap();
    assert_eq!(
        fixture
            .rows()
            .iter()
            .filter(|row| row["kind"] == "loved")
            .count(),
        1
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM loved_tracks", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        2
    );
}
