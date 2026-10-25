use crate::runtime::{Control, ExtensionServices};
use rquickjs::{Ctx, Exception, Function, Object};
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    host.set("legacyBackend", services.legacy_backend)?;
    if !services.legacy_backend {
        return Ok(());
    }
    files::register(ctx, host, Arc::clone(&control), services)?;
    lyrics::register(ctx, host, Arc::clone(&control), services)?;
    host.set(
        "legacySanitize",
        Function::new(ctx.clone(), |value: String| {
            spotiflac_core::filename::sanitize_filename(&value)
        })?,
    )?;
    host.set(
        "legacyFilename",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, template: String, metadata: String| {
                let check = || control.check().map_err(|error| error.to_string());
                let result = serde_json::from_str(&metadata)
                    .map_err(|error| error.to_string())
                    .and_then(|metadata| {
                        spotiflac_core::filename::build_filename_checked(
                            &template,
                            &metadata,
                            8 * 1024 * 1024,
                            &check,
                        )
                    });
                result.map_err(|error| Exception::throw_message(&ctx, &error))
            },
        )?,
    )?;
    host.set(
        "legacyLocalTime",
        Function::new(ctx.clone(), || {
            serde_json::to_string(&spotiflac_core::clock::local_time()).expect("local time JSON")
        })?,
    )?;
    Ok(())
}
mod files;
mod lyrics;
