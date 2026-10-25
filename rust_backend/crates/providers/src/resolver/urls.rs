use spotiflac_network::url::UrlParts;

pub fn canonical(platform: &str) -> &'static str {
    match platform
        .trim()
        .to_lowercase()
        .replace(['-', '_', ' '], "")
        .as_str()
    {
        "spotify" => "spotify",
        "deezer" => "deezer",
        "tidal" => "tidal",
        "qobuz" => "qobuz",
        "soundcloud" => "soundcloud",
        "bandcamp" => "bandcamp",
        "apple" | "applemusic" => "appleMusic",
        "amazon" | "amazonmusic" => "amazonMusic",
        "youtube" => "youtube",
        "youtubemusic" => "youtubeMusic",
        _ => "",
    }
}

pub fn platform(value: &str) -> &'static str {
    let Some(url) = UrlParts::parse(value.trim()) else {
        return "";
    };
    match url.hostname.to_ascii_lowercase().as_str() {
        "open.spotify.com" => "spotify",
        "deezer.com" | "www.deezer.com" => "deezer",
        "tidal.com" | "www.tidal.com" | "listen.tidal.com" => "tidal",
        "open.qobuz.com" | "play.qobuz.com" | "www.qobuz.com" => "qobuz",
        "music.apple.com" | "geo.music.apple.com" => "appleMusic",
        "music.amazon.com" => "amazonMusic",
        "music.youtube.com" => "youtubeMusic",
        "youtube.com" | "www.youtube.com" | "youtu.be" => "youtube",
        "soundcloud.com" | "www.soundcloud.com" | "m.soundcloud.com" => "soundcloud",
        host if host == "bandcamp.com" || host.ends_with(".bandcamp.com") => "bandcamp",
        _ => "",
    }
}

pub fn direct(provider: &str, value: &str) -> String {
    let value = value.trim();
    let provider = canonical(provider);
    let Some(url) = UrlParts::parse(value) else {
        return String::new();
    };
    if provider.is_empty()
        || url.scheme != "https"
        || platform(value) != provider
        || url.escaped_path().to_ascii_lowercase().contains("/search")
    {
        return String::new();
    }
    // Preserve Go's host case, optional port, escaped path, query ordering and
    // fragment. Url::parse would normalize dot segments and default ports.
    let Some((_, rest)) = value.split_once("://") else {
        return String::new();
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let authority = if let Some((user, host)) = authority.rsplit_once('@') {
        let encoded = |value: &str| escape_bytes(&unescape(value), b";$&=+,", false);
        let user = if let Some((name, password)) = user.split_once(':') {
            format!("{}:{}", encoded(name), encoded(password))
        } else {
            encoded(user)
        };
        format!("{user}@{host}")
    } else {
        authority.into()
    };
    let mut output = format!("https://{authority}{}", url.escaped_path());
    if url.force_query || !url.raw_query.is_empty() {
        output.push('?');
        output.push_str(&url.raw_query);
    }
    if !url.fragment.is_empty() {
        output.push('#');
        if url
            .fragment
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/?%[]".contains(&byte))
        {
            output.push_str(&url.fragment);
        } else {
            output.push_str(&escape_bytes(
                &unescape(&url.fragment),
                b"!$&()*+,;=:@/?",
                false,
            ));
        }
    }
    output
}

fn escape(value: &str, extra: &[u8], spaces: bool) -> String {
    escape_bytes(value.as_bytes(), extra, spaces)
}

fn escape_bytes(value: &[u8], extra: &[u8], spaces: bool) -> String {
    use std::fmt::Write;
    let mut output = String::new();
    for &byte in value {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) || extra.contains(&byte) {
            output.push(char::from(byte));
        } else if spaces && byte == b' ' {
            output.push('+');
        } else {
            let _ = write!(output, "%{byte:02X}");
        }
    }
    output
}

fn unescape(value: &str) -> Vec<u8> {
    let mut bytes = value.bytes();
    let mut output = Vec::new();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let high = char::from(bytes.next().expect("validated URL escape"))
                .to_digit(16)
                .expect("validated URL escape");
            let low = char::from(bytes.next().expect("validated URL escape"))
                .to_digit(16)
                .expect("validated URL escape");
            output.push((high * 16 + low) as u8);
        } else {
            output.push(byte);
        }
    }
    output
}

pub fn path_escape(value: &str) -> String {
    escape(value, b"$&+:=@", false)
}
pub fn query_escape(value: &str) -> String {
    escape(value, b"", true)
}
