//! Operating-system layers for the guest agents (ADR-0171) and the
//! workstation CLI.
//!
//! Protocol logic lives in platform-neutral modules; only what touches the
//! kernel differs. The helpers below are the small set the `overalls` CLI needs
//! on every workstation (Linux, macOS and Windows) so its modules stay free of
//! `std::os::unix` and `libc` calls.

#[cfg(windows)]
pub mod windows;

use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;

/// The null device OpenSSH accepts for `-F` and known-hosts options.
pub fn null_device() -> &'static str {
    if cfg!(windows) {
        "NUL"
    } else {
        "/dev/null"
    }
}

/// @cc [owner:ghuntley,label:security] workstation-local-user-name
/// `local_user_name` MUST return the account running the CLI as one bounded
/// token (1 to 256 bytes, no whitespace, NUL or path separators), from `id -un`
/// on Unix and `USERNAME` on Windows; anything else is an error, never a
/// substituted name.
pub fn local_user_name() -> io::Result<String> {
    let name = platform_user_name()?;
    let valid = (1..=256).contains(&name.len())
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c == '\0' || c == '/' || c == '\\');
    if !valid {
        return Err(io::Error::other("local user unavailable"));
    }
    Ok(name)
}

#[cfg(unix)]
fn platform_user_name() -> io::Result<String> {
    let output = std::process::Command::new("id")
        .arg("-un")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("local user unavailable"));
    }
    let name = String::from_utf8(output.stdout).map_err(|_| io::Error::other("local user"))?;
    Ok(name.trim_end_matches('\n').to_owned())
}

#[cfg(windows)]
fn platform_user_name() -> io::Result<String> {
    std::env::var("USERNAME").map_err(|_| io::Error::other("local user unavailable"))
}

/// Fill `buffer` from the operating system's cryptographic RNG.
pub fn random_bytes(buffer: &mut [u8]) -> io::Result<()> {
    platform_random(buffer)
}

#[cfg(unix)]
fn platform_random(buffer: &mut [u8]) -> io::Result<()> {
    use std::io::Read;
    File::open("/dev/urandom")?.read_exact(buffer)
}

#[cfg(windows)]
fn platform_random(buffer: &mut [u8]) -> io::Result<()> {
    u32::try_from(buffer.len()).map_err(|_| io::Error::other("RNG request"))?;
    if !crate::sys::windows::error::system_random(buffer) {
        return Err(io::Error::other("system RNG unavailable"));
    }
    Ok(())
}

/// Restrict a directory to its owner (mode 0700 on Unix). Windows directories
/// under the user's profile already inherit an owner, SYSTEM and
/// Administrators ACL, which OpenSSH accepts.
pub fn restrict_directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
    }
    #[cfg(windows)]
    {
        let _ = path;
        Ok(())
    }
}

/// Restrict an open file to its owner (mode 0600 on Unix; inherited profile
/// ACL on Windows).
pub fn restrict_file(file: &File) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
    }
    #[cfg(windows)]
    {
        let _ = file;
        Ok(())
    }
}

/// @cc [owner:ghuntley,label:security] workstation-private-open-no-follow
/// `open_private` MUST open (creating with owner-only mode 0600 on Unix) the
/// exact path without following a final symbolic link or reparse point, so a
/// planted link cannot redirect CLI state or lock files.
pub fn open_private(path: &Path, options: &mut OpenOptions) -> io::Result<File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT: open the link itself, never its target.
        options.custom_flags(0x0020_0000);
        if let Ok(metadata) = std::fs::symlink_metadata(path) {
            if metadata.file_type().is_symlink() {
                return Err(io::Error::other("refusing a linked path"));
            }
        }
    }
    options.open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_user_name_is_a_bounded_token() {
        let name = local_user_name().unwrap();
        assert!(!name.is_empty() && !name.contains(char::is_whitespace));
    }

    #[test]
    fn random_bytes_fill_the_buffer() {
        let mut first = [0u8; 32];
        let mut second = [0u8; 32];
        random_bytes(&mut first).unwrap();
        random_bytes(&mut second).unwrap();
        assert_ne!(first, second);
    }

    #[cfg(unix)]
    #[test]
    fn open_private_refuses_a_final_symlink() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        std::fs::write(&target, b"x").unwrap();
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let mut options = OpenOptions::new();
        options.read(true);
        assert!(open_private(&link, &mut options).is_err());
    }
}
