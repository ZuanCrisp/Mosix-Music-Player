use crate::runtime::{Control, ExtensionServices};
use rquickjs::{Ctx, Function, Object, Value};
use spotiflac_core::matching;
pub(crate) use spotiflac_network::random_user_agent;
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    let logs = Arc::clone(&services.logs);
    let id = services.extension_id.clone();
    host.set(
        "managedConsole",
        services.load_mode != crate::runtime::LoadMode::Initialize,
    )?;
    let auth = services.auth_registry.clone();
    let provider_id = services.extension_id.clone();
    host.set(
        "providerPendingVerification",
        Function::new(ctx.clone(), move || {
            auth.as_ref()
                .filter(|auth| auth.has_fresh_challenge(&provider_id))
                .map(|_| provider_id.clone())
        })?,
    )?;
    let progress = Arc::clone(&services.downloads.progress);
    let progress_control = Arc::clone(&control);
    host.set(
        "providerProgress",
        Function::new(ctx.clone(), move |percent: i32| {
            let id = progress_control.item_id();
            if !id.is_empty() && progress_control.check().is_ok() {
                let _ = progress.set_progress(&id, f64::from(percent) / 100.0, 0, 0);
            }
        })?,
    )?;
    host.set(
        "providerInteger",
        Function::new(ctx.clone(), crate::provider::integer)?,
    )?;
    host.set(
        "providerTrim",
        Function::new(ctx.clone(), |value: String| value.trim().to_owned())?,
    )?;
    host.set(
        "providerAudioTraits",
        Function::new(ctx.clone(), crate::provider::audio_traits)?,
    )?;
    host.set(
        "extensionLog",
        Function::new(
            ctx.clone(),
            move |level: String, values: Vec<String>, count: usize| {
                logs.extension(&id, &level, values, count)
            },
        )?,
    )?;
    host.set(
        "logOpaqueType",
        Function::new(ctx.clone(), |value: Value<'js>| {
            if value.is_proxy() {
                "<goja.Proxy>"
            } else if value.is_promise() {
                "<*goja.Promise>"
            } else {
                ""
            }
        })?,
    )?;
    let comparison = Arc::clone(&control);
    host.set(
        "compareStrings",
        Function::new(ctx.clone(), move |first: String, second: String| {
            // The call boundary turns cancellation/timeout into its typed error.
            matching::compare_strings(&first, &second, &|| {
                comparison.check().map_err(|e| e.to_string())
            })
            .unwrap_or(0.0)
        })?,
    )?;
    host.set(
        "normalizeMatching",
        Function::new(ctx.clone(), |value: String| matching::normalize(&value))?,
    )?;
    host.set(
        "compareDuration",
        Function::new(ctx.clone(), |first: f64, second: f64, tolerance: f64| {
            // Goja's ToInteger clips infinities and overflow to the i64 endpoints.
            matching::compare_duration(first as i64, second as i64, tolerance as i64)
        })?,
    )?;
    let downloads = Arc::clone(&services.downloads);
    let download_control = Arc::clone(&control);
    host.set(
        "downloadCancelled",
        Function::new(ctx.clone(), move || {
            let id = download_control.item_id();
            !id.is_empty() && downloads.cancellation.is_cancelled(&id).unwrap_or(false)
        })?,
    )?;
    host.set(
        "requestCancelled",
        Function::new(ctx.clone(), move || control.request_cancelled())?,
    )?;
    let version = services.app_version.clone();
    host.set(
        "appVersion",
        Function::new(ctx.clone(), move || version.get())?,
    )?;
    let version = services.app_version.clone();
    host.set(
        "appUserAgent",
        Function::new(ctx.clone(), move || version.user_agent())?,
    )?;
    host.set(
        "randomUserAgent",
        Function::new(ctx.clone(), random_user_agent)?,
    )?;
    Ok(())
}
