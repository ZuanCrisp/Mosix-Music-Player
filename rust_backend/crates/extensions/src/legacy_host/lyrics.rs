use crate::runtime::{Control, ExtensionServices};
use cap_std::fs::OpenOptions;
use rquickjs::{Ctx, Function, Object};
use serde_json::json;
use spotiflac_core::lyrics::{file, lrc};
use spotiflac_providers::lyrics::SearchRequest;
use std::sync::Arc;

pub(super) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    let lyrics = services.lyrics.clone();
    let node = services.lyrics_node.clone();
    let files = services
        .legacy_files
        .clone()
        .or_else(|| services.files.clone());
    host.set(
        "legacyLyrics",
        Function::new(
            ctx.clone(),
            move |spotify_id: String,
                  track: String,
                  artist: String,
                  path: String,
                  duration: f64,
                  duration_text: Option<String>,
                  number_conversion: bool| {
                let check = || control.check().map_err(|error| error.to_string());
                let result: Result<String, String> = (|| {
                    check()?;
                    let (spotify_id, track, artist, path) =
                        (spotify_id.trim(), track.trim(), artist.trim(), path.trim());
                    if !path.is_empty() {
                        let result = file::extract(
                            path,
                            &|path| {
                                files
                                    .as_ref()
                                    .ok_or("file access unavailable")?
                                    .resolve_legacy(path)?
                                    .open(OpenOptions::new().read(true))
                                    .map_err(|error| error.to_string())
                            },
                            &check,
                        );
                        check()?;
                        return Ok(result
                            .ok()
                            .filter(|text| lrc::has_usable_content(text))
                            .unwrap_or_default());
                    }
                    let lyrics = lyrics.upgrade().ok_or("lyrics service unavailable")?;
                    let response = lyrics
                        .fetch(
                            SearchRequest {
                                spotify_id: spotify_id.into(),
                                track: track.into(),
                                artist: artist.into(),
                                duration: duration_ms(
                                    duration,
                                    duration_text.as_deref(),
                                    number_conversion,
                                ) as f64
                                    / 1000.0,
                                caller: Some(node.clone()),
                                ..SearchRequest::default()
                            },
                            &check,
                        )
                        .map_err(|error| error.to_string())?;
                    check()?;
                    Ok(if response.instrumental {
                        "[instrumental:true]".into()
                    } else {
                        lrc::with_metadata(&response, track, artist)
                    })
                })();
                match result {
                    Ok(text) => json!({"lyrics":text}),
                    Err(error) => json!({"error":error}),
                }
                .to_string()
            },
        )?,
    )?;
    Ok(())
}

fn duration_ms(number: f64, text: Option<&str>, number_conversion: bool) -> i64 {
    let Some(text) = text else {
        return number as i64;
    };
    // Goja's primitive unicodeString.ToInteger returns zero. Object coercion
    // first calls ToNumber, which trims ECMAScript whitespace before Go space.
    if !number_conversion && !text.is_ascii() {
        return 0;
    }
    let text = text.trim();
    let (digits, radix) = match text.get(..2) {
        Some("0x" | "0X") => (&text[2..], 16),
        Some("0b" | "0B") => (&text[2..], 2),
        Some("0o" | "0O") => (&text[2..], 8),
        _ => (text, 10),
    };
    match i64::from_str_radix(digits, radix) {
        Ok(value) => value,
        Err(_) if radix != 10 && number_conversion => 0,
        Err(error) if radix != 10 => match error.kind() {
            std::num::IntErrorKind::PosOverflow => i64::MAX,
            std::num::IntErrorKind::NegOverflow => i64::MIN,
            _ => 0,
        },
        _ => {
            // Preserve Go's decimal parsing and reject non-ECMAScript inf names.
            let parsed = if text.contains('_') {
                None
            } else {
                text.parse::<f64>().ok().filter(|value| {
                    !value.is_infinite()
                        || matches!(text, "Infinity" | "+Infinity" | "-Infinity")
                        || text.contains(['e', 'E'])
                })
            };
            parsed.unwrap_or(0.0) as i64
        }
    }
}
