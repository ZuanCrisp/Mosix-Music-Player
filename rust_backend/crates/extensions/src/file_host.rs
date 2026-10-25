use crate::binary;
use crate::files::{ExtensionFiles, MAX_READ, READ_LIMIT_ERROR};
use crate::runtime::{Control, ExtensionServices};
use cap_std::fs::OpenOptions;
use rquickjs::{ArrayBuffer, Ctx, Function, Object, Value};
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    host.set("filesEnabled", services.files.is_some())?;
    let Some(files) = &services.files else {
        return Ok(());
    };
    let files = Arc::clone(files);
    host.set(
        "fileCall",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  method: String,
                  path: String,
                  data: Value<'js>,
                  options: Value<'js>,
                  callback: Value<'js>| {
                let check = || control.check().map_err(|error| error.to_string());
                let result = call(
                    &ctx, &files, &method, &path, data, options, callback, &check,
                );
                if method == "exists" {
                    return Ok::<_, rquickjs::Error>(Value::new_bool(ctx, result.is_ok()));
                }
                match result {
                    Ok(object) => Ok(object.into_value()),
                    Err(error) => {
                        let object = Object::new(ctx)?;
                        object.set("success", false)?;
                        object.set("error", error)?;
                        Ok(object.into_value())
                    }
                }
            },
        )?,
    )?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn call<'js>(
    ctx: &Ctx<'js>,
    files: &ExtensionFiles,
    method: &str,
    path: &str,
    data: Value<'js>,
    options: Value<'js>,
    callback: Value<'js>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Object<'js>, String> {
    check()?;
    let path = files.resolve(path)?;
    let options = Options(options.as_object());
    let result = Object::new(ctx.clone()).map_err(js_error)?;
    result.set("success", true).map_err(js_error)?;
    match method {
        "exists" | "getSize" => {
            let info = path.metadata().map_err(io_error)?;
            if method == "getSize" {
                result.set("size", info.len()).map_err(js_error)?;
            }
        }
        "delete" => {
            let _guard = files.lock(&path, check)?;
            path.remove().map_err(io_error)?;
        }
        "read" | "readBytes" => {
            let offset = if method == "read" {
                0
            } else {
                options.int("offset", 0)?
            };
            let requested = options.int("length", -1)?;
            let encoding = options.text("encoding", "base64")?;
            if offset < 0 {
                return Err("offset must be >= 0".into());
            }
            let mut input = path.open(OpenOptions::new().read(true)).map_err(io_error)?;
            let size = input.metadata().map_err(io_error)?.len();
            let offset = (offset as u64).min(size);
            let mut bytes;
            if method == "read" {
                bytes = Vec::new();
                let mut buffer = [0; 64 << 10];
                while bytes.len() <= MAX_READ {
                    check()?;
                    let capacity = buffer.len().min(MAX_READ + 1 - bytes.len());
                    let count = input.read(&mut buffer[..capacity]).map_err(io_error)?;
                    if count == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buffer[..count]);
                }
                if bytes.len() > MAX_READ {
                    return Err(READ_LIMIT_ERROR.into());
                }
                result
                    .set("data", crate::host::decode_go_utf8_owned(bytes))
                    .map_err(js_error)?;
            } else {
                input
                    .seek(SeekFrom::Start(offset))
                    .map_err(|error| format!("failed to seek file: {error}"))?;
                let length = if requested < 0 {
                    size - offset
                } else {
                    requested as u64
                };
                if length > MAX_READ as u64 {
                    return Err(READ_LIMIT_ERROR.into());
                }
                bytes = vec![0; length.min(size - offset) as usize];
                let count = read_chunk(&mut input, &mut bytes, check)
                    .map_err(|error| format!("failed to read file: {error}"))?;
                bytes.truncate(count);
                if matches!(encoding.trim().to_lowercase().as_str(), "bytes" | "raw") {
                    result
                        .set(
                            "data",
                            ArrayBuffer::new_copy(ctx.clone(), &bytes).map_err(js_error)?,
                        )
                        .map_err(js_error)?;
                } else {
                    result
                        .set("data", binary::encode(&bytes, &encoding)?)
                        .map_err(js_error)?;
                }
                result.set("bytes_read", bytes.len()).map_err(js_error)?;
                result.set("offset", offset).map_err(js_error)?;
                result.set("size", size).map_err(js_error)?;
                result
                    .set("eof", offset + bytes.len() as u64 >= size)
                    .map_err(js_error)?;
            }
        }
        "write" | "writeBytes" => {
            let append = options.boolean("append", false)?;
            let truncate = options.boolean("truncate", false)?;
            let has_offset = options
                .0
                .map(|object| object.contains_key("offset"))
                .transpose()
                .map_err(js_error)?
                .unwrap_or(false);
            let offset = options.int("offset", 0)?;
            if append && has_offset {
                return Err("append and offset cannot be used together".into());
            }
            if offset < 0 {
                return Err("offset must be >= 0".into());
            }
            let encoding = if method == "write" {
                "utf8".into()
            } else {
                options.text("encoding", "base64")?
            };
            let bytes = binary::decode_value(data, &encoding)?;
            let _guard = files.lock(&path, check)?;
            path.mkdir_parent()
                .map_err(|error| format!("failed to create directory: {error}"))?;
            if method == "write" {
                let mut output = path.stage().map_err(io_error)?;
                write_chunks(&mut output.file, &bytes, check)?;
                output.publish(check)?;
            } else {
                let mut output = path
                    .open(
                        OpenOptions::new()
                            .create(true)
                            .write(true)
                            .append(append)
                            .truncate(truncate),
                    )
                    .map_err(io_error)?;
                if has_offset {
                    output
                        .seek(SeekFrom::Start(offset as u64))
                        .map_err(|error| format!("failed to seek file: {error}"))?;
                }
                write_chunks(&mut output, &bytes, check)?;
                result.set("bytes_written", bytes.len()).map_err(js_error)?;
                result
                    .set("size", output.metadata().map_err(io_error)?.len())
                    .map_err(js_error)?;
            }
            result.set("path", path.display()).map_err(js_error)?;
        }
        "copy" | "move" | "transformPatternedBlocks" => {
            let destination = data
                .as_string()
                .ok_or("destination path is required")?
                .to_string()
                .map_err(js_error)?;
            let destination = files.resolve(&destination)?;
            if method == "transformPatternedBlocks" {
                return crate::file_transform::transform(
                    ctx,
                    files,
                    &path,
                    &destination,
                    options,
                    callback,
                    check,
                );
            }
            let _guard = files.lock(&destination, check)?;
            if method == "move" {
                destination
                    .mkdir_parent()
                    .map_err(|error| format!("failed to create directory: {error}"))?;
                check()?;
                path.rename_to(&destination)
                    .map_err(|error| format!("failed to move file: {error}"))?;
            } else {
                let mut input = path
                    .open(OpenOptions::new().read(true))
                    .map_err(|error| format!("failed to read source: {error}"))?;
                destination
                    .mkdir_parent()
                    .map_err(|error| format!("failed to create directory: {error}"))?;
                let mut output = destination
                    .open(OpenOptions::new().write(true).create(true).truncate(true))
                    .map_err(|error| format!("failed to open destination: {error}"))?;
                let mut buffer = [0; 64 << 10];
                loop {
                    let count = read_chunk(&mut input, &mut buffer, check)
                        .map_err(|error| format!("failed to copy file: {error}"))?;
                    if count == 0 {
                        break;
                    }
                    write_chunks(&mut output, &buffer[..count], check)
                        .map_err(|error| format!("failed to copy file: {error}"))?;
                }
            }
            result
                .set("path", destination.display())
                .map_err(js_error)?;
        }
        _ => return Err("unknown file operation".into()),
    }
    check()?;
    Ok(result)
}

