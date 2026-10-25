//! Validate caller JSON without retaining a second object tree before QuickJS
//! parses it. Use normal Serde visits rather than IgnoredAny/RawValue so number
//! range, string escape, nesting, and trailing-data errors remain unchanged.

use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use std::fmt;

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Shape {
    Scalar,
    Array,
    Object { empty: bool },
}

impl Shape {
    pub(super) fn is_array(&self) -> bool {
        matches!(self, Self::Array)
    }

    pub(super) fn is_object(&self) -> bool {
        matches!(self, Self::Object { .. })
    }

    pub(super) fn is_empty_object(&self) -> bool {
        matches!(self, Self::Object { empty: true })
    }
}

impl<'de> Deserialize<'de> for Shape {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ShapeVisitor;

        impl<'de> Visitor<'de> for ShapeVisitor {
            type Value = Shape;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("any valid JSON value")
            }

            fn visit_bool<E>(self, _: bool) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_i64<E>(self, _: i64) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_u64<E>(self, _: u64) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_f64<E>(self, _: f64) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_str<E>(self, _: &str) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_unit<E>(self) -> Result<Shape, E> {
                Ok(Shape::Scalar)
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut values: A) -> Result<Shape, A::Error> {
                while values.next_element::<Shape>()?.is_some() {}
                Ok(Shape::Array)
            }

            fn visit_map<A: MapAccess<'de>>(self, mut values: A) -> Result<Shape, A::Error> {
                let mut empty = true;
                while values.next_entry::<Shape, Shape>()?.is_some() {
                    empty = false;
                }
                Ok(Shape::Object { empty })
            }
        }

        deserializer.deserialize_any(ShapeVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn compare(input: &str) {
        let expected = serde_json::from_str::<serde_json::Value>(input);
        let actual = serde_json::from_str::<Shape>(input);
        match (expected, actual) {
            (Ok(value), Ok(shape)) => {
                assert_eq!(shape.is_array(), value.is_array(), "{input}");
                assert_eq!(shape.is_object(), value.is_object(), "{input}");
                assert_eq!(
                    shape.is_empty_object(),
                    value.as_object().is_some_and(|value| value.is_empty()),
                    "{input}",
                );
            }
            (Err(expected), Err(actual)) => {
                assert_eq!(actual.to_string(), expected.to_string(), "{input}");
            }
            (expected, actual) => {
                panic!("validation differs for {input:?}: {expected:?} / {actual:?}")
            }
        }
    }

    #[test]
    fn validation_matches_value_shapes_numbers_unicode_and_errors() {
        for input in [
            "null",
            "true",
            "false",
            "0",
            "-0",
            "1.25e-100",
            "1e400",
            "[1e400,0]",
            "{\"x\":1e400,\"x\":0}",
            "18446744073709551615",
            "18446744073709551616",
            "-9223372036854775809",
            "NaN",
            "Infinity",
            "[]",
            "{}",
            "{\"x\":null}",
            "  {  }\n",
            "[1,{\"a\":[true,null,\"text\"]}]",
            "\"音楽 🎵\"",
            "\"\\uD83C\\uDFB5\"",
            "\"\\uD800\"",
            "\"\\uDC00\"",
            "\"\\x20\"",
            "\"line\nfeed\"",
            "{\"a\\tb\":\"\\u0000\"}",
            "{\"a\":1,\"a\":2}",
            "{1:true}",
            "[01]",
            "[1,]",
            "[] true",
            "[",
            "{\"x\":",
            "",
        ] {
            compare(input);
        }
        for depth in [1, 100, 127, 128, 129] {
            compare(&format!("{}0{}", "[".repeat(depth), "]".repeat(depth)));
            compare(&format!(
                "{}0{}",
                "{\"key\":".repeat(depth),
                "}".repeat(depth)
            ));
        }
    }

    #[test]
    fn validation_matches_value_for_truncated_and_mutated_payloads() {
        let input = r#"[{"track":"a\\b\n\uD83C\uDFB5","options":{"count":123.4e-3,"ids":[1,2,3],"ok":true,"nil":null}}]"#;
        for index in 0..input.len() {
            compare(&input[..index]);
            for &replacement in b" \"\\0,]}" {
                let mut bytes = input.as_bytes().to_vec();
                bytes[index] = replacement;
                compare(std::str::from_utf8(&bytes).unwrap());
            }
        }
    }

    #[test]
    #[ignore = "manual release benchmark: JSON validation only, not device latency"]
    fn benchmark_shape_validation() {
        use std::hint::black_box;
        use std::time::Instant;

        for count in [1, 100, 1000, 10000] {
            let row = serde_json::json!({"id":"track-123","title":"音楽 🎵","artists":["Artist"],"duration_ms":240000,"options":{"quality":"lossless","enabled":true}});
            let input = serde_json::json!([vec![row; count]]).to_string();
            let mut old = Vec::new();
            let mut new = Vec::new();
            for round in 0..44 {
                for baseline in if round % 2 == 0 {
                    [true, false]
                } else {
                    [false, true]
                } {
                    let start = Instant::now();
                    if baseline {
                        black_box(
                            serde_json::from_str::<serde_json::Value>(black_box(&input)).unwrap(),
                        );
                    } else {
                        black_box(serde_json::from_str::<Shape>(black_box(&input)).unwrap());
                    }
                    if round >= 4 {
                        (if baseline { &mut old } else { &mut new })
                            .push(start.elapsed().as_nanos());
                    }
                }
            }
            old.sort_unstable();
            new.sort_unstable();
            println!(
                "validation rows={count} bytes={} samples=40 old_median_ns={} new_median_ns={} old_p95_ns={} new_p95_ns={}",
                input.len(),
                old[20],
                new[20],
                old[37],
                new[37]
            );
        }
    }
}
