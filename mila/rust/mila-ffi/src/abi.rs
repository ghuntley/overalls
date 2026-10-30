//! Stable C ABI status, version and caller-owned output types.

/// FFI status values. Zero means success; negative values are stable failures.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaFfiStatus {
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
    InvalidRequest = -4,
}

/// A fixed-size route description suitable for a caller-owned buffer.
#[repr(C)]
pub struct MilaRouteOutput {
    pub bytes: *mut u8,
    pub capacity: usize,
    pub written: *mut usize,
}

/// Returns the ABI version consumed by the platform bridge.
#[no_mangle]
pub extern "C" fn mila_ffi_version() -> u32 {
    1
}

/// ABI version represented as two C-compatible integers.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaFfiAbiVersion {
    pub major: u32,
    pub minor: u32,
}

/// Writes the ABI version into caller-owned storage.
///
/// # Safety
/// `out_version` must be null or point to writable storage for one `MilaFfiAbiVersion`.
#[no_mangle]
pub unsafe extern "C" fn mila_ffi_get_version(
    out_version: *mut MilaFfiAbiVersion,
) -> MilaFfiStatus {
    if out_version.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: the caller supplied a non-null pointer to writable version storage.
    *out_version = MilaFfiAbiVersion { major: 1, minor: 0 };
    MilaFfiStatus::Ok
}
