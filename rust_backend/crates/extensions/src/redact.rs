use regex::Regex;
use std::borrow::Cow;
use std::sync::LazyLock;

static PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    // Go's RE2 uses ASCII whitespace and word boundaries. Keep Unicode token
    // contents inside the redacted match instead of treating them as delimiters.
    vec![
        (r"(?i)(?-u:\b)Authorization(?-u:\b)[\t\n\f\r ]*[:=][\t\n\f\r ]*Bearer[\t\n\f\r ]+[A-Za-z0-9._~+/\-]+=*", "Authorization: Bearer [REDACTED]"),
        (r#"(?i)("?(?:access[_\t\n\f\r -]?token|refresh[_\t\n\f\r -]?token|id[_\t\n\f\r -]?token|client[_\t\n\f\r -]?secret|authorization|password|api[_\t\n\f\r -]?key|session[_\t\n\f\r -]?secret|decryption[_\t\n\f\r -]?key|cookie|set-cookie)"?)([\t\n\f\r ]*[:=][\t\n\f\r ]*)("(?:\\.|[^"\\])*"|[^\t\n\f\r ,;}\]]+)"#, "${1}${2}[REDACTED]"),
        (r"(?i)([?&](?:access_token|refresh_token|id_token|token|client_secret|api_key|apikey|password|code|grant|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|awsaccesskeyid|googleaccessid|policy|key-pair-id)=)[^&\t\n\f\r ]+", "${1}[REDACTED]"),
        (r"(?i)(?-u:\b)Bearer[\t\n\f\r ]+[A-Za-z0-9._~+/\-]+=*", "Bearer [REDACTED]"),
        (r"(?i)(-decryption_key[\t\n\f\r ]+)[^\t\n\f\r ]+", "${1}[REDACTED]"),
    ]
    .into_iter()
    .map(|(pattern, replacement)| (Regex::new(pattern).expect("static redaction pattern"), replacement))
    .collect()
});

fn sanitize_text(mut text: String) -> String {
    for (pattern, replacement) in PATTERNS.iter() {
        if let Cow::Owned(replaced) = pattern.replace_all(&text, *replacement) {
            text = replaced;
        }
    }
    text
}

pub(crate) fn preview(bytes: &[u8], limit: usize) -> String {
    let mut text = sanitize_text(crate::host::decode_go_utf8(bytes));
    if text.len() > limit {
        text = crate::host::decode_go_utf8(&text.as_bytes()[..limit]) + "...[truncated]";
    }
    text
}

/// Log arguments can end mid-codepoint after Go's 512-byte truncation. Preserve
/// their raw bytes while matching as Go's regexp UTF-8 decoder would; converting
/// them to replacement characters first would change the later 4000-byte cut.
pub(crate) fn sanitize_bytes(bytes: Vec<u8>) -> Vec<u8> {
    let mut bytes = match String::from_utf8(bytes) {
        Ok(text) => return sanitize_text(text).into_bytes(),
        Err(error) => error.into_bytes(),
    };
    for (pattern, replacement) in PATTERNS.iter() {
        let (text, invalid) = decoded_positions(&bytes);
        let position = |index: usize| index - 2 * invalid.partition_point(|start| *start < index);
        let mut output = Vec::with_capacity(bytes.len());
        let mut copied = 0;
        for captures in pattern.captures_iter(&text) {
            let found = captures.get(0).expect("redaction match");
            let start = position(found.start());
            let end = position(found.end());
            output.extend_from_slice(&bytes[copied..start]);
            let mut expanded = String::new();
            // Retained captures are only key names/separators, never secret
            // values; they cannot contain an invalid UTF-8 byte.
            captures.expand(replacement, &mut expanded);
            output.extend_from_slice(expanded.as_bytes());
            copied = end;
        }
        output.extend_from_slice(&bytes[copied..]);
        bytes = output;
    }
    bytes
}

fn decoded_positions(mut bytes: &[u8]) -> (String, Vec<usize>) {
    let mut text = String::with_capacity(bytes.len());
    let mut invalid = Vec::new();
    while !bytes.is_empty() {
        match std::str::from_utf8(bytes) {
            Ok(valid) => {
                text.push_str(valid);
                break;
            }
            Err(error) => {
                let prefix = error.valid_up_to();
                text.push_str(std::str::from_utf8(&bytes[..prefix]).expect("valid UTF-8 prefix"));
                invalid.push(text.len());
                text.push('\u{fffd}');
                bytes = &bytes[prefix + 1..];
            }
        }
    }
    (text, invalid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redaction_preserves_unicode_and_invalid_bytes_around_secret_values() {
        for prefix in [b"track: ".as_slice(), "曲名: ".as_bytes(), b"\xff\xe3\x81 "] {
            let input = [prefix, b"https://example.test/audio?token=fixture-secret&track=7 password=fixture-password;"].concat();
            let expected = [
                prefix,
                b"https://example.test/audio?token=[REDACTED]&track=7 password=[REDACTED];",
            ]
            .concat();
            assert_eq!(sanitize_bytes(input.clone()), expected);
            assert_eq!(
                preview(&input, usize::MAX),
                crate::host::decode_go_utf8(&expected)
            );
        }
    }
}
