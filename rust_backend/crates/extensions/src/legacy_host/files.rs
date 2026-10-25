use crate::runtime::{Control, ExtensionServices};
use cap_std::fs::OpenOptions;
use rquickjs::{Ctx, Function, Object};
use serde_json::json;
use std::sync::Arc;

pub(super) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    let files = services
        .legacy_files
        .clone()
        .or_else(|| services.files.clone());
    let quality_files = files.clone();
    let quality_control = Arc::clone(&control);
    host.set(
        "legacyQuality",
        Function::new(ctx.clone(), move |path: String| {
            let check = || quality_control.check().map_err(|error| error.to_string());
            let result = (|| {
                check()?;
                let files = quality_files.as_ref().ok_or("file access unavailable")?;
                let path = files.resolve_legacy(&path)?;
                let mut file = path
                    .open(OpenOptions::new().read(true))
                    .map_err(|error| format!("failed to open file: {error}"))?;
                spotiflac_core::media::probe_quality(&mut file, &check)
            })();
            match result {
                Ok(quality) => json!({
                    "bitDepth":quality.bit_depth,"sampleRate":quality.sample_rate,
                    "totalSamples":quality.total_samples,"duration":quality.duration,
                    "codec":quality.codec
                }),
                Err(error) => json!({"error":error}),
            }
            .to_string()
        })?,
    )?;
    let cache = Arc::clone(&services.isrc);
    host.set(
        "legacyIsrc",
        Function::new(
            ctx.clone(),
            move |add: bool, directory: String, isrc: String, path: String| {
                let check = || control.check().map_err(|error| error.to_string());
                let (directory, isrc, path) = (directory.trim(), isrc.trim(), path.trim());
                let result = (|| {
                    if directory.is_empty() || isrc.is_empty() || (add && path.is_empty()) {
                        return Err(if add {
                            "outputDir, isrc, and filePath are required"
                        } else {
                            "outputDir and isrc are required"
                        }
                        .to_owned());
                    }
                    check()?;
                    let files = files.as_ref().ok_or("file access unavailable")?;
                    let directory = files.resolve_legacy(directory)?.display();
                    if add {
                        let path = files.resolve_legacy(path)?.display();
                        cache.add(&directory, isrc, &path, files.as_ref(), &check)?;
                        Ok(json!({"success":true}))
                    } else {
                        let path = cache.check(&directory, isrc, files.as_ref(), &check)?;
                        Ok(json!({"exists":!path.is_empty(),"filePath":path}))
                    }
                })();
                result
                    .unwrap_or_else(|error| json!({"error":error}))
                    .to_string()
            },
        )?,
    )?;
    Ok(())
}
