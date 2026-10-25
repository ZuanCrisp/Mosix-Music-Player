//! Installed packages and runtime lifecycle belong to one native owner.

mod downloads;
mod metadata;
mod postprocess;
mod providers;

pub use downloads::ProviderDownloadRequest;
pub use metadata::ProviderAvailabilityRequest;
pub use postprocess::PostProcessInput;

use crate::environment::{
    ExtensionEnvironment, SUPPORTED_RUNTIME_FEATURES, compare_versions, validate_gates,
};
use crate::manifest::ExtensionManifest;
use crate::package::{ExtensionPackage, is_package_path};
use crate::runtime::{LoadMode, lifecycle_result};
use crate::{ExtensionError, ExtensionRuntime, RuntimeLimits};
use serde_json::{Map, Value, json};
use spotiflac_core::cancellation::RequestLease;
use std::cmp::Ordering as Comparison;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct ManagerError(pub String);

fn error(message: impl Into<String>) -> ManagerError {
    ManagerError(message.into())
}
fn cause(context: &str, error: impl std::fmt::Display) -> ManagerError {
    ManagerError(format!("{context}: {error}"))
}

#[derive(Default)]
struct Status {
    enabled: bool,
    error: String,
}
#[derive(Default)]
struct Engine {
    runtime: Option<Arc<ExtensionRuntime>>,
    initialized: bool,
    source: Option<Arc<str>>,
}
struct Installed {
    manifest: ExtensionManifest,
    manifest_json: String,
    source: PathBuf,
    status: RwLock<Status>,
    engine: Mutex<Engine>,
    // Pool maintenance must not wait for a primary VM running post-processing.
    // Code needing both locks takes engine before downloads.
    downloads: Mutex<downloads::Pool>,
}

struct MetadataChange<'a>(&'a AtomicU64);
impl Drop for MetadataChange<'_> {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
}

pub struct ExtensionManager {
    environment: Arc<ExtensionEnvironment>,
    sources: PathBuf,
    limits: RuntimeLimits,
    entries: Mutex<BTreeMap<String, Arc<Installed>>>,
    mutation: Mutex<()>,
    closed: AtomicBool,
    directory_locks: Mutex<Option<Vec<File>>>,
    priorities: Mutex<providers::Priorities>,
    metadata_revision: AtomicU64,
}

impl ExtensionManager {
    pub fn new(
        sources: &Path,
        data: &Path,
        master_key: &str,
        app_version: &str,
        limits: RuntimeLimits,
    ) -> Result<Self, ManagerError> {
        let environment = ExtensionEnvironment::new(data, master_key, app_version)
            .map_err(|e| error(e.to_string()))?;
        Self::with_environment(sources, environment, limits)
    }

