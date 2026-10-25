//! Active platform resolver chain and cancellation-aware native ownership.

pub mod availability;
mod client;
pub(crate) mod http;
mod rate;
mod service;
pub mod urls;

pub use client::{PlatformResolverChain, ResolverOptions};
use serde::Serialize;
pub use service::PlatformResolverService;
pub use spotiflac_core::resolver::Metadata;
use std::collections::BTreeMap;

pub type Check<'a> = dyn Fn() -> Result<(), String> + Sync + 'a;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ResolverError {
    #[error("{0}")]
    Failed(String),
    #[error("{0}")]
    Transport(String),
    #[error("{0}")]
    Cancelled(String),
    #[error("platform resolver closed")]
    Closed,
    #[error("platform resolver lookup limit reached")]
    Busy,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Resolution {
    pub links: BTreeMap<String, String>,
    pub metadata: Metadata,
}

pub trait Resolver: Send + Sync + 'static {
    /// Implementations must observe `check` during blocking work. Shutdown
    /// waits for calls to release their network streams and other resources.
    fn resolve(
        &self,
        url: &str,
        hint: &Metadata,
        check: &Check<'_>,
    ) -> Result<Resolution, ResolverError>;
}

fn check_active(check: &Check<'_>) -> Result<(), ResolverError> {
    check().map_err(ResolverError::Cancelled)
}

fn add_source(links: &mut BTreeMap<String, String>, input: &str) {
    let platform = urls::platform(input);
    let direct = urls::direct(platform, input);
    if !direct.is_empty() {
        links.entry(platform.into()).or_insert(direct);
    }
}

fn useful(links: &BTreeMap<String, String>) -> bool {
    links.len() >= 4
        && ["deezer", "tidal", "amazonMusic", "qobuz"]
            .iter()
            .filter(|platform| links.get(**platform).is_some_and(|link| !link.is_empty()))
            .count()
            >= 2
}
