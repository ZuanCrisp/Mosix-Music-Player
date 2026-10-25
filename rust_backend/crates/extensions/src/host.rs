use crate::runtime::{Control, ExtensionServices};
use crate::storage::{StorageError, StoreKind};
use base64::Engine;
use base64::alphabet;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, STANDARD};
use hmac::{Hmac, KeyInit, Mac};
use md5::Md5;
use rquickjs::{Ctx, Function, Object};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::Duration;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<Object<'js>> {
    let host = Object::new(ctx.clone())?;
    crate::url_host::register(ctx, &host)?;
    crate::utility_host::register(ctx, &host, Arc::clone(&control), services)?;
    crate::legacy_host::register(ctx, &host, Arc::clone(&control), services)?;
    let item_control = Arc::clone(&control);
    host.set(
        "downloadItemActive",
        Function::new(ctx.clone(), move || !item_control.item_id().is_empty())?,
    )?;
    let status_control = Arc::clone(&control);
    let downloads = Arc::clone(&services.downloads);
    host.set(
        "downloadStatus",
        Function::new(ctx.clone(), move |status: String| {
            let id = status_control.item_id();
            if id.is_empty() {
                return;
            }
            let _ = match status.trim().to_lowercase().as_str() {
                "preparing" => downloads.progress.preparing(&id, ""),
                "downloading" => downloads.progress.downloading(&id),
                "finalizing" => downloads.progress.finalizing(&id),
                _ => Ok(()),
            };
        })?,
    )?;
    let resolution_control = Arc::clone(&control);
    host.set(
        "resolutionRemaining",
        Function::new(ctx.clone(), move || {
            resolution_control
                .resolution()
                .map_or(60_000, |budget| budget.remaining().as_millis() as u64)
        })?,
    )?;
    crate::crypto_host::register(ctx, &host, Arc::clone(&control))?;
    crate::file_host::register(ctx, &host, Arc::clone(&control), services)?;
    crate::ffmpeg_host::register(ctx, &host, Arc::clone(&control), services)?;
    crate::download_host::register(ctx, &host, Arc::clone(&control), services)?;
    crate::network_host::register(ctx, &host, Arc::clone(&control), services)?;
    crate::session_host::register(ctx, &host, Arc::clone(&control), services)?;
    host.set("authEnabled", services.auth.is_some())?;
    if let Some(auth) = &services.auth {
        let auth = Arc::clone(auth);
        let control = Arc::clone(&control);
        host.set(
            "authCall",
            Function::new(
                ctx.clone(),
                move |method: String, arguments: String, expires_is_float: bool| {
                    let arguments = zeroize::Zeroizing::new(arguments);
                    let result = serde_json::from_str::<Vec<serde_json::Value>>(&arguments)
                        .map_err(|error| error.to_string())
                        .and_then(|arguments| {
                            auth.call(&method, &arguments, expires_is_float, || {
                                control.check().map_err(|error| error.to_string())
                            })
                        });
                    match result {
                        Ok(value) => value,
                        Err(error) if method == "generatePKCE" => {
                            serde_json::json!({"error":error})
                        }
                        Err(error) => serde_json::json!({"success":false,"error":error}),
                    }
                    .to_string()
                },
            )?,
        )?;
    }
    host.set("storageEnabled", services.storage.is_some())?;
    if let Some(store) = &services.storage {
        let reader = Arc::clone(store);
        host.set(
            "storageRead",
            Function::new(ctx.clone(), move |credentials: bool, key: String| {
                let kind = if credentials {
                    StoreKind::Credentials
                } else {
                    StoreKind::Storage
                };
                match reader.get(kind, &key) {
                    Ok(Some(value)) => serde_json::json!({"found":true,"value":value}),
                    Ok(None) => serde_json::json!({"found":false}),
                    Err(error) => serde_json::json!({"error":error.to_string()}),
                }
                .to_string()
            })?,
        )?;
        let writer = Arc::clone(store);
        host.set(
            "storageWrite",
            Function::new(
                ctx.clone(),
                move |credentials: bool, key: String, value: String| {
                    let kind = if credentials {
                        StoreKind::Credentials
                    } else {
                        StoreKind::Storage
                    };
                    let result = serde_json::from_str(&value)
                        .map_err(StorageError::from)
                        .and_then(|value| writer.set(kind, &key, value));
                    storage_result(result)
                },
            )?,
        )?;
        let remover = Arc::clone(store);
        host.set(
            "storageRemove",
            Function::new(ctx.clone(), move |credentials: bool, key: String| {
                let kind = if credentials {
                    StoreKind::Credentials
                } else {
                    StoreKind::Storage
                };
                storage_result(remover.remove(kind, &key))
            })?,
        )?;
    }
    host.set(
        "encodeBytes",
        Function::new(ctx.clone(), |value: Vec<u8>| STANDARD.encode(value))?,
    )?;
    host.set(
        "base64Encode",
        Function::new(ctx.clone(), |value: String| STANDARD.encode(value))?,
    )?;
    host.set(
        "base64Decode",
        Function::new(ctx.clone(), |value: String, url_safe: bool| {
            // Go accepts nonzero padding bits and ignores CR/LF, but requires padding.
            let value = value.replace(['\r', '\n'], "");
            let config = GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true);
            let decoded = GeneralPurpose::new(&alphabet::STANDARD, config)
                .decode(&value)
                .or_else(|error| {
                    if url_safe {
                        GeneralPurpose::new(&alphabet::URL_SAFE, config).decode(&value)
                    } else {
                        Err(error)
                    }
                })
                .unwrap_or_default();
            decode_go_utf8_owned(decoded)
        })?,
    )?;
    host.set(
        "encode",
        Function::new(ctx.clone(), |value: String| value.into_bytes())?,
    )?;
    host.set("decode", Function::new(ctx.clone(), decode_go_utf8_owned)?)?;
    host.set(
        "md5",
        Function::new(ctx.clone(), |value: String| {
            crate::binary::encode(&Md5::digest(value), "hex").expect("hex encoding")
        })?,
    )?;
    host.set(
        "sha256",
        Function::new(ctx.clone(), |value: String| {
            crate::binary::encode(&Sha256::digest(value), "hex").expect("hex encoding")
        })?,
    )?;
    host.set(
        "hmacSHA256",
        Function::new(ctx.clone(), |message: String, key: String| {
            let mut mac = Hmac::<Sha256>::new_from_slice(key.as_bytes())
                .expect("HMAC accepts any key length");
            mac.update(message.as_bytes());
            crate::binary::encode(&mac.finalize().into_bytes(), "hex").expect("hex encoding")
        })?,
    )?;
    host.set(
        "hmacSHA256Base64",
        Function::new(ctx.clone(), |message: String, key: String| {
            let mut mac = Hmac::<Sha256>::new_from_slice(key.as_bytes())
                .expect("HMAC accepts any key length");
            mac.update(message.as_bytes());
            STANDARD.encode(mac.finalize().into_bytes())
        })?,
    )?;
    host.set(
        "hmacSHA1",
        Function::new(ctx.clone(), |key: Vec<u8>, message: Vec<u8>| {
            let mut mac = Hmac::<Sha1>::new_from_slice(&key).expect("HMAC accepts any key length");
            mac.update(&message);
            mac.finalize().into_bytes().to_vec()
        })?,
    )?;
    host.set(
        "quoteJSON",
        Function::new(ctx.clone(), |value: String| {
            // Go encoding/json escapes HTML and JS separators in strings.
            serde_json::to_string(&value)
                .expect("JSON string encoding")
                .replace('&', "\\u0026")
                .replace('<', "\\u003c")
                .replace('>', "\\u003e")
                .replace('\u{2028}', "\\u2028")
                .replace('\u{2029}', "\\u2029")
        })?,
    )?;
    host.set(
        "sortKeys",
        Function::new(ctx.clone(), |mut keys: Vec<String>| {
            // UTF-8/code-point ordering, rather than JS sort's UTF-16 ordering.
            keys.sort();
            keys
        })?,
    )?;
    let sleep_control = Arc::clone(&control);
    host.set(
        "sleep",
        Function::new(ctx.clone(), move |milliseconds: u64| {
            sleep_control.sleep(Duration::from_millis(milliseconds.min(300_000)))
        })?,
    )?;
    Ok(host)
}

