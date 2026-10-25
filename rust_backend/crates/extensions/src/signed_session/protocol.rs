use crate::manifest::SignedSession;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use spotiflac_network::{HttpResponse, query, url::UrlParts};
use std::collections::BTreeMap;
use std::time::{Duration, UNIX_EPOCH};
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time};
use zeroize::{Zeroize, Zeroizing};

pub fn defaults(mut config: SignedSession) -> SignedSession {
    for (value, fallback) in [
        (&mut config.app_version, "ext-1.0"),
        (&mut config.platform, "extension"),
        (&mut config.callback_url, "spotiflac://session-grant"),
        (&mut config.scheme_label, "SPOTIFLAC-HMAC-V1"),
        (&mut config.header_prefix, "X-Sig-"),
        (&mut config.endpoints.bootstrap, "/bootstrap"),
        (&mut config.endpoints.challenge, "/challenge"),
        (&mut config.endpoints.exchange, "/session/exchange"),
    ] {
        if value.is_empty() {
            *value = fallback.into();
        }
    }
    if config.time_window_seconds <= 0 {
        config.time_window_seconds = 300;
    }
    config
}

pub fn namespace(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .chars()
        .filter(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ".-_".contains(*ch))
        .collect::<String>()
        .trim_matches(['.', '-', '_'])
        .to_owned()
}

pub fn filename(config: &SignedSession) -> Result<String, String> {
    let namespace = namespace(&config.namespace);
    if namespace.is_empty() {
        return Err("signed session namespace is empty".into());
    }
    let scope = [
        namespace.as_str(),
        &config.base_url.trim().to_lowercase(),
        &config.app_version.trim().to_lowercase(),
        &config.platform.trim().to_lowercase(),
    ]
    .join("\n");
    Ok(format!(
        "{namespace}-{}.json",
        &hex(&Sha256::digest(scope))[..16]
    ))
}

pub fn endpoint(config: &SignedSession, endpoint: &str) -> Result<String, String> {
    let base = UrlParts::parse(&(config.base_url.trim_end_matches('/').to_owned() + "/"))
        .filter(|base| base.scheme == "https" && !base.hostname.is_empty())
        .ok_or("invalid signed session baseUrl")?;
    let endpoint = endpoint.trim();
    if endpoint.is_empty() {
        return Err("signed session endpoint is empty".into());
    }
    if endpoint.starts_with("https://") {
        return Ok(endpoint.to_owned());
    }
    base.resolve(endpoint.trim_start_matches('/'))
        .map(|url| url.display_url())
        .ok_or_else(|| "invalid signed session endpoint".into())
}

pub fn with_query(input: &str, values: &[(&str, &str)]) -> Result<String, String> {
    let mut url = UrlParts::parse(input).ok_or("invalid signed session URL")?;
    let mut query = query::parse(&url.raw_query);
    for (key, value) in values {
        query::set(&mut query, key, value);
    }
    url.raw_query = query::encode(&query);
    Ok(url.display_url())
}

pub fn challenge_url(
    config: &SignedSession,
    challenge: &str,
    state: &str,
) -> Result<String, String> {
    let callback = with_query(
        &config.callback_url,
        &[("cb_version", "v2grant"), ("state", state)],
    )?;
    with_query(
        &endpoint(config, &config.endpoints.challenge)?,
        &[("id", challenge), ("cb", &callback)],
    )
}

