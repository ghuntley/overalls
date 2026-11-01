//! File and directory custody: ACL, ancestry and private state I/O.

use super::account::require_system;
use super::{administrators_sid, system_sid, trusted_installer_sid, wide};
use crate::Refusal;
use crate::windows_model::LocalPath;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::mem::{size_of, zeroed};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicU64, Ordering};
use windows_sys::Win32::Foundation::{
    ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, GetLastError, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetSecurityDescriptorDacl,
    GetSecurityDescriptorOwner, IsValidSecurityDescriptor, OWNER_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES,
};
use windows_sys::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, CreateDirectoryW, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    GetFileInformationByHandle, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    READ_CONTROL,
};

/// @cc [owner:ghuntley,label:security] windows-editor-platform-authority-scope
/// Only directory ancestry and explicit worker search directories MAY accept
/// the exact `TrustedInstaller` service SID as platform servicing authority.
/// Package leaves MUST remain SYSTEM/Administrators-only; private state MUST
/// remain SYSTEM-only. A trusted directory owner MUST NOT authorize foreign
/// write, deletion, reparse traversal or ACL replacement.
#[derive(Clone, Copy)]
pub(super) enum FileAuthority {
    SystemOnly,
    Package,
    Ancestor,
    WorkerDirectory,
}

impl FileAuthority {
    fn platform_servicing(self) -> bool {
        matches!(self, Self::Ancestor | Self::WorkerDirectory)
    }
}

fn path_handle(path: &str) -> Result<File, Refusal> {
    OpenOptions::new()
        .access_mode(READ_CONTROL | FILE_READ_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .map_err(|_| Refusal::Custody)
}

pub(super) fn attributes(file: &File) -> Result<u32, Refusal> {
    // SAFETY: BY_HANDLE_FILE_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
    let mut information: BY_HANDLE_FILE_INFORMATION = unsafe { zeroed() };
    // SAFETY: the file handle is open for the borrow of `file` and `information` is a live writable local.
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &raw mut information) } == 0
        || information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    {
        return Err(Refusal::Custody);
    }
    Ok(information.dwFileAttributes)
}

fn file_acl(file: &File, authority: FileAuthority) -> Result<(), Refusal> {
    let mut descriptor = null_mut();
    // SAFETY: the file handle is open for the borrow of `file`; `descriptor` is a writable out-pointer and the unused out-pointers are null.
    if unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            windows_sys::Win32::Security::Authorization::SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            &raw mut descriptor,
        )
    } != 0
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: GetSecurityInfo returned the owned security descriptor; its
    // owner and DACL remain valid until LocalFree after validation.
    let result = unsafe { descriptor_acl(descriptor, authority) };
    // SAFETY: `descriptor` was allocated by GetSecurityInfo and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    result
}