fn storage_result(result: Result<(), StorageError>) -> String {
    match result {
        Ok(()) => serde_json::json!({"success":true}),
        Err(error) => serde_json::json!({"success":false,"error":error.to_string()}),
    }
    .to_string()
}

// Go's UTF-8 decoder consumes one byte for every invalid rune. Rust's lossy
// conversion groups some invalid prefixes, which would change extension text.
pub(crate) fn decode_go_utf8_owned(bytes: Vec<u8>) -> String {
    // Text responses/files already own their buffer. Reuse it for valid UTF-8
    // instead of holding a second full copy while QuickJS creates its string.
    match String::from_utf8(bytes) {
        Ok(text) => text,
        Err(error) => decode_go_utf8(error.as_bytes()),
    }
}

pub(crate) fn decode_go_utf8(mut bytes: &[u8]) -> String {
    let mut decoded = String::with_capacity(bytes.len());
    while !bytes.is_empty() {
        match std::str::from_utf8(bytes) {
            Ok(valid) => {
                decoded.push_str(valid);
                break;
            }
            Err(error) => {
                let prefix = error.valid_up_to();
                decoded
                    .push_str(std::str::from_utf8(&bytes[..prefix]).expect("valid UTF-8 prefix"));
                decoded.push('\u{fffd}');
                bytes = &bytes[prefix + 1..];
            }
        }
    }
    decoded
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "manual release-process peak-memory measurement"]
    fn benchmark_owned_text_memory() {
        let bytes = vec![b'x'; spotiflac_network::MAX_RESPONSE_BYTES];
        match std::env::var("SPOTIFLAC_TEXT_MEMORY_MODE").as_deref() {
            Ok("copy") => {
                let text = super::decode_go_utf8(&bytes);
                assert_eq!(text.len(), bytes.len());
                std::hint::black_box((&bytes, &text));
            }
            Ok("reuse") => {
                let pointer = bytes.as_ptr();
                let text = super::decode_go_utf8_owned(bytes);
                assert_eq!(text.as_ptr(), pointer);
                assert_eq!(text.len(), spotiflac_network::MAX_RESPONSE_BYTES);
                std::hint::black_box(&text);
            }
            _ => panic!("set SPOTIFLAC_TEXT_MEMORY_MODE to copy or reuse"),
        }
    }

    #[test]
    fn owned_text_reuses_large_buffers_and_preserves_invalid_byte_decoding() {
        let bytes = "Music 音楽 🎵\0".repeat(128 * 1024).into_bytes();
        let pointer = bytes.as_ptr();
        let capacity = bytes.capacity();
        let text = super::decode_go_utf8_owned(bytes);
        assert_eq!(text.as_ptr(), pointer);
        assert_eq!(text.capacity(), capacity);
        assert_eq!(text, "Music 音楽 🎵\0".repeat(128 * 1024));
        for bytes in [
            &b""[..],
            b"a\xffb",
            b"\xe2\x82",
            b"\xed\xa0\x80",
            b"\xf0\x9f\x8e\xb5\0\xff",
        ] {
            assert_eq!(
                super::decode_go_utf8_owned(bytes.to_vec()),
                super::decode_go_utf8(bytes),
            );
        }
        assert_eq!(
            super::decode_go_utf8_owned(vec![0xe2, 0x82]),
            "\u{fffd}\u{fffd}"
        );
    }

    #[test]
    fn digest_upgrade_preserves_extension_hash_and_hmac_encodings() {
        let runtime = crate::ExtensionRuntime::load(
            r#"registerExtension({run() { return [
                utils.md5('abc'), utils.sha256('abc'), utils.hmacSHA256('message', 'key')
            ]; }});"#,
            "{}",
            crate::RuntimeLimits::default(),
        )
        .unwrap();
        let result: serde_json::Value =
            serde_json::from_str(&runtime.call("run", "[]", None, 1000).unwrap()).unwrap();
        assert_eq!(
            result,
            serde_json::json!([
                "900150983cd24fb0d6963f7d28e17f72",
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a",
            ])
        );
        runtime.shutdown();
    }
}
