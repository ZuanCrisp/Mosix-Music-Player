//! net/url-compatible parsing for permissions and HTTP paths. The HTTP request
//! keeps escaped path bytes; browser-style normalization would change signatures.

use std::net::Ipv6Addr;

#[derive(Clone, Debug, Default)]
pub struct UrlParts {
    pub scheme: String,
    pub hostname: String,
    pub path: Vec<u8>,
    pub raw_path: String,
    pub raw_query: String,
    pub force_query: bool,
    pub fragment: String,
    pub port: Option<String>,
    pub has_credentials: bool,
    pub host: Vec<u8>,
    pub username: Vec<u8>,
    pub password: Option<Vec<u8>>,
    pub opaque: String,
    pub omit_host: bool,
}

impl UrlParts {
    pub fn parse(input: &str) -> Option<Self> {
        let (input, fragment) = input.split_once('#').unwrap_or((input, ""));
        decode(fragment, Escape::Path)?;
        if input.bytes().any(|byte| byte < 32 || byte == 127) {
            return None;
        }
        let mut scheme = "";
        let mut rest = input;
        for (index, byte) in input.bytes().enumerate() {
            if byte == b':' {
                if index == 0 {
                    return None;
                }
                scheme = &input[..index];
                rest = &input[index + 1..];
                break;
            }
            if !byte.is_ascii_alphabetic()
                && !(index > 0 && (byte.is_ascii_digit() || b"+-.".contains(&byte)))
            {
                break;
            }
        }
        let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
        let force_query = rest.ends_with('?') && query.is_empty();
        rest = path;
        let mut hostname = String::new();
        let mut port = None;
        let mut has_credentials = false;
        let mut raw_host = Vec::new();
        let mut username = Vec::new();
        let mut password = None;
        if !rest.starts_with('/') {
            if !scheme.is_empty() {
                return Some(Self {
                    scheme: scheme.to_lowercase(),
                    hostname,
                    path: vec![],
                    raw_path: rest.to_owned(),
                    raw_query: query.to_owned(),
                    force_query,
                    fragment: fragment.to_owned(),
                    port,
                    has_credentials,
                    opaque: rest.to_owned(),
                    ..Default::default()
                });
            }
            if rest.split('/').next()?.contains(':') {
                return None;
            }
        }
        if rest.starts_with("//") && (!scheme.is_empty() || !rest.starts_with("///")) {
            let authority_and_path = &rest[2..];
            let end = authority_and_path
                .find('/')
                .unwrap_or(authority_and_path.len());
            let authority = &authority_and_path[..end];
            rest = &authority_and_path[end..];
            let host = if let Some((user, host)) = authority.rsplit_once('@') {
                has_credentials = true;
                if !user.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:%@".contains(&byte)
                }) {
                    return None;
                }
                decode(user, Escape::Path)?;
                let (name, secret) = user
                    .split_once(':')
                    .map_or((user, None), |(name, secret)| (name, Some(secret)));
                username = decode(name, Escape::Path)?;
                password = match secret {
                    Some(secret) => Some(decode(secret, Escape::Path)?),
                    None => None,
                };
                host
            } else {
                authority
            };
            hostname = parse_host(host, scheme)?;
            raw_host = decode(host, Escape::Path)?;
            let port_part = if host.starts_with('[') {
                &host[host.rfind(']')? + 1..]
            } else {
                host.rfind(':').map_or("", |index| &host[index..])
            };
            port = port_part.strip_prefix(':').map(str::to_owned);
        }
        let omit_host = !scheme.is_empty() && path.starts_with('/') && !path.starts_with("//");
        let path = if rest.is_empty() {
            b"/".to_vec()
        } else {
            decode(rest, Escape::Path)?
        };
        Some(Self {
            scheme: scheme.to_lowercase(),
            hostname,
            path,
            raw_path: rest.to_owned(),
            raw_query: query.to_owned(),
            force_query,
            fragment: fragment.to_owned(),
            port,
            has_credentials,
            host: raw_host,
            username,
            password,
            opaque: String::new(),
            omit_host,
        })
    }

    /// Serialize a parsed reference without the HTTP layer's credential removal
    /// or empty-path normalization.
    pub fn reference_string(&self) -> String {
        let mut result = String::new();
        if !self.scheme.is_empty() {
            result.push_str(&self.scheme);
            result.push(':');
        }
        if !self.opaque.is_empty() {
            result.push_str(&self.opaque);
        } else {
            if (!self.scheme.is_empty() || !self.host.is_empty() || self.has_credentials)
                && !(self.omit_host && self.host.is_empty() && !self.has_credentials)
            {
                if !self.host.is_empty() || !self.raw_path.is_empty() || self.has_credentials {
                    result.push_str("//");
                }
                if self.has_credentials {
                    result.push_str(&escape_component(&self.username, b"$&+,;="));
                    if let Some(password) = &self.password {
                        result.push(':');
                        result.push_str(&escape_component(password, b"$&+,;="));
                    }
                    result.push('@');
                }
                result.push_str(&escape_component(&self.host, b"!$&'()*+,;=:[]<>\""));
            }
            let path = self.escaped_path();
            if !path.is_empty() && !path.starts_with('/') && !self.host.is_empty() {
                result.push('/');
            }
            if result.is_empty() && path.split('/').next().is_some_and(|p| p.contains(':')) {
                result.push_str("./");
            }
            result.push_str(&path);
        }
        if self.force_query || !self.raw_query.is_empty() {
            result.push('?');
            result.push_str(&self.raw_query);
        }
        if !self.fragment.is_empty() {
            result.push('#');
            if self.fragment.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:[]/%@?".contains(&byte)
            }) {
                result.push_str(&self.fragment);
            } else {
                result.push_str(&escape_component(
                    &unescape_path(&self.fragment).unwrap_or_default(),
                    b"!$&()*+,/:;=?@",
                ));
            }
        }
        result
    }

    /// Go ResolveReference semantics for JavaScript URL construction, including
    /// credentials and opaque schemes that cannot be used as HTTP requests.
    pub fn resolve_reference(&self, reference: &str) -> Option<Self> {
        let mut target = Self::parse(reference)?;
        let absolute =
            !target.scheme.is_empty() || !target.host.is_empty() || target.has_credentials;
        if target.scheme.is_empty() {
            target.scheme.clone_from(&self.scheme);
        }
        if absolute {
            if target.opaque.is_empty() {
                target.raw_path = resolve_path(&target.escaped_path(), "");
            }
        } else {
            if target.raw_path.is_empty() && !target.force_query && target.raw_query.is_empty() {
                target.raw_query.clone_from(&self.raw_query);
                if target.fragment.is_empty() {
                    target.fragment.clone_from(&self.fragment);
                }
            }
            if target.raw_path.is_empty() && !self.opaque.is_empty() {
                target.opaque.clone_from(&self.opaque);
            } else {
                target.host.clone_from(&self.host);
                target.hostname.clone_from(&self.hostname);
                target.port.clone_from(&self.port);
                target.has_credentials = self.has_credentials;
                target.username.clone_from(&self.username);
                target.password.clone_from(&self.password);
                let base = if self.opaque.is_empty() {
                    self.escaped_path()
                } else {
                    String::new()
                };
                target.raw_path = resolve_path(&base, &target.escaped_path());
            }
        }
        // URL(base) reparses the resolved string in the legacy runtime.
        Self::parse(&target.reference_string())
    }

    pub fn authority(&self) -> String {
        let host = if self.hostname.contains(':') {
            format!("[{}]", self.hostname)
        } else {
            self.hostname.clone()
        };
        match &self.port {
            Some(port) if !port.is_empty() => format!("{host}:{port}"),
            _ => host,
        }
    }

    pub fn display_url(&self) -> String {
        let mut result = format!(
            "{}://{}{}",
            self.scheme,
            escape(&self.authority(), true),
            self.escaped_path()
        );
        if self.force_query || !self.raw_query.is_empty() {
            result.push('?');
            result.push_str(&self.raw_query);
        }
        if !self.fragment.is_empty() {
            result.push('#');
            result.push_str(&escape(&self.fragment, false));
        }
        result
    }

    pub fn escaped_path(&self) -> String {
        if self
            .raw_path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:[]/%@".contains(&byte))
        {
            return self.raw_path.clone();
        }
        // net/url ignores RawPath if it contains unescaped Unicode/spaces.
        // Re-encode the decoded path as a whole, including percent escapes.
        let mut result = String::new();
        for byte in decode(&self.raw_path, Escape::Path).unwrap_or_default() {
            if byte.is_ascii_alphanumeric() || b"-._~$&+,/:;=@".contains(&byte) {
                result.push(char::from(byte));
            } else {
                use std::fmt::Write;
                let _ = write!(result, "%{byte:02X}");
            }
        }
        result
    }

    pub fn request_uri(&self) -> Result<http::Uri, String> {
        if let Some(port) = self.port.as_deref().filter(|port| !port.is_empty()) {
            port.parse::<u16>()
                .map_err(|_| "invalid URL port".to_owned())?;
        }
        let hostname = if self.hostname.contains(':') {
            format!("[{}]", self.hostname)
        } else {
            // URL's domain parser supplies IDNA; the path is deliberately not
            // passed through its browser-style path parser.
            ::url::Host::parse(&self.hostname)
                .map_err(|error| error.to_string())?
                .to_string()
        };
        let authority = match self.port.as_deref().filter(|port| !port.is_empty()) {
            Some(port) => format!("{hostname}:{port}"),
            None => hostname,
        };
        let mut path = if self.raw_path.is_empty() {
            "/".to_owned()
        } else {
            self.escaped_path()
        };
        if self.force_query || !self.raw_query.is_empty() {
            path.push('?');
            path.push_str(&self.raw_query);
        }
        http::Uri::builder()
            .scheme(self.scheme.as_str())
            .authority(authority)
            .path_and_query(path)
            .build()
            .map_err(|error| error.to_string())
    }

    pub fn resolve(&self, location: &str) -> Option<Self> {
        let mut target = Self::parse(location)?;
        let absolute =
            !target.scheme.is_empty() || !target.hostname.is_empty() || target.has_credentials;
        if target.scheme.is_empty() {
            target.scheme.clone_from(&self.scheme);
        }
        if absolute {
            target.raw_path = resolve_path(&target.escaped_path(), "");
        } else {
            if target.raw_path.is_empty() && !target.force_query && target.raw_query.is_empty() {
                target.raw_query.clone_from(&self.raw_query);
                if target.fragment.is_empty() {
                    target.fragment.clone_from(&self.fragment);
                }
            }
            target.hostname.clone_from(&self.hostname);
            target.port.clone_from(&self.port);
            target.has_credentials = self.has_credentials;
            target.raw_path = resolve_path(&self.escaped_path(), &target.escaped_path());
        }
        target.path = decode(&target.raw_path, Escape::Path)?;
        Some(target)
    }
}

