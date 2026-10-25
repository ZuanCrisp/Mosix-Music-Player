//! Shared OAuth state and one-time callback ownership for managed runtimes.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

mod client;
mod persistence;
pub use client::ExtensionAuth;

const SECOND: i128 = 1_000_000_000;
const PENDING_TTL: i128 = 180 * SECOND;

pub trait AuthClock: Send + Sync {
    fn now_nanos(&self) -> i128;
}

struct SystemClock;
impl AuthClock for SystemClock {
    fn now_nanos(&self) -> i128 {
        SystemTime::now().duration_since(UNIX_EPOCH).map_or_else(
            |error| -(error.duration().as_nanos() as i128),
            |time| time.as_nanos() as i128,
        )
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct PendingAuthRequest {
    pub extension_id: String,
    pub auth_url: String,
    pub callback_url: String,
    #[serde(skip)]
    pub state: String,
    #[serde(skip)]
    pub created_at: i128,
}

#[derive(Default)]
struct Record {
    code: Zeroizing<String>,
    access_token: Zeroizing<String>,
    refresh_token: Zeroizing<String>,
    verifier: Zeroizing<String>,
    challenge: String,
    authenticated: bool,
    expires_at: Option<i128>,
}

#[derive(Default)]
struct State {
    records: BTreeMap<String, Record>,
    generations: BTreeMap<String, u64>,
    pending: BTreeMap<String, PendingAuthRequest>,
    owners: BTreeMap<String, String>,
    closed: bool,
}

pub struct AuthRegistry {
    state: Mutex<State>,
    clock: Arc<dyn AuthClock>,
    persistence: Option<persistence::PendingStore>,
}

impl Default for AuthRegistry {
    fn default() -> Self {
        Self::with_clock(Arc::new(SystemClock))
    }
}

impl AuthRegistry {
    pub fn with_clock(clock: Arc<dyn AuthClock>) -> Self {
        Self {
            state: Mutex::default(),
            clock,
            persistence: None,
        }
    }

    pub fn persistent(root: &std::path::Path, key: &crate::storage::StorageMasterKey) -> Self {
        Self::persistent_with_clock(root, key, Arc::new(SystemClock))
    }

    fn persistent_with_clock(
        root: &std::path::Path,
        key: &crate::storage::StorageMasterKey,
        clock: Arc<dyn AuthClock>,
    ) -> Self {
        let mut registry = Self::with_clock(clock);
        let store = persistence::PendingStore::new(root, key);
        // A corrupt/old-key journal invalidates only pending challenges, not
        // installed extensions. Callback ownership is never inferred from URLs.
        for saved in store.load(registry.now()).unwrap_or_default() {
            let mut request = saved.request;
            request.state = saved.nonce;
            request.created_at = saved.created_at;
            let id = request.extension_id.clone();
            if registry.register_pending(request).is_ok() && !saved.verifier.is_empty() {
                let _ = registry.edit(&id, |record| {
                    record.challenge = pkce_challenge(&saved.verifier);
                    record.verifier = Zeroizing::new(saved.verifier);
                });
            }
        }
        registry.persistence = Some(store);
        registry
    }

    fn persist(&self, state: &State) -> Result<(), String> {
        self.persistence
            .as_ref()
            .map_or(Ok(()), |store| store.save(state, self.now()))
    }

    pub fn now(&self) -> i128 {
        self.clock.now_nanos()
    }

    fn edit<T>(&self, id: &str, edit: impl FnOnce(&mut Record) -> T) -> Result<T, String> {
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return Err("extension environment closed".into());
        }
        let generation = state.generations.entry(id.to_owned()).or_default();
        *generation = generation.wrapping_add(1);
        Ok(edit(state.records.entry(id.to_owned()).or_default()))
    }

    pub fn set_code(&self, id: &str, code: &str) -> Result<(), String> {
        self.edit(id, |record| record.code = Zeroizing::new(code.to_owned()))
    }

    pub fn code(&self, id: &str) -> Option<String> {
        self.state
            .lock()
            .expect("auth registry lock")
            .records
            .get(id)
            .filter(|record| !record.code.is_empty())
            .map(|record| record.code.to_string())
    }

    pub fn authenticated(&self, id: &str) -> bool {
        let now = self.now();
        self.state
            .lock()
            .expect("auth registry lock")
            .records
            .get(id)
            .is_some_and(|record| {
                record.authenticated && record.expires_at.is_none_or(|expires| now <= expires)
            })
    }

    pub fn tokens(&self, id: &str) -> Value {
        let state = self.state.lock().expect("auth registry lock");
        let Some(record) = state.records.get(id) else {
            return json!({});
        };
        let mut result = json!({"access_token":record.access_token.as_str(),"refresh_token":record.refresh_token.as_str(),"is_authenticated":record.authenticated});
        if let Some(expires) = record.expires_at {
            result["expires_at"] = json!(expires.div_euclid(SECOND) as i64);
            result["is_expired"] = json!(self.now() > expires);
        }
        result
    }

    pub fn clear(&self, id: &str) {
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return;
        }
        state.records.remove(id);
        let generation = state.generations.entry(id.to_owned()).or_default();
        *generation = generation.wrapping_add(1);
        Self::remove_pending(&mut state, id, self.now());
        let _ = self.persist(&state);
    }