    pub(crate) fn with_environment(
        sources: &Path,
        environment: ExtensionEnvironment,
        limits: RuntimeLimits,
    ) -> Result<Self, ManagerError> {
        let environment = Arc::new(environment);
        environment.attach_manager();
        if sources.as_os_str().is_empty() {
            return Err(error("extension directory is not configured"));
        }
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(sources)
            .map_err(|e| cause("failed to create extensions directory", e))?;
        let sources = fs::canonicalize(sources)
            .map_err(|e| cause("failed to inspect extensions directory", e))?;
        let data = environment.data_directory();
        if sources.starts_with(data) || data.starts_with(&sources) {
            return Err(error(
                "extension source and data directories must be separate",
            ));
        }
        let mut locks = Vec::new();
        for directory in [&sources, data] {
            let lock = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(
                    (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32,
                )
                .open(directory.join(".backend-manager.lock"))
                .map_err(|e| cause("failed to lock extension directory", e))?;
            if !lock
                .metadata()
                .map_err(|e| cause("failed to inspect directory lock", e))?
                .is_file()
            {
                return Err(error("extension directory lock must be a regular file"));
            }
            lock.try_lock()
                .map_err(|_| error("extension directories are already managed"))?;
            locks.push(lock);
        }
        Ok(Self {
            environment,
            sources,
            limits,
            entries: Mutex::default(),
            mutation: Mutex::new(()),
            closed: AtomicBool::new(false),
            directory_locks: Mutex::new(Some(locks)),
            priorities: Mutex::default(),
            metadata_revision: AtomicU64::new(0),
        })
    }

    pub fn environment(&self) -> Arc<ExtensionEnvironment> {
        Arc::clone(&self.environment)
    }

    fn check(&self) -> Result<(), ManagerError> {
        if self.closed.load(Ordering::Acquire) || self.environment.is_closed() {
            Err(error("extension manager closed"))
        } else {
            Ok(())
        }
    }

    fn get(&self, id: &str) -> Result<Arc<Installed>, ManagerError> {
        self.check()?;
        self.entries
            .lock()
            .expect("extension manager lock")
            .get(id)
            .cloned()
            .ok_or_else(|| error("extension not found"))
    }

    fn current(&self, entry: &Arc<Installed>) -> bool {
        !self.closed.load(Ordering::Acquire)
            && self
                .entries
                .lock()
                .expect("extension manager lock")
                .get(&entry.manifest.name)
                .is_some_and(|value| Arc::ptr_eq(value, entry))
    }

    pub(crate) fn health_manifest(&self, id: &str) -> Result<ExtensionManifest, ManagerError> {
        // The explicit health API also accepts disabled installed extensions.
        Ok(self.get(id)?.manifest.clone())
    }

    pub fn install(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        self.install_or_upgrade(package)
    }

    fn install_or_upgrade(&self, package: ExtensionPackage) -> Result<String, ManagerError> {
        let existing = self
            .entries
            .lock()
            .expect("extension manager lock")
            .get(&package.manifest.name)
            .cloned();
        if let Some(existing) = existing {
            match compare_versions(&package.manifest.version, &existing.manifest.version) {
                Comparison::Greater => return self.upgrade_package(package, existing),
                Comparison::Equal => {
                    return Err(error(format!(
                        "extension '{}' v{} is already installed",
                        existing.manifest.display_name, existing.manifest.version
                    )));
                }
                Comparison::Less => {
                    return Err(error(format!(
                        "cannot downgrade '{}' from v{} to v{}",
                        existing.manifest.display_name,
                        existing.manifest.version,
                        package.manifest.version
                    )));
                }
            }
        }
        self.install_package(package)
    }

    fn stage(
        &self,
        package: &mut ExtensionPackage,
        kind: &str,
    ) -> Result<tempfile::TempDir, ManagerError> {
        let stage = tempfile::Builder::new()
            .prefix(&format!(".{}-{kind}-", package.manifest.name))
            .tempdir_in(&self.sources)
            .map_err(|e| cause("failed to create extension staging directory", e))?;
        package
            .extract(stage.path(), &|| self.check().map_err(|e| e.to_string()))
            .map_err(|e| error(e.to_string()))?;
        Ok(stage)
    }

    fn candidate(&self, package: &ExtensionPackage, path: &Path, enabled: bool) -> Arc<Installed> {
        Arc::new(Installed {
            manifest: package.manifest.clone(),
            manifest_json: package.manifest_json.clone(),
            source: path.to_owned(),
            status: RwLock::new(Status {
                enabled,
                error: String::new(),
            }),
            engine: Mutex::default(),
            downloads: Mutex::default(),
        })
    }

    fn install_package(&self, mut package: ExtensionPackage) -> Result<String, ManagerError> {
        let target = self.sources.join(&package.manifest.name);
        if fs::symlink_metadata(&target).is_ok() {
            return Err(error(format!(
                "extension directory already exists for {:?}",
                package.manifest.name
            )));
        }
        let stage = self.stage(&mut package, "install")?;
        let mut candidate = self.candidate(&package, stage.path(), false);
        if let Err(error) = self.validate(&candidate) {
            self.failed(&candidate, &error);
        }
        self.check()?;
        fs::rename(stage.path(), &target).map_err(|e| cause("failed to activate extension", e))?;
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    fn prepare_with_lease(
        &self,
        entry: &Installed,
        lease: Option<Arc<RequestLease>>,
        mode: LoadMode,
    ) -> Result<(Arc<ExtensionRuntime>, Arc<str>), ManagerError> {
        let source: Arc<str> = read_source(&entry.source.join("index.js"), 8 * 1024 * 1024)
            .map_err(|e| cause("failed to read index.js", e))?
            .into();
        let runtime = self
            .environment
            .load_registered_with_lease(
                &entry.manifest_json,
                &source,
                self.limits.clone(),
                mode,
                lease,
            )
            .map_err(|error| match error {
                crate::environment::EnvironmentError::Runtime(ExtensionError::Script(message)) => {
                    cause(
                        if message.starts_with("SyntaxError:") {
                            "failed to compile extension code"
                        } else {
                            "failed to execute extension code"
                        },
                        message,
                    )
                }
                other => self
                    .check()
                    .err()
                    .unwrap_or_else(|| error_from_environment(other)),
            })?;
        // Keep the same source allocation as the VM/isolated-worker cache.
        // The loader copied the input into its owned CompiledSource.
        let source = runtime.shared_source();
        Ok((runtime, source))
    }

    fn validate(&self, entry: &Installed) -> Result<(), ManagerError> {
        let (runtime, _) = self.prepare_with_lease(entry, None, LoadMode::Validate)?;
        // The worker already ran cleanup; join it before publishing the package.
        runtime.shutdown();
        Ok(())
    }

    fn lifecycle(
        &self,
        runtime: &ExtensionRuntime,
        method: &str,
        arguments: &str,
    ) -> Result<(), ManagerError> {
        self.lifecycle_with_lease(runtime, method, arguments, None)
    }

    fn lifecycle_with_lease(
        &self,
        runtime: &ExtensionRuntime,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<(), ManagerError> {
        lifecycle_result(
            method,
            runtime.managed_call_with_lease(
                method,
                arguments,
                false,
                self.limits.timeout_ms,
                lease,
            ),
        )
        .map_err(|e| error(e.to_string()))
    }

    fn teardown_runtime(&self, runtime: &ExtensionRuntime) {
        if let Err(error) = self.lifecycle(runtime, "cleanup", "[]") {
            let _ = self
                .environment
                .log_buffer()
                .backend(&format!("[Extension] Cleanup error: {error}"));
        }
        runtime.shutdown();
    }

    fn teardown(&self, entry: &Installed, engine: &mut Engine) {
        let mut pool = entry.downloads.lock().expect("download pool lock");
        self.invalidate_download_pool(&mut pool);
        for runtime in pool.active.drain(..) {
            // Join every native operation before source/data can be removed.
            runtime.shutdown();
        }
        drop(pool);
        if let Some(runtime) = engine.runtime.take() {
            self.teardown_runtime(&runtime);
        }
        engine.initialized = false;
        engine.source = None;
    }

    fn failed(&self, entry: &Installed, failure: &ManagerError) {
        let mut status = entry.status.write().expect("extension status lock");
        status.enabled = false;
        status.error = failure.to_string();
    }

    fn ready(
        &self,
        entry: &Installed,
        engine: &mut Engine,
        settings: bool,
    ) -> Result<Arc<ExtensionRuntime>, ManagerError> {
        self.ready_with_lease(entry, engine, settings, None)
    }

    fn ready_with_lease(
        &self,
        entry: &Installed,
        engine: &mut Engine,
        settings: bool,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<Arc<ExtensionRuntime>, ManagerError> {
        // Go rechecks gates even when a VM already exists. A version change
        // disables an incompatible provider on its next managed call.
        let version = self
            .environment
            .get_app_version()
            .map_err(error_from_environment)?;
        validate_gates(&entry.manifest, &version, &SUPPORTED_RUNTIME_FEATURES)
            .map_err(error)
            .inspect_err(|failure| self.failed(entry, failure))?;
        if engine
            .runtime
            .as_ref()
            .is_some_and(|runtime| runtime.is_closed())
        {
            self.invalidate_download_pool(&mut entry.downloads.lock().expect("download pool lock"));
            engine.runtime = None;
            engine.initialized = false;
            engine.source = None;
        }
        if engine.runtime.is_none() {
            let (runtime, source) =
                self.prepare_with_lease(entry, lease.clone(), LoadMode::Register)?;
            engine.runtime = Some(runtime);
            engine.source = Some(source);
        }
        let runtime = Arc::clone(engine.runtime.as_ref().unwrap());
        if settings && !engine.initialized {
            let mut values = self
                .environment
                .settings(&entry.manifest.name)
                .map_err(error_from_environment)?;
            values.retain(|key, _| !key.starts_with('_'));
            if !values.is_empty()
                && let Err(error) = self.lifecycle_with_lease(
                    &runtime,
                    "initialize",
                    &json!([values]).to_string(),
                    lease.clone(),
                )
            {
                if lease
                    .as_ref()
                    .is_some_and(|lease| lease.check_active().is_err())
                {
                    runtime.shutdown();
                    engine.runtime = None;
                    engine.initialized = false;
                    engine.source = None;
                } else {
                    self.teardown(entry, engine);
                }
                return Err(error);
            }
            engine.initialized = true;
        }
        entry
            .status
            .write()
            .expect("extension status lock")
            .error
            .clear();
        Ok(runtime)
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        let entry = self.get(id)?;
        {
            let mut status = entry.status.write().expect("extension status lock");
            status.enabled = enabled;
            if !enabled {
                status.error.clear();
            }
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if enabled {
            if let Err(error) = self.ready(&entry, &mut engine, true) {
                self.failed(&entry, &error);
                let _ = self.environment.set_setting(id, "_enabled", false.into());
                return Err(error);
            }
        } else {
            self.teardown(&entry, &mut engine);
        }
        if let Err(error) = self.environment.set_setting(id, "_enabled", enabled.into()) {
            let _ = self.environment.log_buffer().backend(&format!(
                "[Extension] Failed to persist enabled state for {id}: {error}"
            ));
        }
        Ok(())
    }

    pub fn update_settings(
        &self,
        id: &str,
        settings: Map<String, Value>,
    ) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.get(id)?;
        self.environment
            .replace_settings(id, settings.clone())
            .map_err(error_from_environment)?;
        self.initialize(id, settings)
    }

    pub fn initialize(&self, id: &str, settings: Map<String, Value>) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id)?;
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) {
            return Err(error("extension is no longer installed"));
        }
        self.invalidate_download_pool(&mut entry.downloads.lock().expect("download pool lock"));
        let result = self.ready(&entry, &mut engine, false).and_then(|runtime| {
            self.lifecycle(&runtime, "initialize", &json!([settings]).to_string())
        });
        if let Err(error) = &result {
            self.failed(&entry, error);
        } else {
            engine.initialized = true;
        }
        result
    }

    pub fn cleanup(&self, id: &str) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id)?;
        let engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) {
            return Err(error("extension is no longer installed"));
        }
        engine
            .runtime
            .as_ref()
            .map_or(Ok(()), |runtime| self.lifecycle(runtime, "cleanup", "[]"))
    }

    pub fn invoke_action(&self, id: &str, action: &str) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id).map_err(|e| {
            if e.0 == "extension not found" {
                error(format!("extension not found: {id}"))
            } else {
                e
            }
        })?;
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled"));
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let runtime = self
            .ready(&entry, &mut engine, true)
            .inspect_err(|e| self.failed(&entry, e))?;
        let timeout = entry.manifest.action_timeout_ms(self.limits.timeout_ms);
        runtime
            .managed_call(action, "[]", true, timeout)
            .map_err(|e| cause("action failed", e))
    }

    pub fn call(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<spotiflac_core::cancellation::RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        let entry = self.get(id)?;
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled"));
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let runtime = self
            .ready(&entry, &mut engine, true)
            .inspect_err(|e| self.failed(&entry, e))?;
        runtime
            .call(method, arguments, lease, timeout_ms)
            .map_err(|e| error(e.to_string()))
    }

    fn unload_locked(&self, id: &str) -> Result<(), ManagerError> {
        self.check()?;
        let entry = self
            .entries
            .lock()
            .expect("extension manager lock")
            .remove(id)
            .ok_or_else(|| error("extension not found"))?;
        entry.status.write().expect("extension status lock").enabled = false;
        self.teardown(
            &entry,
            &mut entry.engine.lock().expect("extension engine lock"),
        );
        Ok(())
    }

    pub fn remove(&self, id: &str) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        let entry = self.get(id)?;
        if entry.source != self.sources.join(id) {
            return Err(error(
                "refusing to remove extension outside the managed source directory",
            ));
        }
        self.unload_locked(id)?;
        // Attempt both roots even if one fails. Keep a disabled registry entry
        // on partial removal so the native caller can retry the same operation.
        let source =
            remove_directory(&entry.source).map_err(|e| cause("failed to remove source dir", e));
        let data = self
            .environment
            .remove_data(id)
            .map_err(error_from_environment);
        let failures: Vec<_> = [source, data].into_iter().filter_map(Result::err).collect();
        if failures.is_empty() {
            Ok(())
        } else {
            let failure = error(
                failures
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("; "),
            );
            self.failed(&entry, &failure);
            self.entries
                .lock()
                .expect("extension manager lock")
                .insert(id.to_owned(), entry);
            Err(failure)
        }
    }

    pub fn upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        let existing = self.get(&package.manifest.name).map_err(|_| {
            error(format!(
                "extension '{}' is not installed; use install instead of upgrade",
                package.manifest.display_name
            ))
        })?;
        self.upgrade_package(package, existing)
    }

    fn upgrade_package(
        &self,
        mut package: ExtensionPackage,
        existing: Arc<Installed>,
    ) -> Result<String, ManagerError> {
        match compare_versions(&package.manifest.version, &existing.manifest.version) {
            Comparison::Less => {
                return Err(error(format!(
                    "cannot downgrade extension: current version: {}, new version: {}",
                    existing.manifest.version, package.manifest.version
                )));
            }
            Comparison::Equal => {
                return Err(error(format!(
                    "extension is already at version {}",
                    existing.manifest.version
                )));
            }
            Comparison::Greater => {}
        }
        let target = self.sources.join(&existing.manifest.name);
        let stage = self.stage(&mut package, "upgrade")?;
        let enabled = existing
            .status
            .read()
            .expect("extension status lock")
            .enabled;
        let mut candidate = self.candidate(&package, stage.path(), enabled);
        let valid = if enabled {
            self.ready(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
                true,
            )
            .map(|_| ())
        } else {
            self.validate(&candidate)
        };
        if let Err(error) = valid {
            return Err(cause("upgraded extension failed validation", error));
        }
        let backup = (|| {
            self.check()?;
            let backup = tempfile::Builder::new()
                .prefix(&format!(".{}-backup-", existing.manifest.name))
                .tempdir_in(&self.sources)
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            fs::remove_dir(backup.path())
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            Ok(backup)
        })()
        .inspect_err(|_: &ManagerError| {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
        })?;
        if let Err(error) = fs::rename(&target, backup.path()) {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            return Err(cause("failed to preserve current extension", error));
        }
        if let Err(error) = fs::rename(stage.path(), &target) {
            let restored = fs::rename(backup.path(), &target);
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            if let Err(rollback) = restored {
                let path = backup.keep();
                return Err(error_from_rollback(error, rollback, &path));
            }
            return Err(cause("failed to activate upgraded extension", error));
        }
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        existing
            .status
            .write()
            .expect("extension status lock")
            .enabled = false;
        self.teardown(
            &existing,
            &mut existing.engine.lock().expect("extension engine lock"),
        );
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    pub fn check_upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| {
            if e.0.starts_with("cannot open extension file:") {
                error("cannot open extension file")
            } else {
                error(e.to_string())
            }
        })?;
        let entries = self.entries.lock().expect("extension manager lock");
        let existing = entries.get(&package.manifest.name);
        Ok(json!({"extension_id":package.manifest.name,"current_version":existing.map_or("", |entry| entry.manifest.version.as_str()),"new_version":package.manifest.version,"is_installed":existing.is_some(),"can_upgrade":existing.is_some_and(|entry| compare_versions(&package.manifest.version, &entry.manifest.version)==Comparison::Greater)}).to_string())
    }

    pub fn load_all(&self) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let mut paths: Vec<_> = fs::read_dir(&self.sources)
            .map_err(|e| cause("failed to read extensions directory", e))?
            .collect::<Result<_, _>>()
            .map_err(|e| cause("failed to read extensions directory", e))?;
        paths.sort_by_key(|entry| entry.file_name());
        let mut loaded = Vec::new();
        let mut errors = Vec::new();
        for path in paths {
            self.check()?;
            let result = if path.file_type().map_err(|e| error(e.to_string()))?.is_dir() {
                if !path.path().join("manifest.json").exists() {
                    continue;
                }
                self.load_directory(&path.path())
            } else if is_package_path(&path.path()) {
                // Reuse the mutation already held instead of entering install().
                ExtensionPackage::open(&path.path())
                    .map_err(|e| error(e.to_string()))
                    .and_then(|package| self.install_or_upgrade(package))
                    .and_then(|value| {
                        serde_json::from_str::<Value>(&value)
                            .map(|value| value["id"].as_str().unwrap().to_owned())
                            .map_err(|e| error(e.to_string()))
                    })
            } else {
                continue;
            };
            match result {
                Ok(id) => loaded.push(id),
                Err(error) => {
                    errors.push(format!("{}: {error}", path.file_name().to_string_lossy()))
                }
            }
        }
        Ok(json!({"loaded":if loaded.is_empty() { Value::Null } else { json!(loaded) },"errors":errors}).to_string())
    }

    fn load_directory(&self, path: &Path) -> Result<String, ManagerError> {
        let manifest_json = read_source(&path.join("manifest.json"), 1024 * 1024)
            .map_err(|e| cause("failed to read manifest.json", e))?;
        let manifest = ExtensionManifest::parse(&manifest_json)
            .map_err(|e| cause("invalid extension manifest", e))?;
        if !path.join("index.js").exists() {
            return Err(error("extension is missing index.js file"));
        }
        if self
            .entries
            .lock()
            .expect("extension manager lock")
            .contains_key(&manifest.name)
        {
            return Ok(manifest.name);
        }
        if path != self.sources.join(&manifest.name) {
            return Err(error(format!(
                "extension directory name must match manifest name {:?}",
                manifest.name
            )));
        }
        // A package is still installed when its private settings cannot be
        // decrypted. Keep it visible for recovery without running its code or
        // replacing the unreadable data with defaults.
        let settings = self.environment.settings(&manifest.name);
        let enabled = settings
            .as_ref()
            .is_ok_and(|values| values.get("_enabled") == Some(&Value::Bool(true)));
        let entry = Arc::new(Installed {
            manifest,
            manifest_json,
            source: path.to_owned(),
            status: RwLock::new(Status {
                enabled,
                error: String::new(),
            }),
            engine: Mutex::default(),
            downloads: Mutex::default(),
        });
        match settings {
            Err(error) => self.failed(&entry, &error_from_environment(error)),
            Ok(_) => {
                if let Err(error) = self.validate(&entry) {
                    self.failed(&entry, &error);
                }
            }
        }
        self.check()?;
        let id = entry.manifest.name.clone();
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(id.clone(), entry);
        Ok(id)
    }

    pub fn installed(&self) -> Result<String, ManagerError> {
        self.check()?;
        let entries: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .cloned()
            .collect();
        Ok(Value::Array(entries.iter().map(|entry| information(entry)).collect()).to_string())
    }

    pub fn installed_versions(&self) -> Result<BTreeMap<String, String>, ManagerError> {
        self.check()?;
        Ok(self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .map(|entry| (entry.manifest.name.clone(), entry.manifest.version.clone()))
            .collect())
    }

    pub fn provider_ids(&self, kind: &str) -> Result<Vec<String>, ManagerError> {
        self.check()?;
        Ok(self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .filter(|entry| {
                let status = entry.status.read().expect("extension status lock");
                entry.manifest.has_type(kind) && status.enabled && status.error.is_empty()
            })
            .map(|entry| entry.manifest.name.clone())
            .collect())
    }

    /// Emergency shutdown interrupts workers; orderly unload runs cleanup first.
    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.environment.shutdown();
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.entries.lock().expect("extension manager lock").clear();
        if let Some(locks) = self
            .directory_locks
            .lock()
            .expect("extension directory locks")
            .take()
        {
            // A subprocess can inherit the descriptor between fork and exec.
            // Closing our copy alone may leave the old owner's lock held.
            for lock in locks {
                let _ = lock.unlock();
            }
        }
    }
}

