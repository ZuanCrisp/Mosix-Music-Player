//! Build an isolated playlist write batch. Only the live database's owner may
//! attach this closed file and publish its rows into the application's tables.
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::{Value, json, value::RawValue};
use std::{
    borrow::Cow,
    fs::File,
    io::{BufRead, BufReader},
    path::Path,
};

#[derive(Deserialize)]
struct TrackRow<'a> {
    #[serde(borrow)]
    key: Cow<'a, str>,
    #[serde(borrow)]
    track: &'a RawValue,
}

pub(crate) fn execute(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let input = request["rows_path"]
        .as_str()
        .ok_or("Missing playlist rows_path")?;
    let output = request["output_path"]
        .as_str()
        .ok_or("Missing playlist output_path")?;
    let expected = request["expected_count"]
        .as_u64()
        .ok_or("Invalid playlist expected_count")?;
    let output = Path::new(output);
    if !Path::new(input).is_absolute()
        || !output.is_absolute()
        || output.file_name().and_then(|name| name.to_str()) != Some("playlist_additions.db")
    {
        return Err(
            "Playlist staging requires absolute rows_path and private playlist_additions.db".into(),
        );
    }
    let mut input =
        BufReader::with_capacity(64 * 1024, File::open(input).map_err(|e| e.to_string())?);
    let staged = tempfile::NamedTempFile::new_in(
        output
            .parent()
            .ok_or("Missing playlist staging directory")?,
    )
    .map_err(|e| e.to_string())?;
    // Never open output_path itself: it may already exist. The temporary file
    // is exclusively owned by this job and is published without replacement.
    let mut db = Connection::open(staged.path()).map_err(|e| e.to_string())?;
    db.execute_batch(
        "PRAGMA user_version=1;
        CREATE TABLE playlist_additions(
            position INTEGER PRIMARY KEY,
            track_key TEXT NOT NULL UNIQUE,
            track_json TEXT NOT NULL
        );",
    )
    .map_err(|e| e.to_string())?;
    let transaction = db.transaction().map_err(|e| e.to_string())?;
    let mut count = 0_u64;
    {
        let mut insert = transaction
            .prepare("INSERT INTO playlist_additions(track_key,track_json) VALUES (?,?)")
            .map_err(|e| e.to_string())?;
        let mut line = Vec::new();
        loop {
            check()?;
            line.clear();
            if input
                .read_until(b'\n', &mut line)
                .map_err(|e| e.to_string())?
                == 0
            {
                break;
            }
            let row: TrackRow<'_> = serde_json::from_slice(&line).map_err(|e| e.to_string())?;
            if row.key.is_empty() || !row.track.get().starts_with('{') {
                return Err("Invalid playlist track row".into());
            }
            if count == expected {
                return Err("Playlist staging received too many rows".into());
            }
            // Preserve the original track JSON byte-for-byte instead of
            // allocating a metadata map and serializing every field again.
            insert
                .execute([row.key.as_ref(), row.track.get()])
                .map_err(|e| e.to_string())?;
            count += 1;
        }
    }
    if count != expected {
        return Err(format!(
            "Incomplete playlist staging: expected {expected}, got {count}"
        ));
    }
    check()?;
    transaction.commit().map_err(|e| e.to_string())?;
    db.close().map_err(|(_, error)| error.to_string())?;
    staged.as_file().sync_all().map_err(|e| e.to_string())?;
    check()?;
    staged
        .persist_noclobber(output)
        .map_err(|e| e.to_string())?;
    Ok(json!({"path":output,"count":count,"committed":true,"published":true}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn stages_ordered_unicode_rows_and_preserves_raw_track_json() {
        let root = tempfile::tempdir().unwrap();
        let input = root.path().join("rows.ndjson");
        let output = root.path().join("playlist_additions.db");
        let raw = r#"{ "name": "音楽 🎵", "unmodeled": {"value":1e-12}, "id":"one" }"#;
        std::fs::write(&input, format!("{{\"key\":\"source:one\\n\\\"\",\"track\":{raw}}}\n{{\"key\":\"source:two\",\"track\":{{\"id\":\"two\"}}}}\n")).unwrap();
        let result = execute(
            &json!({"rows_path":input,"output_path":output,"expected_count":2}),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(result["count"], 2);
        let db = Connection::open(&output).unwrap();
        let rows = db
            .prepare("SELECT track_key,track_json FROM playlist_additions ORDER BY position")
            .unwrap()
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            rows,
            [
                ("source:one\n\"".into(), raw.into()),
                ("source:two".into(), r#"{"id":"two"}"#.into())
            ]
        );
        assert_eq!(
            db.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }

    #[test]
    fn rejects_invalid_duplicate_truncated_and_cancelled_batches_without_publication() {
        let valid = "{\"key\":\"one\",\"track\":{\"id\":\"one\"}}\n";
        for (payload, expected, cancel) in [
            (valid.to_owned(), 2, false),
            (valid.repeat(2), 1, false),
            (valid.repeat(2), 2, false),
            (format!("{valid}{{bad"), 2, false),
            ("{\"key\":\"one\",\"track\":null}\n".into(), 1, false),
            ("{\"key\":\"\",\"track\":{}}\n".into(), 1, false),
            (valid.to_owned(), 1, true),
        ] {
            let root = tempfile::tempdir().unwrap();
            let input = root.path().join("rows.ndjson");
            let output = root.path().join("playlist_additions.db");
            std::fs::write(&input, payload).unwrap();
            let checks = Cell::new(0);
            let result = execute(
                &json!({"rows_path":input,"output_path":output,"expected_count":expected}),
                &|| {
                    checks.set(checks.get() + 1);
                    if cancel && checks.get() == 3 {
                        Err("cancelled".into())
                    } else {
                        Ok(())
                    }
                },
            );
            assert!(result.is_err());
            assert!(!output.exists());
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
        }
    }

    #[test]
    fn never_replaces_an_existing_destination_or_opens_the_live_database() {
        for filename in ["playlist_additions.db", "library_collections.db"] {
            let root = tempfile::tempdir().unwrap();
            let input = root.path().join("rows.ndjson");
            let output = root.path().join(filename);
            std::fs::write(&input, "").unwrap();
            std::fs::write(&output, "existing database").unwrap();
            assert!(
                execute(
                    &json!({"rows_path":input,"output_path":output,"expected_count":0}),
                    &|| Ok(())
                )
                .is_err()
            );
            assert_eq!(
                std::fs::read_to_string(output).unwrap(),
                "existing database"
            );
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 2);
        }
    }
}
