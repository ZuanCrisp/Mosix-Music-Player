//! The v2/v3 Flutter archive contract, with bounded streaming payloads. Only
//! generated filenames are written, and incomplete staging is always removed.
use super::{Check, MAX_HISTORY_BYTES, err, output_path, required};
use serde::{Deserialize, de::MapAccess};
use serde_json::{Map, Value, json, value::RawValue};
use std::{
    collections::HashSet,
    fs::{File, OpenOptions},
    io::{BufWriter, Read, Write},
    path::Path,
};
use zip::{CompressionMethod, ZipArchive, ZipWriter, write::SimpleFileOptions};

const MAX_METADATA_BYTES: u64 = 8 << 20;
const MAX_COVER_BYTES: u64 = 20 << 20;
const MAX_ALL_COVERS_BYTES: u64 = 256 << 20;
const MAX_PHOTO_BYTES: u64 = 2 << 20;
const PHOTO_ENTRY: &str = "profile/avatar.png";
const BUFFER_SIZE: usize = 64 << 10;

fn regular_file(path: &str) -> Result<File, String> {
    let file = File::open(path).map_err(|e| err("open backup payload", e))?;
    if !file
        .metadata()
        .map_err(|e| err("inspect backup payload", e))?
        .is_file()
    {
        return Err("Backup payload must be a regular file".into());
    }
    Ok(file)
}

fn copy_checked(
    input: &mut impl Read,
    output: &mut impl Write,
    limit: u64,
    check: Check<'_>,
) -> Result<u64, String> {
    let mut buffer = [0_u8; BUFFER_SIZE];
    let mut size = 0_u64;
    loop {
        check()?;
        let count = input
            .read(&mut buffer)
            .map_err(|e| err("read backup payload", e))?;
        if count == 0 {
            return Ok(size);
        }
        size += count as u64;
        if size > limit {
            return Err("Backup payload exceeds size limit".into());
        }
        output
            .write_all(&buffer[..count])
            .map_err(|e| err("write backup payload", e))?;
    }
}

pub(super) fn write(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let output = output_path(request, "output_path")?;
    let files = request["files"].as_array().ok_or("Backup requires files")?;
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(output)
        .map_err(|e| err("create backup archive", e))?;
    let result = (|| {
        let mut archive = ZipWriter::new(BufWriter::new(file));
        let mut names = HashSet::new();
        for entry in files {
            check()?;
            let name = required(entry, "name")?;
            let path = required(entry, "path")?;
            if name.starts_with('/')
                || name.contains('\\')
                || name
                    .split('/')
                    .any(|part| part.is_empty() || part == "." || part == "..")
                || !names.insert(name)
                || Path::new(path) == Path::new(output)
            {
                return Err("Invalid backup archive entry".into());
            }
            let mut input = regular_file(path)?;
            let options =
                SimpleFileOptions::default().compression_method(if entry["store"] == true {
                    CompressionMethod::Stored
                } else {
                    CompressionMethod::Deflated
                });
            archive
                .start_file(name, options)
                .map_err(|e| err("start backup entry", e))?;
            copy_checked(&mut input, &mut archive, u64::MAX, check)?;
        }
        let mut writer = archive
            .finish()
            .map_err(|e| err("finish backup archive", e))?;
        writer
            .flush()
            .and_then(|_| writer.get_ref().sync_all())
            .map_err(|e| err("publish backup archive", e))?;
        check()?;
        Ok(json!({"published": true, "count": files.len(), "path": output}))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(output);
    }
    result
}

fn extract(
    archive: &mut ZipArchive<File>,
    name: &str,
    output: &Path,
    limit: u64,
    check: Check<'_>,
) -> Result<u64, String> {
    let mut entry = archive
        .by_name(name)
        .map_err(|e| err("open backup entry", e))?;
    if !entry.is_file() || entry.size() > limit {
        return Err("Missing or oversized backup entry".into());
    }
    let expected = entry.size();
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(output)
        .map_err(|e| err("create restored payload", e))?;
    let mut writer = BufWriter::new(file);
    let size = copy_checked(&mut entry, &mut writer, limit, check)?;
    if size != expected {
        return Err("Incomplete backup entry".into());
    }
    writer
        .flush()
        .map_err(|e| err("flush restored payload", e))?;
    Ok(size)
}

fn cover_extension(value: &Value) -> &str {
    let ext = value.as_str().unwrap_or(".jpg");
    if (2..=9).contains(&ext.len())
        && ext.starts_with('.')
        && ext.as_bytes()[1..]
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    {
        ext
    } else {
        ".jpg"
    }
}

// serde_json::Value sorts object keys. Keep the original manifest order for
// the existing cumulative cover budget (the first covers win when it fills).
fn ordered_covers(metadata: &[u8]) -> Result<Vec<(String, Value)>, String> {
    #[derive(Deserialize)]
    struct Envelope<'a> {
        #[serde(borrow)]
        data: &'a RawValue,
    }
    #[derive(Deserialize)]
    struct Data<'a> {
        #[serde(default, borrow)]
        playlist_covers: Option<&'a RawValue>,
    }
    struct Covers;
    impl<'de> serde::de::Visitor<'de> for Covers {
        type Value = Vec<(String, Value)>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a playlist cover manifest")
        }
        fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
            let mut entries: Vec<(String, Value)> = Vec::new();
            let mut positions = std::collections::HashMap::new();
            while let Some((key, value)) = map.next_entry::<String, Value>()? {
                if let Some(&position) = positions.get(&key) {
                    entries[position] = (key, value);
                } else {
                    positions.insert(key.clone(), entries.len());
                    entries.push((key, value));
                }
            }
            Ok(entries)
        }
    }
    let envelope: Envelope<'_> =
        serde_json::from_slice(metadata).map_err(|e| err("backup metadata", e))?;
    let data: Data<'_> =
        serde_json::from_str(envelope.data.get()).map_err(|e| err("backup data", e))?;
    let Some(raw) = data.playlist_covers else {
        return Ok(Vec::new());
    };
    if !raw.get().trim_start().starts_with('{') {
        return Ok(Vec::new());
    }
    serde::Deserializer::deserialize_map(&mut serde_json::Deserializer::from_str(raw.get()), Covers)
        .map_err(|e| err("backup covers", e))
}

