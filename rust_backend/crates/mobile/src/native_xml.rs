//! Bounds for the recursive tokenizer used by our native XML readers.
pub(crate) fn check_depth(input: &str) -> Result<(), String> {
    // roxmltree's tokenizer recurses through nested elements. Guard its input
    // before parsing so pathological metadata returns an error, not a native
    // stack overflow. Ordinary TTML is only a handful of elements deep.
    const MAX_DEPTH: usize = 16;
    let bytes = input.as_bytes();
    let (mut index, mut depth) = (0, 0_usize);
    while index < bytes.len() {
        if bytes[index] != b'<' {
            index += 1;
            continue;
        }
        let tail = &input[index..];
        let ending = if tail.starts_with("<!--") {
            Some("-->")
        } else if tail.starts_with("<![CDATA[") {
            Some("]]>")
        } else if tail.starts_with("<?") {
            Some("?>")
        } else {
            None
        };
        if let Some(ending) = ending {
            let Some(end) = tail.find(ending) else {
                return Ok(()); // The XML parser reports unterminated markup.
            };
            index += end + ending.len();
            continue;
        }
        let Some(end) = markup_end(tail, tail.starts_with("<!DOCTYPE")) else {
            return Ok(());
        };
        if tail.starts_with("</") {
            depth = depth.saturating_sub(1);
        } else if !tail.starts_with("<!")
            && !tail[..end - 1]
                .trim_end_matches([' ', '\t', '\r', '\n'])
                .ends_with('/')
        {
            depth += 1;
            if depth > MAX_DEPTH {
                return Err(format!("XML nesting exceeds {MAX_DEPTH} elements"));
            }
        }
        index += end;
    }
    Ok(())
}

pub(crate) fn markup_end(input: &str, doctype: bool) -> Option<usize> {
    let bytes = input.as_bytes();
    let (mut quote, mut brackets, mut position) = (None, 0_usize, 0);
    while position < bytes.len() {
        let byte = bytes[position];
        if let Some(current) = quote {
            if byte == current {
                quote = None;
            }
        } else {
            // A DOCTYPE's internal subset may contain comments or processing
            // instructions whose brackets and tag-like text have no meaning.
            let ending = if doctype && bytes[position..].starts_with(b"<!--") {
                Some(b"-->".as_slice())
            } else if doctype && bytes[position..].starts_with(b"<?") {
                Some(b"?>".as_slice())
            } else {
                None
            };
            if let Some(ending) = ending {
                let end = bytes[position..]
                    .windows(ending.len())
                    .position(|window| window == ending)?;
                position += end + ending.len();
                continue;
            }
            match byte {
                b'\'' | b'"' => quote = Some(byte),
                b'[' if doctype => brackets += 1,
                b']' if doctype => brackets = brackets.saturating_sub(1),
                b'>' if brackets == 0 => return Some(position + 1),
                _ => {}
            }
        }
        position += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_actual_element_nesting_and_ignores_self_closing_nodes() {
        let maximum = format!("{}{}", "<a>".repeat(16), "</a>".repeat(16));
        check_depth(&maximum).unwrap();
        assert!(check_depth(&format!("<a>{maximum}</a>")).is_err());
        check_depth(&format!("<a>{}</a>", "<b/>".repeat(10_000))).unwrap();
    }

    #[test]
    fn quoted_attributes_and_opaque_sections_are_not_element_depth() {
        let markup = "<span>".repeat(1_000);
        check_depth(&format!(
            "<?xml version='1.0'?><!DOCTYPE a [<!-- ]> {markup} --> <?note ]>?> <!ENTITY b '{markup}'>]><a value='>'><!--{markup}--><![CDATA[{markup}]]><b value=\">\"/></a>"
        )).unwrap();
    }
}