pub fn unescape_path(input: &str) -> Option<Vec<u8>> {
    decode(input, Escape::Path)
}

fn escape_component(value: &[u8], reserved: &[u8]) -> String {
    let mut result = String::with_capacity(value.len());
    for &byte in value {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) || reserved.contains(&byte) {
            result.push(char::from(byte));
        } else {
            use std::fmt::Write;
            let _ = write!(result, "%{byte:02X}");
        }
    }
    result
}

// RFC 3986 dot segments apply to escaped paths. In particular, %2e%2e and
// %2f remain escaped rather than becoming browser-style traversal segments.
fn resolve_path(base: &str, reference: &str) -> String {
    let full = if reference.is_empty() {
        base.to_owned()
    } else if reference.starts_with('/') {
        reference.to_owned()
    } else {
        format!(
            "{}{reference}",
            &base[..base.rfind('/').map_or(0, |index| index + 1)]
        )
    };
    if full.is_empty() {
        return full;
    }
    let mut result = String::from("/");
    let mut first = true;
    let mut last = "";
    for part in full.split('/') {
        last = part;
        match part {
            "." => first = false,
            ".." => {
                result.truncate(result[1..].rfind('/').map_or(1, |index| index + 1));
                first = result.len() == 1;
            }
            _ => {
                if !first {
                    result.push('/');
                }
                result.push_str(part);
                first = false;
            }
        }
    }
    if last == "." || last == ".." {
        result.push('/');
    }
    if result.starts_with("//") {
        result.remove(0);
    }
    result
}

