use super::{AuthRegistry, PendingAuthRequest, callback_state, pkce_challenge, pkce_verifier};
use serde_json::{Map, Value, json};
use spotiflac_core::app_version::AppVersion;
use spotiflac_network::{HttpRequest, NetworkSession, query};
use std::collections::BTreeMap;
use std::sync::Arc;
use zeroize::Zeroizing;

pub struct ExtensionAuth {
    id: String,
    registry: Arc<AuthRegistry>,
    network: Arc<NetworkSession>,
    app_version: AppVersion,
}

impl ExtensionAuth {
    pub fn new(
        id: &str,
        registry: Arc<AuthRegistry>,
        network: Arc<NetworkSession>,
        app_version: impl Into<AppVersion>,
    ) -> Self {
        Self {
            id: id.to_owned(),
            registry,
            network,
            app_version: app_version.into(),
        }
    }

    pub fn call(
        &self,
        method: &str,
        arguments: &[Value],
        expires_is_float: bool,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        check()?;
        let first = arguments.first().unwrap_or(&Value::Null);
        match method {
            "getAuthCode" => Ok(self
                .registry
                .code(&self.id)
                .map_or(Value::Null, Value::String)),
            "getTokens" => Ok(self.registry.tokens(&self.id)),
            "isAuthenticated" => Ok(json!(self.registry.authenticated(&self.id))),
            "clearAuth" => {
                self.registry.clear(&self.id);
                Ok(json!(true))
            }
            "setAuthCode" => {
                if arguments.is_empty() {
                    return Ok(json!(false));
                }
                self.registry.edit(&self.id, |record| {
                    if let Some(code) = first.as_str() {
                        record.code = Zeroizing::new(code.to_owned());
                    } else if let Some(value) = first.as_object() {
                        if let Some(code) = value.get("code").and_then(Value::as_str) {
                            record.code = Zeroizing::new(code.to_owned());
                        }
                        if let Some(access) = value.get("access_token").and_then(Value::as_str) {
                            record.access_token = Zeroizing::new(access.to_owned());
                            record.authenticated = true;
                        }
                        if let Some(refresh) = value.get("refresh_token").and_then(Value::as_str) {
                            record.refresh_token = Zeroizing::new(refresh.to_owned());
                        }
                        if expires_is_float
                            && let Some(expires) = value.get("expires_in").and_then(Value::as_f64)
                        {
                            record.expires_at = Some(
                                self.registry.now()
                                    + i128::from((expires as i64).wrapping_mul(1_000_000_000)),
                            );
                        }
                    }
                })?;
                Ok(json!(true))
            }
            "generatePKCE" => {
                let length = first.as_u64().unwrap_or(64) as usize;
                let verifier = pkce_verifier(length)?;
                self.store_pkce(&verifier, false)?;
                Ok(
                    json!({"verifier":verifier,"challenge":pkce_challenge(&verifier),"method":"S256"}),
                )
            }
            "getPKCE" => {
                let state = self.registry.state.lock().expect("auth registry lock");
                Ok(state.records.get(&self.id).filter(|record| !record.verifier.is_empty())
                    .map_or_else(|| json!({}), |record| json!({"verifier":record.verifier.as_str(),"challenge":record.challenge,"method":"S256"})))
            }
            "openAuthUrl" => {
                if arguments.is_empty() {
                    return Err("auth URL is required".into());
                }
                let mut url = self
                    .network
                    .validate_auth_url(first.as_str().unwrap_or(""), &check)?;
                let nonce = callback_state()?;
                let mut params = query::parse(&url.raw_query);
                query::set(&mut params, "state", &nonce);
                url.raw_query = query::encode(&params);
                self.registry.register_pending(PendingAuthRequest {
                    extension_id: self.id.clone(),
                    auth_url: url.display_url(),
                    callback_url: arguments
                        .get(1)
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned(),
                    state: nonce,
                    created_at: self.registry.now(),
                })?;
                self.registry.set_code(&self.id, "")?;
                Ok(json!({"success":true,"message":"Auth URL will be opened by the app"}))
            }
            "startOAuthWithPKCE" | "exchangeCodeWithPKCE" => {
                if arguments.is_empty() {
                    return Err("config object is required".into());
                }
                let config = first
                    .as_object()
                    .ok_or_else(|| "config must be an object".to_owned())?;
                if method == "startOAuthWithPKCE" {
                    self.start(config, &check)
                } else {
                    self.exchange(config, &check)
                }
            }
            _ => Err("unknown auth method".into()),
        }
    }

    fn store_pkce(&self, verifier: &str, clear_code: bool) -> Result<(), String> {
        self.registry.edit(&self.id, |record| {
            record.verifier = Zeroizing::new(verifier.to_owned());
            record.challenge = pkce_challenge(verifier);
            if clear_code {
                record.code = Zeroizing::default();
            }
        })
    }

