use crate::host::decode_go_utf8;
use crate::runtime::{Control, ExtensionServices};
use base64::Engine;
use rquickjs::{Array, Ctx, Function, Object, TypedArray, Value};
use spotiflac_network::{HttpRequest, HttpResponse};
use std::collections::BTreeMap;
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    host.set("networkEnabled", services.network.is_some())?;
    let Some(session) = &services.network else {
        return Ok(());
    };
    let validator = Arc::clone(session);
    host.set(
        "validateURL",
        Function::new(ctx.clone(), move |url: String| {
            validator.validate_url(&url).err()
        })?,
    )?;
    let clearer = Arc::clone(session);
    host.set(
        "clearCookies",
        Function::new(ctx.clone(), move || {
            clearer.clear_cookies();
            true
        })?,
    )?;
    let session = Arc::clone(session);
    host.set(
        "request",
        Function::new(
            ctx.clone(),
            move |url: String,
                  method: String,
                  body: String,
                  headers: Object<'js>,
                  default_json: bool,
                  user_agent: String,
                  fetch: bool|
                  -> rquickjs::Result<Object<'js>> {
                let ctx = headers.ctx().clone();
                let headers = headers
                    .props::<String, String>()
                    .collect::<rquickjs::Result<BTreeMap<_, _>>>()?;
                let result = session.request(
                    HttpRequest {
                        url,
                        method,
                        body,
                        headers,
                        default_json,
                        user_agent,
                    },
                    || control.check().map_err(|error| error.to_string()),
                );
                match result {
                    Ok(response) => response_object(&ctx, response, fetch),
                    Err(error) => {
                        let object = Object::new(ctx)?;
                        object.set("error", error)?;
                        Ok(object)
                    }
                }
            },
        )?,
    )?;
    host.set(
        "decodeBuffer",
        Function::new(ctx.clone(), |bytes: TypedArray<'js, u8>| {
            decode_buffer(&bytes)
        })?,
    )?;
    host.set(
        "parseJSONBuffer",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, bytes: TypedArray<'js, u8>| {
            parse_json(&ctx, &decode_buffer(&bytes))
        })?,
    )?;
    host.set(
        "encodeBuffer",
        Function::new(ctx.clone(), |bytes: TypedArray<'js, u8>| {
            encode_buffer(&bytes)
        })?,
    )?;
    Ok(())
}

fn parse_json<'js>(ctx: &Ctx<'js>, text: &str) -> rquickjs::Result<Value<'js>> {
    let text = spotiflac_core::normalize_json_surrogates(text);
    let bytes = text.as_bytes();
    let (mut position, mut depth) = (0, 0usize);
    // Go validates every float64 before overwriting duplicate object keys.
    // The engine supplies syntax validation and allocates directly in its heap.
    while position < bytes.len() {
        match bytes[position] {
            b'"' => {
                position += 1;
                while position < bytes.len() && bytes[position] != b'"' {
                    position += if bytes[position] == b'\\' { 2 } else { 1 };
                }
            }
            b'[' | b'{' => {
                depth += 1;
                if depth > 10_000 {
                    return Err(rquickjs::Exception::throw_syntax(
                        ctx,
                        "JSON exceeds maximum depth",
                    ));
                }
            }
            b']' | b'}' => depth = depth.saturating_sub(1),
            b'-' | b'0'..=b'9' => {
                let start = position;
                while position < bytes.len()
                    && matches!(
                        bytes[position],
                        b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E'
                    )
                {
                    position += 1;
                }
                if !text[start..position]
                    .parse::<f64>()
                    .is_ok_and(f64::is_finite)
                {
                    return Err(rquickjs::Exception::throw_syntax(
                        ctx,
                        "invalid JSON number",
                    ));
                }
                continue;
            }
            _ => {}
        }
        position += 1;
    }
    ctx.json_parse(text.as_bytes())
}

fn response_object<'js>(
    ctx: &Ctx<'js>,
    response: HttpResponse,
    fetch: bool,
) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("status", response.status)?;
    object.set("ok", (200..300).contains(&response.status))?;
    object.set("url", response.url)?;
    let headers = Object::new(ctx.clone())?;
    for (key, values) in response.headers {
        if values.len() == 1 {
            headers.set(key, &values[0])?;
        } else {
            let array = Array::new(ctx.clone())?;
            for (index, value) in values.into_iter().enumerate() {
                array.set(index, value)?;
            }
            headers.set(key, array)?;
        }
    }
    object.set("headers", headers)?;
    if fetch {
        object.set("statusText", response.status_text)?;
        // Copy into engine-owned memory so retained responses count against the
        // VM heap limit. No base64 intermediate or per-byte JS Number array.
        object.set("bytes", TypedArray::new_copy(ctx.clone(), response.body)?)?;
    } else {
        object.set("statusCode", response.status)?;
        object.set("body", crate::host::decode_go_utf8_owned(response.body))?;
    }
    Ok(object)
}

#[allow(unsafe_code)]
fn decode_buffer(bytes: &TypedArray<'_, u8>) -> String {
    // SAFETY: the VM has one worker and exposes no shared-memory workers. No
    // JavaScript or engine operation runs while borrowing its buffer. The owned
    // Rust String is completed before returning through rquickjs into JavaScript.
    let bytes = unsafe { bytes.as_bytes() }.unwrap_or_default();
    decode_go_utf8(bytes)
}

#[allow(unsafe_code)]
fn encode_buffer(bytes: &TypedArray<'_, u8>) -> String {
    // SAFETY: same single-worker, no-engine-call borrowing rule as decode_buffer.
    let bytes = unsafe { bytes.as_bytes() }.unwrap_or_default();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_response_preserves_status_headers_unicode_and_invalid_bytes() {
        let runtime = rquickjs::Runtime::new().unwrap();
        let context = rquickjs::Context::full(&runtime).unwrap();
        context.with(|ctx| {
            for body in ["Music 音楽 🎵\0".as_bytes(), &b"a\xe2\x82b"[..]] {
                let response = response_object(
                    &ctx,
                    HttpResponse {
                        status: 201,
                        status_text: "Created".into(),
                        url: "https://example.invalid/metadata".into(),
                        headers: BTreeMap::from([(
                            "Content-Type".into(),
                            vec!["text/plain".into()],
                        )]),
                        body: body.to_vec(),
                    },
                    false,
                )
                .unwrap();
                assert_eq!(
                    response.get::<_, String>("body").unwrap(),
                    decode_go_utf8(body)
                );
                assert_eq!(response.get::<_, u16>("statusCode").unwrap(), 201);
                assert!(response.get::<_, bool>("ok").unwrap());
                assert_eq!(
                    response
                        .get::<_, Object>("headers")
                        .unwrap()
                        .get::<_, String>("Content-Type")
                        .unwrap(),
                    "text/plain",
                );
            }
        });
    }
}