pub(super) fn read(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let mut archive = ZipArchive::new(regular_file(required(request, "input_path")?)?)
        .map_err(|e| err("open backup archive", e))?;
    let mut metadata = Vec::new();
    {
        let mut entry = archive
            .by_name("metadata.json")
            .map_err(|e| err("backup metadata", e))?;
        if !entry.is_file() || entry.size() > MAX_METADATA_BYTES {
            return Err("Missing or oversized backup metadata".into());
        }
        let expected = entry.size();
        let size = copy_checked(&mut entry, &mut metadata, MAX_METADATA_BYTES, check)?;
        if size != expected {
            return Err("Incomplete backup metadata".into());
        }
    }
    let root: Value =
        serde_json::from_slice(&metadata).map_err(|e| err("backup metadata JSON", e))?;
    let version = root["format_version"].as_u64();
    if root["magic"] != "spotiflac-backup"
        || !matches!(version, Some(2 | 3))
        || !root["data"].is_object()
    {
        return Err("Invalid or unsupported backup metadata".into());
    }
    let has_history = archive.index_for_name("history.ndjson").is_some();
    if version == Some(2) && !has_history {
        return Err("Version 2 backup requires history".into());
    }
    let temporary = output_path(request, "temporary_directory")?;
    let staging = tempfile::Builder::new()
        .prefix("spotiflac_restore_")
        .tempdir_in(temporary)
        .map_err(|e| err("create backup staging", e))?;
    let metadata_path = staging.path().join("metadata.json");
    std::fs::write(&metadata_path, &metadata).map_err(|e| err("stage backup metadata", e))?;
    let history_path = if has_history {
        let path = staging.path().join("history.ndjson");
        extract(
            &mut archive,
            "history.ndjson",
            &path,
            MAX_HISTORY_BYTES,
            check,
        )?;
        Some(path)
    } else {
        None
    };
    let mut covers = Map::new();
    let mut cover_bytes = 0;
    for (key, cover) in ordered_covers(&metadata)? {
        check()?;
        if !cover.is_object() {
            continue;
        }
        let name = cover["file"].as_str().unwrap_or("");
        if !name.starts_with("covers/") || name.contains("..") {
            continue;
        }
        let size = match archive.by_name(name) {
            Ok(entry) if entry.size() <= MAX_COVER_BYTES => entry.size(),
            _ => continue,
        };
        if cover_bytes + size > MAX_ALL_COVERS_BYTES {
            break;
        }
        let ext = cover_extension(&cover["ext"]);
        let path = staging.path().join(format!("cover_{}{ext}", covers.len()));
        cover_bytes += extract(&mut archive, name, &path, MAX_COVER_BYTES, check)?;
        covers.insert(key, json!({"ext": ext, "path": path}));
    }
    let profile_photo_path = if let Some(profile) = root["data"].get("profile") {
        if !profile.is_object() || !profile["name"].is_string() {
            return Err("Invalid profile".into());
        }
        if !profile["photo"].is_null() {
            if profile["photo"] != PHOTO_ENTRY {
                return Err("Invalid profile photo entry".into());
            }
            let path = staging.path().join("profile.png");
            extract(&mut archive, PHOTO_ENTRY, &path, MAX_PHOTO_BYTES, check)?;
            Some(path)
        } else {
            None
        }
    } else {
        None
    };
    check()?;
    Ok(json!({
        "published": true,
        // After ownership transfers, return the staging path even if a lease
        // is cancelled. Flutter needs that path to dispose the published files.
        "committed": true,
        "metadata_path": metadata_path,
        "history_path": history_path,
        "playlist_covers": covers,
        "profile_photo_path": profile_photo_path,
        "temporary_directory_path": staging.keep(),
    }))
}

#[cfg(test)]
mod tests;