pub fn parse_time(value: &str) -> Option<i128> {
    // Match Go's RFC3339 fallback parser: uppercase T/Z, one- or two-digit
    // hours, comma fractions, truncated nanoseconds, and normalized +24:60.
    fn number(value: &str, minimum: usize, maximum: usize) -> Option<u32> {
        ((minimum..=maximum).contains(&value.len())
            && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| value.parse().ok())
        .flatten()
    }
    let (date, clock) = value.trim().split_once('T')?;
    let mut date = date.split('-');
    let year = number(date.next()?, 4, 4)? as i32;
    let month = Month::try_from(number(date.next()?, 2, 2)? as u8).ok()?;
    let day = number(date.next()?, 2, 2)? as u8;
    if date.next().is_some() {
        return None;
    }
    let zone_start = clock.find(['Z', '+', '-'])?;
    let (clock, zone) = clock.split_at(zone_start);
    let offset = if zone == "Z" {
        0
    } else {
        let (sign, zone) = zone.split_at(1);
        let (hours, minutes) = zone.split_once(':')?;
        let hours = number(hours, 2, 2)?;
        let minutes = number(minutes, 2, 2)?;
        if hours > 24 || minutes > 60 {
            return None;
        }
        i128::from(hours * 3600 + minutes * 60)
            * if sign == "-" {
                -1
            } else if sign == "+" {
                1
            } else {
                return None;
            }
    };
    let mut clock = clock.split(':');
    let hours = number(clock.next()?, 1, 2)? as u8;
    let minutes = number(clock.next()?, 2, 2)? as u8;
    let seconds = clock.next()?;
    if clock.next().is_some() {
        return None;
    }
    let (seconds, fraction) = seconds.split_once(['.', ',']).unwrap_or((seconds, ""));
    let seconds = number(seconds, 2, 2)? as u8;
    let nanos = if fraction.is_empty() {
        if value.contains(['.', ',']) {
            return None;
        }
        0
    } else {
        if !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        let digits = &fraction[..fraction.len().min(9)];
        digits.parse::<u32>().ok()? * 10_u32.pow(9 - digits.len() as u32)
    };
    let date = Date::from_calendar_date(year, month, day).ok()?;
    let time = Time::from_hms_nano(hours, minutes, seconds, nanos).ok()?;
    Some(
        PrimitiveDateTime::new(date, time)
            .assume_utc()
            .unix_timestamp_nanos()
            - offset * 1_000_000_000,
    )
}

fn string_or_null<'de, D: serde::Deserializer<'de>>(value: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(value)?.unwrap_or_default())
}

// Go's JSON struct decoder accepts ASCII case-insensitive field names and
// treats null scalars as their zero values. All gateway decisions use this path.
pub(super) fn object_fields(
    bytes: &[u8],
    strings: &[&str],
    booleans: &[&str],
    integers: &[&str],
) -> Result<serde_json::Map<String, Value>, String> {
    struct Fields<'a>([&'a [&'a str]; 3]);
    impl<'de> serde::de::Visitor<'de> for Fields<'_> {
        type Value = serde_json::Map<String, Value>;
        fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("a signed session object")
        }
        fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
            Ok(serde_json::Map::new())
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut map: A,
        ) -> Result<Self::Value, A::Error> {
            let mut result = serde_json::Map::new();
            while let Some(key) = map.next_key::<String>()? {
                let key = key.to_ascii_lowercase();
                let Some(kind) = self
                    .0
                    .iter()
                    .position(|fields| fields.contains(&key.as_str()))
                else {
                    map.next_value::<serde::de::IgnoredAny>()?;
                    continue;
                };
                let value = map.next_value::<Value>()?;
                if value.is_null() {
                    continue;
                }
                let valid = match kind {
                    0 => value.is_string(),
                    1 => value.is_boolean(),
                    _ => value
                        .as_i64()
                        .is_some_and(|value| isize::try_from(value).is_ok()),
                };
                if !valid {
                    return Err(serde::de::Error::custom(format!(
                        "invalid signed session field: {key}"
                    )));
                }
                // Preserve encounter order across duplicate/case-folded keys;
                // null leaves the preceding scalar untouched, as in Go.
                result.insert(key, value);
            }
            Ok(result)
        }
    }
    let mut decoder = serde_json::Deserializer::from_slice(bytes);
    let result =
        serde::Deserializer::deserialize_any(&mut decoder, Fields([strings, booleans, integers]))
            .map_err(|error| error.to_string())?;
    decoder.end().map_err(|error| error.to_string())?;
    Ok(result)
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct Record {
    #[serde(default, deserialize_with = "string_or_null")]
    pub install_id: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub session_id: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub session_secret: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub expires_at: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub namespace: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub base_url: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub app_version: String,
    #[serde(
        default,
        skip_serializing_if = "String::is_empty",
        deserialize_with = "string_or_null"
    )]
    pub platform: String,
}

impl Drop for Record {
    fn drop(&mut self) {
        self.session_secret.zeroize();
    }
}

