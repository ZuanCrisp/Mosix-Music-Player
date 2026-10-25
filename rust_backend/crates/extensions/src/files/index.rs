use super::{ExtensionFiles, clean};
use cap_std::fs::{Metadata, OpenOptions};
use spotiflac_core::isrc::{FileStamp, IndexFiles};
use std::time::UNIX_EPOCH;

impl IndexFiles for ExtensionFiles {
    fn list(
        &self,
        directory: &str,
        check: &(dyn Fn() -> Result<(), String> + Sync),
    ) -> Result<Vec<FileStamp>, String> {
        let directory = self.resolve_legacy(directory)?;
        let mut pending = vec![(directory.relative.clone(), directory.absolute.clone())];
        let mut result = Vec::new();
        while let Some((relative, absolute)) = pending.pop() {
            check()?;
            let Ok(metadata) = directory.root.directory.symlink_metadata(&relative) else {
                continue;
            };
            if !metadata.is_dir() {
                let path = absolute.to_str().ok_or("invalid UTF-8 path")?;
                result.push(stamp(path, &metadata));
                continue;
            }
            let Ok(opened) = directory.root.directory.open_dir(&relative) else {
                continue;
            };
            let Ok(entries) = opened.entries() else {
                continue;
            };
            let mut names = Vec::new();
            for entry in entries {
                check()?;
                if let Ok(entry) = entry {
                    names.push(entry.file_name());
                }
            }
            names.sort();
            pending.extend(
                names
                    .into_iter()
                    .rev()
                    .map(|name| (relative.join(&name), clean(&absolute.join(name)))),
            );
        }
        check()?;
        Ok(result)
    }

    fn read(
        &self,
        path: &str,
        check: &(dyn Fn() -> Result<(), String> + Sync),
    ) -> Result<String, String> {
        check()?;
        let resolved = self.resolve_legacy(path)?;
        let Ok(mut file) = resolved.open(OpenOptions::new().read(true)) else {
            return Ok(String::new());
        };
        let format = std::path::Path::new(path)
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        spotiflac_core::isrc::read_isrc(&mut file, &format, check)
    }

    fn stat(&self, path: &str) -> Result<Option<FileStamp>, String> {
        let path = self.resolve_legacy(path)?;
        Ok(path
            .metadata()
            .ok()
            .map(|metadata| stamp(&path.display(), &metadata)))
    }
}

fn stamp(path: &str, metadata: &Metadata) -> FileStamp {
    let modified_ns = metadata
        .modified()
        .map(|time| match time.into_std().duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_nanos() as i128,
            Err(error) => -(error.duration().as_nanos() as i128),
        })
        .unwrap_or_default();
    FileStamp {
        path: path.into(),
        size: metadata.len(),
        modified_ns,
        directory: metadata.is_dir(),
    }
}
