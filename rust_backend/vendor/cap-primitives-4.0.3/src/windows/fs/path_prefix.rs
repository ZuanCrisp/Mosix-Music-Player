use std::borrow::Cow;

/// Convert DOS and UNC extended paths without losing the network root. Keep
/// other device namespaces verbatim because removing their prefix changes them.
pub(crate) fn strip_extended_prefix(wide: &[u16]) -> Cow<'_, [u16]> {
    let Some(tail) = wide.strip_prefix(&[b'\\' as u16, b'\\' as u16, b'?' as u16, b'\\' as u16])
    else {
        return Cow::Borrowed(wide);
    };
    if tail.len() >= 4
        && (tail[0] | 0x20) == b'u' as u16
        && (tail[1] | 0x20) == b'n' as u16
        && (tail[2] | 0x20) == b'c' as u16
        && tail[3] == b'\\' as u16
    {
        let mut unc = Vec::with_capacity(tail.len() - 2);
        unc.extend_from_slice(&[b'\\' as u16, b'\\' as u16]);
        unc.extend_from_slice(&tail[4..]);
        Cow::Owned(unc)
    } else if tail.len() >= 3
        && ((b'A' as u16..=b'Z' as u16).contains(&tail[0])
            || (b'a' as u16..=b'z' as u16).contains(&tail[0]))
        && tail[1] == b':' as u16
        && tail[2] == b'\\' as u16
    {
        Cow::Borrowed(tail)
    } else {
        Cow::Borrowed(wide)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(input: &str, expected: &str) {
        let input: Vec<_> = input.encode_utf16().collect();
        let expected: Vec<_> = expected.encode_utf16().collect();
        assert_eq!(strip_extended_prefix(&input).as_ref(), expected);
    }

    #[test]
    fn unc_paths_keep_the_server_and_share_root() {
        check(r"\\?\UNC\server\share\Music", r"\\server\share\Music");
        check(r"\\?\UNC\192.0.2.1\Music", r"\\192.0.2.1\Music");
        check(r"\\?\unc\server\share\", r"\\server\share\");
        check(r"\\server\share\Music", r"\\server\share\Music");
    }

    #[test]
    fn dos_and_other_namespaces_keep_their_meaning() {
        check(r"\\?\C:\Music\song.flac", r"C:\Music\song.flac");
        check(r"\\?\z:\Music", r"z:\Music");
        check(r"C:\Music", r"C:\Music");
        check(r"\\?\Volume{1234}\Music", r"\\?\Volume{1234}\Music");
        check(r"\\.\C:\Music", r"\\.\C:\Music");
        check("", "");
    }

    #[test]
    fn unc_conversion_preserves_utf16_names_and_long_paths() {
        check(r"\\?\UNC\server\音乐\Björk 🎵", r"\\server\音乐\Björk 🎵");
        let tail = r"album\".repeat(100);
        check(
            &format!(r"\\?\UNC\server\share\{tail}"),
            &format!(r"\\server\share\{tail}"),
        );
        let mut input: Vec<_> = r"\\?\UNC\server\share\".encode_utf16().collect();
        input.extend_from_slice(&[0xd800, b'.' as u16, b'f' as u16]);
        let mut expected: Vec<_> = r"\\server\share\".encode_utf16().collect();
        expected.extend_from_slice(&[0xd800, b'.' as u16, b'f' as u16]);
        assert_eq!(strip_extended_prefix(&input).as_ref(), expected);
    }
}
