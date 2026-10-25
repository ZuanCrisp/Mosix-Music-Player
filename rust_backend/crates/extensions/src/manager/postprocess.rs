use super::*;
use crate::files::clean;
use serde::{Deserialize, Serialize};
use spotiflac_core::matching::lowercase;

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct PostProcessInput {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub item_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub path: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub uri: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub mime_type: String,
    #[serde(skip_serializing_if = "is_zero")]
    pub size: i64,
    #[serde(skip_serializing_if = "is_false")]
    pub is_saf: bool,
}

fn is_zero(value: &i64) -> bool {
    *value == 0
}
fn is_false(value: &bool) -> bool {
    !value
}
fn failed(message: impl std::fmt::Display) -> Value {
    json!({"success":false,"error":message.to_string()})
}

impl ExtensionManager {
    pub fn post_process(
        &self,
        id: &str,
        input: PostProcessInput,
        metadata: Map<String, Value>,
        hook: &str,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        let lease = self.post_process_lease(&input)?;
        self.post_process_hook(id, &input, &metadata, hook, timeout_ms, lease)
            .map(|value| value.to_string())
    }

    fn post_process_lease(
        &self,
        input: &PostProcessInput,
    ) -> Result<Option<Arc<RequestLease>>, ManagerError> {
        if input.item_id.is_empty() {
            return Ok(None);
        }
        let lease = self
            .environment
            .download_state()
            .acquire(&input.item_id)
            .map_err(|failure| error(failure.to_string()))?;
        lease
            .check_active()
            .map_err(|failure| error(failure.to_string()))?;
        Ok(Some(Arc::new(lease)))
    }

    fn post_process_hook(
        &self,
        id: &str,
        input: &PostProcessInput,
        metadata: &Map<String, Value>,
        hook: &str,
        timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<Value, ManagerError> {
        let entry = self.get(id)?;
        if !entry
            .manifest
            .post_processing
            .as_ref()
            .is_some_and(|config| config.enabled)
        {
            return Err(error(format!(
                "extension '{id}' does not support post-processing"
            )));
        }
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error(format!("extension '{id}' is disabled")));
        }
        let mut engine = self.download_engine(&entry, lease.as_ref())?;
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Ok(failed("extension is disabled or no longer installed"));
        }
        let runtime = match self.ready_with_lease(&entry, &mut engine, true, lease.clone()) {
            Ok(runtime) => runtime,
            Err(error) => {
                if lease
                    .as_ref()
                    .is_some_and(|lease| lease.check_active().is_err())
                {
                    return Err(error);
                }
                self.failed(&entry, &error);
                return Ok(failed(error));
            }
        };
        let result = match runtime.call_post_process(
            &json!([input, metadata, hook]).to_string(),
            timeout_ms,
            &input.item_id,
            lease,
        ) {
            Ok(result) => result,
            Err(ExtensionError::Timeout) => {
                return Ok(failed(
                    "postProcess timeout: extension took too long to complete",
                ));
            }
            Err(error) => return Ok(failed(error)),
        };
        let mut response: Value =
            serde_json::from_str(&result).map_err(|e| error(e.to_string()))?;
        Ok(response["value"].take())
    }

    pub fn run_post_processing(
        &self,
        mut input: PostProcessInput,
        metadata: Map<String, Value>,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        self.check()?;
        let lease = self.post_process_lease(&input)?;
        let check = || -> Result<(), ManagerError> {
            self.check()?;
            if let Some(lease) = &lease {
                lease
                    .check_active()
                    .map_err(|failure| error(failure.to_string()))?;
            }
            Ok(())
        };
        // Go's map iteration has no defined provider order. Use stable IDs;
        // hooks within each provider retain their manifest order.
        let providers: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .filter(|entry| {
                let status = entry.status.read().expect("extension status lock");
                status.enabled
                    && status.error.is_empty()
                    && entry
                        .manifest
                        .post_processing
                        .as_ref()
                        .is_some_and(|config| config.enabled)
            })
            .cloned()
            .collect();
        for provider in providers {
            let config = provider
                .manifest
                .post_processing
                .as_ref()
                .expect("post-processing config");
            for hook in &config.hooks {
                check()?;
                if !hook.default_enabled {
                    continue;
                }
                let mut extension = extension(&input.path);
                if extension.is_empty() {
                    extension = self::extension(&input.name);
                }
                if !hook.supported_formats.is_empty()
                    && !extension.is_empty()
                    && !hook.supported_formats.iter().any(|format| {
                        format!(".{format}") == extension || format == &extension[1..]
                    })
                {
                    continue;
                }
                let id = &provider.manifest.name;
                let log = |message: String| {
                    let _ = self
                        .environment
                        .log_buffer()
                        .backend(&format!("[PostProcessV2] {message}"));
                };
                log(format!(
                    "Running hook {} from {id} on {}",
                    hook.id, input.path
                ));
                let result = match self.post_process_hook(
                    id,
                    &input,
                    &metadata,
                    &hook.id,
                    timeout_ms,
                    lease.clone(),
                ) {
                    Ok(result) => result,
                    Err(error) => {
                        log(format!("Hook {} failed: {error}", hook.id));
                        continue;
                    }
                };
                check()?;
                if result["success"] != true {
                    continue;
                }
                if let Err(error) = self.validate_post_process_result(&provider, &input, &result) {
                    log(format!(
                        "Hook {} returned an unsafe result: {error}",
                        hook.id
                    ));
                    continue;
                }
                if let Some(path) = result["new_file_path"]
                    .as_str()
                    .filter(|path| !path.is_empty())
                {
                    input.path = path.into();
                    if input.name.is_empty() {
                        let clean = clean(Path::new(path));
                        input.name = clean
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                            .unwrap_or("/".into());
                    }
                }
                if let Some(uri) = result["new_file_uri"]
                    .as_str()
                    .filter(|uri| !uri.is_empty())
                {
                    input.uri = uri.into();
                }
            }
        }
        check()?;
        let mut result = json!({"success":true});
        if !input.path.is_empty() {
            result["new_file_path"] = input.path.into();
        }
        if !input.uri.is_empty() {
            result["new_file_uri"] = input.uri.into();
        }
        Ok(result.to_string())
    }

    fn validate_post_process_result(
        &self,
        entry: &Installed,
        input: &PostProcessInput,
        result: &Value,
    ) -> Result<(), ManagerError> {
        let path = result["new_file_path"].as_str().unwrap_or("");
        let uri = result["new_file_uri"].as_str().unwrap_or("");
        if !uri.is_empty() && uri != input.uri {
            return Err(error("an extension cannot replace the destination URI"));
        }
        if path.is_empty() || clean(Path::new(path)) == clean(Path::new(&input.path)) {
            return Ok(());
        }
        if !entry.manifest.permissions.file {
            return Err(error(
                "file permission is required to replace the processed file",
            ));
        }
        if !Path::new(path).is_absolute() {
            return Err(error("replacement file path must be absolute"));
        }
        self.environment
            .validate_post_process_path(&entry.manifest.name, &input.path, path)
            .map_err(error)
    }
}

fn extension(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or("");
    name.rfind('.')
        .map(|index| lowercase(&name[index..]))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::extension;

    #[test]
    fn extension_uses_go_filename_rules_before_path_cleaning() {
        for (path, expected) in [
            ("song.FLAC", ".flac"),
            ("album.flac/", ""),
            (".hidden", ".hidden"),
            ("a/.", "."),
            ("a/..", "."),
            ("a\\b.FLAC", ".flac"),
            ("", ""),
        ] {
            assert_eq!(extension(path), expected, "{path}");
        }
    }
}