pub(crate) struct Options<'a, 'js>(pub Option<&'a Object<'js>>);

impl Options<'_, '_> {
    pub fn text(&self, key: &str, fallback: &str) -> Result<String, String> {
        binary::option_string(self.0, key, fallback)
    }
    pub fn int(&self, key: &str, fallback: i64) -> Result<i64, String> {
        self.0.map_or(Ok(fallback), |object| {
            binary::option_i64(object, key, fallback)
        })
    }
    pub fn boolean(&self, key: &str, fallback: bool) -> Result<bool, String> {
        self.0.map_or(Ok(fallback), |object| {
            binary::option_bool(object, key, fallback)
        })
    }
}

pub(crate) fn read_chunk(
    input: &mut impl Read,
    buffer: &mut [u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<usize, String> {
    let mut total = 0;
    while total < buffer.len() {
        check()?;
        let end = buffer.len().min(total + (64 << 10));
        match input.read(&mut buffer[total..end]) {
            Ok(0) => break,
            Ok(count) => total += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(total)
}

pub(crate) fn write_chunks(
    output: &mut impl Write,
    bytes: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    for chunk in bytes.chunks(64 << 10) {
        check()?;
        output.write_all(chunk).map_err(io_error)?;
    }
    check()
}

pub(crate) fn js_error(error: rquickjs::Error) -> String {
    error.to_string()
}
fn io_error(error: std::io::Error) -> String {
    error.to_string()
}
