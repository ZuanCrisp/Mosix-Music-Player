//! Go net/url query encoding, including invalid-pair and semicolon handling.

use std::collections::BTreeMap;

pub type Query = BTreeMap<Vec<u8>, Vec<Vec<u8>>>;

pub fn parse(query: &str) -> Query {
    let mut values = Query::new();
    for pair in query
        .split('&')
        .filter(|pair| !pair.is_empty() && !pair.contains(';'))
    {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        if let (Some(key), Some(value)) = (decode(key), decode(value)) {
            values.entry(key).or_default().push(value);
        }
    }
    values
}

pub fn set(values: &mut Query, key: &str, value: &str) {
    values.insert(key.as_bytes().to_vec(), vec![value.as_bytes().to_vec()]);
}

pub fn encode(values: &Query) -> String {
    values
        .iter()
        .flat_map(|(key, values)| {
            values
                .iter()
                .map(move |value| format!("{}={}", escape(key), escape(value)))
        })
        .collect::<Vec<_>>()
        .join("&")
}

fn escape(value: &[u8]) -> String {
    let mut result = String::new();
    for byte in value {
        if byte.is_ascii_alphanumeric() || b"-_.~".contains(byte) {
            result.push(char::from(*byte));
        } else if *byte == b' ' {
            result.push('+');
        } else {
            use std::fmt::Write;
            let _ = write!(result, "%{byte:02X}");
        }
    }
    result
}

fn decode(value: &str) -> Option<Vec<u8>> {
    let mut result = Vec::new();
    let mut bytes = value.bytes();
    while let Some(byte) = bytes.next() {
        result.push(match byte {
            b'+' => b' ',
            b'%' => {
                (char::from(bytes.next()?).to_digit(16)? * 16
                    + char::from(bytes.next()?).to_digit(16)?) as u8
            }
            _ => byte,
        });
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    #[test]
    fn query_keeps_bytes_duplicates_and_go_escaping() {
        assert_eq!(
            super::encode(&super::parse(
                "z=one+two&x=%FF&x=%2f&bad=%Q0&semi=a;b&empty&~!=*"
            )),
            "empty=&x=%FF&x=%2F&z=one+two&~%21=%2A"
        );
    }
}