    pub fn register_pending(&self, mut request: PendingAuthRequest) -> Result<(), String> {
        if request.extension_id.trim().is_empty() {
            return Err("extension id is required".into());
        }
        if request.state.is_empty() {
            request.state = callback_state()?;
        }
        if request.created_at == 0 {
            request.created_at = self.now();
        }
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return Err("extension environment closed".into());
        }
        let previous = state.pending.clone();
        let previous_owners = state.owners.clone();
        if let Some(owner) = state
            .owners
            .get(&request.state)
            .filter(|owner| **owner != request.extension_id)
        {
            let same = state.pending.get(owner).is_some_and(|previous| {
                previous.state == request.state
                    && previous.auth_url == request.auth_url
                    && previous.callback_url == request.callback_url
                    && previous.created_at == request.created_at
            });
            if !same {
                return Err("callback state is already registered".into());
            }
        }
        if state
            .pending
            .get(&request.extension_id)
            .is_some_and(|previous| previous.state != request.state)
        {
            Self::remove_pending(&mut state, &request.extension_id, self.now());
        }
        state
            .owners
            .entry(request.state.clone())
            .or_insert_with(|| request.extension_id.clone());
        state.pending.insert(request.extension_id.clone(), request);
        if let Err(error) = self.persist(&state) {
            state.pending = previous;
            state.owners = previous_owners;
            return Err(error);
        }
        Ok(())
    }

    fn remove_pending(state: &mut State, id: &str, now: i128) {
        let Some(request) = state.pending.remove(id) else {
            return;
        };
        if state
            .owners
            .get(&request.state)
            .is_none_or(|owner| owner != id)
        {
            return;
        }
        state.owners.remove(&request.state);
        if let Some((id, _)) = state.pending.iter().find(|(_, candidate)| {
            candidate.state == request.state && now - candidate.created_at < PENDING_TTL
        }) {
            state.owners.insert(request.state, id.clone());
        }
    }

    pub fn clear_pending(&self, id: &str) {
        let mut state = self.state.lock().expect("auth registry lock");
        Self::remove_pending(&mut state, id, self.now());
        let _ = self.persist(&state);
    }

    pub fn pending(&self, id: &str) -> Option<PendingAuthRequest> {
        let mut state = self.state.lock().expect("auth registry lock");
        if state
            .pending
            .get(id)
            .is_some_and(|request| self.now() - request.created_at >= PENDING_TTL)
        {
            Self::remove_pending(&mut state, id, self.now());
        }
        state.pending.get(id).cloned()
    }

    pub(crate) fn has_fresh_challenge(&self, id: &str) -> bool {
        self.pending(id).is_some_and(|request| {
            request.extension_id == id
                && !request.auth_url.trim().is_empty()
                && (0..PENDING_TTL).contains(&(self.now() - request.created_at))
        })
    }

    pub fn resolve_callback(&self, nonce: &str, consume: bool) -> Result<String, String> {
        let nonce = nonce.trim();
        if nonce.is_empty() {
            return Err("callback state is required".into());
        }
        let mut state = self.state.lock().expect("auth registry lock");
        let owner = state.owners.get(nonce).cloned();
        let valid = owner
            .as_ref()
            .and_then(|owner| state.pending.get(owner))
            .is_some_and(|request| {
                request.state == nonce
                    && (0..PENDING_TTL).contains(&(self.now() - request.created_at))
            });
        if !valid || consume {
            state.owners.remove(nonce);
            state.pending.retain(|_, request| request.state != nonce);
            self.persist(&state)?;
        }
        if valid {
            Ok(owner.expect("validated callback owner"))
        } else {
            Err("callback state is invalid, expired, or already used".into())
        }
    }

    pub fn shutdown(&self) {
        let mut state = self.state.lock().expect("auth registry lock");
        *state = State {
            closed: true,
            ..State::default()
        };
    }
}

