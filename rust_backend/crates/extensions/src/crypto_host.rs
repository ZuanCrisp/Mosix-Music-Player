use crate::{
    binary,
    crypto::{self, BlockCipher},
    host::decode_go_utf8,
    runtime::Control,
    storage,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use rquickjs::{ArrayBuffer, Ctx, Function, Object, Value};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use zeroize::Zeroizing;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
) -> rquickjs::Result<()> {
    let text_control = Arc::clone(&control);
    host.set(
        "cryptoText",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, decrypt: bool, data: String, key: String| {
                let data = Zeroizing::new(data);
                let key = Zeroizing::new(key);
                let key = Zeroizing::new(<[u8; 32]>::from(Sha256::digest(key.as_bytes())));
                let result = (|| {
                    text_control.check().map_err(|error| error.to_string())?;
                    let output = if decrypt {
                        let bytes = Zeroizing::new(
                            binary::decode_base64(&data)
                                .map_err(|_| "invalid base64 ciphertext".to_owned())?,
                        );
                        let plain = storage::decrypt(&bytes, &key)
                            .map_err(|_| "invalid base64 ciphertext".to_owned())?;
                        decode_go_utf8(&plain)
                    } else {
                        STANDARD.encode(
                            storage::encrypt(data.as_bytes(), &key)
                                .map_err(|error| error.to_string())?,
                        )
                    };
                    text_control.check().map_err(|error| error.to_string())?;
                    Ok(output)
                })();
                let object = result_object(&ctx, result.as_ref().err())?;
                if let Ok(data) = result {
                    object.set("data", data)?;
                }
                Ok::<_, rquickjs::Error>(object)
            },
        )?,
    )?;
    host.set(
        "generateKey",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, length: u32| {
            let result = (|| {
                if !(1..=4096).contains(&length) {
                    return Err("key length must be an integer between 1 and 4096 bytes".to_owned());
                }
                let mut bytes = Zeroizing::new(vec![0; length as usize]);
                getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
                Ok(bytes)
            })();
            let object = result_object(&ctx, result.as_ref().err())?;
            if let Ok(bytes) = result {
                object.set("key", STANDARD.encode(&*bytes))?;
                object.set("hex", binary::encode(&bytes, "hex").expect("hex encoding"))?;
            }
            Ok::<_, rquickjs::Error>(object)
        })?,
    )?;
    host.set(
        "blockTransform",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, operation: String, data: Value<'js>, options: Value<'js>| {
                let check = || control.check().map_err(|error| error.to_string());
                let result = if operation == "segments" {
                    segments(data, options, &check)
                } else {
                    block(data, options, operation == "decrypt", &check)
                };
                let object = result_object(&ctx, result.as_ref().err())?;
                if let Ok(result) = result {
                    object.set(result.count_name, result.count)?;
                    if result.raw {
                        // Charge retained output to QuickJS's heap; external Rust-owned
                        // ArrayBuffers would bypass the runtime's memory limit.
                        object.set("data", ArrayBuffer::new_copy(ctx.clone(), &*result.bytes)?)?;
                    } else {
                        match binary::encode(&result.bytes, &result.encoding) {
                            Ok(data) => object.set("data", data)?,
                            Err(error) => return result_object(&ctx, Some(&error)),
                        }
                    }
                }
                Ok(object)
            },
        )?,
    )?;
    Ok(())
}

fn result_object<'js>(ctx: &Ctx<'js>, error: Option<&String>) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("success", error.is_none())?;
    if let Some(error) = error {
        object.set("error", error.as_str())?;
    }
    Ok(object)
}

struct Output {
    bytes: Zeroizing<Vec<u8>>,
    encoding: String,
    raw: bool,
    count_name: &'static str,
    count: usize,
}

