pub mod builtin;
pub mod cache;
mod calls;
mod http;
pub mod lrclib;
mod service;

pub use calls::{CallGraph, CallNode, CallWait};
pub use service::{LyricsFetcher, LyricsService, SearchRequest};

use spotiflac_core::lyrics::errors::ErrorKind;

pub type Check<'a> = dyn Fn() -> Result<(), String> + Sync + 'a;

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum LyricsError {
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Unavailable(String),
    #[error("{0}")]
    Other(String),
    #[error("{0}")]
    Cancelled(String),
    #[error("{0}")]
    Recursive(String),
}

impl LyricsError {
    pub fn classified(kind: ErrorKind, message: impl Into<String>) -> Self {
        match kind {
            ErrorKind::NotFound => Self::NotFound(message.into()),
            ErrorKind::Unavailable => Self::Unavailable(message.into()),
            ErrorKind::Other => Self::Other(message.into()),
        }
    }
}
