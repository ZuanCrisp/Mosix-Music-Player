use crate::binary;
use crate::crypto::BlockCipher;
use crate::file_host::{Options, js_error, read_chunk, write_chunks};
use crate::files::{ExtensionFiles, FilePath, MAX_READ};
use cap_std::fs::OpenOptions;
use rquickjs::{Coerced, Ctx, FromJs, Object, Value};
use zeroize::Zeroizing;

#[allow(clippy::too_many_arguments)]
pub(crate) fn transform<'js>(
    ctx: &Ctx<'js>,
    files: &ExtensionFiles,
    input: &FilePath,
    output: &FilePath,
    options: Options<'_, 'js>,
    callback: Value<'js>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Object<'js>, String> {
    let algorithm = options.text("algorithm", "")?.to_lowercase();
    let mode = options.text("mode", "cbc")?.to_lowercase();
    let padding = options.text("padding", "none")?.to_lowercase();
    if algorithm.is_empty() {
        return Err("algorithm is required".into());
    }
    let key = Zeroizing::new(
        binary::decode_option_bytes(options.0, "key", &options.text("keyEncoding", "utf8")?)
            .map_err(|error| format!("invalid key: {error}"))?,
    );
    if key.is_empty() {
        return Err("key is required".into());
    }
    let iv = binary::decode_option_bytes(options.0, "iv", &options.text("ivEncoding", "utf8")?)
        .map_err(|error| format!("invalid iv: {error}"))?;
    if mode != "cbc" && mode != "ctr" {
        return Err(format!("unsupported block cipher mode: {mode}"));
    }
    if padding != "none" {
        return Err("patterned file transforms only support padding: none".into());
    }
    let operation = options.text("operation", "decrypt")?.to_lowercase();
    if operation != "decrypt" && operation != "encrypt" {
        return Err("operation must be decrypt or encrypt".into());
    }
    let segment_size = options.int("segmentSize", 0)?;
    let every = options.int("transformEvery", 1)?;
    let offset = options.int("transformOffset", 0)?;
    let buffer_size = options.int("bufferSize", 1 << 20)?;
    let partial = options.boolean("transformPartial", false)?;
    if !(1..=MAX_READ as i64).contains(&segment_size) {
        return Err(format!(
            "segmentSize must be between 1 and {MAX_READ} bytes"
        ));
    }
    if every <= 0 {
        return Err("transformEvery must be greater than zero".into());
    }
    if offset < 0 || offset >= every {
        return Err("transformOffset must be between 0 and transformEvery - 1".into());
    }
    let buffer_size = buffer_size.clamp(segment_size, MAX_READ as i64);
    let buffer_size = (buffer_size - buffer_size % segment_size) as usize;
    let cipher = BlockCipher::new(&algorithm, &key)?;
    let block_size = cipher.block_size();
    if iv.len() != block_size {
        return Err(format!("iv must be {block_size} bytes for {algorithm}"));
    }
    if mode == "cbc" && segment_size % block_size as i64 != 0 {
        return Err(format!(
            "segmentSize must be a multiple of {block_size} bytes for CBC"
        ));
    }
    let callback = if callback.is_null() || callback.is_undefined() {
        None
    } else {
        Some(
            callback
                .as_function()
                .ok_or("progress callback must be a function")?,
        )
    };
    let _guard = files.lock(output, check)?;
    let mut source = input
        .open(OpenOptions::new().read(true))
        .map_err(|error| format!("failed to open input file: {error}"))?;
    let total = source
        .metadata()
        .map_err(|error| format!("failed to stat input file: {error}"))?
        .len();
    // Keep the legacy collision check although randomized staging no longer
    // risks clobbering a caller's existing .transform.partial file.
    if input.display() == format!("{}.transform.partial", output.display()) {
        return Err("input path conflicts with transform staging path".into());
    }
    output
        .mkdir_parent()
        .map_err(|error| format!("failed to create output directory: {error}"))?;
    let mut staged = output
        .stage()
        .map_err(|error| format!("failed to create staged output: {error}"))?;
    let mut buffer = Zeroizing::new(vec![0; buffer_size]);
    let (mut processed, mut index, mut transformed) = (0_u64, 0_u64, 0_u64);
    loop {
        let count = read_chunk(&mut source, &mut buffer, check)
            .map_err(|error| format!("failed to read input file: {error}"))?;
        if count == 0 {
            break;
        }
        for segment in buffer[..count].chunks_mut(segment_size as usize) {
            check()?;
            if index % every as u64 == offset as u64
                && (segment.len() == segment_size as usize || partial)
            {
                if mode == "cbc" && segment.len() % block_size != 0 {
                    return Err(format!(
                        "selected segment {index} is not a multiple of {block_size} bytes"
                    ));
                }
                // Each selected segment restarts its IV/counter, matching Go.
                cipher.transform(segment, &iv, &mode, operation == "decrypt", check)?;
                transformed += 1;
            }
            index += 1;
        }
        write_chunks(&mut staged.file, &buffer[..count], check)
            .map_err(|error| format!("failed to write transformed file: {error}"))?;
        processed += count as u64;
        if let Some(callback) = callback
            && let Err(error) = callback.call::<_, ()>((processed, total))
        {
            let message = if error.is_exception() {
                let exception = ctx.catch();
                match Coerced::<String>::from_js(ctx, exception) {
                    Ok(message) => message.0,
                    Err(_) => {
                        ctx.catch();
                        "JavaScript exception".into()
                    }
                }
            } else {
                error.to_string()
            };
            return Err(format!("progress callback failed: {message}"));
        }
        check()?;
    }
    drop(source);
    staged
        .publish(check)
        .map_err(|error| format!("failed to publish transformed file: {error}"))?;
    let result = Object::new(ctx.clone()).map_err(js_error)?;
    result.set("success", true).map_err(js_error)?;
    result.set("path", output.display()).map_err(js_error)?;
    result.set("bytes_processed", processed).map_err(js_error)?;
    result.set("segments_processed", index).map_err(js_error)?;
    result
        .set("segments_transformed", transformed)
        .map_err(js_error)?;
    Ok(result)
}
