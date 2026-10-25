//! Health snapshots share the installed manager's revision and HTTP transport.

use super::Backend;
use crate::manager::ExtensionManager;
use crate::manifest::{ExtensionManifest, HealthCheck};
use serde::Serialize;
use serde_json::Value;
use spotiflac_core::app_version::AppVersion;
use spotiflac_network::{
    HttpRequest, NetworkService, policy::NetworkPermissions, policy::private_literal_or_local,
    url::UrlParts,
};
use spotiflac_providers::resolver::Check;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[derive(Clone, Serialize)]
struct ResultSnapshot {
    extension_id: String,
    status: String,
    checked_at: String,
    checks: Vec<CheckResult>,
}

#[derive(Clone, Serialize)]
struct CheckResult {
    id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    label: String,
    url: String,
    method: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    service_key: String,
    required: bool,
    status: String,
    #[serde(skip_serializing_if = "is_zero")]
    http_status: u16,
    latency_ms: u128,
    #[serde(skip_serializing_if = "String::is_empty")]
    message: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    error: String,
    checked_at: String,
}

fn is_zero(value: &u16) -> bool {
    *value == 0
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

struct Cached {
    revision: u64,
    result: ResultSnapshot,
    expires: Instant,
}

#[derive(Default)]
struct State {
    entries: BTreeMap<String, Cached>,
    refreshing: BTreeMap<String, u64>,
    workers: Vec<JoinHandle<()>>,
}

pub(super) struct Health {
    network: Arc<NetworkService>,
    version: AppVersion,
    state: Mutex<State>,
    closed: AtomicBool,
}

impl Health {
    pub fn new(network: &Arc<NetworkService>, version: AppVersion) -> Self {
        Self {
            network: network.clone(),
            version,
            state: Mutex::default(),
            closed: AtomicBool::new(false),
        }
    }

    pub fn clear_memory_cache(&self) {
        self.state
            .lock()
            .expect("health state lock")
            .entries
            .clear();
    }

    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        let workers = {
            let mut state = self.state.lock().expect("health state lock");
            state.entries.clear();
            std::mem::take(&mut state.workers)
        };
        for worker in workers {
            let _ = worker.join();
        }
    }

    fn fetch(
        &self,
        manager: &ExtensionManager,
        manifest: &ExtensionManifest,
        revision: u64,
        check: &Check<'_>,
    ) -> Result<ResultSnapshot, String> {
        let check = || {
            check()?;
            if self.closed.load(Ordering::Acquire) || manager.environment().is_closed() {
                return Err("health service closed".into());
            }
            if manager.metadata_revision() != revision {
                return Err("extension changed during health check".into());
            }
            Ok(())
        };
        check()?;
        let mut result = ResultSnapshot {
            extension_id: manifest.name.clone(),
            status: "unsupported".into(),
            checked_at: now(),
            checks: Vec::new(),
        };
        if manifest.service_health.is_empty() {
            return Ok(result);
        }
        result.status = "online".into();
        for health_check in &manifest.service_health {
            let entry = self.run_check(manifest, health_check, &check)?;
            result.status = match (
                entry.status.as_str(),
                entry.required,
                result.status.as_str(),
            ) {
                ("offline", true, _) => "offline",
                ("offline", false, "online") | ("degraded", _, "online") => "degraded",
                ("unknown", _, "online") => "unknown",
                _ => &result.status,
            }
            .into();
            result.checks.push(entry);
        }
        check()?;
        let ttl = manifest
            .service_health
            .iter()
            .filter(|check| check.cache_ttl_seconds > 0)
            .map(|check| (check.cache_ttl_seconds as u64).clamp(60, 600))
            .min()
            .unwrap_or(600);
        let ttl = if result.status == "unknown" {
            ttl.min(120)
        } else {
            ttl
        };
        let mut state = self.state.lock().expect("health state lock");
        check()?;
        state.entries.retain(|_, entry| entry.revision == revision);
        state.entries.insert(
            manifest.name.clone(),
            Cached {
                revision,
                result: result.clone(),
                expires: Instant::now() + Duration::from_secs(ttl),
            },
        );
        Ok(result)
    }

    fn fallback_status(self: &Arc<Self>, manager: &Arc<ExtensionManager>, id: &str) -> String {
        let revision = manager.metadata_revision();
        let Ok(manifest) = manager.health_manifest(id) else {
            return "unknown".into();
        };
        if manifest.service_health.is_empty() {
            return "unknown".into();
        }
        let mut state = self.state.lock().expect("health state lock");
        if self.closed.load(Ordering::Acquire) {
            return "unknown".into();
        }
        state.entries.retain(|_, entry| entry.revision == revision);
        let mut status = "unknown".to_owned();
        if let Some(entry) = state.entries.get(id) {
            if Instant::now() < entry.expires {
                return entry.result.status.clone();
            }
            if entry.result.status != "offline" {
                status.clone_from(&entry.result.status);
            }
        }
        if state.refreshing.get(id) == Some(&revision) {
            return status;
        }
        // Reap completed native threads, retaining handles for shutdown to join.
        let mut index = 0;
        while index < state.workers.len() {
            if state.workers[index].is_finished() {
                let _ = state.workers.swap_remove(index).join();
            } else {
                index += 1;
            }
        }
        let health = self.clone();
        let manager = manager.clone();
        let id = id.to_owned();
        let running_id = id.clone();
        state.refreshing.insert(id.clone(), revision);
        match std::thread::Builder::new()
            .name("extension-health".into())
            .spawn(move || {
                let _ = health.fetch(&manager, &manifest, revision, &|| Ok(()));
                let mut state = health.state.lock().expect("health state lock");
                if state.refreshing.get(&running_id) == Some(&revision) {
                    state.refreshing.remove(&running_id);
                }
            }) {
            Ok(worker) => state.workers.push(worker),
            Err(_) => {
                state.refreshing.remove(&id);
            }
        }
        status
    }

    fn run_check(
        &self,
        manifest: &ExtensionManifest,
        input: &HealthCheck,
        check: &Check<'_>,
    ) -> Result<CheckResult, String> {
        check()?;
        let mut method = input.method.trim().to_uppercase();
        if method.is_empty() {
            method = "GET".into();
        }
        let mut result = CheckResult {
            id: input.id.clone(),
            label: input.label.clone(),
            url: input.url.clone(),
            method: method.clone(),
            service_key: input.service_key.trim().into(),
            required: input.required,
            status: "unknown".into(),
            http_status: 0,
            latency_ms: 0,
            message: String::new(),
            error: String::new(),
            checked_at: now(),
        };
        let permissions = NetworkPermissions {
            domains: manifest.permissions.network.clone().unwrap_or_default(),
            allow_http: false,
        };
        let parsed = UrlParts::parse(&input.url);
        let invalid = match &parsed {
            None => Some("invalid health URL".to_owned()),
            Some(url) if url.scheme != "https" => Some("health check must use https".into()),
            Some(url) if url.hostname.is_empty() => {
                Some("health check URL hostname is required".into())
            }
            Some(url) if private_literal_or_local(&url.hostname) => {
                Some("private/local health check host is not allowed".into())
            }
            Some(url) if !permissions.allows_domain(&url.hostname) => Some(format!(
                "health check host '{}' is not in extension network permissions",
                url.hostname
            )),
            _ if method != "GET" && method != "HEAD" => {
                Some("health check method must be GET or HEAD".into())
            }
            _ => None,
        };
        if let Some(error) = invalid {
            result.status = "offline".into();
            result.error = error;
            return Ok(result);
        }
        let timeout = Duration::from_millis(if input.timeout_ms > 0 {
            input.timeout_ms as u64
        } else {
            4000
        });
        let start = Instant::now();
        let network_check = || {
            check()?;
            if start.elapsed() >= timeout {
                Err("HTTP request timeout exceeded".into())
            } else {
                Ok(())
            }
        };
        let session = self.network.session(permissions, timeout);
        let response = session.open_response_stream(
            HttpRequest {
                url: input.url.clone(),
                method: method.clone(),
                body: String::new(),
                headers: BTreeMap::from([("Accept".into(), "application/json".into())]),
                default_json: false,
                user_agent: if parsed
                    .as_ref()
                    .is_some_and(|url| url.hostname.eq_ignore_ascii_case("api.zarz.moe"))
                {
                    self.version.user_agent()
                } else {
                    crate::utility_host::random_user_agent()
                },
            },
            network_check,
        );
        result.latency_ms = start.elapsed().as_millis();
        check()?;
        let mut response = match response {
            Ok(response) => response,
            Err(error) => {
                result.status = if transient_transport(&error) {
                    "unknown"
                } else {
                    "offline"
                }
                .into();
                result.error = error;
                return Ok(result);
            }
        };
        result.http_status = response.response.status;
        result.message = format!(
            "{} {}",
            response.response.status, response.response.status_text
        );
        if !(200..300).contains(&result.http_status) {
            result.status = "offline".into();
            return Ok(result);
        }
        if method == "HEAD" {
            result.status = "online".into();
            return Ok(result);
        }
        let mut body = Vec::new();
        let mut buffer = [0; 8192];
        while body.len() < 64 * 1024 {
            let limit = buffer.len().min(64 * 1024 - body.len());
            match response.read(&mut buffer[..limit], network_check) {
                Ok(0) => break,
                Ok(count) => body.extend_from_slice(&buffer[..count]),
                Err(error) => {
                    check()?;
                    result.status = "degraded".into();
                    result.error = error;
                    result.message.clear();
                    return Ok(result);
                }
            }
        }
        check()?;
        let (status, message) = classify_body(&body, &input.service_key);
        result.status = status.into();
        if !message.is_empty() {
            result.message = message;
        }
        Ok(result)
    }
}

