//! Native kernel and transport identity over the host-only vsock channel.
//!
//! This probe is deliberately separate from the six-key readiness response.
//! The kernel transport reports its compiled build-input identity, which must
//! match the image's root-owned expectation before a kernel-file digest is sent.
//! This is guest-local identity checking, not cryptographic measured boot.
//! Native admission also requires independent boot and transport evidence.

use crate::guest::readiness::Boot;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
use std::io::Write;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// Private native kernel-attestation port.
pub const PORT: u32 = 1098;
/// The host rejects a response larger than the normal readiness line bound.
pub const MAX_LINE: usize = 512;
const MAX_KERNEL_BYTES: u64 = 8_589_934_592;

#[derive(Debug, Serialize)]
pub struct Response<'a> {
    pub version: u8,
    pub state: &'static str,
    pub os: &'a str,
    pub placement_id: &'a str,
    pub execution_epoch: u64,
    pub boot_challenge: &'a str,
    pub boot_id: &'a str,
    pub kernel_sha256: &'a str,
}

/// The immutable kernel path is supplied by the image builder. The defaults
/// are the canonical paths used by the two supported native families.
pub fn kernel_path(os: &str) -> io::Result<PathBuf> {
    if !matches!(os, "freebsd" | "illumos") {
        return Err(io::Error::other("unsupported native kernel"));
    }
    if let Some(path) = std::env::var_os("OVERALLS_KERNEL_PATH") {
        return Ok(PathBuf::from(path));
    }
    match os {
        "freebsd" => Ok(PathBuf::from("/boot/kernel/kernel")),
        "illumos" => Ok(PathBuf::from("/platform/i86pc/kernel/amd64/unix")),
        _ => Err(io::Error::other("unsupported native kernel")),
    }
}

/// Hash the image's kernel file, without claiming measured boot evidence.
pub fn kernel_sha256(os: &str) -> io::Result<String> {
    hash_kernel(&kernel_path(os)?)
}

/// @cc [owner:ghuntley,label:security;verification] native-build-expectation-file
/// The immutable build expectation MUST be a bounded regular file containing
/// exactly 64 lower-case hex bytes and an optional LF. Symlinks, special files,
/// extra bytes and malformed values MUST refuse before native attestation.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn expected_build_id(path: &Path) -> io::Result<String> {
    read_build_id(path, 0)
}

#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    test
))]
fn read_build_id(path: &Path, expected_owner: u32) -> io::Result<String> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || !(64..=65).contains(&metadata.len()) {
        return Err(io::Error::other("invalid kernel build expectation"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let parent = fs::symlink_metadata(
            path.parent()
                .ok_or_else(|| io::Error::other("invalid kernel build expectation"))?,
        )?;
        if metadata.uid() != expected_owner
            || metadata.mode() & 0o022 != 0
            || !parent.is_dir()
            || parent.uid() != expected_owner
            || parent.mode() & 0o022 != 0
        {
            return Err(io::Error::other("untrusted kernel build expectation"));
        }
    }
    let mut bytes = [0_u8; 66];
    let mut length = 0;
    while length < bytes.len() {
        let count = file.read(&mut bytes[length..])?;
        if count == 0 {
            break;
        }
        length += count;
    }
    if !(length == 64 || (length == 65 && bytes[64] == b'\n'))
        || !bytes[..64]
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err(io::Error::other("invalid kernel build expectation"));
    }
    String::from_utf8(bytes[..64].to_vec())
        .map_err(|_| io::Error::other("invalid kernel build expectation"))
}

/// Require the executing transport's identity to match the installed image.
/// On illumos this identifies the patched transport/module inputs, with the
/// separately hashed artifact retaining the complete installed module set.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub fn verified_build_id(listener: &crate::native_vsock::Listener) -> io::Result<String> {
    let observed = listener.kernel_build_id()?;
    if observed != expected_build_id(Path::new("/etc/overalls/kernel-build-id"))? {
        return Err(io::Error::other("kernel build identity mismatch"));
    }
    Ok(observed)
}

/// @cc [owner:ghuntley,label:security;verification] native-kernel-file-bounded
/// Kernel file hashing MUST reject empty, nonregular or larger-than-8-GiB
/// files and changes in byte length while reading. The digest is file identity
/// only and MUST NOT be presented as proof of the running kernel.
fn hash_kernel(path: &Path) -> io::Result<String> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || !(1..=MAX_KERNEL_BYTES).contains(&metadata.len()) {
        return Err(io::Error::other("invalid kernel artifact"));
    }
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut bytes = 0_u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        bytes += read as u64;
        if bytes > metadata.len() {
            return Err(io::Error::other("changed kernel artifact"));
        }
        digest.update(&buffer[..read]);
    }
    if bytes != metadata.len() || file.metadata()?.len() != bytes {
        return Err(io::Error::other("changed kernel artifact"));
    }
    Ok(hex::encode(digest.finalize()))
}

