use crate::files::ExtensionFiles;
use crate::runtime::{Control, ExtensionServices};
use cap_std::fs::OpenOptions;
use rquickjs::{Ctx, Function, Object, Value};
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    host.set("rawFfmpegStub", services.raw_ffmpeg_stub)?;
    let Some(files) = &services.files else {
        return Ok(());
    };
    let info_files = Arc::clone(files);
    let info_control = Arc::clone(&control);
    host.set(
        "mediaInfo",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, path: String| {
            let check = || info_control.check().map_err(|e| e.to_string());
            let result = media_info(&info_files, &path, &check);
            let object = Object::new(ctx.clone())?;
            match result {
                Ok(quality) => {
                    object.set("success", true)?;
                    object.set("bit_depth", quality.bit_depth)?;
                    object.set("sample_rate", quality.sample_rate)?;
                    object.set("total_samples", quality.total_samples)?;
                    object.set(
                        "duration",
                        quality.total_samples as f64 / quality.sample_rate as f64,
                    )?;
                    object.set("codec", quality.codec)?;
                }
                Err(error) => {
                    object.set("success", false)?;
                    object.set("error", error)?;
                }
            }
            Ok::<_, rquickjs::Error>(object)
        })?,
    )?;
    let files = Arc::clone(files);
    let registry = Arc::clone(&services.ffmpeg);
    let id = services.extension_id.clone();
    host.set(
        "mediaConvert",
        Function::new(
            ctx.clone(),
            move |input: String, output: String, options: Value<'js>| {
                let result = (|| {
                    let input = files
                        .resolve(&input)
                        .and_then(|path| path.native_display())
                        .map_err(|e| format!("invalid input path: {e}"))?;
                    let output = files
                        .resolve(&output)
                        .and_then(|path| path.native_display())
                        .map_err(|e| format!("invalid output path: {e}"))?;
                    let arguments = conversion_arguments(&input, &output, options.as_object())?;
                    let budget = control.resolution();
                    let _pause = budget.as_ref().map(|budget| budget.enter(false));
                    registry.execute(&id, arguments, input, output, &control)
                })();
                match result {
                    Ok(result) => serde_json::to_string(&result).expect("FFmpeg result JSON"),
                    Err(error) => serde_json::json!({"success":false,"error":error}).to_string(),
                }
            },
        )?,
    )?;
    Ok(())
}

fn media_info(
    files: &ExtensionFiles,
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<spotiflac_core::media::AudioQuality, String> {
    let path = files.resolve(path)?;
    let mut file = path
        .open(OpenOptions::new().read(true))
        .map_err(|e| format!("failed to open file: {e}"))?;
    spotiflac_core::media::probe_quality(&mut file, check)
}

fn conversion_arguments(
    input: &str,
    output: &str,
    options: Option<&Object<'_>>,
) -> Result<Vec<String>, String> {
    let mut arguments = vec![
        "-hide_banner".into(),
        "-nostdin".into(),
        "-i".into(),
        input.into(),
    ];
    if let Some(options) = options {
        for (key, flag) in [("codec", "-c:a"), ("bitrate", "-b:a")] {
            let value: Value = options.get(key).map_err(|e| e.to_string())?;
            if let Some(value) = value.as_string() {
                let value = value.to_string().map_err(|e| e.to_string())?;
                if key == "codec" {
                    if !matches!(
                        value.as_str(),
                        "aac"
                            | "alac"
                            | "copy"
                            | "flac"
                            | "libmp3lame"
                            | "libopus"
                            | "opus"
                            | "pcm_s16le"
                            | "pcm_s24le"
                    ) {
                        return Err("unsupported audio codec".into());
                    }
                } else {
                    let digits = value.strip_suffix(['k', 'K', 'm', 'M']).unwrap_or(&value);
                    if digits.is_empty()
                        || digits.len() > 8
                        || digits.starts_with('0')
                        || !digits.bytes().all(|byte| byte.is_ascii_digit())
                    {
                        return Err("invalid audio bitrate".into());
                    }
                }
                arguments.extend([flag.into(), value]);
            }
        }
        for (key, message) in [
            ("sample_rate", "invalid sample rate"),
            ("channels", "invalid channel count"),
        ] {
            let value: Value = options.get(key).map_err(|e| e.to_string())?;
            if let Some(value) = value.as_number() {
                // Goja exports integral JS Numbers as int64; the old host only
                // accepts float64 here. Preserve its ignored integer options.
                // Every remaining float is fractional, non-finite, or outside
                // Goja's integer range, and fails the host's range/integer check.
                if !value.is_finite()
                    || value.fract() != 0.0
                    || (value == 0.0 && value.is_sign_negative())
                    || !(-9_007_199_254_740_992.0..=9_007_199_254_740_992.0).contains(&value)
                {
                    return Err(message.into());
                }
            }
        }
    }
    arguments.extend(["-y".into(), output.into()]);
    Ok(arguments)
}
