#![deny(unsafe_code)]
#![doc = "Non-setuid startup capability probe. No guest runs and no state is retained."]

use rustix::fs::{open, Mode as FileMode, OFlags};
use rustix::io::Errno;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::Path;

/// Expected KVM API version reported by `/dev/kvm`.
pub const REQUIRED_API_VERSION: i32 = 12;
/// `KVM_GET_API_VERSION` = `_IO(KVMIO, 0x00)` with `KVMIO = 0xAE`.
pub const KVM_GET_API_VERSION: libc::c_ulong = 0x0000_AE00;
/// `KVM_CREATE_VM` = `_IO(KVMIO, 0x01)`.
pub const KVM_CREATE_VM: libc::c_ulong = 0x0000_AE01;
/// The only device the probe may consult.
pub const KVM_DEVICE: &str = "/dev/kvm";

/// Why probing failed. Fixed codes only; the kernel error stays local.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProbeError {
    /// /dev/kvm failed to open (absent, denied or unusable node).
    Open,
    /// API version mismatch or ioctl failure.
    ApiVersion,
    /// Empty-VM creation failed.
    CreateVm,
}

#[allow(
    unsafe_code,
    reason = "the two KVM ioctls need libc's unsafe variadic ioctl; this shim is the only unsafe surface"
)]
mod kvm_ioctl {
    use std::os::fd::{OwnedFd, RawFd};

    /// @cc [owner:ghuntley,label:assurance] kvm-ioctl-shim-only-unsafe
    /// libc's variadic ioctl is unsafe-signatured; confinement is this shim.
    /// Requests are fixed protocol constants, the argument slot stays zero, and
    /// the raw descriptor is a live-owned local kernel handle. No buffer memory
    /// crosses the boundary and no caller input reaches the request numbers.
    use std::os::fd::FromRawFd;

    pub(super) fn api_version(kvm: RawFd) -> Result<i32, ()> {
        // SAFETY: `kvm` is the caller's live, owned /dev/kvm descriptor for the
        // whole call; KVM_GET_API_VERSION is an `_IO` request that reads no
        // argument memory, so the zero argument is never dereferenced.
        match unsafe { libc::ioctl(kvm, super::KVM_GET_API_VERSION, 0) } {
            version if version >= 0 => Ok(version),
            _ => Err(()),
        }
    }

    pub(super) fn create_vm(kvm: RawFd) -> Result<OwnedFd, ()> {
        // SAFETY: `kvm` is the caller's live, owned /dev/kvm descriptor for the
        // whole call; KVM_CREATE_VM is an `_IO` request whose zero argument is
        // the default machine type and is never dereferenced.
        match unsafe { libc::ioctl(kvm, super::KVM_CREATE_VM, 0) } {
            // SAFETY: a nonnegative KVM_CREATE_VM result is a new descriptor
            // the kernel hands to this process; nothing else owns or closes it,
            // so wrapping it in OwnedFd transfers that sole ownership.
            fd if fd >= 0 => Ok(unsafe { <OwnedFd as FromRawFd>::from_raw_fd(fd) }),
            _ => Err(()),
        }
    }
}

/// @cc [owner:ghuntley,label:assurance] kvm-probe-requires-real-vm-creation
/// probe MUST report success only after opening /dev/kvm, observing API version
/// 12 and creating an empty VM; device-file existence or open permission alone
/// must not establish execution capability. The probe must run no guest code.
pub fn probe() -> Result<(), ProbeError> {
    let kvm = open(
        Path::new(KVM_DEVICE),
        OFlags::RDWR | OFlags::CLOEXEC,
        FileMode::empty(),
    )
    .map_err(|_: Errno| ProbeError::Open)?;
    if kvm_ioctl::api_version(kvm.as_raw_fd()).map_err(|()| ProbeError::ApiVersion)?
        != REQUIRED_API_VERSION
    {
        return Err(ProbeError::ApiVersion);
    }
    // OwnedFd drops close both descriptors on return and on early exit.
    let _vm: OwnedFd = kvm_ioctl::create_vm(kvm.as_raw_fd()).map_err(|()| ProbeError::CreateVm)?;
    drop(kvm);
    Ok(())
}

#[cfg(test)]
mod tests;
