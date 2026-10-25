// Exercise the production Windows path conversion on every host, including
// UTF-16 names that cannot be represented by a Rust String.
#[path = "../../../vendor/cap-primitives-4.0.3/src/windows/fs/path_prefix.rs"]
mod path_prefix;
