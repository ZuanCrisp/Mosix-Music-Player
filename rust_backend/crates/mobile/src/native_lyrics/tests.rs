use super::*;
#[test]
fn shared_dart_parser_goldens() {
    let fixtures: Value = serde_json::from_str(include_str!(
        "../../../../../test/fixtures/native_lyrics_parsers.json"
    ))
    .unwrap();
    for fixture in fixtures.as_array().unwrap() {
        let actual = execute(&fixture["request"], None, &|| Ok(())).unwrap();
        assert_eq!(actual, fixture["expected"], "{}", fixture["name"]);
    }
}
#[test]
fn cancellation_stops_before_result_publication() {
    assert_eq!(
        execute(&serde_json::json!({"raw":"[00:01]Line"}), None, &|| Err(
            "cancelled".into()
        ))
        .unwrap_err(),
        "cancelled"
    );
}
#[test]
fn malformed_structural_ttml_remains_an_error() {
    for raw in [
        "<tt><body><p>Unclosed",
        "<tt><p>Mismatch</tt>",
        "<tt><m:p>Unknown namespace</m:p></tt>",
    ] {
        assert!(execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).is_err());
    }
}
#[test]
fn deeply_nested_vocals_preserve_timing_and_document_order() {
    std::thread::Builder::new().stack_size(512 << 10).spawn(|| {
            let depth = 12; // Including tt/body/p and each word: the 16-level limit.
    let raw = format!(
        "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><p begin=\"00:01.000\" end=\"00:03.000\">{}<span begin=\"00:01.000\">First </span><span begin=\"00:02.000\">second</span>{}</p></body></tt>",
        "<span>".repeat(depth),
        "</span>".repeat(depth),
    );
    let parsed = execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap();
    assert_eq!(parsed["lines"][0]["text"], "First second");
    assert_eq!(parsed["lines"][0]["words"][0]["timeMs"], 1000);
    assert_eq!(parsed["lines"][0]["words"][1]["timeMs"], 2000);
    }).unwrap().join().unwrap();
}
#[test]
fn pathological_ttml_depth_is_rejected_before_recursive_tokenization() {
    let raw = format!(
        "<tt><body><p>{}Line{}</p></body></tt>",
        "<span>".repeat(10_000),
        "</span>".repeat(10_000),
    );
    assert_eq!(
        execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap_err(),
        "XML nesting exceeds 16 elements"
    );
}
#[test]
fn depth_guard_ignores_opaque_markup_and_quoted_tag_boundaries() {
    let opaque = "<span>".repeat(1_000);
    let raw = format!(
        "<?xml version=\"1.0\"?><!DOCTYPE tt [<!-- ]> {opaque} --> <!ENTITY markup \"{opaque}\">]><tt><!--{opaque}--><body><p begin='1s' end='2s' data=\">\"><![CDATA[{opaque}]]><span data='>'>Line</span></p></body></tt>"
    );
    mornye_core::xml::check_depth(&raw).unwrap();
    let parsed = execute(&serde_json::json!({"raw":raw}), None, &|| Ok(())).unwrap();
    assert_eq!(parsed["plainText"], "Line");
}