fn escape(value: &str, host: bool) -> String {
    let mut result = String::with_capacity(value.len());
    for byte in value.bytes() {
        let allowed = byte.is_ascii_alphanumeric()
            || b"-._~!$&'()*+,;=:[]".contains(&byte)
            || (!host && b"/%@?".contains(&byte));
        if allowed {
            result.push(char::from(byte));
        } else {
            use std::fmt::Write;
            let _ = write!(result, "%{byte:02X}");
        }
    }
    result
}

fn valid_port(port: &str) -> bool {
    port.is_empty()
        || port
            .strip_prefix(':')
            .is_some_and(|port| port.bytes().all(|byte| byte.is_ascii_digit()))
}

fn parse_host(host: &str, scheme: &str) -> Option<String> {
    if let Some(open) = host.rfind('[') {
        if open != 0 {
            return None;
        }
        let close = host.rfind(']')?;
        if !valid_port(&host[close + 1..]) {
            return None;
        }
        let raw = &host[1..close];
        let decoded = if let Some((address, zone)) = raw.split_once("%25") {
            let mut bytes = decode(address, Escape::Host)?;
            bytes.extend(decode(&format!("%25{zone}"), Escape::Zone)?);
            bytes
        } else {
            decode(raw, Escape::Host)?
        };
        let hostname = String::from_utf8_lossy(&decoded).into_owned();
        let address = if let Some((address, zone)) = hostname.split_once('%') {
            if zone.is_empty() {
                return None;
            }
            address
        } else {
            hostname.as_str()
        };
        address.parse::<Ipv6Addr>().ok()?;
        return Some(hostname);
    }
    let mut hostname = host;
    if let Some(first) = host.find(':') {
        let index = if scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https") {
            first
        } else {
            host.rfind(':')?
        };
        if !valid_port(&host[index..]) {
            return None;
        }
        hostname = &host[..index];
    }
    Some(String::from_utf8_lossy(&decode(hostname, Escape::Host)?).into_owned())
}