    fn start(
        &self,
        config: &Map<String, Value>,
        check: &impl Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let auth_url = string(config, "authUrl");
        let client = string(config, "clientId");
        let redirect = string(config, "redirectUri");
        if auth_url.is_empty() || client.is_empty() || redirect.is_empty() {
            return Err("authUrl, clientId, and redirectUri are required".into());
        }
        let mut url = self.network.validate_auth_url(auth_url, check)?;
        let verifier = Zeroizing::new(
            pkce_verifier(64).map_err(|error| format!("failed to generate PKCE: {error}"))?,
        );
        let challenge = pkce_challenge(&verifier);
        self.store_pkce(&verifier, true)?;
        let mut params = query::parse(&url.raw_query);
        for (key, value) in [
            ("client_id", client),
            ("redirect_uri", redirect),
            ("response_type", "code"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
        ] {
            query::set(&mut params, key, value);
        }
        let scope = string(config, "scope");
        if !scope.is_empty() {
            query::set(&mut params, "scope", scope);
        }
        extra_params(config, &mut params);
        let nonce =
            callback_state().map_err(|error| format!("failed to generate OAuth state: {error}"))?;
        query::set(&mut params, "state", &nonce);
        url.raw_query = query::encode(&params);
        let auth_url = url.display_url();
        self.registry
            .register_pending(PendingAuthRequest {
                extension_id: self.id.clone(),
                auth_url: auth_url.clone(),
                callback_url: redirect.to_owned(),
                state: nonce,
                created_at: self.registry.now(),
            })
            .map_err(|error| format!("failed to register OAuth callback: {error}"))?;
        Ok(
            json!({"success":true,"authUrl":auth_url,"pkce":{"verifier":verifier.as_str(),"challenge":challenge,"method":"S256"}}),
        )
    }

    fn exchange(
        &self,
        config: &Map<String, Value>,
        check: &impl Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let token_url = string(config, "tokenUrl");
        let client = string(config, "clientId");
        let code = string(config, "code");
        if token_url.is_empty() || client.is_empty() || code.is_empty() {
            return Err("tokenUrl, clientId, and code are required".into());
        }
        let (verifier, generation) = {
            let state = self.registry.state.lock().expect("auth registry lock");
            let verifier = state
                .records
                .get(&self.id)
                .map(|record| record.verifier.clone())
                .unwrap_or_default();
            (
                verifier,
                state.generations.get(&self.id).copied().unwrap_or(0),
            )
        };
        if verifier.is_empty() {
            return Err(
                "no PKCE verifier found - call generatePKCE or startOAuthWithPKCE first".into(),
            );
        }
        self.network.validate_url(token_url)?;
        let mut params = query::Query::new();
        for (key, value) in [
            ("grant_type", "authorization_code"),
            ("client_id", client),
            ("code", code),
            ("code_verifier", &verifier),
        ] {
            query::set(&mut params, key, value);
        }
        let redirect = string(config, "redirectUri");
        if !redirect.is_empty() {
            query::set(&mut params, "redirect_uri", redirect);
        }
        extra_params(config, &mut params);
        let response = self.network.request(
            HttpRequest {
                url: token_url.to_owned(),
                method: "POST".into(),
                body: query::encode(&params),
                headers: BTreeMap::from([(
                    "Content-Type".into(),
                    "application/x-www-form-urlencoded".into(),
                )]),
                default_json: false,
                user_agent: self.app_version.user_agent(),
            },
            check,
        )?;
        let body = Zeroizing::new(response.body);
        let token = match serde_json::from_slice::<Value>(&body) {
            Ok(Value::Object(token)) => token,
            Ok(Value::Null) => Map::new(),
            result => {
                let message = match result {
                    Err(error) => error.to_string(),
                    _ => "token response must be an object".into(),
                };
                return Ok(
                    json!({"success":false,"error":format!("failed to parse token response: {message}"),"body":crate::redact::preview(&body, 1000)}),
                );
            }
        };
        if let Some(error) = token.get("error").and_then(Value::as_str) {
            return Ok(
                json!({"success":false,"error":error,"error_description":string(&token,"error_description")}),
            );
        }
        let access = string(&token, "access_token");
        let refresh = string(&token, "refresh_token");
        let expires = token
            .get("expires_in")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        if access.is_empty() {
            return Ok(
                json!({"success":false,"error":"no access_token in response","body":crate::redact::preview(&body, 1000)}),
            );
        }
        check()?;
        let mut state = self.registry.state.lock().expect("auth registry lock");
        if state.closed || state.generations.get(&self.id).copied().unwrap_or(0) != generation {
            return Err("authentication state changed during token exchange".into());
        }
        let record = state.records.entry(self.id.clone()).or_default();
        record.access_token = Zeroizing::new(access.to_owned());
        record.refresh_token = Zeroizing::new(refresh.to_owned());
        record.authenticated = true;
        if expires > 0.0 {
            record.expires_at = Some(
                self.registry.now() + i128::from((expires as i64).wrapping_mul(1_000_000_000)),
            );
        }
        record.verifier = Zeroizing::default();
        record.challenge.clear();
        let generation = state.generations.entry(self.id.clone()).or_default();
        *generation = generation.wrapping_add(1);
        let mut result = json!({"success":true,"access_token":access,"refresh_token":refresh,"token_type":token.get("token_type")});
        if expires > 0.0 {
            result["expires_in"] = json!(expires);
        }
        if let Some(scope) = token.get("scope").and_then(Value::as_str) {
            result["scope"] = json!(scope);
        }
        Ok(result)
    }
}

fn string<'a>(config: &'a Map<String, Value>, key: &str) -> &'a str {
    config.get(key).and_then(Value::as_str).unwrap_or("")
}

// The JS bridge exports extraParams with Go's fmt formatting, rather than JSON.
fn extra_params(config: &Map<String, Value>, params: &mut query::Query) {
    if let Some(extras) = config.get("extraParams").and_then(Value::as_object) {
        for (key, value) in extras {
            query::set(params, key, value.as_str().unwrap_or(""));
        }
    }
}