fn block(
    data: Value<'_>,
    options: Value<'_>,
    decrypt: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Output, String> {
    check()?;
    let options = options.as_object();
    let text = |key, fallback| binary::option_string(options, key, fallback);
    let algorithm = text("algorithm", "")?.to_lowercase();
    let mode = text("mode", "cbc")?.to_lowercase();
    let input_encoding = text("inputEncoding", "base64")?.to_lowercase();
    let encoding = text("outputEncoding", "base64")?.to_lowercase();
    let padding = text("padding", "none")?.to_lowercase();
    if algorithm.is_empty() {
        return Err("algorithm is required".into());
    }
    let key = Zeroizing::new(
        binary::decode_option_bytes(options, "key", &text("keyEncoding", "utf8")?)
            .map_err(|error| format!("invalid key: {error}"))?,
    );
    if key.is_empty() {
        return Err("key is required".into());
    }
    let iv = binary::decode_option_bytes(options, "iv", &text("ivEncoding", "utf8")?)
        .map_err(|error| format!("invalid iv: {error}"))?;
    if mode != "cbc" && mode != "ctr" {
        return Err(format!("unsupported block cipher mode: {mode}"));
    }
    let mut bytes = Zeroizing::new(binary::decode_value(data, &input_encoding)?);
    let cipher = BlockCipher::new(&algorithm, &key)?;
    let size = cipher.block_size();
    if iv.len() != size {
        return Err(format!(
            "{} must be {size} bytes for {algorithm}",
            if mode == "ctr" { "iv (counter)" } else { "iv" }
        ));
    }
    if mode == "cbc" && !decrypt && padding == "pkcs7" {
        crypto::pad(&mut bytes, size);
    }
    cipher.transform(&mut bytes, &iv, &mode, decrypt, check)?;
    if mode == "cbc" && decrypt && padding == "pkcs7" {
        crypto::unpad(&mut bytes, size)?;
    }
    Ok(Output {
        bytes,
        encoding,
        raw: false,
        count_name: "block_size",
        count: size,
    })
}

fn segments(
    data: Value<'_>,
    options: Value<'_>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Output, String> {
    check()?;
    let options = options.as_object().ok_or("options object is required")?;
    let text = |key, fallback| binary::option_string(Some(options), key, fallback);
    let algorithm = text("algorithm", "aes")?.to_lowercase();
    let input_encoding = text("inputEncoding", "base64")?.to_lowercase();
    let encoding = text("outputEncoding", "base64")?.to_lowercase();
    let iv_encoding = text("ivEncoding", "base64")?.to_lowercase();
    let key = Zeroizing::new(
        binary::decode_option_bytes(Some(options), "key", &text("keyEncoding", "hex")?)
            .map_err(|error| format!("invalid key: {error}"))?,
    );
    if key.is_empty() {
        return Err("key is required".into());
    }
    if algorithm != "aes" && algorithm != "blowfish" {
        return Err(format!("unsupported algorithm: {algorithm}"));
    }
    let cipher = BlockCipher::new(&algorithm, &key)?;
    let size = cipher.block_size();
    let raw_input = input_encoding == "bytes" || input_encoding == "raw";
    let mut bytes = Zeroizing::new(
        binary::decode_value(data, if raw_input { "" } else { &input_encoding }).map_err(
            |error| {
                if raw_input {
                    format!("invalid byte payload: {error}")
                } else {
                    error
                }
            },
        )?,
    );
    let segments: Value = options.get("segments").map_err(|error| error.to_string())?;
    if segments.is_null() || segments.is_undefined() {
        return Err("segments array is required".into());
    }
    let segments = segments.as_array().ok_or("segments must be an array")?;
    let mut count = 0;
    for (index, segment) in segments.iter::<Value>().enumerate() {
        check()?;
        let segment = segment.map_err(|error| error.to_string())?;
        let segment = segment
            .as_object()
            .ok_or_else(|| format!("segment {index} is not an object"))?;
        let offset = binary::option_i64(segment, "offset", -1)?;
        let length = binary::option_i64(segment, "size", -1)?;
        if offset < 0 || length < 0 {
            return Err(format!("segment {index} has invalid offset/size"));
        }
        if length == 0 {
            continue;
        }
        let offset = offset as u64;
        let length = length as u64;
        if offset
            .checked_add(length)
            .is_none_or(|end| end > bytes.len() as u64)
        {
            return Err(format!(
                "segment {index} out of bounds (offset={offset} size={length} len={})",
                bytes.len()
            ));
        }
        let mut iv = binary::decode_option_bytes(Some(segment), "iv", &iv_encoding)
            .map_err(|error| format!("segment {index} has invalid iv: {error}"))?;
        if iv.len() > size {
            return Err(format!(
                "segment {index} iv longer than block size ({} > {size})",
                iv.len()
            ));
        }
        iv.resize(size, 0);
        cipher.transform(
            &mut bytes[offset as usize..(offset + length) as usize],
            &iv,
            "ctr",
            true,
            check,
        )?;
        count += 1;
    }
    Ok(Output {
        bytes,
        raw: encoding == "bytes" || encoding == "raw",
        encoding,
        count_name: "segments_processed",
        count,
    })
}
