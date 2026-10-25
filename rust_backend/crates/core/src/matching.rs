//! Matching compatibility uses Go's simple case mapping and UTF-8 byte distance.

/// Unlike String::to_lowercase, Go's unicode.ToLower maps one rune to one rune.
pub fn lowercase(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            // Go 1.26 uses Unicode 15.0; these lowercase mappings were added
            // in Unicode 16/17, used by the pinned Rust toolchain.
            '\u{1c89}'
            | '\u{a7cb}'
            | '\u{a7cc}'
            | '\u{a7ce}'
            | '\u{a7d2}'
            | '\u{a7d4}'
            | '\u{a7da}'
            | '\u{a7dc}'
            | '\u{10d50}'..='\u{10d65}'
            | '\u{16ea0}'..='\u{16eb8}' => ch,
            _ => ch.to_lowercase().next().expect("lowercase character"),
        })
        .collect()
}

/// Go's Unicode 15 simple uppercase does not expand characters such as ß.
pub fn uppercase(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            '\u{019b}'
            | '\u{0264}'
            | '\u{1c8a}'
            | '\u{a7cd}'
            | '\u{a7cf}'
            | '\u{a7d3}'
            | '\u{a7d5}'
            | '\u{a7db}'
            | '\u{10d70}'..='\u{10d85}'
            | '\u{16ebb}'..='\u{16ed3}' => ch,
            // Full uppercase expands these Greek letters; simple uppercase uses
            // the corresponding single precomposed capital instead.
            '\u{1f80}'..='\u{1f87}' | '\u{1f90}'..='\u{1f97}' | '\u{1fa0}'..='\u{1fa7}' => {
                char::from_u32(ch as u32 + 8).expect("Greek capital")
            }
            '\u{1fb3}' => '\u{1fbc}',
            '\u{1fc3}' => '\u{1fcc}',
            '\u{1ff3}' => '\u{1ffc}',
            _ => {
                let mut mapped = ch.to_uppercase();
                let first = mapped.next().expect("uppercase character");
                if mapped.next().is_none() { first } else { ch }
            }
        })
        .collect()
}

pub fn normalize(value: &str) -> String {
    let mut value = lowercase(value);
    for suffix in [
        " (remastered)",
        " (remaster)",
        " - remastered",
        " - remaster",
        " (deluxe)",
        " (deluxe edition)",
        " - deluxe",
        " - deluxe edition",
        " (explicit)",
        " (clean)",
        " [explicit]",
        " [clean]",
        " (album version)",
        " (single version)",
        " (radio edit)",
        " (feat.",
        " (ft.",
        " feat.",
        " ft.",
    ] {
        if let Some(index) = value.find(suffix) {
            value.truncate(index);
        }
    }
    let filtered: String = value
        .chars()
        .filter(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || *ch == ' ')
        .collect();
    filtered.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn compare_strings(
    first: &str,
    second: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<f64, String> {
    check()?;
    let first = lowercase(first.trim());
    let second = lowercase(second.trim());
    if first == second {
        return Ok(1.0);
    }
    let maximum = first.len().max(second.len());
    if first.is_empty() || second.is_empty() {
        return Ok(0.0);
    }
    let mut first = first.as_bytes();
    let mut second = second.as_bytes();
    let prefix = first.iter().zip(second).take_while(|(a, b)| a == b).count();
    first = &first[prefix..];
    second = &second[prefix..];
    let suffix = first
        .iter()
        .rev()
        .zip(second.iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    first = &first[..first.len() - suffix];
    second = &second[..second.len() - suffix];
    if first.len() < second.len() {
        std::mem::swap(&mut first, &mut second);
    }
    let mut row: Vec<_> = (0..=second.len()).collect();
    for (i, a) in first.iter().enumerate() {
        check()?;
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, b) in second.iter().enumerate() {
            if j % 4096 == 0 {
                check()?;
            }
            let old = row[j + 1];
            row[j + 1] = (old + 1)
                .min(row[j] + 1)
                .min(diagonal + usize::from(a != b));
            diagonal = old;
        }
    }
    Ok(1.0 - row[second.len()] as f64 / maximum as f64)
}

/// Go's `int` is native-width and arithmetic wraps, including abs(MIN).
pub fn compare_duration(first: i64, second: i64, tolerance: i64) -> bool {
    let difference = (first as isize)
        .wrapping_sub(second as isize)
        .wrapping_abs();
    difference <= tolerance as isize
}