#[derive(Clone, Copy)]
enum Escape {
    Path,
    Host,
    Zone,
}

fn valid_host_byte(byte: u8) -> bool {
    byte >= 128 || byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:[]<>\"".contains(&byte)
}

fn decode(input: &str, mode: Escape) -> Option<Vec<u8>> {
    let mut result = Vec::with_capacity(input.len());
    let mut bytes = input.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let high = char::from(bytes.next()?).to_digit(16)?;
            let low = char::from(bytes.next()?).to_digit(16)?;
            let value = (high * 16 + low) as u8;
            match mode {
                Escape::Host if value < 128 && value != b'%' => return None,
                Escape::Zone if value != b'%' && value != b' ' && !valid_host_byte(value) => {
                    return None;
                }
                _ => result.push(value),
            }
        } else {
            if !matches!(mode, Escape::Path) && !valid_host_byte(byte) {
                return None;
            }
            result.push(byte);
        }
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_requests_and_relative_redirect_paths_keep_go_semantics() {
        let base = UrlParts::parse("https://example.test/a/../b/%2e%2e/x?old#fragment?").unwrap();
        assert_eq!(
            base.request_uri()
                .unwrap()
                .path_and_query()
                .unwrap()
                .as_str(),
            "/a/../b/%2e%2e/x?old"
        );
        for (reference, expected) in [
            ("../z", "https://example.test/b/z"),
            ("%2e%2e/z", "https://example.test/b/%2e%2e/%2e%2e/z"),
            ("/a//b/../c", "https://example.test/a//c"),
            ("?", "https://example.test/b/%2e%2e/x?"),
            ("#new?", "https://example.test/b/%2e%2e/x?old#new?"),
        ] {
            assert_eq!(
                base.resolve(reference).unwrap().display_url(),
                expected,
                "{reference}"
            );
        }
        assert_eq!(
            UrlParts::parse("https://example.test?")
                .unwrap()
                .request_uri()
                .unwrap()
                .to_string(),
            "https://example.test/?"
        );
    }
}