impl Drop for ExtensionManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn error_from_environment(error: crate::environment::EnvironmentError) -> ManagerError {
    ManagerError(error.to_string())
}
fn error_from_rollback(
    error: std::io::Error,
    rollback: std::io::Error,
    path: &Path,
) -> ManagerError {
    cause(
        "failed to activate upgraded extension",
        format!(
            "{error}; restore failed: {rollback}; previous source preserved at {}",
            path.display()
        ),
    )
}
fn remove_directory(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}
fn read_source(path: &Path, limit: u64) -> std::io::Result<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other(
            "extension source must be a regular file",
        ));
    }
    let mut bytes = Vec::new();
    (&mut file).take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(std::io::Error::other(
            "extension source exceeds its size limit",
        ));
    }
    Ok(crate::host::decode_go_utf8(&bytes))
}
fn summary(entry: &Installed) -> String {
    json!({"id":entry.manifest.name,"name":entry.manifest.name,"display_name":entry.manifest.display_name,"version":entry.manifest.version,"enabled":entry.status.read().expect("extension status lock").enabled}).to_string()
}
fn asset(root: &Path, name: &str) -> Option<String> {
    if name.is_empty() || name.contains('\\') {
        return None;
    }
    let mut parts = Vec::new();
    for component in Path::new(name).components() {
        match component {
            Component::Normal(part) => parts.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop()?;
            }
            _ => return None,
        }
    }
    let mut path = root.to_owned();
    for part in parts {
        path.push(part);
        if fs::symlink_metadata(&path).ok()?.file_type().is_symlink() {
            return None;
        }
    }
    path.is_file().then(|| path.to_string_lossy().into_owned())
}
fn information(entry: &Installed) -> Value {
    let manifest = &entry.manifest;
    let status = entry.status.read().expect("extension status lock");
    let mut permissions: Vec<String> = manifest
        .permissions
        .network
        .clone()
        .unwrap_or_default()
        .iter()
        .map(|domain| format!("network:{domain}"))
        .collect();
    if manifest.permissions.storage {
        permissions.push("storage:enabled".into());
    }
    if manifest.permissions.file {
        permissions.push("file:enabled".into());
    }
    if manifest.permissions.allow_http {
        permissions.push("network:http".into());
    }
    if manifest.has_capability("rawFfmpeg") {
        permissions.push("ffmpeg:raw".into());
    }
    let mut value = json!({"id":manifest.name,"name":manifest.name,"display_name":manifest.display_name,"version":manifest.version,"description":manifest.description,"types":manifest.types,"enabled":status.enabled,"status":if !status.error.is_empty() {"error"} else if status.enabled {"loaded"} else {"disabled"},"permissions":permissions,"has_metadata_provider":manifest.has_type("metadata_provider"),"has_download_provider":manifest.has_type("download_provider"),"has_lyrics_provider":manifest.has_type("lyrics_provider"),"skip_metadata_enrichment":manifest.skip_metadata_enrichment,"skip_lyrics":manifest.skip_lyrics,"stop_provider_fallback":manifest.stops_provider_fallback()});
    if !status.error.is_empty() {
        value["error_message"] = status.error.clone().into();
    }
    if let Some(icon) =
        asset(&entry.source, &manifest.icon).or_else(|| asset(&entry.source, "icon.png"))
    {
        value["icon_path"] = icon.into();
    }
    let serialized = serde_json::to_value(manifest).expect("manifest serialization");
    for (source, target) in [
        ("homepage", "homepage"),
        ("settings", "settings"),
        ("qualityOptions", "quality_options"),
        ("searchBehavior", "search_behavior"),
        ("trackMatching", "track_matching"),
        ("postProcessing", "post_processing"),
        ("serviceHealth", "service_health"),
        ("capabilities", "capabilities"),
    ] {
        if let Some(field) = serialized.get(source) {
            value[target] = field.clone();
        }
    }
    value
}