/// Encode the closed-line probe response, refusing oversized output.
pub fn response(os: &str, boot: &Boot, kernel_sha256: &str) -> io::Result<Vec<u8>> {
    if !matches!(os, "freebsd" | "illumos")
        || kernel_sha256.len() != 64
        || !kernel_sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(io::Error::other("invalid kernel digest"));
    }
    let mut line = serde_json::to_vec(&Response {
        version: 1,
        state: "attested",
        os,
        placement_id: &boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: &boot.boot_challenge,
        boot_id: &boot.boot_id,
        kernel_sha256,
    })?;
    line.push(b'\n');
    if line.len() > MAX_LINE {
        return Err(io::Error::other("oversized kernel response"));
    }
    Ok(line)
}

/// Serve one response per accepted host connection. `Listener::accept`
/// enforces host CID 2 before this function can read or write any bytes. The
/// Firecracker UDS proxy consumes the CONNECT/OK handshake, so the guest sends
/// only the bounded attestation body.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub fn run(os: &str) -> io::Result<()> {
    let (boot, _, _) = crate::native_guest::identity()?;
    let listener = crate::native_vsock::Listener::bind(PORT, 4)?;
    let build_id = verified_build_id(&listener)?;
    let digest = kernel_sha256(os)?;
    let line = response(os, &boot, &digest)?;
    loop {
        // A rejected peer or reset must consume only that connection; it must
        // not take the attestation service down for the rest of the boot.
        let Ok(mut connection) = listener.accept() else {
            continue;
        };
        if verified_build_id(&listener).is_ok_and(|current| current == build_id)
            && kernel_sha256(os).is_ok_and(|current| current == digest)
        {
            // A host disconnect consumes only this connection. A reset must
            // not retire the listener or change the boot identity.
            let _ = connection
                .write_all(&line)
                .and_then(|()| connection.flush());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    #[test]
    fn response_is_bounded_and_closed() {
        let line = response("freebsd", &boot(), &"a".repeat(64)).unwrap();
        assert!(line.len() <= MAX_LINE);
        let value: serde_json::Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 8);
        assert_eq!(value["version"], 1);
        assert_eq!(value["state"], "attested");
        assert_eq!(value["os"], "freebsd");
        assert_eq!(value["kernel_sha256"], "a".repeat(64));
    }

    #[test]
    fn malformed_digest_is_refused() {
        assert!(response("freebsd", &boot(), "not-a-digest").is_err());
        assert!(response("freebsd", &boot(), &"A".repeat(64)).is_err());
        assert!(response("linux", &boot(), &"a".repeat(64)).is_err());
    }

    #[test]
    fn hashing_requires_a_bounded_regular_kernel_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("kernel");
        fs::write(&path, b"kernel bytes").unwrap();
        assert_eq!(
            hash_kernel(&path).unwrap(),
            hex::encode(Sha256::digest(b"kernel bytes"))
        );
        fs::write(&path, []).unwrap();
        assert!(hash_kernel(&path).is_err());
        assert!(hash_kernel(directory.path()).is_err());
        let file = fs::File::create(&path).unwrap();
        file.set_len(MAX_KERNEL_BYTES + 1).unwrap();
        assert!(hash_kernel(&path).is_err());
    }

    #[test]
    fn build_expectation_refuses_unbounded_or_malformed_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("build-id");
        #[cfg(unix)]
        let owner = {
            use std::os::unix::fs::MetadataExt;
            fs::metadata(directory.path()).unwrap().uid()
        };
        #[cfg(not(unix))]
        let owner = 0;
        for value in ["a".repeat(64), format!("{}\n", "0".repeat(64))] {
            fs::write(&path, &value).unwrap();
            assert_eq!(read_build_id(&path, owner).unwrap(), value.trim_end());
        }
        for value in [
            "a".repeat(63),
            "a".repeat(66),
            "A".repeat(64),
            format!("{} ", "a".repeat(64)),
        ] {
            fs::write(&path, value).unwrap();
            assert!(read_build_id(&path, owner).is_err());
        }
        assert!(read_build_id(directory.path(), owner).is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let link = directory.path().join("link");
            fs::write(&path, "a".repeat(64)).unwrap();
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(read_build_id(&link, owner).is_err());
            assert!(read_build_id(&path, owner.wrapping_add(1)).is_err());
            fs::set_permissions(&path, fs::Permissions::from_mode(0o666)).unwrap();
            assert!(read_build_id(&path, owner).is_err());
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o777)).unwrap();
            assert!(read_build_id(&path, owner).is_err());
        }
    }
}
