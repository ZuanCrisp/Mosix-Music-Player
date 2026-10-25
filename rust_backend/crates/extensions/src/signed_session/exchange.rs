use super::coordinator::{Check, Flight, SignedSessionClient};
use super::protocol::{self, Record};
use crate::auth::{PendingAuthRequest, callback_state};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use spotiflac_network::{query, url::UrlParts};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

enum Bootstrap {
    Session(Record),
    Challenge {
        url: String,
        callback: String,
        state: String,
    },
}

fn response_record(body: &[u8]) -> Result<Record, String> {
    let fields = protocol::object_fields(
        body,
        &[
            "session_id",
            "session_secret",
            "expires_at",
            "challenge_id",
            "challenge_url",
            "auth_url",
        ],
        &[],
        &[],
    )?;
    serde_json::from_value(Value::Object(fields)).map_err(|error| error.to_string())
}

impl SignedSessionClient {
    pub fn preflight(&self, check: impl Fn() -> Result<(), String>) -> Result<bool, String> {
        self.check(&check)?;
        {
            let state = self.scope.lock().expect("signed session coordinator lock");
            let record = self.load()?;
            if record.usable(self.registry.auth.now()) && !state.blocked(&record) {
                return Ok(false);
            }
        }
        let url = self.bootstrap(&check)?;
        if !url.is_empty() {
            return Ok(true);
        }
        let _state = self.scope.lock().expect("signed session coordinator lock");
        if self.load()?.usable(self.registry.auth.now()) {
            Ok(false)
        } else {
            Err(
                "signed-session bootstrap did not return a session or verification challenge"
                    .into(),
            )
        }
    }

