//! OHOS bridge library — P0 spike artifact.
//!
//! Proves the Rust cdylib toolchain (`aarch64-unknown-linux-ohos`, NDK clang
//! wrapper) links against the OpenHarmony musl sysroot and exports a stable C
//! ABI that a NAPI module can call. The full Clash Verge Rev backend port
//! (core/config/profile logic from `src-tauri`) will live behind this ABI.

use std::os::raw::c_char;

/// Liveness probe callable from ArkTS/NAPI.
#[no_mangle]
pub extern "C" fn verge_ohos_ping() -> u32 {
    42
}

/// Version string of the bridge, returned as a static NUL-terminated C string.
#[no_mangle]
pub extern "C" fn verge_ohos_version() -> *const c_char {
    b"0.1.0-p0\0".as_ptr() as *const c_char
}
