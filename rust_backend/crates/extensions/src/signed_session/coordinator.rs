use super::{RecordStore, RuntimeHints, protocol};
use crate::auth::{AuthRegistry, PendingAuthRequest};
use crate::manifest::SignedSession;
use serde_json::{Value, json};
use spotiflac_network::{HttpRequest, HttpResponse, NetworkSession};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

pub(super) type Check<'a> = &'a dyn Fn() -> Result<(), String>;

#[derive(Default)]
pub(super) struct Flight {
    result: Mutex<Option<Result<(), String>>>,
    done: Condvar,
}

impl Flight {
    pub fn finish(&self, result: Result<(), String>) {
        *self.result.lock().expect("signed session flight lock") = Some(result);
        self.done.notify_all();
    }

    pub fn wait(&self, check: Check<'_>) -> Result<(), String> {
        let mut result = self.result.lock().expect("signed session flight lock");
        loop {
            check()?;
            if let Some(result) = &*result {
                return result.clone();
            }
            result = self
                .done
                .wait_timeout(result, Duration::from_millis(10))
                .expect("signed session flight wait")
                .0;
        }
    }
}

#[derive(Default)]
pub(super) struct State {
    pub clear_generation: u64,
    pub completed_grant: String,
    pub blocked_generation: String,
    pub challenge: Option<PendingAuthRequest>,
    pub pending_ids: BTreeSet<String>,
    pub bootstrap: Option<Arc<Flight>>,
    pub refresh: Option<Arc<Flight>>,
    pub exchange: Option<Arc<Flight>>,
}

impl State {
    pub fn blocked(&self, record: &protocol::Record) -> bool {
        let generation = record.generation();
        !generation.is_empty() && self.blocked_generation == generation
    }

    pub fn clear_challenge(&mut self, auth: &AuthRegistry) {
        for id in &self.pending_ids {
            auth.clear_pending(id);
        }
        self.pending_ids.clear();
        self.challenge = None;
    }

    pub fn remember(&mut self, pending: PendingAuthRequest) {
        self.pending_ids.insert(pending.extension_id.clone());
        self.challenge = Some(pending);
    }
}

pub struct SignedRegistry {
    root: PathBuf,
    pub(super) auth: Arc<AuthRegistry>,
    hints: Mutex<RuntimeHints>,
    scopes: Mutex<BTreeMap<PathBuf, Arc<Mutex<State>>>>,
    pub(super) grants: Mutex<BTreeMap<String, Zeroizing<String>>>,
    closed: AtomicBool,
}

impl SignedRegistry {
    pub fn new(root: &Path, auth: Arc<AuthRegistry>) -> Arc<Self> {
        Arc::new(Self {
            root: root.to_owned(),
            auth,
            hints: Mutex::default(),
            scopes: Mutex::default(),
            grants: Mutex::default(),
            closed: AtomicBool::new(false),
        })
    }

    pub fn set_runtime_state(&self, raw: &str) -> Result<(), String> {
        self.check()?;
        *self.hints.lock().expect("session hints lock") = RuntimeHints::parse(raw);
        Ok(())
    }

    pub fn set_grant(&self, id: &str, grant: &str) -> Result<(), String> {
        let mut grants = self.grants.lock().expect("session grants lock");
        self.check()?;
        if !id.trim().is_empty() && !grant.trim().is_empty() {
            grants.insert(id.trim().into(), Zeroizing::new(grant.trim().into()));
        }
        Ok(())
    }

    pub fn session(
        self: &Arc<Self>,
        id: &str,
        config: SignedSession,
        network: Arc<NetworkSession>,
    ) -> Result<Arc<SignedSessionClient>, String> {
        self.check()?;
        let config = protocol::defaults(config);
        let store = RecordStore::open(&self.root, &config)?;
        let mut scopes = self.scopes.lock().expect("signed session scopes lock");
        self.check()?;
        let scope = Arc::clone(scopes.entry(store.path().to_owned()).or_default());
        Ok(Arc::new(SignedSessionClient {
            id: id.to_owned(),
            registry: Arc::clone(self),
            config,
            store,
            scope,
            network,
            verification_url: Mutex::new(String::new()),
        }))
    }

    pub(super) fn check(&self) -> Result<(), String> {
        if self.closed.load(Ordering::Acquire) {
            Err("extension environment closed".into())
        } else {
            Ok(())
        }
    }

    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.grants.lock().expect("session grants lock").clear();
        for state in self
            .scopes
            .lock()
            .expect("signed session scopes lock")
            .values()
        {
            state
                .lock()
                .expect("signed session coordinator lock")
                .clear_challenge(&self.auth);
        }
    }

    pub(crate) fn forget_extension(&self, id: &str) {
        self.grants.lock().expect("session grants lock").remove(id);
        // Session records can be shared by multiple extensions through their
        // manifest namespace. Only remove this extension's pending challenge.
        for scope in self
            .scopes
            .lock()
            .expect("signed session scopes lock")
            .values()
        {
            let mut state = scope.lock().expect("signed session coordinator lock");
            state.pending_ids.remove(id);
            if state
                .challenge
                .as_ref()
                .is_some_and(|pending| pending.extension_id == id)
            {
                state.challenge = None;
            }
        }
    }
}

