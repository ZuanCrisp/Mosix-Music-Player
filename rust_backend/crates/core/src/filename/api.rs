use serde_json::{Map, Number, Value};

const MAX_INPUT_BYTES: usize = 8 * 1024 * 1024;

/// Native BuildFilename accepts a JSON object (or null). Go's JSON decoder
/// exports every number as float64, even when the token looks like an integer.
pub fn build_filename_json(template: &str, metadata_json: &str) -> Result<String, String> {
    if template.len() > MAX_INPUT_BYTES || metadata_json.len() > MAX_INPUT_BYTES {
        return Err("filename input exceeds 8 MiB limit".into());
    }
    let mut metadata = serde_json::from_str::<Option<Map<String, Value>>>(
        &crate::text::json_surrogates(metadata_json),
    )
    .map_err(|error| error.to_string())?
    .unwrap_or_default();
    for value in metadata.values_mut() {
        if let Value::Number(number) = value {
            *number = Number::from_f64(number.as_f64().ok_or("invalid metadata number")?)
                .ok_or("invalid metadata number")?;
        }
    }
    super::build_filename_checked(template, &metadata, MAX_INPUT_BYTES, &|| Ok(()))
}
