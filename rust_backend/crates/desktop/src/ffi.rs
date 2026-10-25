//! The exported C functions. This is the only module that allows unsafe code:
//! each block turns a pointer and length from Dart into a Rust slice, or
//! reclaims a buffer this library handed out. Panics never cross the
//! boundary.
#![allow(unsafe_code)]

use crate::runtime::{self, MosixCallback};
use std::ffi::{CStr, c_char};

/// Copies `len` bytes at `data`, treating NULL as empty.
///
/// # Safety
/// `data` must be NULL or valid for reads of `len` bytes.
unsafe fn bytes<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if data.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees `data` is readable for `len` bytes and
    // stays valid for the duration of this call; we copy before returning to
    // Dart.
    unsafe { std::slice::from_raw_parts(data, len) }
}

fn guard(body: impl FnOnce()) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));
}

/// Idempotent initialization. `config_json` is a UTF-8 JSON object with
/// `app_support_dir`, `documents_dir`, `temp_dir`, `ffmpeg_path` and
/// `ffprobe_path`.
///
/// # Safety
/// `config_json` must be NULL or valid for reads of `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mornye_init(
    cb: Option<MosixCallback>,
    config_json: *const u8,
    len: usize,
) {
    // SAFETY: forwarded caller guarantee.
    let config = unsafe { bytes(config_json, len) }.to_vec();
    guard(|| runtime::init(cb, &config));
}

/// Starts one method call; the answer arrives through the callback with `id`.
///
/// # Safety
/// `method` must be NULL or a NUL-terminated string; `args_json` and `bytes`
/// must be NULL or valid for reads of their lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mornye_call(
    id: u64,
    method: *const c_char,
    args_json: *const u8,
    args_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
) {
    let method = if method.is_null() {
        String::new()
    } else {
        // SAFETY: the caller passes a NUL-terminated string.
        unsafe { CStr::from_ptr(method) }
            .to_string_lossy()
            .into_owned()
    };
    // SAFETY: forwarded caller guarantees; both are copied immediately.
    let args = unsafe { bytes(args_json, args_len) }.to_vec();
    let binary = (!bytes_ptr.is_null()).then(|| unsafe { bytes(bytes_ptr, bytes_len) }.to_vec());
    guard(|| {
        if let Some(runtime) = runtime::get() {
            runtime.call(id, &method, &args, binary);
        }
    });
}

/// Best-effort cancellation of an in-flight call.
#[unsafe(no_mangle)]
pub extern "C" fn mornye_cancel(id: u64) {
    guard(|| {
        if let Some(runtime) = runtime::get() {
            runtime.cancel(id);
        }
    });
}

/// Starts pushing an event kind. Idempotent.
#[unsafe(no_mangle)]
pub extern "C" fn mornye_subscribe(kind: i32) {
    guard(|| {
        if let Some(runtime) = runtime::get() {
            crate::events::subscribe(runtime, kind);
        }
    });
}

/// Stops pushing an event kind. Idempotent.
#[unsafe(no_mangle)]
pub extern "C" fn mornye_unsubscribe(kind: i32) {
    guard(|| {
        if let Some(runtime) = runtime::get() {
            crate::events::unsubscribe(runtime, kind);
        }
    });
}

/// Frees a buffer handed to the callback.
///
/// # Safety
/// `data` must be NULL or a pointer this library passed to the callback with
/// the same `len`, freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mornye_free(data: *mut u8, len: usize) {
    if data.is_null() || len == 0 {
        return;
    }
    // SAFETY: `runtime::emit` created this buffer with
    // `Box::into_raw(Box<[u8]>)` of exactly `len` bytes, and the caller frees
    // it once.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)) });
}