impl Backend {
    pub fn check_extension_health_json(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let revision = self.manager.metadata_revision();
        let manifest = self
            .manager
            .health_manifest(id)
            .map_err(|error| error.to_string())?;
        let result = self.health.fetch(&self.manager, &manifest, revision, &|| {
            self.check().and_then(|()| check())
        })?;
        serde_json::to_string(&result).map_err(|error| error.to_string())
    }

    pub(super) fn prioritize_healthy_downloads(
        &self,
        priority: Vec<String>,
        protected: &str,
        selected: &str,
    ) -> Result<Vec<String>, String> {
        let mut groups = [Vec::new(), Vec::new(), Vec::new()];
        for id in priority {
            let id = id.trim();
            if id.is_empty() {
                continue;
            }
            let status = if id.eq_ignore_ascii_case(protected)
                || !self
                    .fallback_allowed(id)
                    .map_err(|error| error.to_string())?
                || !self
                    .download_manifest(id)
                    .is_ok_and(|manifest| manifest.has_type("download_provider"))
            {
                "unknown".into()
            } else {
                self.health.fallback_status(&self.manager, id)
            };
            let index = match status.as_str() {
                "online" => 0,
                "degraded" => 1,
                "offline" => continue,
                _ => 2,
            };
            groups[index].push(id.to_owned());
        }
        let mut ordered: Vec<_> = groups.into_iter().flatten().collect();
        if let Some(index) = ordered
            .iter()
            .position(|id| id.eq_ignore_ascii_case(selected))
        {
            let id = ordered.remove(index);
            ordered.insert(0, id);
        }
        Ok(ordered)
    }
}

