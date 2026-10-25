use crate::host::decode_go_utf8;
use base64::{
    Engine, alphabet,
    engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, STANDARD},
};
use rquickjs::{Object, TypedArray, Value};

pub(crate) fn option_string(
    options: Option<&Object<'_>>,
    key: &str,
    fallback: &str,
) -> Result<String, String> {
    let Some(options) = options else {
        return Ok(fallback.into());
    };
    let value: Value = options.get(key).map_err(|error| error.to_string())?;
    if let Some(value) = value.as_string() {
        let value = value.to_string().map_err(|error| error.to_string())?;
        if !value.trim().is_empty() {
            return Ok(value.trim().into());
        }
    } else if let Ok(value) = TypedArray::<u8>::from_value(value) {
        let bytes = copy_typed(&value);
        if !bytes.is_empty() {
            return Ok(decode_go_utf8(&bytes));
        }
    }
    Ok(fallback.into())
}

pub(crate) fn option_i64(options: &Object<'_>, key: &str, fallback: i64) -> Result<i64, String> {
    let value: Value = options.get(key).map_err(|error| error.to_string())?;
    if let Some(number) = value.as_number() {
        return Ok(go_float_i64(number));
    }
    if let Some(value) = value.as_string() {
        let value = value.to_string().map_err(|error| error.to_string())?;
        let value = value.trim();
        let prefix: String = value
            .chars()
            .enumerate()
            .take_while(|(index, ch)| {
                ch.is_ascii_digit() || (*index == 0 && (*ch == '+' || *ch == '-'))
            })
            .map(|(_, ch)| ch)
            .collect();
        return Ok(prefix.parse().unwrap_or(fallback));
    }
    Ok(fallback)
}

pub(crate) fn option_bool(options: &Object<'_>, key: &str, fallback: bool) -> Result<bool, String> {
    let value: Value = options.get(key).map_err(|error| error.to_string())?;
    if let Some(value) = value.as_bool() {
        return Ok(value);
    }
    if let Some(value) = value.as_number() {
        return Ok(value != 0.0);
    }
    if let Some(value) = value.as_string() {
        return Ok(
            match value
                .to_string()
                .map_err(|error| error.to_string())?
                .trim()
                .to_lowercase()
                .as_str()
            {
                "1" | "true" | "yes" | "on" => true,
                "0" | "false" | "no" | "off" => false,
                _ => fallback,
            },
        );
    }
    Ok(fallback)
}

pub(crate) fn decode_string(value: &str, encoding: &str) -> Result<Vec<u8>, String> {
    match encoding.trim().to_lowercase().as_str() {
        "" | "utf8" | "utf-8" | "text" => Ok(value.as_bytes().to_vec()),
        "base64" => {
            decode_base64(value.trim()).map_err(|error| format!("invalid base64 data: {error}"))
        }
        "hex" => {
            let value = value.trim().as_bytes();
            let mut bytes = Vec::with_capacity(value.len() / 2);
            let digit = |byte: u8| {
                (byte as char)
                    .to_digit(16)
                    .map(|value| value as u8)
                    .ok_or_else(|| format!("invalid hex data: invalid byte 0x{byte:02x}"))
            };
            for pair in value.chunks(2) {
                let first = digit(pair[0])?;
                if pair.len() < 2 {
                    return Err("invalid hex data: encoding/hex: odd length hex string".into());
                }
                bytes.push(first * 16 + digit(pair[1])?);
            }
            Ok(bytes)
        }
        _ => Err(format!("unsupported byte encoding: {encoding}")),
    }
}

pub(crate) fn decode_base64(value: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let engine = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
    );
    if value.contains(['\r', '\n']) {
        engine.decode(value.replace(['\r', '\n'], ""))
    } else {
        engine.decode(value)
    }
}

pub(crate) fn decode_option_bytes(
    options: Option<&Object<'_>>,
    key: &str,
    encoding: &str,
) -> Result<Vec<u8>, String> {
    if let Some(options) = options {
        let value: Value = options.get(key).map_err(|error| error.to_string())?;
        if let Ok(value) = TypedArray::<u8>::from_value(value) {
            // runtimeOptionString converts []byte to a Go string without UTF-8
            // replacement or trimming. Preserve arbitrary binary keys and IVs.
            if matches!(
                encoding.trim().to_lowercase().as_str(),
                "" | "utf8" | "utf-8" | "text"
            ) {
                return Ok(copy_typed(&value));
            }
        }
    }
    decode_string(&option_string(options, key, "")?, encoding)
}