#[cfg(test)]
mod tests {
    use super::{ExtensionManager, RuntimeLimits};
    use crate::storage::{StorageMasterKey, encrypt};
    use serde_json::{Value, json};
    use std::fs::File;
    use std::sync::Arc;

    #[test]
    fn unreadable_settings_keep_installed_packages_visible_and_preserve_data() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let data = directory.path().join("data");
        let original_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        let other_key = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
        let key = StorageMasterKey::from_base64(original_key).unwrap();
        let ids = ["example.first", "example.second"];
        let mut snapshots = Vec::new();
        for id in ids {
            let source = sources.join(id);
            let private = data.join(id);
            std::fs::create_dir_all(&source).unwrap();
            std::fs::create_dir_all(&private).unwrap();
            std::fs::write(
                source.join("manifest.json"),
                json!({"name":id,"displayName":"Example","version":"1","description":"Storage recovery fixture","type":["metadata_provider"]}).to_string(),
            ).unwrap();
            // Even validation must not execute while private storage is broken.
            std::fs::write(source.join("index.js"), "throw Error('must not run');").unwrap();
            let settings = encrypt(
                br#"{"_enabled":true,"region":"example"}"#,
                &key.derive(id, "settings"),
            )
            .unwrap();
            let credentials = encrypt(
                br#"{"token":"example-secret"}"#,
                &key.derive(id, "credentials"),
            )
            .unwrap();
            std::fs::write(private.join("settings.enc"), &settings).unwrap();
            std::fs::write(private.join(".credentials.enc"), &credentials).unwrap();
            snapshots.push((private, settings, credentials));
        }
        let manager =
            ExtensionManager::new(&sources, &data, other_key, "1", RuntimeLimits::default())
                .unwrap();
        let loaded: Value = serde_json::from_str(&manager.load_all().unwrap()).unwrap();
        assert_eq!(loaded["loaded"], json!(ids));
        let installed: Value = serde_json::from_str(&manager.installed().unwrap()).unwrap();
        assert_eq!(installed.as_array().unwrap().len(), 2);
        for entry in installed.as_array().unwrap() {
            assert_eq!(entry["enabled"], false);
            assert_eq!(entry["status"], "error");
            assert_eq!(
                entry["error_message"],
                "cipher: message authentication failed"
            );
            assert!(
                manager
                    .get(entry["id"].as_str().unwrap())
                    .unwrap()
                    .engine
                    .lock()
                    .unwrap()
                    .runtime
                    .is_none()
            );
        }
        for (private, settings, credentials) in &snapshots {
            assert_eq!(
                std::fs::read(private.join("settings.enc")).unwrap(),
                *settings
            );
            assert_eq!(
                std::fs::read(private.join(".credentials.enc")).unwrap(),
                *credentials
            );
            assert!(!private.join(".cred_salt").exists());
        }
        manager.shutdown();