    pub(super) fn bootstrap(&self, check: Check<'_>) -> Result<String, String> {
        loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if let Some(challenge) = state.challenge.as_ref().filter(|challenge| {
                !challenge.auth_url.trim().is_empty()
                    && self.registry.auth.now() - challenge.created_at < 180_000_000_000
            }) {
                let mut pending = challenge.clone();
                pending.extension_id = self.id.clone();
                self.registry.auth.register_pending(pending.clone())?;
                state.pending_ids.insert(self.id.clone());
                return Ok(pending.auth_url);
            }
            if state.challenge.is_some() {
                state.clear_challenge(&self.registry.auth);
            }
            if let Some(pending) = self
                .registry
                .auth
                .pending(&self.id)
                .filter(|pending| !pending.auth_url.trim().is_empty())
            {
                let url = pending.auth_url.clone();
                state.remember(pending);
                return Ok(url);
            }
            let record = self
                .load()
                .map_err(|error| format!("load signed-session bootstrap state: {error}"))?;
            if record.usable(self.registry.auth.now()) && !state.blocked(&record) {
                return Ok(String::new());
            }
            if let Some(flight) = state.bootstrap.clone() {
                drop(state);
                flight.wait(&|| self.check(check))?;
                continue;
            }
            let flight = Arc::new(Flight::default());
            state.bootstrap = Some(Arc::clone(&flight));
            let generation = state.clear_generation;
            drop(state);
            let bootstrap = self.perform_bootstrap(&record, check);
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let result = (|| {
                let bootstrap = bootstrap?;
                self.check(check)?;
                if state.clear_generation != generation {
                    return Err("signed-session bootstrap was superseded by session clear".into());
                }
                let mut latest = self.load()?;
                if latest.usable(self.registry.auth.now())
                    && !latest.same_session(&record)
                    && !state.blocked(&latest)
                {
                    state.clear_challenge(&self.registry.auth);
                    return Ok(String::new());
                }
                match bootstrap {
                    Bootstrap::Session(record) => {
                        latest.session_id.clone_from(&record.session_id);
                        latest.session_secret.clone_from(&record.session_secret);
                        latest.expires_at.clone_from(&record.expires_at);
                        self.store.save(&latest).map_err(|error| {
                            format!("save bootstrapped signed session: {error}")
                        })?;
                        state.blocked_generation.clear();
                        state.clear_challenge(&self.registry.auth);
                        Ok(String::new())
                    }
                    Bootstrap::Challenge {
                        url,
                        callback,
                        state: nonce,
                    } => {
                        let pending = PendingAuthRequest {
                            extension_id: self.id.clone(),
                            auth_url: url.clone(),
                            callback_url: callback,
                            state: nonce,
                            created_at: self.registry.auth.now(),
                        };
                        self.registry.auth.register_pending(pending.clone())?;
                        state.remember(pending);
                        Ok(url)
                    }
                }
            })();
            state.bootstrap = None;
            flight.finish(result.as_ref().map(|_| ()).map_err(Clone::clone));
            return result;
        }
    }

    fn perform_bootstrap(&self, record: &Record, check: Check<'_>) -> Result<Bootstrap, String> {
        let url = protocol::endpoint(&self.config, &self.config.endpoints.bootstrap)
            .map_err(|error| format!("build signed-session bootstrap URL: {error}"))?;
        let url = protocol::with_query(
            &url,
            &[
                ("app_version", &self.config.app_version),
                ("install_id", &record.install_id),
            ],
        )?;
        let mut response = self.request("GET", url.clone(), String::new(), BTreeMap::new(), check);
        if response.is_err() {
            self.check(check)?;
            self.network.reset_connections();
            response = self.request("GET", url.clone(), String::new(), BTreeMap::new(), check);
        }
        let response = response.map_err(|error| {
            format!(
                "signed-session bootstrap network request to {} failed: {error}",
                UrlParts::parse(&url)
                    .map(|url| url.authority())
                    .unwrap_or_default()
            )
        })?;
        if !(200..300).contains(&response.status) {
            let mut error = format!(
                "signed-session bootstrap {}returned HTTP {}",
                if response.status >= 500 {
                    "network request "
                } else {
                    ""
                },
                response.status
            );
            let retry = protocol::response_retry_after(&response, self.registry.auth.now());
            if retry > 0 {
                error += &format!("; retry-after seconds: {retry}");
            }
            return Err(error);
        }
        let body = Zeroizing::new(response.body);
        let record = response_record(&body)
            .map_err(|error| format!("decode signed-session bootstrap response: {error}"))?;
        let boot = protocol::object_fields(
            &body,
            &["auth_url", "challenge_url", "challenge_id"],
            &[],
            &[],
        )
        .map_err(|error| format!("decode signed-session bootstrap response: {error}"))?;
        if !record.session_id.is_empty()
            && !record.session_secret.is_empty()
            && !record.expires_at.is_empty()
        {
            return Ok(Bootstrap::Session(record));
        }
        let text = |key| boot.get(key).and_then(Value::as_str).unwrap_or("");
        let mut auth_url = text("auth_url").to_owned();
        if auth_url.is_empty() {
            auth_url = text("challenge_url").to_owned();
        }
        let mut state = callback_state()
            .map_err(|error| format!("prepare signed-session callback state: {error}"))?;
        if let Some(url) = UrlParts::parse(&auth_url) {
            let values = query::parse(&url.raw_query);
            let server_state = values
                .get(b"state".as_slice())
                .and_then(|values| values.first())
                .map(|bytes| crate::host::decode_go_utf8(bytes))
                .unwrap_or_default();
            if !server_state.trim().is_empty() {
                state = server_state.trim().to_owned();
            } else if !auth_url.is_empty() {
                auth_url = protocol::with_query(&auth_url, &[("state", &state)])?;
            }
        }
        let callback = protocol::with_query(&self.config.callback_url, &[("state", &state)])
            .map_err(|error| format!("prepare signed-session callback: {error}"))?;
        if auth_url.is_empty() && !text("challenge_id").is_empty() {
            auth_url = protocol::challenge_url(&self.config, text("challenge_id"), &state)
                .unwrap_or_default();
        }
        if auth_url.is_empty() {
            return Err(
                "signed-session bootstrap did not return a session or verification challenge"
                    .into(),
            );
        }
        Ok(Bootstrap::Challenge {
            url: auth_url,
            callback,
            state,
        })
    }

    pub fn complete_grant(
        &self,
        grant: &str,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        self.registry.set_grant(&self.id, grant)?;
        let grant = self
            .registry
            .grants
            .lock()
            .expect("session grants lock")
            .get(&self.id)
            .cloned()
            .filter(|grant| !grant.is_empty())
            .ok_or("no pending grant")?;
        let end = Instant::now() + Duration::from_secs(30);
        let check = || {
            self.check(&check)?;
            if Instant::now() >= end {
                Err("context deadline exceeded".into())
            } else {
                Ok(())
            }
        };
        self.exchange(&grant, &check)?;
        let mut grants = self.registry.grants.lock().expect("session grants lock");
        // A newer callback can arrive during HTTP. Do not discard its grant.
        if grants
            .get(&self.id)
            .is_some_and(|pending| pending.as_str() == grant.as_str())
        {
            grants.remove(&self.id);
        }
        self.registry.auth.clear_pending(&self.id);
        Ok(())
    }

    fn exchange(&self, grant: &str, check: Check<'_>) -> Result<(), String> {
        let generation = self
            .scope
            .lock()
            .expect("signed session coordinator lock")
            .clear_generation;
        let flight = loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if let Some(flight) = state.exchange.clone() {
                drop(state);
                // Exchange slots serialize different grants. The preceding
                // grant's failure is not the outcome of this new operation.
                let _ = flight.wait(&|| self.check(check));
                self.check(check)?;
            } else {
                let flight = Arc::new(Flight::default());
                state.exchange = Some(Arc::clone(&flight));
                break flight;
            }
        };
        let result = self.exchange_owned(grant, generation, check);
        self.scope
            .lock()
            .expect("signed session coordinator lock")
            .exchange = None;
        flight.finish(result.clone());
        result
    }

    fn exchange_owned(&self, grant: &str, generation: u64, check: Check<'_>) -> Result<(), String> {
        let grant_hash =
            crate::binary::encode(&Sha256::digest(grant), "hex").expect("hex encoding");
        let record = {
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            if state.clear_generation != generation {
                return Err("signed-session exchange was superseded by session clear".into());
            }
            let record = self.load()?;
            if state.completed_grant == grant_hash && record.usable(self.registry.auth.now()) {
                state.blocked_generation.clear();
                state.clear_challenge(&self.registry.auth);
                return Ok(());
            }
            record
        };
        let url = protocol::endpoint(&self.config, &self.config.endpoints.exchange)?;
        let body = Zeroizing::new(json!({"grant":grant,"install_id":record.install_id,"app_version":self.config.app_version,"platform":self.config.platform}).to_string());
        let mut exchanged = None;
        for attempt in 0..3 {
            let response = self.request(
                "POST",
                url.clone(),
                body.to_string(),
                BTreeMap::from([("content-type".into(), "application/json".into())]),
                check,
            )?;
            let retry = protocol::response_retry_after(&response, self.registry.auth.now());
            if response.status == 429 && attempt < 2 {
                self.wait(Duration::from_secs(retry.clamp(1, 300) as u64), check)?;
                continue;
            }
            if !(200..300).contains(&response.status) {
                let mut error = format!("session exchange failed: HTTP {}", response.status);
                if retry > 0 {
                    error += &format!("; retry-after seconds: {retry}");
                }
                return Err(error);
            }
            exchanged = Some(
                response_record(&Zeroizing::new(response.body))
                    .map_err(|error| format!("invalid session exchange response: {error}"))?,
            );
            break;
        }
        let exchanged = exchanged.ok_or("session exchange did not complete")?;
        if exchanged.session_id.is_empty()
            || exchanged.session_secret.is_empty()
            || exchanged.expires_at.is_empty()
        {
            return Err("session exchange response missing session fields".into());
        }
        self.check(check)?;
        let mut state = self.scope.lock().expect("signed session coordinator lock");
        if state.clear_generation != generation {
            return Err("signed-session exchange was superseded by session clear".into());
        }
        let mut latest = self.load()?;
        if !(latest.usable(self.registry.auth.now())
            && (state.completed_grant == grant_hash || !latest.same_session(&record)))
        {
            latest.session_id.clone_from(&exchanged.session_id);
            latest.session_secret.clone_from(&exchanged.session_secret);
            latest.expires_at.clone_from(&exchanged.expires_at);
            self.store.save(&latest)?;
            state.completed_grant = grant_hash;
        }
        state.blocked_generation.clear();
        state.clear_challenge(&self.registry.auth);
        Ok(())
    }

    pub(super) fn refresh(&self, check: Check<'_>) -> Result<(), String> {
        loop {
            self.check(check)?;
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let record = self.load()?;
            if !record.refresh_due(&self.config, self.registry.auth.now()) {
                return Ok(());
            }
            if let Some(flight) = state.refresh.clone() {
                drop(state);
                flight.wait(&|| self.check(check))?;
                continue;
            }
            let flight = Arc::new(Flight::default());
            state.refresh = Some(Arc::clone(&flight));
            let generation = state.clear_generation;
            drop(state);
            let response = self.signed_request(
                &record,
                "POST",
                &self.config.endpoints.refresh,
                &json!({"install_id":record.install_id}).to_string(),
                &BTreeMap::new(),
                check,
            );
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let result = (|| {
                let response = response?;
                if !(200..300).contains(&response.status) {
                    return Err(format!("session refresh failed: HTTP {}", response.status));
                }
                let refreshed = response_record(&Zeroizing::new(response.body))?;
                self.check(check)?;
                if state.clear_generation != generation {
                    return Err("signed-session refresh was superseded by session clear".into());
                }
                let mut latest = self.load()?;
                if latest.same_session(&record) {
                    let mut changed = false;
                    for (field, value) in [
                        (&mut latest.session_id, &refreshed.session_id),
                        (&mut latest.session_secret, &refreshed.session_secret),
                        (&mut latest.expires_at, &refreshed.expires_at),
                    ] {
                        if !value.is_empty() && field != value {
                            field.clone_from(value);
                            changed = true;
                        }
                    }
                    if changed {
                        self.store.save(&latest)?;
                    }
                }
                Ok(())
            })();
            state.refresh = None;
            flight.finish(result.clone());
            return result;
        }
    }
}
