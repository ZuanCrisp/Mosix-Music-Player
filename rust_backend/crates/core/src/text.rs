/// Go replaces every malformed UTF-8 byte separately when serializing JSON.
/// Rust's lossy decoder can combine a truncated sequence into one replacement.
pub(crate) fn utf8(mut bytes: &[u8]) -> String {
    let mut text = String::new();
    while !bytes.is_empty() {
        match std::str::from_utf8(bytes) {
            Ok(valid) => {
                text.push_str(valid);
                break;
            }
            Err(error) => {
                let valid = error.valid_up_to();
                text.push_str(std::str::from_utf8(&bytes[..valid]).expect("valid UTF-8 prefix"));
                text.push(char::REPLACEMENT_CHARACTER);
                bytes = &bytes[valid + 1..];
            }
        }
    }
    text
}

/// encoding/json replaces unpaired UTF-16 escapes, including in ignored fields.
pub fn json_surrogates(json: &str) -> std::borrow::Cow<'_, str> {
    fn unit(bytes: &[u8]) -> Option<u16> {
        let digits = bytes.get(..4)?;
        if !digits.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        u16::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
    }
    let bytes = json.as_bytes();
    let (mut position, mut copied, mut quoted) = (0, 0, false);
    let mut output = String::new();
    while position < bytes.len() {
        if quoted && bytes[position] == b'\\' {
            if bytes.get(position + 1) == Some(&b'u')
                && let Some(code) = unit(&bytes[position + 2..])
            {
                if (0xd800..=0xdbff).contains(&code)
                    && bytes.get(position + 6..position + 8) == Some(b"\\u")
                    && unit(&bytes[position + 8..])
                        .is_some_and(|code| (0xdc00..=0xdfff).contains(&code))
                {
                    position += 12;
                    continue;
                }
                if (0xd800..=0xdfff).contains(&code) {
                    output.push_str(&json[copied..position]);
                    output.push_str("\\ufffd");
                    copied = position + 6;
                }
                position += 6;
                continue;
            }
            position += 2;
            continue;
        }
        if bytes[position] == b'"' {
            quoted = !quoted;
        }
        position += 1;
    }
    if copied == 0 {
        std::borrow::Cow::Borrowed(json)
    } else {
        output.push_str(&json[copied..]);
        std::borrow::Cow::Owned(output)
    }
}
