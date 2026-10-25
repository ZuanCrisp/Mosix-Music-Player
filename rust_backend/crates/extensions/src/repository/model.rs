use super::{RepositoryError, error};
use crate::environment::compare_versions;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use spotiflac_core::matching::lowercase;
use std::cmp::Ordering;
use std::collections::BTreeMap;

// Preserve Go's case-insensitive fields, duplicate-field order and null rules.
// A null scalar leaves its previous value; a null slice clears the slice.
trait NullField {
    fn clear_null(&mut self) {}
}
impl NullField for String {}
impl NullField for isize {}
impl<T> NullField for Vec<T> {
    fn clear_null(&mut self) {
        self.clear();
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(transparent)]
pub struct Tags(Vec<String>);

impl<'de> Deserialize<'de> for Tags {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self(
            Vec::<Option<String>>::deserialize(deserializer)?
                .into_iter()
                .map(Option::unwrap_or_default)
                .collect(),
        ))
    }
}

impl std::ops::Deref for Tags {
    type Target = Vec<String>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl NullField for Tags {
    fn clear_null(&mut self) {
        self.0.clear();
    }
}

fn field_matches(key: &str, wire: &str) -> bool {
    key.chars()
        .map(|value| match value {
            'ſ' => 's',
            'K' => 'k',
            value => value.to_ascii_lowercase(),
        })
        .eq(wire.chars().map(|value| value.to_ascii_lowercase()))
}

macro_rules! wire_struct {
    ($name:ident {$($field:ident: $kind:ty => $wire:literal),* $(,)?}) => {
        #[derive(Clone, Debug, Default, Serialize)]
        pub struct $name {
            $(#[serde(rename = $wire)] pub $field: $kind,)*
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                struct Visitor;
                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;
                    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                        formatter.write_str("a registry object")
                    }
                    fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
                        Ok($name::default())
                    }
                    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                        let mut result = $name::default();
                        while let Some(key) = map.next_key::<String>()? {
                            $(if field_matches(&key, $wire) {
                                match map.next_value::<Option<$kind>>()? {
                                    Some(value) => result.$field = value,
                                    None => result.$field.clear_null(),
                                }
                                continue;
                            })*
                            map.next_value::<serde::de::IgnoredAny>()?;
                        }
                        Ok(result)
                    }
                }
                deserializer.deserialize_any(Visitor)
            }
        }
    };
}

wire_struct!(Registry {
    version: isize => "version",
    updated_at: String => "updated_at",
    extensions: Vec<RepoExtension> => "extensions",
});

wire_struct!(RepoExtension {
    id: String => "id",
    name: String => "name",
    display_name: String => "display_name",
    version: String => "version",
    description: String => "description",
    download_url: String => "download_url",
    icon_url: String => "icon_url",
    category: String => "category",
    tags: Tags => "tags",
    downloads: isize => "downloads",
    updated_at: String => "updated_at",
    min_app_version: String => "min_app_version",
    sha256: String => "sha256",
    checksum_sha256: String => "checksum_sha256",
    display_name_alt: String => "displayName",
    download_url_alt: String => "downloadUrl",
    icon_url_alt: String => "iconUrl",
    min_app_version_alt: String => "minAppVersion",
    checksum_alt: String => "checksumSha256",
});

fn first<'a>(values: &[&'a str]) -> &'a str {
    values
        .iter()
        .copied()
        .find(|value| !value.is_empty())
        .unwrap_or("")
}

pub fn normalize_sha256(value: &str) -> String {
    let normalized = lowercase(value.trim());
    let normalized = normalized.strip_prefix("sha256:").unwrap_or(&normalized);
    if normalized.len() == 64 && normalized.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        normalized.into()
    } else {
        String::new()
    }
}

impl RepoExtension {
    pub fn raw_sha256(&self) -> &str {
        first(&[
            self.sha256.trim(),
            self.checksum_sha256.trim(),
            self.checksum_alt.trim(),
        ])
    }

    pub fn download_url(&self) -> &str {
        first(&[&self.download_url, &self.download_url_alt])
    }

    pub fn response(&self, installed: &BTreeMap<String, String>) -> Value {
        let version = installed.get(&self.id);
        let mut result = json!({
            "id":self.id,"name":self.name,"version":self.version,
            "display_name":first(&[&self.display_name,&self.display_name_alt,&self.name]),
            "description":self.description,"download_url":self.download_url(),
            "category":self.category,"downloads":self.downloads,"updated_at":self.updated_at,
            "is_installed":version.is_some(),
            "has_update":version.is_some_and(|installed| compare_versions(&self.version,installed)==Ordering::Greater),
        });
        for (key, value) in [
            ("icon_url", first(&[&self.icon_url, &self.icon_url_alt])),
            (
                "min_app_version",
                first(&[&self.min_app_version, &self.min_app_version_alt]),
            ),
            ("installed_version", version.map_or("", String::as_str)),
            ("sha256", normalize_sha256(self.raw_sha256()).as_str()),
        ] {
            if !value.is_empty() {
                result[key] = value.into();
            }
        }
        if !self.tags.is_empty() {
            result["tags"] = json!(self.tags);
        }
        result
    }
}

impl Registry {
    pub fn parse(body: &[u8]) -> Result<Self, RepositoryError> {
        let text = crate::host::decode_go_utf8(body);
        let mut registry: Self = serde_json::from_str(&text).map_err(|cause| {
            if text.trim_start().starts_with('<') {
                error("registry URL returned a web page instead of JSON. Make sure the URL points to a registry.json file or a GitHub repository that contains one")
            } else {
                error(format!("failed to parse registry: {cause}"))
            }
        })?;
        registry.extensions.retain(|entry| {
            entry.raw_sha256().is_empty() || !normalize_sha256(entry.raw_sha256()).is_empty()
        });
        Ok(registry)
    }

    pub fn responses(
        &self,
        installed: &BTreeMap<String, String>,
        query: &str,
        category: &str,
    ) -> Vec<Value> {
        let query = lowercase(query);
        self.extensions
            .iter()
            .filter(|entry| category.is_empty() || entry.category == category)
            .map(|entry| entry.response(installed))
            .filter(|entry| {
                query.is_empty()
                    || ["name", "display_name", "description"]
                        .iter()
                        .any(|key| lowercase(entry[key].as_str().unwrap_or("")).contains(&query))
                    || entry["tags"].as_array().is_some_and(|tags| {
                        tags.iter()
                            .any(|tag| lowercase(tag.as_str().unwrap_or("")).contains(&query))
                    })
            })
            .collect()
    }
}
