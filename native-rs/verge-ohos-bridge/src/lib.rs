//! Ported subset of Clash Verge Rev's backend (`src-tauri/src/config/clash.rs`,
//! `core/manager`) that is meaningful on HarmonyOS: runtime config generation,
//! mihomo sidecar process management, subscription fetching.
//!
//! Everything here is platform-independent Rust and is unit/integration tested
//! on the host (macOS) with a real mihomo binary; the OHOS cdylib is a thin
//! C-ABI wrapper over the same code.

pub mod config;
pub mod core;
pub mod subscription;

// ---------------------------------------------------------------------------
// C ABI (called from the OHOS NAPI module in app/entry/src/main/cpp).
// Strings are NUL-terminated C strings; returns 0 on success unless noted.
// ---------------------------------------------------------------------------

use std::ffi::{c_char, CStr};

fn str_in(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("null string arg".into());
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(|s| s.to_owned())
        .map_err(|e| format!("invalid utf8: {e}"))
}

fn err_code(r: Result<impl Sized, String>) -> i32 {
    match r {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

/// Write the runtime config generated from `profile_path` to `runtime_path`.
#[no_mangle]
pub extern "C" fn verge_config_generate(
    profile_path: *const c_char,
    runtime_path: *const c_char,
) -> i32 {
    match (|| {
        let p = str_in(profile_path)?;
        let r = str_in(runtime_path)?;
        config::generate_to_file(&p, &r)
    })() {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Start the mihomo sidecar. Writes the pid into `out_pid` (i64) on success.
#[no_mangle]
pub extern "C" fn verge_core_start(
    binary_path: *const c_char,
    data_dir: *const c_char,
    runtime_config_path: *const c_char,
    out_pid: *mut i64,
) -> i32 {
    match (|| {
        let bin = str_in(binary_path)?;
        let dir = str_in(data_dir)?;
        let cfg = str_in(runtime_config_path)?;
        core::start(core::CoreStart {
            binary_path: &bin,
            data_dir: &dir,
            runtime_config_path: &cfg,
        })
    })() {
        Ok(pid) => unsafe {
            if !out_pid.is_null() {
                *out_pid = pid as i64;
            }
            0
        },
        Err(_) => -1,
    }
}

/// Stop the running core.
#[no_mangle]
pub extern "C" fn verge_core_stop() -> i32 {
    err_code(core::stop())
}

/// 1 if running, 0 if not, -1 on error.
#[no_mangle]
pub extern "C" fn verge_core_status() -> i32 {
    core::status().unwrap_or(-1)
}

/// Poll /version until ready (up to `timeout_ms`); 0 on success.
#[no_mangle]
pub extern "C" fn verge_core_wait_ready(timeout_ms: u64) -> i32 {
    err_code(core::wait_ready(timeout_ms).map(|_| ()))
}

/// GET a core REST path; writes the JSON body into `out_buf` (capacity
/// `cap`). Returns needed length, or -1 on error / -2 when buffer too small.
#[no_mangle]
pub unsafe extern "C" fn verge_core_rest_get(
    path: *const c_char,
    out_buf: *mut c_char,
    cap: usize,
) -> i64 {
    let p = match str_in(path) {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let body = match core::rest_get(&p) {
        Ok(b) => b,
        Err(_) => return -1,
    };
    let n = body.len();
    if out_buf.is_null() || cap <= n {
        return (n + 1) as i64;
    }
    std::ptr::copy_nonoverlapping(body.as_ptr(), out_buf as *mut u8, n);
    *out_buf.add(n) = 0;
    (n + 1) as i64
}

/// Fetch a subscription URL to `out_path`; returns bytes written or -1.
#[no_mangle]
pub unsafe extern "C" fn verge_subscription_fetch(
    url: *const c_char,
    out_path: *const c_char,
) -> i64 {
    match (|| {
        let u = str_in(url)?;
        let p = str_in(out_path)?;
        subscription::fetch_to_file(&u, &p)
    })() {
        Ok(n) => n as i64,
        Err(_) => -1,
    }
}
