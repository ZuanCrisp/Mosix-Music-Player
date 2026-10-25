//! Inspect before extraction; only a private staging directory receives files.

use crate::host::decode_go_utf8;
use crate::manifest::ExtensionManifest;
use spotiflac_core::matching::lowercase;
use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use zip::ZipArchive;

const MAX_ENTRIES: u64 = 2048;
const MAX_EXTRACTED: u64 = 256 * 1024 * 1024;
const MAX_MANIFEST: u64 = 1024 * 1024;
const INVALID_ARCHIVE: &str =
    "cannot open extension file: the file may be corrupted or not a valid extension package";

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct PackageError(pub String);

fn error(message: impl Into<String>) -> PackageError {
    PackageError(message.into())
}
fn corrupt(_: impl std::fmt::Display) -> PackageError {
    error(INVALID_ARCHIVE)
}
fn io_error(message: &str, cause: impl std::fmt::Display) -> PackageError {
    error(format!("{message}: {cause}"))
}

pub fn is_package_path(path: &Path) -> bool {
    let name = lowercase(&path.to_string_lossy());
    name.ends_with(".spotiflac-ext") || name.ends_with(".sflx")
}

struct Entry {
    path: PathBuf,
    directory: bool,
    size: u64,
}

pub struct ExtensionPackage {
    archive: ZipArchive<File>,
    entries: Vec<Entry>,
    pub manifest: ExtensionManifest,
    pub manifest_json: String,
}

impl ExtensionPackage {
    pub fn open(path: &Path) -> Result<Self, PackageError> {
        if !is_package_path(path) {
            return Err(error(
                "invalid file format: please select a .spotiflac-ext or .sflx file",
            ));
        }
        let mut input = OpenOptions::new()
            .read(true)
            .custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32)
            .open(path)
            .map_err(corrupt)?;
        if !input.metadata().map_err(corrupt)?.is_file() {
            return Err(error(INVALID_ARCHIVE));
        }
        // zip-rs coalesces duplicate raw names. Inspect the original central
        // directory first, and bound its entry count before it allocates metadata.
        let names = central_names(&mut input)?;
        let mut archive = ZipArchive::new(input).map_err(corrupt)?;
        if archive.len() != names.len() {
            return Err(error(INVALID_ARCHIVE));
        }
        let mut entries = Vec::with_capacity(names.len());
        let mut total = 0u64;
        let mut manifest_index = None;
        let mut has_index = false;
        for (index, name) in names.into_iter().enumerate() {
            let file = archive.by_index_raw(index).map_err(corrupt)?;
            let mode = file.unix_mode().unwrap_or(0) & 0o170000;
            if mode == 0o120000 {
                return Err(error(format!(
                    "unsafe path in extension archive: {}",
                    decode_go_utf8(&name)
                )));
            }
            let path = clean_path(&name)?;
            let directory = name.ends_with(b"/") || mode == 0o040000;
            if !directory {
                if file.size() > MAX_EXTRACTED - total {
                    return Err(error(
                        "extension archive exceeds the 256 MiB extracted size limit",
                    ));
                }
                total += file.size();
            }
            if path == Path::new("manifest.json") && !directory {
                manifest_index = Some(index);
            }
            if path == Path::new("index.js") && !directory {
                has_index = true;
            }
            entries.push(Entry {
                path,
                directory,
                size: file.size(),
            });
        }
        let index = manifest_index
            .ok_or_else(|| error("invalid extension package: root manifest.json not found"))?;
        if !has_index {
            return Err(error("invalid extension package: root index.js not found"));
        }
        if entries[index].size > MAX_MANIFEST {
            return Err(error(
                "invalid extension package: manifest.json is too large",
            ));
        }
        let mut bytes = Vec::new();
        archive
            .by_index(index)
            .map_err(|e| io_error("failed to open manifest.json", e))?
            .take(MAX_MANIFEST + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| io_error("failed to read manifest.json", e))?;
        if bytes.len() as u64 > MAX_MANIFEST {
            return Err(error(
                "invalid extension package: manifest.json is too large",
            ));
        }
        let manifest_json = decode_go_utf8(&bytes);
        let manifest = ExtensionManifest::parse(&manifest_json)
            .map_err(|e| io_error("invalid extension manifest", e))?;
        Ok(Self {
            archive,
            entries,
            manifest,
            manifest_json,
        })
    }

    pub fn extract(
        &mut self,
        destination: &Path,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), PackageError> {
        let metadata = fs::symlink_metadata(destination)
            .map_err(|e| io_error("failed to inspect staging directory", e))?;
        if !metadata.is_dir() || fs::read_dir(destination).map_err(corrupt)?.next().is_some() {
            return Err(error(
                "extension extraction requires an empty staging directory",
            ));
        }
        let mut total = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        for (index, entry) in self.entries.iter().enumerate() {
            check().map_err(error)?;
            if entry.directory {
                continue;
            }
            let path = destination.join(&entry.path);
            fs::create_dir_all(path.parent().expect("staging parent"))
                .map_err(|e| io_error("failed to create extension directory", e))?;
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)
                .map_err(|e| io_error("failed to create extension file", e))?;
            let mut input = self
                .archive
                .by_index(index)
                .map_err(|e| io_error("failed to open file in archive", e))?;
            let mut written = 0u64;
            loop {
                check().map_err(error)?;
                let count = input
                    .read(&mut buffer)
                    .map_err(|e| io_error("failed to extract extension file", e))?;
                if count == 0 {
                    break;
                }
                if count as u64 > MAX_EXTRACTED - total
                    || count as u64 > entry.size.saturating_sub(written)
                {
                    return Err(error(
                        "extension archive exceeds its declared extracted size",
                    ));
                }
                output
                    .write_all(&buffer[..count])
                    .map_err(|e| io_error("failed to extract extension file", e))?;
                total += count as u64;
                written += count as u64;
            }
            if written != entry.size {
                return Err(error("failed to extract extension file: unexpected EOF"));
            }
            output
                .sync_all()
                .map_err(|e| io_error("failed to close extracted extension file", e))?;
        }
        Ok(())
    }
}

