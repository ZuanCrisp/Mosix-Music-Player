use super::{RepositoryError, cause, error, normalize_sha256};
use sha2::{Digest, Sha256};
use spotiflac_core::filename::sanitize_filename;
use spotiflac_core::matching::lowercase;
use spotiflac_network::url::UrlParts;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const MAX_PACKAGE_BYTES: u64 = 64 << 20;

pub fn destination_path(directory: &Path, id: &str, url: &str) -> Result<PathBuf, RepositoryError> {
    if id.trim().is_empty() {
        return Err(error("invalid extension id"));
    }
    let path = UrlParts::parse(url)
        .map_or_else(|| url.into(), |url| crate::host::decode_go_utf8(&url.path));
    let suffix = if lowercase(&path).ends_with(".sflx") {
        ".sflx"
    } else {
        ".spotiflac-ext"
    };
    Ok(crate::files::clean(
        &directory.join(format!("{}{suffix}", sanitize_filename(id))),
    ))
}

/// Streams to a private sibling file and publishes only verified bytes. An
/// interrupted reader, oversized body or checksum mismatch preserves the old
/// destination. Native callers own the destination directory during this call.
pub fn write_verified_package(
    mut read: impl FnMut(&mut [u8]) -> Result<usize, String>,
    destination: &Path,
    expected: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), RepositoryError> {
    check().map_err(error)?;
    let directory = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(directory)
        .map_err(|e| cause("failed to prepare extension download directory", e))?;
    let name = destination
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    let mut file = tempfile::Builder::new()
        .prefix(&format!(".{name}.download-"))
        .tempfile_in(directory)
        .map_err(|e| cause("failed to create extension download", e))?;
    let mut hasher = Sha256::new();
    let mut written = 0u64;
    let mut buffer = [0; 64 * 1024];
    loop {
        check().map_err(error)?;
        let limit = buffer.len().min((MAX_PACKAGE_BYTES + 1 - written) as usize);
        let count = read(&mut buffer[..limit])
            .map_err(|e| cause("failed to write extension package", e))?;
        if count == 0 {
            break;
        }
        if count > limit {
            return Err(error("invalid extension package reader length"));
        }
        written += count as u64;
        if written > MAX_PACKAGE_BYTES {
            return Err(error("extension package exceeds the 64 MiB size limit"));
        }
        file.write_all(&buffer[..count])
            .map_err(|e| cause("failed to write extension package", e))?;
        hasher.update(&buffer[..count]);
    }
    file.as_file()
        .sync_all()
        .map_err(|e| cause("failed to flush extension package", e))?;
    let normalized = normalize_sha256(expected);
    if !expected.trim().is_empty() && normalized.is_empty() {
        return Err(error(
            "registry contains an invalid extension SHA-256 checksum",
        ));
    }
    if !normalized.is_empty() {
        let actual = crate::binary::encode(&hasher.finalize(), "hex").expect("hex encoding");
        // The checksum is public, but keep the comparison independent of its
        // first mismatching byte, matching the Go implementation.
        if actual
            .bytes()
            .zip(normalized.bytes())
            .fold(0, |difference, (a, b)| difference | (a ^ b))
            != 0
        {
            return Err(error(
                "extension package integrity check failed: SHA-256 mismatch",
            ));
        }
    }
    check().map_err(error)?;
    file.persist(destination)
        .map_err(|e| cause("failed to publish extension package", e))?;
    Ok(())
}