pub(crate) fn encode(bytes: &[u8], encoding: &str) -> Result<String, String> {
    match encoding.trim().to_lowercase().as_str() {
        "" | "base64" => Ok(STANDARD.encode(bytes)),
        "hex" => {
            use std::fmt::Write;
            let mut value = String::with_capacity(bytes.len() * 2);
            for byte in bytes {
                let _ = write!(value, "{byte:02x}");
            }
            Ok(value)
        }
        "utf8" | "utf-8" | "text" => Ok(decode_go_utf8(bytes)),
        _ => Err(format!("unsupported byte encoding: {encoding}")),
    }
}

pub(crate) fn decode_value(value: Value<'_>, encoding: &str) -> Result<Vec<u8>, String> {
    if let Some(text) = value.as_string() {
        return decode_string(
            &text.to_string().map_err(|error| error.to_string())?,
            encoding,
        );
    }
    if let Ok(bytes) = TypedArray::<u8>::from_value(value.clone()) {
        return Ok(copy_typed(&bytes));
    }
    if let Some(array) = value.as_array() {
        return array
            .iter::<Value>()
            .enumerate()
            .map(|(index, item)| {
                let value = item.map_err(|error| error.to_string())?;
                let number = value
                    .as_number()
                    .ok_or_else(|| format!("unsupported byte array item at index {index}"))?;
                // Goja exports integral values within int64 as int64. Other
                // numbers use Go's float64 -> native int conversion first.
                if number.fract() == 0.0
                    && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&number)
                {
                    return Ok(number as i64 as u8);
                }
                #[cfg(any(target_arch = "aarch64", target_arch = "arm"))]
                return Ok(number as isize as u8);
                #[cfg(not(any(target_arch = "aarch64", target_arch = "arm")))]
                Ok(go_float_i64(number) as u8)
            })
            .collect();
    }
    Err("unsupported byte payload type".into())
}

#[allow(unsafe_code)]
fn copy_typed(bytes: &TypedArray<'_, u8>) -> Vec<u8> {
    // SAFETY: only this worker can access the VM. Finish the owned copy before
    // any engine call, getter, callback, or operation that can detach a buffer.
    unsafe { bytes.as_bytes() }.unwrap_or_default().to_vec()
}

fn go_float_i64(number: f64) -> i64 {
    #[cfg(target_arch = "aarch64")]
    return number as i64;
    #[cfg(target_arch = "arm")]
    {
        // Go ARM32 uses runtime._d2v for int64 conversions, while byte-array
        // conversion above uses the hardware's native int32 instruction.
        let bits = number.to_bits();
        let shift = ((bits >> 52) & 0x7ff) as i32 - 1075;
        let mantissa = (bits & ((1_u64 << 52) - 1)) | (1_u64 << 52);
        let magnitude = if shift < -63 {
            0
        } else if shift < 0 {
            mantissa >> -shift
        } else if shift <= 11 {
            mantissa << shift
        } else {
            u64::from(number as u32) << 32
        };
        return if number.is_sign_negative() {
            magnitude.wrapping_neg() as i64
        } else {
            magnitude as i64
        };
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "arm")))]
    if number.is_finite()
        && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&number)
    {
        number as i64
    } else {
        i64::MIN
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_preserves_newlines_trailing_bits_and_error_offsets() {
        let engine = GeneralPurpose::new(
            &alphabet::STANDARD,
            GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
        );
        for value in [
            "",
            "Zg==",
            "Zh==",
            "Zm8=",
            "Zm9=",
            "Zm9v",
            "\r\nZ\rg==\n",
            "\r\n",
            "Zg=",
            "Zg===",
            "Zg==!",
            "Zg==\n!",
            "Z g==",
            "Zg==\t",
            "🎵",
            "\n🎵",
        ] {
            assert_eq!(
                decode_base64(value),
                engine.decode(value.replace(['\r', '\n'], "")),
                "{value:?}"
            );
        }
        let bytes: Vec<_> = (0..=255).cycle().take(1024 * 1024).collect();
        let encoded = STANDARD.encode(&bytes);
        assert_eq!(decode_base64(&encoded).unwrap(), bytes);
        let wrapped = encoded
            .as_bytes()
            .chunks(76)
            .map(|line| std::str::from_utf8(line).unwrap())
            .collect::<Vec<_>>()
            .join("\r\n");
        assert_eq!(decode_base64(&wrapped).unwrap(), bytes);
    }
}