fn transient_message(value: &str) -> bool {
    let value = value.trim().to_lowercase();
    [
        "deadline exceeded",
        "timeout",
        "timed out",
        "temporarily unavailable",
        "try again",
    ]
    .iter()
    .any(|part| value.contains(part))
}

fn transient_transport(value: &str) -> bool {
    let value = value.to_lowercase();
    transient_message(&value)
        || [
            "dns",
            "resolve",
            "connect",
            "unreachable",
            "certificate",
            "tls",
            "unexpected eof",
            "incomplete message",
        ]
        .iter()
        .any(|part| value.contains(part))
}

fn classify_body(body: &[u8], key: &str) -> (&'static str, String) {
    let Ok(payload) = serde_json::from_slice::<Value>(body) else {
        return ("online", String::new());
    };
    let key = key.trim();
    if !key.is_empty()
        && let Some(services) = payload["services"].as_object()
    {
        let Some(service) = services.get(key) else {
            return ("unknown", format!("service '{key}' not found"));
        };
        if !service.is_object() {
            return (
                "unknown",
                format!("service '{key}' has invalid health payload"),
            );
        }
        let text = |field: &str| service[field].as_str().unwrap_or_default();
        let message = [text("label"), text("detail"), text("error")]
            .into_iter()
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(": ");
        let transient = [text("detail"), text("error"), text("label")]
            .into_iter()
            .any(transient_message);
        let ok = service["ok"].as_bool();
        let status = if let Some(code) = service["status"].as_f64() {
            let code = code as i64;
            if (200..300).contains(&code) || (code == 500 && ok == Some(true)) {
                "online"
            } else if matches!(code, 401 | 403) {
                "degraded"
            } else if transient || matches!(code, 408 | 429 | 502 | 503 | 504) {
                "unknown"
            } else {
                "offline"
            }
        } else if matches!(
            text("detail").trim().to_lowercase().as_str(),
            "auth_required" | "authorization_required" | "login_required" | "unauthorized"
        ) {
            "degraded"
        } else if transient {
            "unknown"
        } else if let Some(ok) = ok {
            if ok { "online" } else { "offline" }
        } else {
            match text("status").trim().to_lowercase().as_str() {
                "ok" | "up" | "online" | "healthy" | "operational" => "online",
                "degraded" | "partial" | "warning" | "warn" => "degraded",
                "down" | "offline" | "error" | "failed" | "fail" | "unhealthy" => "offline",
                _ => "unknown",
            }
        };
        return (status, message);
    }
    let raw = payload["status"].as_str().unwrap_or_default();
    let status = match raw.trim().to_lowercase().as_str() {
        "degraded" | "partial" | "warning" | "warn" => "degraded",
        "down" | "offline" | "error" | "failed" | "fail" | "unhealthy" => {
            if transient_message(&String::from_utf8_lossy(body)) {
                "unknown"
            } else {
                "offline"
            }
        }
        _ => "online",
    };
    (status, raw.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RuntimeLimits;
    use crate::backend::MetadataOptions;
    use crate::environment::ExtensionEnvironment;
    use serde_json::json;
    use spotiflac_network::{Lookup, LookupFuture, NetworkOptions};
    use std::sync::atomic::AtomicUsize;

    struct PendingLookup(Arc<AtomicUsize>);
    impl Lookup for PendingLookup {
        fn lookup(&self, _: &str) -> LookupFuture {
            self.0.fetch_add(1, Ordering::AcqRel);
            Box::pin(std::future::pending())
        }
    }

    #[test]
    fn health_ordering_recovers_stale_offline_coalesces_and_joins_refresh() {
        let root = tempfile::tempdir().unwrap();
        let lookups = Arc::new(AtomicUsize::new(0));
        let network = NetworkService::with_options(NetworkOptions {
            lookup: Arc::new(PendingLookup(lookups.clone())),
            doh_upstreams: Vec::new(),
            ..Default::default()
        })
        .unwrap();
        let environment = ExtensionEnvironment::with_network(
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            network,
        )
        .unwrap();
        let backend = Backend::with_environment(
            &root.path().join("sources"),
            environment,
            RuntimeLimits::default(),
            MetadataOptions::default(),
        )
        .unwrap();
        let ids = [
            "example.selected",
            "example.offline",
            "example.unknown",
            "example.degraded",
            "example.online",
        ];
        for id in ids {
            let source = root.path().join("sources").join(id);
            std::fs::create_dir_all(&source).unwrap();
            std::fs::write(source.join("manifest.json"), json!({"name":id,"version":"1","description":"Generic health fixture","type":["download_provider"],
                "permissions":{"network":["example.com"]},"serviceHealth":[{"id":"status","url":"https://example.com/status","required":true}]}).to_string()).unwrap();
            std::fs::write(source.join("index.js"), "registerExtension({});").unwrap();
        }
        backend.load_all().unwrap();
        for id in ids {
            backend.set_enabled(id, true).unwrap();
        }
        let revision = backend.metadata_revision();
        {
            let mut state = backend.health.state.lock().unwrap();
            for (id, status) in [
                (ids[0], "offline"),
                (ids[1], "offline"),
                (ids[3], "degraded"),
                (ids[4], "online"),
            ] {
                state.entries.insert(
                    id.into(),
                    Cached {
                        revision,
                        expires: Instant::now() + Duration::from_secs(60),
                        result: ResultSnapshot {
                            extension_id: id.into(),
                            status: status.into(),
                            checked_at: now(),
                            checks: Vec::new(),
                        },
                    },
                );
            }
        }
        let priority = || ids.iter().map(|id| (*id).to_owned()).collect();
        let first = backend
            .prioritize_healthy_downloads(priority(), ids[0], ids[0])
            .unwrap();
        assert_eq!(first, [ids[0], ids[4], ids[3], ids[2]]);
        backend
            .health
            .state
            .lock()
            .unwrap()
            .entries
            .get_mut(ids[1])
            .unwrap()
            .expires = Instant::now() - Duration::from_secs(1);
        let started = Instant::now();
        for _ in 0..4 {
            let order = backend
                .prioritize_healthy_downloads(priority(), ids[0], ids[0])
                .unwrap();
            assert_eq!(order, [ids[0], ids[4], ids[3], ids[1], ids[2]]);
        }
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "fallback waited for unresolved health network work"
        );
        assert_eq!(backend.health.state.lock().unwrap().workers.len(), 2);
        while lookups.load(Ordering::Acquire) == 0 {
            assert!(started.elapsed() < Duration::from_secs(3));
            std::thread::sleep(Duration::from_millis(5));
        }
        let cached = backend.health.state.lock().unwrap().entries.len();
        assert!(cached > 0);
        backend.release_memory(false).unwrap();
        assert_eq!(backend.health.state.lock().unwrap().entries.len(), cached);
        backend.release_memory(true).unwrap();
        {
            let state = backend.health.state.lock().unwrap();
            assert!(state.entries.is_empty());
            assert_eq!(state.workers.len(), 2);
            assert!(state.workers.iter().all(|worker| !worker.is_finished()));
        }
        // A manager mutation invalidates all old snapshots and late refreshes.
        backend.set_enabled(ids[1], false).unwrap();
        backend.set_enabled(ids[1], true).unwrap();
        assert_eq!(
            backend
                .prioritize_healthy_downloads(priority(), ids[0], ids[0])
                .unwrap(),
            ids
        );
        let closed = Instant::now();
        backend.shutdown();
        assert!(
            closed.elapsed() < Duration::from_secs(1),
            "shutdown did not interrupt pending health DNS"
        );
        assert!(backend.health.state.lock().unwrap().workers.is_empty());
        assert!(backend.health.state.lock().unwrap().entries.is_empty());
        assert!(
            backend
                .check_extension_health_json(ids[0], &|| Ok(()))
                .is_err()
        );
    }
}
