//! Native numeric and album-quality rules used while reading provider objects.

pub(crate) fn integer(value: f64, wide: bool) -> String {
    let integer = value as i64;
    if wide {
        integer.to_string()
    } else {
        (integer as isize).to_string()
    }
}

pub(crate) fn audio_traits(qualities: Vec<String>, modes: Vec<String>) -> Vec<String> {
    let mut atmos = false;
    let mut hires = false;
    let mut lossless = false;
    for (quality, mode) in qualities.iter().zip(&modes) {
        // Go uses one-rune uppercase mappings, so expanding ß to SS must not
        // accidentally make an unrecognized label match LOSSLESS.
        let upper = |value: &str| {
            value
                .chars()
                .map(|character| {
                    let mut mapped = character.to_uppercase();
                    let first = mapped.next().unwrap();
                    if mapped.next().is_none() {
                        first
                    } else {
                        character
                    }
                })
                .collect::<String>()
        };
        let quality = upper(quality);
        atmos |= upper(mode).contains("ATMOS") || quality.contains("ATMOS");
        hires |= ["HI_RES", "HIRES", "MASTER", "MQA"]
            .iter()
            .any(|part| quality.contains(part));
        lossless |= quality.contains("LOSSLESS") || quality.contains("FLAC");
        let lower = spotiflac_core::matching::lowercase(&quality);
        let numeric_prefix = |suffix: &str, decimal: bool| {
            lower
                .find(suffix)
                .map(|end| {
                    let mut start = end;
                    while start > 0
                        && (lower.as_bytes()[start - 1].is_ascii_digit()
                            || (decimal && lower.as_bytes()[start - 1] == b'.'))
                    {
                        start -= 1;
                    }
                    &lower[start..end]
                })
                .unwrap_or("")
        };
        let depth = numeric_prefix("bit", false).parse::<isize>().unwrap_or(0);
        let rate = numeric_prefix("khz", true)
            .parse::<f64>()
            .ok()
            .filter(|value| value.is_finite())
            .unwrap_or(0.0);
        if depth > 0 {
            if depth > 16 || rate > 48.0 {
                hires = true;
            } else {
                lossless = true;
            }
        }
    }
    let mut traits = Vec::new();
    if atmos {
        traits.push("dolby_atmos".into());
    }
    if hires {
        traits.push("hi_res_lossless".into());
    } else if lossless {
        traits.push("lossless".into());
    }
    traits
}
