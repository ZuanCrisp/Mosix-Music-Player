//! Extension return URLs, ported from `ios/Runner/ExtensionCallbackParser.swift`:
//! - OAuth: `mornye://callback?code=...&state=<one_time_nonce>`
//! - Signed session: `mornye://session-grant?grant=...&state=<one_time_nonce>`

use crate::backend::CallbackRoute;

/// Percent-decodes like `URLComponents.queryItems`, which keeps `+` as is.
fn decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let hex = |offset: usize| {
            bytes
                .get(index + offset)
                .and_then(|byte| (*byte as char).to_digit(16))
        };
        if bytes[index] == b'%'
            && let (Some(high), Some(low)) = (hex(1), hex(2))
        {
            decoded.push((high * 16 + low) as u8);
            index += 3;
            continue;
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

pub(crate) fn parse(raw: &str) -> Option<CallbackRoute> {
    let url = url::Url::parse(raw.trim()).ok()?;
    if !url.scheme().eq_ignore_ascii_case("mosix") && !url.scheme().eq_ignore_ascii_case("mornye") {
        return None;
    }
    let host = url.host_str().unwrap_or("").to_lowercase();
    let path = url.path().to_lowercase();
    let session_grant = host == "session-grant";
    let supported = session_grant
        || host == "callback"
        || host == "spotify-callback"
        || path.contains("callback");
    if !supported {
        return None;
    }
    let items: Vec<(String, String)> = url
        .query()
        .unwrap_or("")
        .split('&')
        .filter(|item| !item.is_empty())
        .map(|item| {
            let (name, value) = item.split_once('=').unwrap_or((item, ""));
            (decode(name), decode(value))
        })
        .collect();
    let first = |name: &str| {
        items
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.trim().to_owned())
    };
    let primary = if session_grant { "grant" } else { "code" };
    let code = first(primary).or_else(|| first("code")).unwrap_or_default();
    let state = first("state").unwrap_or_default();
    if code.is_empty() || state.is_empty() {
        return None;
    }
    Some(CallbackRoute {
        code,
        state,
        session_grant,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_oauth_and_session_grant() {
        assert_eq!(
            parse("mornye://callback?code=a%2Bb+c&state=s1"),
            Some(CallbackRoute {
                code: "a+b+c".into(),
                state: "s1".into(),
                session_grant: false,
            })
        );
        assert_eq!(
            parse("MOSIX://session-grant?grant=g&state=s2"),
            Some(CallbackRoute {
                code: "g".into(),
                state: "s2".into(),
                session_grant: true,
            })
        );
    }

    #[test]
    fn rejects_other_urls() {
        assert_eq!(parse("https://callback?code=a&state=b"), None);
        assert_eq!(parse("mornye://player"), None);
        assert_eq!(parse("mornye://callback?code=a"), None);
    }
}
