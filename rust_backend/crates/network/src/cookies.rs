use crate::url::UrlParts;
use cookie::Cookie;
use cookie::time::OffsetDateTime;
use std::collections::BTreeMap;
use std::net::IpAddr;

#[derive(Default)]
pub(crate) struct CookieJar {
    entries: BTreeMap<(String, String, Vec<u8>, String), Entry>,
    sequence: u64,
}

struct Entry {
    value: String,
    host_only: bool,
    secure: bool,
    expires: Option<OffsetDateTime>,
    sequence: u64,
}

impl CookieJar {
    pub(crate) fn store(&mut self, url: &UrlParts, headers: &http::HeaderMap) {
        let host = canonical_host(url);
        let partition = jar_key(&host);
        let now = OffsetDateTime::now_utc();
        // Go's default cookie parser rejects the entire batch over this limit.
        if headers.get_all(http::header::SET_COOKIE).iter().count() > 3000 {
            return;
        }
        for header in headers.get_all(http::header::SET_COOKIE) {
            let Ok(raw) = header.to_str() else { continue };
            let Ok(cookie) = Cookie::parse(raw) else {
                continue;
            };
            if http::HeaderName::from_bytes(cookie.name().as_bytes()).is_err() {
                continue;
            }
            let Some((_, raw_value)) = raw.split(';').next().and_then(|pair| pair.split_once('='))
            else {
                continue;
            };
            let raw_value = raw_value.trim();
            let quoted =
                raw_value.starts_with('"') && raw_value.ends_with('"') && raw_value.len() >= 2;
            let value = if quoted {
                &raw_value[1..raw_value.len() - 1]
            } else {
                raw_value
            };
            if !value
                .bytes()
                .all(|byte| (32..127).contains(&byte) && !b"\";\\".contains(&byte))
            {
                continue;
            }
            // Keep the unstripped Domain attribute: Go rejects .IP and ..host.
            let raw_domain = raw
                .split(';')
                .skip(1)
                .filter_map(|attribute| attribute.trim().split_once('='))
                .filter(|(name, _)| name.eq_ignore_ascii_case("domain"))
                .map(|(_, value)| value.trim())
                .last()
                .unwrap_or("");
            let (domain, host_only) = if raw_domain.is_empty() {
                (host.clone(), true)
            } else if host.parse::<IpAddr>().is_ok() || host.contains(':') {
                if raw_domain != host {
                    continue;
                }
                (host.clone(), true)
            } else {
                let domain = raw_domain
                    .strip_prefix('.')
                    .unwrap_or(raw_domain)
                    .to_ascii_lowercase();
                if domain.is_empty()
                    || !domain.is_ascii()
                    || domain.starts_with('.')
                    || domain.ends_with('.')
                    || (host != domain && !host.ends_with(&format!(".{domain}")))
                {
                    continue;
                }
                (domain, false)
            };
            let path = cookie
                .path()
                .filter(|path| path.starts_with('/'))
                .map(|path| path.as_bytes().to_vec())
                .unwrap_or_else(|| default_path(&url.path));
            let key = (partition.clone(), domain, path, cookie.name().to_owned());
            let max_age = raw
                .split(';')
                .skip(1)
                .filter_map(|attribute| attribute.trim().split_once('='))
                .filter(|(name, _)| name.eq_ignore_ascii_case("max-age"))
                .filter_map(|(_, value)| {
                    let value = value.trim();
                    let seconds = value.parse::<isize>().ok()?;
                    if seconds != 0 && value.starts_with('0') {
                        None
                    } else {
                        Some(seconds)
                    }
                })
                .last();
            let expires = match max_age {
                Some(seconds) if seconds <= 0 => Some(now),
                Some(seconds) => now.checked_add(cookie::time::Duration::seconds(seconds as i64)),
                None => cookie.expires_datetime(),
            };
            if expires.is_some_and(|expires| expires <= now) {
                self.entries.remove(&key);
                continue;
            }
            let sequence = self.entries.get(&key).map_or_else(
                || {
                    let sequence = self.sequence;
                    self.sequence += 1;
                    sequence
                },
                |entry| entry.sequence,
            );
            let value = if quoted || value.contains([' ', ',']) {
                format!("\"{value}\"")
            } else {
                value.to_owned()
            };
            self.entries.insert(
                key,
                Entry {
                    value,
                    host_only,
                    secure: cookie.secure().unwrap_or(false),
                    expires,
                    sequence,
                },
            );
        }
    }

    pub(crate) fn header(&mut self, url: &UrlParts) -> String {
        let now = OffsetDateTime::now_utc();
        self.entries
            .retain(|_, entry| entry.expires.is_none_or(|expires| expires > now));
        let host = canonical_host(url);
        let partition = jar_key(&host);
        let mut selected: Vec<_> = self
            .entries
            .iter()
            .filter(|((jar, domain, path, _), entry)| {
                *jar == partition
                    && (!entry.secure || url.scheme == "https")
                    && (host == *domain
                        || (!entry.host_only && host.ends_with(&format!(".{domain}"))))
                    && (url.path == *path
                        || (url.path.starts_with(path)
                            && (path.ends_with(b"/") || url.path.get(path.len()) == Some(&b'/'))))
            })
            .collect();
        selected.sort_by(|((_, _, left, _), a), ((_, _, right, _), b)| {
            right.cmp(left).then(a.sequence.cmp(&b.sequence))
        });
        selected
            .iter()
            .map(|((_, _, _, name), entry)| format!("{name}={}", entry.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    pub(crate) fn clear(&mut self) {
        self.entries.clear();
    }
}

fn canonical_host(url: &UrlParts) -> String {
    let host = url.hostname.strip_suffix('.').unwrap_or(&url.hostname);
    ::url::Host::parse(host).map_or_else(|_| host.to_ascii_lowercase(), |host| host.to_string())
}

// Go uses cookiejar.New(nil): buckets use the final two labels, with no PSL.
fn jar_key(host: &str) -> String {
    if host.parse::<IpAddr>().is_ok() || host.contains(':') {
        return host.to_owned();
    }
    let mut dots = host.rmatch_indices('.');
    dots.next();
    host[dots.next().map_or(0, |(index, _)| index + 1)..].to_owned()
}

fn default_path(path: &[u8]) -> Vec<u8> {
    let end = path.iter().rposition(|byte| *byte == b'/').unwrap_or(0);
    if !path.starts_with(b"/") || end == 0 {
        b"/".to_vec()
    } else {
        path[..end].to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_domains_expiry_quoting_and_clear_are_session_local() {
        let mut jar = CookieJar::default();
        let url = UrlParts::parse("https://api.example.test/a/b").unwrap();
        let mut headers = http::HeaderMap::new();
        for value in [
            "root=1; Path=/",
            "deep=2",
            "wide=3; Domain=.example.test; Secure",
            "quoted=\"a b\"; Path=/",
            "bad=4; Domain=other.test",
            "old=5; Max-Age=0",
            "public=6; Domain=test; Path=/",
        ] {
            headers.append(http::header::SET_COOKIE, value.parse().unwrap());
        }
        jar.store(&url, &headers);
        assert_eq!(
            jar.header(&url),
            "deep=2; wide=3; root=1; quoted=\"a b\"; public=6"
        );
        assert_eq!(
            jar.header(&UrlParts::parse("http://sub.example.test/a/b").unwrap()),
            "public=6"
        );
        assert_eq!(
            jar.header(&UrlParts::parse("https://other.test/a/b").unwrap()),
            ""
        );
        assert_eq!(CookieJar::default().header(&url), "");
        jar.clear();
        assert_eq!(jar.header(&url), "");
    }
}