pub fn callback_state() -> Result<String, String> {
    let mut random = Zeroizing::new([0_u8; 32]);
    getrandom::fill(random.as_mut())
        .map_err(|error| format!("generate callback state: {error}"))?;
    Ok(URL_SAFE_NO_PAD.encode(random.as_ref()))
}

pub fn pkce_verifier(length: usize) -> Result<String, String> {
    let length = length.clamp(43, 128);
    let mut random = Zeroizing::new(vec![0; length]);
    getrandom::fill(&mut random).map_err(|error| error.to_string())?;
    let mut verifier = URL_SAFE_NO_PAD.encode(random.as_slice());
    verifier.truncate(length);
    Ok(verifier)
}

pub fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(byte: u8) -> crate::storage::StorageMasterKey {
        crate::storage::StorageMasterKey::from_base64(
            &base64::engine::general_purpose::STANDARD.encode([byte; 32]),
        )
        .unwrap()
    }

    fn challenge(nonce: &str, age_seconds: i128) -> PendingAuthRequest {
        PendingAuthRequest {
            extension_id: "example.auth".into(),
            auth_url: "https://example.test/verify".into(),
            callback_url: "mornye://session-grant".into(),
            state: nonce.into(),
            created_at: (1000 - age_seconds) * SECOND,
        }
    }

    #[test]
    fn encrypted_challenge_and_pkce_survive_restart_but_consumption_does_not_replay() {
        let root = tempfile::tempdir().unwrap();
        let key = key(7);
        let auth = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        auth.edit("example.auth", |record| {
            record.verifier = Zeroizing::new("private-pkce-verifier".into());
        })
        .unwrap();
        auth.register_pending(challenge("private-browser-nonce", 0))
            .unwrap();
        let encrypted = std::fs::read(root.path().join(".pending-auth.enc")).unwrap();
        for secret in ["private-pkce-verifier", "private-browser-nonce"] {
            assert!(
                !encrypted
                    .windows(secret.len())
                    .any(|window| window == secret.as_bytes())
            );
        }
        auth.shutdown();
        drop(auth);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert_eq!(
            restored
                .resolve_callback("private-browser-nonce", false)
                .unwrap(),
            "example.auth"
        );
        assert_eq!(
            restored.state.lock().unwrap().records["example.auth"]
                .verifier
                .as_str(),
            "private-pkce-verifier"
        );
        assert!(restored.resolve_callback("unregistered", false).is_err());
        let public = serde_json::to_value(restored.pending("example.auth").unwrap()).unwrap();
        assert!(public.get("state").is_none());
        assert!(public.get("created_at").is_none());
        restored
            .resolve_callback("private-browser-nonce", true)
            .unwrap();
        drop(restored);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert!(
            restored
                .resolve_callback("private-browser-nonce", false)
                .is_err()
        );
    }

    #[test]
    fn restart_rejects_expired_future_replaced_and_cleared_challenges() {
        let root = tempfile::tempdir().unwrap();
        let key = key(7);
        for age in [-1, 180] {
            let auth = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
            auth.register_pending(challenge("stale", age)).unwrap();
            drop(auth);
            let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
            assert!(restored.resolve_callback("stale", false).is_err());
        }
        let auth = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        auth.register_pending(challenge("old", 0)).unwrap();
        auth.register_pending(challenge("new", 0)).unwrap();
        drop(auth);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert!(restored.resolve_callback("old", false).is_err());
        assert!(restored.resolve_callback("new", false).is_ok());
        restored.clear_pending("example.auth");
        drop(restored);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert!(restored.resolve_callback("new", false).is_err());
    }

    #[test]
    fn shared_scope_callbacks_remain_one_time_after_restart() {
        let root = tempfile::tempdir().unwrap();
        let key = key(7);
        let auth = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        auth.register_pending(challenge("shared", 0)).unwrap();
        let mut alias = challenge("shared", 0);
        alias.extension_id = "example.other".into();
        auth.register_pending(alias).unwrap();
        drop(auth);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        restored.clear_pending("example.auth");
        assert_eq!(
            restored.resolve_callback("shared", true).unwrap(),
            "example.other"
        );
        drop(restored);
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert!(restored.resolve_callback("shared", false).is_err());
    }

    #[test]
    fn corrupt_or_changed_key_journal_never_restores_callback_ownership() {
        let root = tempfile::tempdir().unwrap();
        let key = key(7);
        let auth = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        auth.register_pending(challenge("nonce", 0)).unwrap();
        drop(auth);
        let other_key = super::tests::key(8);
        let restored =
            AuthRegistry::persistent_with_clock(root.path(), &other_key, Arc::new(Clock));
        assert!(restored.pending("example.auth").is_none());
        std::fs::write(root.path().join(".pending-auth.enc"), b"corrupt").unwrap();
        let restored = AuthRegistry::persistent_with_clock(root.path(), &key, Arc::new(Clock));
        assert!(restored.pending("example.auth").is_none());
        restored
            .register_pending(challenge("replacement", 0))
            .unwrap();
        assert!(restored.resolve_callback("replacement", false).is_ok());
    }

    #[test]
    fn failed_journal_write_does_not_publish_an_unsaved_challenge() {
        let root = tempfile::tempdir().unwrap();
        let auth = AuthRegistry::persistent_with_clock(root.path(), &key(7), Arc::new(Clock));
        std::fs::create_dir(root.path().join(".pending-auth.enc")).unwrap();
        assert!(auth.register_pending(challenge("unsaved", 0)).is_err());
        assert!(auth.pending("example.auth").is_none());
    }

    struct Clock;
    impl AuthClock for Clock {
        fn now_nanos(&self) -> i128 {
            1000 * SECOND
        }
    }

    #[test]
    fn verification_requires_own_nonempty_challenge_between_zero_and_180_seconds_old() {
        for (age, url, expected) in [
            (-1, "https://example.test/verify", false),
            (0, "https://example.test/verify", true),
            (179, "https://example.test/verify", true),
            (180, "https://example.test/verify", false),
            (0, " \n", false),
        ] {
            let auth = AuthRegistry::with_clock(Arc::new(Clock));
            auth.register_pending(PendingAuthRequest {
                extension_id: "example.auth".into(),
                auth_url: url.into(),
                callback_url: "mornye://callback".into(),
                state: "state".into(),
                created_at: (1000 - age) * SECOND,
            })
            .unwrap();
            assert_eq!(auth.has_fresh_challenge("example.auth"), expected);
            assert!(!auth.has_fresh_challenge("example.other"));
        }
    }
}