pub struct SignedSessionClient {
    pub(super) id: String,
    pub(super) registry: Arc<SignedRegistry>,
    pub(super) config: SignedSession,
    pub(super) store: RecordStore,
    pub(super) scope: Arc<Mutex<State>>,
    pub(super) network: Arc<NetworkSession>,
    verification_url: Mutex<String>,
}

impl SignedSessionClient {
    pub(super) fn check(&self, check: Check<'_>) -> Result<(), String> {
        self.registry.check()?;
        check()
    }

    pub(super) fn load(&self) -> Result<protocol::Record, String> {
        self.store
            .load(&self.registry.hints.lock().expect("session hints lock"))
    }

    pub fn status(&self) -> Result<Value, String> {
        self.registry.check()?;
        let state = self.scope.lock().expect("signed session coordinator lock");
        let record = self.load()?;
        let blocked = state.blocked(&record);
        Ok(
            json!({"authenticated":record.usable(self.registry.auth.now()) && !blocked, "verification_required":blocked,
            "expires_at":record.expires_at,"install_id":record.install_id,"session_id":record.session_id,
            "app_version":self.config.app_version,"platform":self.config.platform}),
        )
    }

    pub fn clear(&self) -> Result<(), String> {
        self.registry.check()?;
        let mut state = self.scope.lock().expect("signed session coordinator lock");
        let mut record = self.load()?;
        record.clear();
        self.store.save(&record)?;
        state.clear_generation = state.clear_generation.wrapping_add(1);
        state.completed_grant.clear();
        state.blocked_generation.clear();
        state.clear_challenge(&self.registry.auth);
        self.registry.auth.clear_pending(&self.id);
        Ok(())
    }

    pub fn take_verification_url(&self) -> String {
        std::mem::take(
            &mut self
                .verification_url
                .lock()
                .expect("signed session verification URL lock"),
        )
    }

    pub(super) fn verification_required(&self, url: String) -> Value {
        if !url.is_empty() {
            *self
                .verification_url
                .lock()
                .expect("signed session verification URL lock") = url.clone();
        }
        json!({"ok":false,"needsVerification":true,"error":"VERIFY_REQUIRED","open_auth_url":url,"auth_url":url})
    }

    pub(super) fn request(
        &self,
        method: &str,
        url: String,
        body: String,
        mut headers: BTreeMap<String, String>,
        check: Check<'_>,
    ) -> Result<HttpResponse, String> {
        self.check(check)?;
        // Header matching is case-insensitive on the wire. Normalize before
        // applying extension overrides so a lowercase override cannot coexist.
        headers = headers
            .into_iter()
            .map(|(key, value)| (key.to_ascii_lowercase(), value))
            .collect();
        headers
            .entry("accept".into())
            .or_insert_with(|| "application/json".into());
        self.network.request(
            HttpRequest {
                url,
                method: method.into(),
                body,
                headers,
                default_json: false,
                user_agent: format!("SpotiFLAC-Mobile/{}", self.config.app_version),
            },
            || self.check(check),
        )
    }

    pub(super) fn signed_request(
        &self,
        record: &protocol::Record,
        method: &str,
        path: &str,
        body: &str,
        extras: &BTreeMap<String, String>,
        check: Check<'_>,
    ) -> Result<HttpResponse, String> {
        let url = protocol::endpoint(&self.config, path)?;
        let mut headers: BTreeMap<_, _> = protocol::signed_headers(
            &self.config,
            record,
            method,
            &url,
            body.as_bytes(),
            self.registry.auth.now(),
            &protocol::random_hex(12)?,
        )?
        .into_iter()
        .map(|(key, value)| (key.to_ascii_lowercase(), value))
        .collect();
        if !body.is_empty() {
            headers.insert("content-type".into(), "application/json".into());
        }
        for (key, value) in extras {
            headers.insert(key.to_ascii_lowercase(), value.clone());
        }
        self.request(method, url, body.into(), headers, check)
    }

    pub(super) fn wait(&self, delay: Duration, check: Check<'_>) -> Result<(), String> {
        let end = Instant::now() + delay;
        loop {
            self.check(check)?;
            let Some(remaining) = end.checked_duration_since(Instant::now()) else {
                return Ok(());
            };
            std::thread::sleep(remaining.min(Duration::from_millis(10)));
        }
    }
}