/// Validate only a Windows-owned, live security descriptor. The caller MUST
/// retain its allocation through this call; arbitrary pointers are forbidden.
pub(super) unsafe fn descriptor_acl(
    descriptor: PSECURITY_DESCRIPTOR,
    authority: FileAuthority,
) -> Result<(), Refusal> {
    // SAFETY: the caller guarantees `descriptor` is a live Windows-owned security descriptor, checked non-null first.
    if descriptor.is_null() || unsafe { IsValidSecurityDescriptor(descriptor) } == 0 {
        return Err(Refusal::Custody);
    }
    let mut owner = null_mut();
    let mut dacl = null_mut();
    let mut owner_defaulted = 0;
    let mut dacl_present = 0;
    let mut dacl_defaulted = 0;
    // SAFETY: `descriptor` is a valid live security descriptor and the out-pointers are live writable locals.
    if unsafe { GetSecurityDescriptorOwner(descriptor, &raw mut owner, &raw mut owner_defaulted) }
        == 0
        // SAFETY: `descriptor` is a valid live security descriptor and the out-pointers are live writable locals.
        || unsafe {
            GetSecurityDescriptorDacl(
                descriptor,
                &raw mut dacl_present,
                &raw mut dacl,
                &raw mut dacl_defaulted,
            )
        } == 0
        || dacl_present == 0
    {
        return Err(Refusal::Custody);
    }
    let system = system_sid();
    let administrators = administrators_sid();
    let trusted_installer = trusted_installer_sid();
    let system_only = matches!(authority, FileAuthority::SystemOnly);
    let ancestor = matches!(authority, FileAuthority::Ancestor);
    // SAFETY: `sid` comes from the live descriptor or DACL, and `system` is a live well-formed SID array that EqualSid only reads.
    let is_system = |sid| unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } != 0;
    // SAFETY: `sid` comes from the live descriptor or DACL, and `administrators` is a live well-formed SID array that EqualSid only reads.
    let is_admin = |sid| unsafe { EqualSid(sid, administrators.as_ptr().cast_mut().cast()) } != 0;
    let is_platform = |sid| {
        authority.platform_servicing()
            // SAFETY: `sid` comes from the live descriptor or DACL, and `trusted_installer` is a live well-formed SID array that EqualSid only reads.
            && unsafe { EqualSid(sid, trusted_installer.as_ptr().cast_mut().cast()) } != 0
    };
    if owner.is_null()
        || dacl.is_null()
        || (system_only && !is_system(owner))
        || (!system_only && !is_system(owner) && !is_admin(owner) && !is_platform(owner))
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: `dacl` is non-null and points to the ACL inside the live descriptor.
    let count = unsafe { (*dacl).AceCount };
    if count == 0 || count > 128 {
        return Err(Refusal::Custody);
    }
    for index in 0..u32::from(count) {
        let mut ace = null_mut();
        // SAFETY: `dacl` is a live ACL, `index` is below its AceCount, and `ace` is a writable out-pointer.
        if unsafe { GetAce(dacl, index, &raw mut ace) } == 0 || ace.is_null() {
            return Err(Refusal::Custody);
        }
        // SAFETY: GetAce returned a non-null pointer to an ACE inside the live DACL; its header is read before any type-specific field is trusted.
        let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        if allowed.Header.AceType == 1 {
            continue;
        } // Denials cannot grant write authority.
        if allowed.Header.AceType != 0
            || (allowed.Header.AceSize as usize) < size_of::<ACCESS_ALLOWED_ACE>()
        {
            return Err(Refusal::Custody);
        }
        if allowed.Header.AceFlags & 8 != 0 {
            continue;
        } // INHERIT_ONLY does not apply here.
        let sid = (&raw const allowed.SidStart).cast_mut().cast();
        if is_system(sid) {
            continue;
        }
        if system_only {
            return Err(Refusal::Custody);
        }
        if is_admin(sid) || is_platform(sid) {
            continue;
        }
        // A parent may allow creation of unrelated children. It MUST NOT
        // allow replacing/deleting this already-owned child or its ACL.
        let write_mask = 0x500d_0040 | if ancestor { 0 } else { 0x0000_0116 };
        if allowed.Mask & write_mask != 0 {
            return Err(Refusal::Custody);
        }
    }
    Ok(())
}

fn ancestors(path: &LocalPath) -> Result<(), Refusal> {
    let mut parent = std::path::Path::new(path.as_str()).parent();
    while let Some(directory) = parent {
        let text = directory.to_str().ok_or(Refusal::Custody)?;
        let handle = path_handle(text)?;
        if attributes(&handle)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
            return Err(Refusal::Custody);
        }
        file_acl(&handle, FileAuthority::Ancestor)?;
        parent = directory.parent();
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] windows-editor-package-path-custody
/// Configured executable/configuration/certificate paths MUST be real regular
/// files with SYSTEM or Administrators ownership and write authority only for
/// those principals. Every ancestor MUST refuse reparse traversal and foreign
/// replacement/delete/ACL authority. A caller path or existence alone MUST NOT
/// establish immutable package custody. Retained-worker adoption and recovery
/// MUST recheck executable custody before trusting the retained process.
pub fn package_file(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let file = path_handle(path.as_str())?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::Package)
}