impl Record {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        serde_json::from_value(Value::Object(object_fields(
            bytes,
            &[
                "install_id",
                "session_id",
                "session_secret",
                "expires_at",
                "namespace",
                "base_url",
                "app_version",
                "platform",
            ],
            &[],
            &[],
        )?))
        .map_err(|error| error.to_string())
    }
    pub fn usable(&self, now: i128) -> bool {
        !self.session_id.trim().is_empty()
            && !self.session_secret.trim().is_empty()
            && parse_time(&self.expires_at).is_none_or(|expires| now < expires)
    }

    pub fn same_session(&self, other: &Self) -> bool {
        !self.session_id.is_empty()
            && self.session_id == other.session_id
            && self.session_secret == other.session_secret
    }

    pub fn generation(&self) -> String {
        if self.session_id.is_empty() || self.session_secret.is_empty() {
            return String::new();
        }
        hex(&Sha256::digest(
            Zeroizing::new(format!("{}\n{}", self.session_id, self.session_secret)).as_bytes(),
        ))
    }

    pub fn clear(&mut self) {
        self.session_id.clear();
        self.session_secret.zeroize();
        self.expires_at.clear();
    }

    pub fn normalize_scope(&mut self, config: &SignedSession) -> bool {
        let namespace = namespace(&config.namespace);
        if self.namespace == namespace
            && self.base_url == config.base_url.trim()
            && self.app_version == config.app_version.trim()
            && self.platform == config.platform.trim()
        {
            return false;
        }
        if !self.namespace.is_empty()
            || !self.base_url.is_empty()
            || !self.app_version.is_empty()
            || !self.platform.is_empty()
        {
            self.clear();
        }
        self.namespace = namespace;
        self.base_url = config.base_url.trim().to_owned();
        self.app_version = config.app_version.trim().to_owned();
        self.platform = config.platform.trim().to_owned();
        true
    }

    pub fn refresh_due(&self, config: &SignedSession, now: i128) -> bool {
        !config.endpoints.refresh.is_empty()
            && self.usable(now)
            && parse_time(&self.expires_at)
                .is_some_and(|expires| now < expires && expires - now <= 3_600_000_000_000)
    }
}

