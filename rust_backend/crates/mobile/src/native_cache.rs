//! Cache traversal, reference lookup and eviction execute on the native worker.
//! Child directory descriptors never follow symlinks, including during races.
#[cfg(unix)]
mod unix;

pub(crate) fn execute(
    request: &serde_json::Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<serde_json::Value, String> {
    #[cfg(unix)]
    {
        unix::execute(request, check)
    }
    #[cfg(not(unix))]
    {
        let _ = (request, check);
        Err("Native cache maintenance requires a Unix platform".into())
    }
}
