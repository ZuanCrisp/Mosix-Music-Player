//! Go's typed provider JSON accepts case-insensitive fields and null scalars.
//! The lenient struct decoder lives in [`crate::json`].

use serde::de::DeserializeOwned;

pub(super) fn decode<T: DeserializeOwned>(raw: &str) -> Result<T, serde_json::Error> {
    serde_json::from_str(&crate::text::json_surrogates(raw))
}

#[cfg(test)]
mod tests {
    #[test]
    fn field_folding_preserves_special_letters_and_null_duplicates() {
        let response: crate::lyrics::LyricsResponse = serde_json::from_str(
            r#"{"plainlyrics":"kept","PLAINLYRICS":null,"ſource":"old","SOURCE":"new"}"#,
        )
        .unwrap();
        assert_eq!(response.plain_lyrics, "kept");
        assert_eq!(response.source, "new");
    }
}