/// @cc [owner:ghuntley,label:security] windows-editor-path-directory-custody
/// Every initial worker PATH entry MUST be an existing real directory owned by
/// SYSTEM, Administrators or the exact Windows `TrustedInstaller` service SID.
/// Those principals alone may write it or control ancestor replacement/ACLs;
/// every component MUST refuse reparse traversal. `TrustedInstaller` already
/// controls platform servicing; it MUST NOT gain package-file or receipt trust.
pub(super) fn package_directory(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let directory = path_handle(path.as_str())?;
    if attributes(&directory)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&directory, FileAuthority::WorkerDirectory)
}

fn checked_private_directory(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let directory = path_handle(path.as_str())?;
    if attributes(&directory)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&directory, FileAuthority::SystemOnly)
}

/// Create only the final directory under trusted ancestors, with SYSTEM-only ACL.
pub fn private_directory(path: &LocalPath) -> Result<(), Refusal> {
    require_system()?;
    ancestors(path)?;
    if std::path::Path::new(path.as_str()).exists() {
        return checked_private_directory(path);
    }
    let sddl = wide("O:SYG:SYD:P(A;OICI;FA;;;SY)");
    let mut descriptor = null_mut();
    // SAFETY: `sddl` is a live NUL-terminated UTF-16 string and `descriptor` is a writable out-pointer; the optional length pointer is null.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &raw mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>()).map_err(|_| Refusal::Custody)?,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let name = wide(path.as_str());
    // SAFETY: `name` is a live NUL-terminated UTF-16 path and `attributes` points to the converted descriptor, both live for the call.
    let created = unsafe { CreateDirectoryW(name.as_ptr(), &raw const attributes) };
    // SAFETY: GetLastError only reads this thread's last-error value.
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    if created == 0 && !existed {
        return Err(Refusal::Custody);
    }
    checked_private_directory(path)
}

fn private_parent(path: &LocalPath) -> Result<(), Refusal> {
    let parent = std::path::Path::new(path.as_str())
        .parent()
        .and_then(std::path::Path::to_str)
        .ok_or(Refusal::Custody)?;
    checked_private_directory(&LocalPath::parse(parent).map_err(|_| Refusal::Custody)?)
}

/// Read a bounded ordinary receipt only after SYSTEM-only parent/file custody.
pub fn read_private(path: &LocalPath, maximum: usize) -> Result<Vec<u8>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = OpenOptions::new()
        .read(true)
        .access_mode(0x8000_0000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
        .map_err(|_| Refusal::Custody)?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::SystemOnly)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(bytes)
}

/// Read an optional receipt. Absence is the only non-error state; ACL,
/// reparse, malformed, and other I/O failures remain custody refusals.
pub fn read_private_optional(path: &LocalPath, maximum: usize) -> Result<Option<Vec<u8>>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = match OpenOptions::new()
        .read(true)
        .access_mode(0x8000_0000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
    {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(ERROR_FILE_NOT_FOUND.cast_signed()) => {
            return Ok(None);
        }
        Err(_) => return Err(Refusal::Custody),
    };
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::SystemOnly)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(Some(bytes))
}

/// Publish a complete bounded receipt by rename under its SYSTEM-only parent.
pub fn write_private(path: &LocalPath, bytes: &[u8]) -> Result<(), Refusal> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    require_system()?;
    private_parent(path)?;
    if bytes.is_empty() || bytes.len() > 65536 {
        return Err(Refusal::Custody);
    }
    let temporary = format!(
        "{}.{}.{}.tmp",
        path.as_str(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .access_mode(0x4000_0000 | READ_CONTROL)
            .share_mode(0)
            .open(&temporary)
            .map_err(|_| Refusal::Custody)?;
        attributes(&file)?;
        file_acl(&file, FileAuthority::SystemOnly)?;
        file.write_all(bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Refusal::Custody)?;
        drop(file);
        let source = wide(&temporary);
        let destination = wide(path.as_str());
        // SAFETY: `source` and `destination` are live NUL-terminated UTF-16 paths.
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            return Err(Refusal::Custody);
        }
        let published = read_private(path, bytes.len())?;
        (published == bytes).then_some(()).ok_or(Refusal::Custody)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
