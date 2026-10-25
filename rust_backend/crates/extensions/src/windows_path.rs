//! Windows rules for path names that an extension or a package controls.
//!
//! Win32 path parsing gives meaning to text that POSIX treats as a plain file
//! name: drive prefixes (`C:\x`, drive-relative `C:x`), root-relative, UNC and
//! device paths (`\x`, `\\server\share`, `\\?\`, `\\.\`), alternate data
//! streams (`name:stream`), reserved device names (`NUL`, `com1.txt`) and the
//! trailing dots and spaces Win32 strips (`name.` opens `name`). A sandboxed
//! name must be a plain relative path, so these are rejected, never rewritten.

/// Accept `path` only when every component is a plain Windows file name.
/// Both separators are accepted; empty and `.` components collapse. `..` is
/// rejected even where it would stay inside the sandbox.
pub(crate) fn check_relative(path: &str) -> Result<(), String> {
    if path.starts_with(['/', '\\']) {
        return Err(format!("path '{path}' must be relative"));
    }
    for component in path.split(['/', '\\']) {
        check_component(component).map_err(|reason| format!("path '{path}' {reason}"))?;
    }
    Ok(())
}

fn check_component(name: &str) -> Result<(), &'static str> {
    match name {
        "" | "." => return Ok(()),
        ".." => return Err("must not contain parent directory components"),
        _ => {}
    }
    if name.contains(':') {
        return Err("must not contain drive prefixes or stream names");
    }
    if name
        .chars()
        .any(|c| c < ' ' || matches!(c, '<' | '>' | '"' | '|' | '?' | '*'))
    {
        return Err("contains characters Windows file names cannot use");
    }
    if name.ends_with(['.', ' ']) {
        return Err("must not end a component with a dot or space");
    }
    if is_reserved_device(name) {
        return Err("must not name a Windows device");
    }
    Ok(())
}

/// Win32 maps these names to devices case-insensitively, even with an
/// extension or spaces before it (`nul.txt`, `aux .flac`).
fn is_reserved_device(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or(name).trim_end_matches(' ');
    let stem = stem.to_ascii_uppercase();
    if matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$"
    ) {
        return true;
    }
    let Some(number) = stem
        .strip_prefix("COM")
        .or_else(|| stem.strip_prefix("LPT"))
    else {
        return false;
    };
    let mut chars = number.chars();
    matches!(
        (chars.next(), chars.next()),
        (Some('0'..='9' | '\u{b9}' | '\u{b2}' | '\u{b3}'), None)
    )
}

#[cfg(test)]
mod tests {
    use super::check_relative;

    #[test]
    fn plain_relative_names_are_accepted() {
        for path in [
            "song.flac",
            "album/disc 1/01 song.flac",
            "album\\disc\\song.flac",
            "./album//song.flac",
            ".",
            ".hidden",
            "console.log",
            "nul_file",
            "COMPUTER.txt",
            "COM10",
            "LPT",
            "\u{e9}t\u{e9}/caf\u{e9}.flac",
        ] {
            assert_eq!(check_relative(path), Ok(()), "{path}");
        }
    }

    #[test]
    fn escape_and_alias_attempts_are_rejected() {
        for path in [
            // Parent traversal, including traversal that cancels out.
            "..",
            "../outside.flac",
            "album/../../outside.flac",
            "album\\..\\..\\outside.flac",
            "album/../song.flac",
            // Root-relative, UNC and device namespace paths.
            "/outside.flac",
            "\\outside.flac",
            "\\\\server\\share\\x.flac",
            "//server/share/x.flac",
            "\\\\?\\C:\\Windows\\x",
            "\\\\.\\PhysicalDrive0",
            "\\??\\C:\\x",
            // Absolute and drive-relative paths.
            "C:\\Windows\\win.ini",
            "C:/Windows/win.ini",
            "C:outside.flac",
            "c:",
            // Alternate data streams.
            "song.flac:hidden",
            "song.flac::$DATA",
            "album:stream/song.flac",
            // Reserved device names, with any case, extension or padding.
            "NUL",
            "nul.txt",
            "con",
            "album/Com1.flac",
            "LPT9",
            "COM\u{b9}",
            "CONIN$",
            "conout$.log",
            "aux .flac",
            "PRN.tar.gz",
            // Names Win32 strips or treats as wildcards.
            "song.",
            "song ",
            "album./song.flac",
            "...",
            "so*ng.flac",
            "so?ng.flac",
            "so<ng.flac",
            "so>ng.flac",
            "so|ng.flac",
            "so\"ng.flac",
            "so\u{1}ng.flac",
            "so\0ng.flac",
        ] {
            assert!(check_relative(path).is_err(), "{path:?} was accepted");
        }
    }
}
