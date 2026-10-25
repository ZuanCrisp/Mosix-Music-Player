// English title-case control flow follows golang.org/x/text/cases (Go Authors).
// See rust_backend/NOTICE for the BSD license.
use super::case_data::{MAPPINGS, RANGES};

fn flags(ch: char) -> u8 {
    let code = ch as u32;
    let index = RANGES.partition_point(|(_, end, _)| *end < code);
    RANGES
        .get(index)
        .filter(|(start, _, _)| *start <= code)
        .map_or(4, |(_, _, flags)| *flags)
}

fn mapped(output: &mut String, ch: char, first: bool) {
    if let Ok(index) = MAPPINGS.binary_search_by_key(&(ch as u32), |(code, _, _)| *code) {
        let (_, title, lower) = MAPPINGS[index];
        let mapping = if first { title } else { lower };
        if !mapping.is_empty() {
            output.push_str(mapping);
            return;
        }
    }
    output.push(ch);
}

pub(super) fn title(value: &str) -> String {
    let chars: Vec<_> = value.chars().collect();
    let mut output = String::with_capacity(value.len());
    let mut mid_word = false;
    let mut index = 0;
    while let Some(&ch) = chars.get(index) {
        let properties = flags(ch);
        index += 1;
        if properties & 1 != 0 {
            if !mid_word {
                mapped(&mut output, ch, true);
                mid_word = true;
            } else if ch == 'Σ' {
                // Go caps this lookahead at 30 ignorables plus one following
                // rune. Ignorables are copied, even if they are also cased.
                let sigma = output.len();
                output.push('ς');
                let mut was_mid = false;
                for _ in 0..31 {
                    let Some(&next) = chars.get(index) else { break };
                    let next_flags = flags(next);
                    if next_flags & 2 == 0 {
                        if next_flags & 1 != 0 {
                            output.replace_range(sigma..sigma + 'ς'.len_utf8(), "σ");
                        }
                        break;
                    }
                    let is_mid = next_flags & 8 != 0;
                    if (was_mid && is_mid) || next_flags & 4 != 0 {
                        mid_word = false;
                    }
                    was_mid = is_mid;
                    output.push(next);
                    index += 1;
                }
            } else {
                mapped(&mut output, ch, false);
            }
        } else {
            output.push(ch);
            if properties & 4 != 0 {
                mid_word = false;
            }
        }
        if properties & 8 != 0 && chars.get(index).is_some_and(|next| flags(*next) & 8 != 0) {
            mid_word = false;
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::title;

    #[test]
    fn sigma_context_does_not_depend_on_transform_buffer_boundaries() {
        // Go's transform.String can lose mid-word state at its 128-byte
        // buffer boundary while looking beyond sigma. Preserve the same
        // contextual casing regardless of the length of an earlier prefix.
        for size in 0..300 {
            let prefix = "a|".repeat(size);
            let value = format!("{prefix}ΟΣ\u{1aff1}A'ß_\u{1aff1}ǳ|");
            let expected = format!("{}Οσ\u{1aff1}A'ß_\u{1aff1}ǲ|", "A|".repeat(size));
            assert_eq!(title(&value), expected, "prefix length {size}");
        }
    }
}