        // Restoring the correct key makes the existing settings readable again.
        for id in ids {
            std::fs::write(sources.join(id).join("index.js"), "registerExtension({});").unwrap();
        }
        let recovered =
            ExtensionManager::new(&sources, &data, original_key, "1", RuntimeLimits::default())
                .unwrap();
        recovered.load_all().unwrap();
        let installed: Value = serde_json::from_str(&recovered.installed().unwrap()).unwrap();
        for entry in installed.as_array().unwrap() {
            assert_eq!(entry["enabled"], true);
            assert_eq!(entry["status"], "loaded");
            assert_eq!(
                recovered
                    .environment
                    .settings(entry["id"].as_str().unwrap())
                    .unwrap()["region"],
                "example"
            );
        }
    }

    #[test]
    fn manager_and_isolated_vm_share_one_retained_source_allocation() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let source_dir = sources.join("example.memory");
        std::fs::create_dir_all(&source_dir).unwrap();
        let manifest = r#"{"name":"example.memory","displayName":"Example Memory","version":"1","description":"Generic memory fixture","type":["metadata_provider"]}"#;
        std::fs::write(source_dir.join("manifest.json"), manifest).unwrap();
        let source = format!(
            "/*{}*/let calls=0;registerExtension({{next(){{return ++calls;}}}});",
            "x".repeat(4 * 1024 * 1024)
        );
        let source_bytes = source.len();
        std::fs::write(source_dir.join("index.js"), &source).unwrap();
        drop(source);
        let manager = ExtensionManager::new(
            &sources,
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.memory", true).unwrap();
        let entry = manager.get("example.memory").unwrap();
        let mut engine = entry.engine.lock().unwrap();
        let primary = manager.ready(&entry, &mut engine, true).unwrap();
        let retained = engine.source.as_ref().unwrap();
        assert!(Arc::ptr_eq(retained, &primary.shared_source()));
        let isolated = manager
            .environment
            .load_isolated(manifest, retained, RuntimeLimits::default(), &primary)
            .unwrap();
        assert!(Arc::ptr_eq(retained, &isolated.shared_source()));
        assert_eq!(retained.len(), source_bytes);
        drop(engine);
        assert_eq!(primary.call("next", "[]", None, 0).unwrap(), "1");
        assert_eq!(isolated.call("next", "[]", None, 0).unwrap(), "1");
        isolated.shutdown();
        assert_eq!(primary.call("next", "[]", None, 0).unwrap(), "2");
        eprintln!(
            "retained source text: baseline_bytes={} shared_bytes={} saved_bytes={source_bytes}; primary/isolated JS state remains separate",
            source_bytes * 2,
            source_bytes
        );
        manager.shutdown();
    }

    #[test]
    fn shutdown_unlocks_inherited_descriptors_without_unlocking_reopened_owner() {
        let directory = tempfile::tempdir().unwrap();
        let open = || {
            ExtensionManager::new(
                &directory.path().join("sources"),
                &directory.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "1",
                RuntimeLimits::default(),
            )
        };
        let manager = open().unwrap();
        // A fork before exec can retain the same open file description even
        // though the manager closes its own descriptor during shutdown.
        let inherited = manager
            .directory_locks
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .iter()
            .map(File::try_clone)
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        manager.shutdown();
        let reopened = open().unwrap();
        drop(inherited);
        drop(manager);
        assert!(
            open()
                .err()
                .unwrap()
                .to_string()
                .contains("already managed")
        );
        reopened.shutdown();
        assert!(open().is_ok());
    }
}