fn clean_path(name: &[u8]) -> Result<PathBuf, PackageError> {
    let unsafe_path = || {
        error(format!(
            "unsafe path in extension archive: {}",
            decode_go_utf8(name)
        ))
    };
    if name.starts_with(b"/") || name.contains(&b'\\') || name.contains(&0) {
        return Err(unsafe_path());
    }
    let mut parts = Vec::new();
    for part in name.split(|byte| *byte == b'/') {
        match part {
            b"" | b"." => {}
            b".." => {
                if parts.pop().is_none() {
                    return Err(unsafe_path());
                }
            }
            _ => parts.push(part),
        }
    }
    if parts.is_empty() {
        return Err(unsafe_path());
    }
    Ok(PathBuf::from(OsString::from_vec(parts.join(&b'/'))))
}

fn number16(bytes: &[u8], offset: usize) -> u64 {
    u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap()) as u64
}
fn number32(bytes: &[u8], offset: usize) -> u64 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) as u64
}
fn number64(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}
fn read_at<const N: usize>(input: &mut File, offset: u64) -> Result<[u8; N], PackageError> {
    input.seek(SeekFrom::Start(offset)).map_err(corrupt)?;
    let mut bytes = [0; N];
    input.read_exact(&mut bytes).map_err(corrupt)?;
    Ok(bytes)
}

fn central_names(input: &mut File) -> Result<Vec<Vec<u8>>, PackageError> {
    let length = input.metadata().map_err(corrupt)?.len();
    let tail_size = length.min(65557) as usize;
    let mut tail = vec![0; tail_size];
    input
        .seek(SeekFrom::Start(length - tail_size as u64))
        .map_err(corrupt)?;
    input.read_exact(&mut tail).map_err(corrupt)?;
    let end = (0..tail.len().saturating_sub(21))
        .rev()
        .find(|index| {
            tail[*index..].starts_with(b"PK\x05\x06")
                && *index + 22 + number16(&tail, *index + 20) as usize <= tail.len()
        })
        .ok_or_else(|| error(INVALID_ARCHIVE))?;
    let absolute_end = length - tail_size as u64 + end as u64;
    let mut count = number16(&tail, end + 10);
    let mut size = number32(&tail, end + 12);
    let mut offset = number32(&tail, end + 16);
    let mut directory_end = absolute_end;
    if absolute_end >= 20 {
        let locator = read_at::<20>(input, absolute_end - 20)?;
        if locator.starts_with(b"PK\x06\x07") {
            let record_offset = number64(&locator, 8);
            let record = read_at::<56>(input, record_offset)?;
            if !record.starts_with(b"PK\x06\x06") {
                return Err(error(INVALID_ARCHIVE));
            }
            count = number64(&record, 32);
            size = number64(&record, 40);
            offset = number64(&record, 48);
            directory_end = record_offset;
        }
    }
    if count > size / 46 {
        return Err(error(INVALID_ARCHIVE));
    }
    if count > MAX_ENTRIES {
        return Err(error(
            "extension archive contains too many entries (maximum 2048)",
        ));
    }
    let inferred = directory_end
        .checked_sub(size)
        .ok_or_else(|| error(INVALID_ARCHIVE))?;
    let mut position = inferred;
    if offset < length && read_at::<4>(input, offset)? == *b"PK\x01\x02" {
        position = offset;
    }
    let mut names = Vec::with_capacity(count as usize);
    let mut seen = HashSet::new();
    for _ in 0..count {
        let header = read_at::<46>(input, position)?;
        if !header.starts_with(b"PK\x01\x02") {
            return Err(error(INVALID_ARCHIVE));
        }
        let name_length = number16(&header, 28);
        let mut name = vec![0; name_length as usize];
        input.read_exact(&mut name).map_err(corrupt)?;
        let normalized = clean_path(&name)?;
        use std::os::unix::ffi::OsStrExt;
        let key = lowercase(&decode_go_utf8(normalized.as_os_str().as_bytes()));
        if !seen.insert(key) {
            return Err(error(format!(
                "duplicate path in extension archive: {}",
                decode_go_utf8(&name)
            )));
        }
        position = position
            .checked_add(46 + name_length + number16(&header, 30) + number16(&header, 32))
            .filter(|value| *value <= directory_end)
            .ok_or_else(|| error(INVALID_ARCHIVE))?;
        names.push(name);
    }
    if position
        .checked_add(4)
        .is_some_and(|end| end <= directory_end)
        && read_at::<4>(input, position)? == *b"PK\x01\x02"
    {
        return Err(error(INVALID_ARCHIVE));
    }
    input.rewind().map_err(corrupt)?;
    Ok(names)
}