pub fn random_hex(count: usize) -> Result<String, String> {
    let mut bytes = Zeroizing::new(vec![0; count]);
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    Ok(hex(&bytes))
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn hmac(key: &[u8], message: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(message);
    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

pub fn signed_headers(
    config: &SignedSession,
    record: &Record,
    method: &str,
    url: &str,
    body: &[u8],
    now: i128,
    nonce: &str,
) -> Result<BTreeMap<String, String>, String> {
    let url = UrlParts::parse(url).ok_or("invalid signed session URL")?;
    let time = OffsetDateTime::from_unix_timestamp_nanos(now).map_err(|error| error.to_string())?;
    let timestamp = format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        time.year(),
        u8::from(time.month()),
        time.day(),
        time.hour(),
        time.minute(),
        time.second(),
        time.millisecond()
    );
    let hash = hex(&Sha256::digest(body));
    if config.time_window_seconds <= 0 {
        return Err("invalid signed session time window".into());
    }
    let window = time.unix_timestamp() / config.time_window_seconds as i64;
    let rolling = Zeroizing::new(hmac(
        record.session_secret.as_bytes(),
        format!("{window}:{}", record.session_id).as_bytes(),
    ));
    let signing = [
        &config.scheme_label,
        method,
        &url.escaped_path(),
        "",
        &hash,
        &timestamp,
        nonce,
        &record.session_id,
        &config.app_version,
        &config.platform,
    ]
    .join("\n");
    let signature = hmac(rolling.as_bytes(), signing.as_bytes());
    Ok([
        ("Session", record.session_id.clone()),
        ("Timestamp", timestamp),
        ("Nonce", nonce.to_owned()),
        ("Body-SHA256", hash),
        ("Signature", signature),
        ("App-Version", config.app_version.clone()),
        ("Platform", config.platform.clone()),
    ]
    .into_iter()
    .map(|(name, value)| (format!("{}{name}", config.header_prefix), value))
    .collect())
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ErrorContract {
    #[serde(deserialize_with = "string_or_null")]
    pub error: String,
    #[serde(deserialize_with = "string_or_null")]
    pub code: String,
    #[serde(deserialize_with = "string_or_null")]
    pub origin: String,
    #[serde(deserialize_with = "string_or_null")]
    pub action: String,
    pub retryable: bool,
    #[serde(deserialize_with = "string_or_null")]
    pub retry_mode: String,
    pub retry_after_seconds: isize,
}

impl ErrorContract {
    pub fn parse(body: &[u8]) -> Self {
        let mut value: Self = object_fields(
            body,
            &["error", "code", "origin", "action", "retry_mode"],
            &["retryable"],
            &["retry_after_seconds"],
        )
        .ok()
        .and_then(|fields| serde_json::from_value(Value::Object(fields)).ok())
        .unwrap_or_default();
        value.error = value.error.trim().to_owned();
        value.code = value.code.trim().to_uppercase();
        value.origin = value.origin.trim().to_lowercase();
        value.action = value.action.trim().to_lowercase();
        value.retry_mode = value.retry_mode.trim().to_lowercase();
        value.retry_after_seconds = value.retry_after_seconds.max(0);
        value
    }

    pub fn gateway_action(&self, status: u16) -> &str {
        match (
            status,
            self.origin.as_str(),
            self.code.as_str(),
            self.action.as_str(),
        ) {
            (401, "gateway", "SESSION_INVALID", "bootstrap_session") => "bootstrap_session",
            (428, "gateway", "VERIFY_REQUIRED", "verify") => "verify",
            _ => "",
        }
    }

    pub fn provider_retry(&self, status: u16) -> bool {
        status == 503
            && self.origin == "provider"
            && self.code == "PROVIDER_UNAVAILABLE"
            && self.retryable
            && self.retry_mode == "same_operation"
    }

    pub fn request_auth_invalid(&self, status: u16) -> bool {
        status == 403
            && self.origin == "gateway"
            && self.code == "REQUEST_AUTH_INVALID"
            && self.action.is_empty()
    }
}

pub fn retry_after(value: &str, now: i128) -> i64 {
    let value = value.trim();
    if let Ok(seconds) = value.parse::<isize>() {
        return seconds.max(0) as i64;
    }
    httpdate::parse_http_date(value)
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |time| {
            ((time.as_nanos() as i128 - now) / 1_000_000_000).max(0) as i64
        })
}

pub fn response_retry_after(response: &HttpResponse, now: i128) -> i64 {
    response
        .headers
        .get("Retry-After")
        .and_then(|values| values.first())
        .map_or(0, |value| retry_after(value, now))
}

pub fn provider_delay(response: &HttpResponse, contract: &ErrorContract, now: i128) -> Duration {
    // Go's retry scheduler preserves the fractional part of an HTTP date and
    // parses numeric headers without trimming; the response metadata uses a
    // separate, whole-second parser above.
    if let Some(value) = response
        .headers
        .get("Retry-After")
        .and_then(|values| values.first())
    {
        let nanos = if let Ok(seconds) = value.parse::<isize>() {
            // time.Duration is an int64 in Go, including multiplication overflow.
            i128::from((seconds as i64).wrapping_mul(1_000_000_000))
        } else {
            httpdate::parse_http_date(value)
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |time| time.as_nanos() as i128 - now)
        };
        if nanos > 0 {
            return Duration::from_nanos(nanos.min(120_000_000_000) as u64);
        }
    }
    Duration::from_secs(if contract.retry_after_seconds > 0 {
        contract.retry_after_seconds.min(120) as u64
    } else {
        1
    })
}

pub fn response_value(response: HttpResponse, now: i128) -> Value {
    let contract = ErrorContract::parse(&response.body);
    let retry = response_retry_after(&response, now);
    let mut result = json!({"statusCode":response.status,"status":response.status,"ok":(200..300).contains(&response.status),
        "url":response.url,"body":crate::host::decode_go_utf8(&response.body),"headers":response.headers.into_iter().map(|(key, values)| {
            let value = if values.len() == 1 { json!(values[0]) } else { json!(values) }; (key,value)
        }).collect::<BTreeMap<_,_>>(),"retryAfterSeconds":if retry>0 {retry} else {contract.retry_after_seconds as i64}});
    if !contract.code.is_empty() || !contract.origin.is_empty() || !contract.action.is_empty() {
        for (key, value) in [
            ("error", json!(contract.error)),
            ("code", json!(contract.code)),
            ("origin", json!(contract.origin)),
            ("action", json!(contract.action)),
            ("retryable", json!(contract.retryable)),
            ("retryMode", json!(contract.retry_mode)),
        ] {
            result[key] = value;
        }
    }
    result
}
