use super::protocol::{self, Record};
use crate::manifest::SignedSession;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

#[derive(Default)]
pub struct RuntimeHints {
    default: String,
    values: BTreeMap<String, String>,
}

impl<'de> Deserialize<'de> for RuntimeHints {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct Fields;
        impl<'de> serde::de::Visitor<'de> for Fields {
            type Value = RuntimeHints;
            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a runtime state object")
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                Ok(RuntimeHints::default())
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<Self::Value, A::Error> {
                let mut result = RuntimeHints::default();
                while let Some(key) = map.next_key::<String>()? {
                    if key.eq_ignore_ascii_case("d") {
                        if let Some(value) = map.next_value::<Option<String>>()? {
                            result.default = value;
                        }
                    } else if key.eq_ignore_ascii_case("s") {
                        match map.next_value::<Option<BTreeMap<String, Option<String>>>>()? {
                            Some(values) => result.values.extend(
                                values
                                    .into_iter()
                                    .map(|(key, value)| (key, value.unwrap_or_default())),
                            ),
                            None => result.values.clear(),
                        }
                    } else {
                        map.next_value::<serde::de::IgnoredAny>()?;
                    }
                }
                Ok(result)
            }
        }
        decoder.deserialize_any(Fields)
    }
}

impl RuntimeHints {
    pub fn parse(raw: &str) -> Self {
        let mut hints: Self = serde_json::from_str(raw).unwrap_or_default();
        hints.default = normalize_hint(&hints.default);
        hints.values = hints
            .values
            .into_iter()
            .filter_map(|(path, value)| {
                let key = path
                    .trim()
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .to_owned();
                let value = normalize_hint(&value);
                (!key.is_empty() && key != "." && !value.is_empty()).then_some((key, value))
            })
            .collect();
        hints
    }

    fn get(&self, path: &Path) -> &str {
        path.file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| self.values.get(name))
            .map_or(&self.default, String::as_str)
    }
}

fn normalize_hint(value: &str) -> String {
    let value = value.trim().to_lowercase();
    if value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        value
    } else {
        String::new()
    }
}

pub struct RecordStore {
    path: PathBuf,
    config: SignedSession,
}

impl RecordStore {
    pub fn open(root: &Path, config: &SignedSession) -> Result<Self, String> {
        let directory = root.join("signed_sessions");
        if directory
            .symlink_metadata()
            .is_ok_and(|metadata| !metadata.is_dir())
        {
            return Err("invalid signed session directory".into());
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&directory)
            .map_err(|error| error.to_string())?;
        let directory = fs::canonicalize(directory).map_err(|error| error.to_string())?;
        Ok(Self {
            path: directory.join(protocol::filename(config)?),
            config: config.clone(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Call while holding this scope's coordinator lock. Go stores this record
    /// as private JSON; preserve that format for the eventual ownership cutover.
    pub fn load(&self, hints: &RuntimeHints) -> Result<Record, String> {
        let mut record = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => {
                if !metadata.is_file() || metadata.len() > 1024 * 1024 {
                    return Err("invalid signed session file".into());
                }
                let bytes =
                    Zeroizing::new(fs::read(&self.path).map_err(|error| error.to_string())?);
                Record::decode(&bytes)
                    .map_err(|error| format!("invalid signed session record: {error}"))?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Record::default(),
            Err(error) => return Err(error.to_string()),
        };
        let mut changed = false;
        if record.install_id.trim().is_empty() {
            record.install_id = hints.get(&self.path).to_owned();
            if record.install_id.is_empty() {
                record.install_id = protocol::random_hex(16)?;
            }
            changed = true;
        }
        if record.normalize_scope(&self.config) {
            changed = true;
        }
        if changed {
            self.save(&record)?;
        }
        Ok(record)
    }

    pub fn save(&self, record: &Record) -> Result<(), String> {
        let bytes =
            Zeroizing::new(serde_json::to_vec_pretty(record).map_err(|error| error.to_string())?);
        crate::storage::atomic_write(&self.path, &bytes).map_err(|error| error.to_string())
    }
}
