//! Gateway signed sessions shared by scope, with isolated extension permissions.

mod coordinator;
mod exchange;
mod fetch;
pub mod protocol;
mod store;

pub use coordinator::{SignedRegistry, SignedSessionClient};
pub use store::{RecordStore, RuntimeHints};
