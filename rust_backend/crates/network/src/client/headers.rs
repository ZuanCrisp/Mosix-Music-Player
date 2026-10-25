use super::*;

pub(super) fn update_explicit_cookies(headers: &mut HeaderMap, response: &HeaderMap) {
    let Some(original) = headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
    else {
        return;
    };
    let names: Vec<_> = response
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .filter_map(|value| cookie::Cookie::parse(value).ok())
        .map(|cookie| cookie.name().to_owned())
        .collect();
    let mut changed = false;
    let mut remaining: Vec<_> = original
        .split(';')
        .map(str::trim)
        .filter(|pair| {
            let remove = pair
                .split_once('=')
                .is_some_and(|(name, _)| names.iter().any(|replaced| replaced == name));
            changed |= remove;
            !remove
        })
        .collect();
    if changed {
        remaining.sort_unstable();
        let value = remaining
            .join("; ")
            .parse()
            .expect("existing HTTP cookie header");
        headers.insert(header::COOKIE, value);
    }
}

pub(super) fn forward_sensitive_headers(original: &str, target: &str) -> bool {
    let original = original.to_lowercase();
    let target = target.to_lowercase();
    original == target
        || (!target.contains([':', '%']) && target.ends_with(&format!(".{original}")))
}

pub(super) fn canonical_header(name: &str) -> String {
    name.split('-')
        .map(|word| {
            let mut bytes = word.as_bytes().to_vec();
            if let Some(first) = bytes.first_mut() {
                first.make_ascii_uppercase();
            }
            String::from_utf8(bytes).expect("ASCII HTTP header name")
        })
        .collect::<Vec<_>>()
        .join("-")
}
