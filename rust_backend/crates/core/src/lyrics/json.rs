//! Go's typed provider JSON accepts case-insensitive fields and null scalars.

use serde::de::{DeserializeOwned, DeserializeSeed, Visitor};
use serde::{Deserialize, Deserializer};
use std::borrow::Cow;

pub(super) fn decode<T: DeserializeOwned>(raw: &str) -> Result<T, serde_json::Error> {
    serde_json::from_str(&crate::text::json_surrogates(raw))
}

pub(crate) fn field_name(name: &str) -> String {
    name.chars()
        .map(|ch| match ch {
            'ſ' => 's',
            'K' => 'k',
            _ => ch.to_ascii_lowercase(),
        })
        .collect()
}

struct KeyVisitor;

impl<'de> Visitor<'de> for KeyVisitor {
    type Value = Cow<'de, str>;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a string key")
    }

    fn visit_borrowed_str<E: serde::de::Error>(self, value: &'de str) -> Result<Self::Value, E> {
        Ok(Cow::Borrowed(value))
    }

    fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Self::Value, E> {
        Ok(Cow::Owned(value.into()))
    }

    fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Self::Value, E> {
        Ok(Cow::Owned(value))
    }
}

pub(crate) struct KeySeed;

impl<'de> DeserializeSeed<'de> for KeySeed {
    type Value = Cow<'de, str>;

    fn deserialize<D: Deserializer<'de>>(self, decoder: D) -> Result<Self::Value, D::Error> {
        decoder.deserialize_str(KeyVisitor)
    }
}

pub(crate) trait Update<'de> {
    fn update<D: Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error>;
}

macro_rules! scalar {
    ($($type:ty),*) => {$(
        impl<'de> Update<'de> for $type {
            fn update<D: Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error> {
                // A later null does not overwrite an already decoded scalar.
                if let Some(value) = Option::<Self>::deserialize(decoder)? { *self = value; }
                Ok(())
            }
        }
    )*};
}
scalar!(String, bool, i64, isize, f64);

impl<'de, T: Deserialize<'de>> Update<'de> for Option<T> {
    fn update<D: Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error> {
        *self = Self::deserialize(decoder)?;
        Ok(())
    }
}

pub(crate) struct Field<'a, T>(pub &'a mut T);

impl<'de, T: Update<'de>> DeserializeSeed<'de> for Field<'_, T> {
    type Value = ();
    fn deserialize<D: Deserializer<'de>>(self, decoder: D) -> Result<(), D::Error> {
        self.0.update(decoder)
    }
}

macro_rules! go_deserialize {
    ($name:ident { $($key:literal => $field:ident,)* }) => {
        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
                let mut result = Self::default();
                $crate::lyrics::json::Update::update(&mut result, decoder)?;
                Ok(result)
            }
        }
        impl<'de> $crate::lyrics::json::Update<'de> for $name {
            fn update<D: serde::Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error> {
                struct Visitor<'a>(&'a mut $name);
                impl<'de> serde::de::Visitor<'de> for Visitor<'_> {
                    type Value = ();
                    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                        formatter.write_str("a lyrics object or null")
                    }
                    fn visit_unit<E: serde::de::Error>(self) -> Result<(), E> {
                        Ok(())
                    }
                    fn visit_map<M: serde::de::MapAccess<'de>>(self, mut map: M) -> Result<(), M::Error> {
                        while let Some(key) = map.next_key_seed($crate::lyrics::json::KeySeed)? {
                            let raw_key = key.as_ref();
                            let folded;
                            let lookup = match raw_key {
                                $($key => raw_key,)*
                                _ => {
                                    folded = $crate::lyrics::json::field_name(raw_key);
                                    folded.as_str()
                                }
                            };
                            match lookup {
                                $($key => map.next_value_seed($crate::lyrics::json::Field(&mut self.0.$field))?,)*
                                _ => { map.next_value::<serde::de::IgnoredAny>()?; }
                            }
                        }
                        Ok(())
                    }
                }
                decoder.deserialize_any(Visitor(self))
            }
        }
    };
}
pub(crate) use go_deserialize;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_seed_borrows_canonical_keys_and_owns_escaped_keys() {
        let mut decoder = serde_json::Deserializer::from_str(r#""source""#);
        assert!(matches!(
            KeySeed.deserialize(&mut decoder).unwrap(),
            Cow::Borrowed("source")
        ));

        let mut decoder = serde_json::Deserializer::from_str(r#""so\u0075rce""#);
        assert!(matches!(
            KeySeed.deserialize(&mut decoder).unwrap(),
            Cow::Owned(value) if value == "source"
        ));
    }

    #[test]
    fn field_folding_preserves_special_letters_and_null_duplicates() {
        assert_eq!(field_name("ſOURCE"), "source");
        assert_eq!(field_name("K"), "k");

        let response: crate::lyrics::LyricsResponse = serde_json::from_str(
            r#"{"plainlyrics":"kept","PLAINLYRICS":null,"ſource":"old","SOURCE":"new"}"#,
        )
        .unwrap();
        assert_eq!(response.plain_lyrics, "kept");
        assert_eq!(response.source, "new");
    }
}
