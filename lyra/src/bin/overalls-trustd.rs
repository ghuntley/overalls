//! Immutable, boot-bound public CA installer for Firecracker guests.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::fs::symlink;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PORT: u32 = 1030;
const MAX_FRAME: usize = 1_048_576;
const MAX_ROOTS: usize = 32;
const MAX_CERT: usize = 16_384;
const STATE: &str = "/var/lib/overalls-trust";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    placement_id: String,
    execution_epoch: u64,
    boot_challenge: String,
    nonce: String,
    bundle_digest: String,
    roots: Vec<String>,
}

#[derive(Serialize)]
struct Receipt<'a> {
    version: u8,
    state: &'static str,
    placement_id: &'a str,
    execution_epoch: u64,
    boot_challenge: &'a str,
    boot_id: &'a str,
    nonce: &'a str,
    bundle_digest: &'a str,
}

#[expect(
    clippy::struct_field_names,
    reason = "fields mirror the boot identity names in the receipt wire format"
)]
struct Boot {
    placement_id: String,
    execution_epoch: u64,
    boot_challenge: String,
    boot_id: String,
}

enum Store {
    Nixos(PathBuf),
    Ubuntu,
    Linux(PathBuf),
}

fn event(name: &'static str) {
    eprintln!("{{\"event\":\"guest_trust.{name}\"}}");
}

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn boot() -> io::Result<Boot> {
    let command_line = fs::read_to_string("/proc/cmdline")?;
    if command_line.len() > 4096 {
        return Err(io::Error::other("invalid boot"));
    }
    let mut placement = None;
    let mut epoch = None;
    let mut challenge = None;
    for field in command_line.split_whitespace() {
        let (name, value) = field.split_once('=').unwrap_or((field, ""));
        let slot = match name {
            "lilly.placement" => &mut placement,
            "lilly.execution_epoch" => &mut epoch,
            "lilly.boot_challenge" => &mut challenge,
            _ => continue,
        };
        if slot.replace(value.to_owned()).is_some() {
            return Err(io::Error::other("invalid boot"));
        }
    }
    let placement_id = placement.ok_or_else(|| io::Error::other("invalid boot"))?;
    let execution_epoch = epoch
        .ok_or_else(|| io::Error::other("invalid boot"))?
        .parse::<u64>()
        .map_err(|_| io::Error::other("invalid boot"))?;
    let boot_challenge = challenge.ok_or_else(|| io::Error::other("invalid boot"))?;
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .to_owned();
    if !valid_uuid(&placement_id)
        || execution_epoch == 0
        || !valid_hex(&boot_challenge, 64)
        || !valid_uuid(&boot_id)
    {
        return Err(io::Error::other("invalid boot"));
    }
    Ok(Boot {
        placement_id,
        execution_epoch,
        boot_challenge,
        boot_id,
    })
}

// @cc [owner:ghuntley,label:security;recovery] guest-trust-exact-boot
// Only a bounded host-CID-2 request matching this kernel boot may install an
// exact public CA set. A failed or interrupted installation MUST NOT acknowledge.
fn validate(request: &Request, boot: &Boot) -> io::Result<()> {
    if request.version != 1
        || request.placement_id != boot.placement_id
        || request.execution_epoch != boot.execution_epoch
        || request.boot_challenge != boot.boot_challenge
        || !valid_hex(&request.nonce, 64)
        || !valid_hex(&request.bundle_digest, 64)
        || request.roots.is_empty()
        || request.roots.len() > MAX_ROOTS
    {
        return Err(io::Error::other("invalid trust request"));
    }
    let mut fingerprints = Vec::with_capacity(request.roots.len());
    for pem in &request.roots {
        if pem.len() > MAX_CERT
            || !pem.starts_with("-----BEGIN CERTIFICATE-----\n")
            || !pem.trim_end().ends_with("-----END CERTIFICATE-----")
            || pem.matches("-----BEGIN CERTIFICATE-----").count() != 1
            || pem.matches("-----END CERTIFICATE-----").count() != 1
            || pem.contains("PRIVATE KEY")
            || reqwest::Certificate::from_pem(pem.as_bytes()).is_err()
        {
            return Err(io::Error::other("invalid trust certificate"));
        }
        fingerprints.push(Sha256::digest(pem.as_bytes()).to_vec());
    }
    fingerprints.sort();
    if fingerprints.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(io::Error::other("duplicate trust certificate"));
    }
    let digest = hex::encode(Sha256::digest(fingerprints.concat()));
    if digest != request.bundle_digest {
        return Err(io::Error::other("trust digest mismatch"));
    }
    Ok(())
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

fn write_sync(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

// @cc [owner:ghuntley,label:security] guest-public-bundle-readable
// The installed public CA bundle and every parent created here MUST be
// traversable and readable by unprivileged guest services, including SSH auth.
fn install_nixos(base: &Path, roots: &[String], digest: &str) -> io::Result<()> {
    install_nixos_at(base, roots, digest, Path::new(STATE))
}

fn install_nixos_at(
    base: &Path,
    roots: &[String],
    digest: &str,
    directory: &Path,
) -> io::Result<()> {
    fs::create_dir_all(directory)?;
    let name = format!("bundle-{digest}");
    let destination = directory.join(&name);
    let mut bytes = fs::read(base)?;
    if bytes.len() > MAX_FRAME {
        return Err(io::Error::other("system trust unavailable"));
    }
    bytes.push(b'\n');
    for root in roots {
        bytes.extend_from_slice(root.as_bytes());
        bytes.push(b'\n');
    }
    if !destination.exists() {
        let staging = tempfile::Builder::new()
            .prefix(".trust-")
            .tempdir_in(directory)?;
        let bundle = staging.path().join("ca-bundle.pem");
        write_sync(&bundle, &bytes)?;
        sync_directory(staging.path())?;
        fs::rename(staging.keep(), &destination)?;
    } else if fs::read(destination.join("ca-bundle.pem"))? != bytes {
        return Err(io::Error::other("trust bundle conflict"));
    }
    // The SSH authorization callback reads this public bundle as an unprivileged
    // user. tempfile creates the staging directory with mode 0700.
    let bundle = destination.join("ca-bundle.pem");
    fs::set_permissions(&bundle, fs::Permissions::from_mode(0o644))?;
    fs::set_permissions(&destination, fs::Permissions::from_mode(0o755))?;
    File::open(&bundle)?.sync_all()?;
    sync_directory(&destination)?;
    sync_directory(directory)?;
    let next = directory.join("current.next");
    if next.exists() || next.symlink_metadata().is_ok() {
        fs::remove_file(&next)?;
    }
    symlink(&name, &next)?;
    fs::rename(&next, directory.join("current"))?;
    sync_directory(directory)
}

/// Ubuntu trust store locations; fixed in production, temporary in tests.
struct UbuntuStore<'a> {
    state: &'a Path,
    parent: &'a Path,
    certs: &'a Path,
    bundle: &'a Path,
}

fn ubuntu_store() -> UbuntuStore<'static> {
    UbuntuStore {
        state: Path::new(STATE),
        parent: Path::new("/usr/local/share/ca-certificates"),
        certs: Path::new("/etc/ssl/certs"),
        bundle: Path::new("/etc/ssl/certs/ca-certificates.crt"),
    }
}

/// How a boot's delivered Ubuntu root set reached the system store.
#[derive(Debug, Eq, PartialEq)]
enum UbuntuInstall {
    /// The store already held exactly this set; nothing was rewritten.
    Current,
    /// The managed roots were replaced and update-ca-certificates rebuilt the store.
    Replaced,
}

/// Find `needle` at the start of any PEM block in `haystack`.
fn contains_pem(haystack: &[u8], needle: &[u8]) -> bool {
    const BEGIN: &[u8] = b"-----BEGIN CERTIFICATE-----";
    haystack
        .windows(BEGIN.len())
        .enumerate()
        .filter(|(_, window)| *window == BEGIN)
        .any(|(start, _)| haystack[start..].starts_with(needle))
}

// @cc [owner:ghuntley,label:security;recovery] guest-trust-ubuntu-verified-current
// A delivered Ubuntu root set MAY skip update-ca-certificates only when the
// installed marker equals its digest, the managed directory holds exactly
// overalls-0..N-1.crt as regular files byte-equal to the delivered roots in
// order, every root appears as a PEM block in the system bundle and every
// /etc/ssl/certs/overalls-I.pem link resolves to its managed file. Any other
// state takes the full replace path, which removes the marker before mutating
// and writes it only after update-ca-certificates succeeds, so a present
// marker always describes a completed store rebuild.
fn ubuntu_current(store: &UbuntuStore<'_>, roots: &[String], digest: &str) -> bool {
    let managed = store.parent.join("overalls-platform");
    let marker = fs::read(store.state.join("installed")).ok();
    let names = fs::read_dir(&managed).ok().and_then(|entries| {
        entries
            .map(|entry| entry.ok().map(|entry| entry.file_name()))
            .collect::<Option<Vec<_>>>()
    });
    let bundle = fs::read(store.bundle).ok();
    match (marker, names, bundle) {
        (Some(marker), Some(names), Some(bundle)) => {
            marker == digest.as_bytes()
                && names.len() == roots.len()
                && roots.iter().enumerate().all(|(index, root)| {
                    let file = managed.join(format!("overalls-{index}.crt"));
                    let link = store.certs.join(format!("overalls-{index}.pem"));
                    file.symlink_metadata().is_ok_and(|meta| meta.is_file())
                        && fs::read(&file).is_ok_and(|bytes| bytes == root.as_bytes())
                        && fs::read_link(&link).is_ok_and(|target| target == file)
                        && contains_pem(&bundle, root.as_bytes())
                })
        }
        _ => false,
    }
}

fn install_ubuntu(roots: &[String], digest: &str) -> io::Result<UbuntuInstall> {
    install_ubuntu_at(&ubuntu_store(), roots, digest, &|| {
        let status = Command::new("/usr/sbin/update-ca-certificates")
            .arg("--fresh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(io::Error::other("system trust unavailable"))
        }
    })
}

fn install_ubuntu_at(
    store: &UbuntuStore<'_>,
    roots: &[String],
    digest: &str,
    update: &dyn Fn() -> io::Result<()>,
) -> io::Result<UbuntuInstall> {
    if ubuntu_current(store, roots, digest) {
        return Ok(UbuntuInstall::Current);
    }
    let state = store.state;
    let parent = store.parent;
    let managed = parent.join("overalls-platform");
    fs::create_dir_all(state)?;
    fs::create_dir_all(parent)?;
    // The marker vouches for a completed rebuild; withdraw it before mutating.
    let installed = state.join("installed");
    if installed.symlink_metadata().is_ok() {
        fs::remove_file(&installed)?;
        sync_directory(state)?;
    }
    let staging = tempfile::Builder::new()
        .prefix(".trust-")
        .tempdir_in(parent)?;
    for (index, root) in roots.iter().enumerate() {
        write_sync(
            &staging.path().join(format!("overalls-{index}.crt")),
            root.as_bytes(),
        )?;
    }
    sync_directory(staging.path())?;
    // Previous roots must leave the directory scanned by update-ca-certificates.
    let old = state.join("previous");
    if old.exists() {
        fs::remove_dir_all(&old)?;
    }
    if managed.exists() {
        fs::rename(&managed, &old)?;
    }
    fs::rename(staging.keep(), &managed)?;
    fs::set_permissions(&managed, fs::Permissions::from_mode(0o755))?;
    for index in 0..roots.len() {
        fs::set_permissions(
            managed.join(format!("overalls-{index}.crt")),
            fs::Permissions::from_mode(0o644),
        )?;
    }
    sync_directory(&managed)?;
    sync_directory(parent)?;
    update()?;
    let system = fs::read(store.bundle)?;
    if system.is_empty()
        || !roots
            .iter()
            .all(|root| contains_pem(&system, root.as_bytes()))
    {
        return Err(io::Error::other("system trust unavailable"));
    }
    let marker = state.join("installed.next");
    write_sync(&marker, digest.as_bytes())?;
    fs::rename(marker, &installed)?;
    sync_directory(state)?;
    if old.exists() {
        fs::remove_dir_all(old)?;
    }
    Ok(UbuntuInstall::Replaced)
}

fn install(store: &Store, request: &Request) -> io::Result<()> {
    match store {
        Store::Nixos(base) => install_nixos(base, &request.roots, &request.bundle_digest),
        Store::Ubuntu => match install_ubuntu(&request.roots, &request.bundle_digest)? {
            UbuntuInstall::Current => {
                event("current");
                Ok(())
            }
            UbuntuInstall::Replaced => Ok(()),
        },
        Store::Linux(base) => install_linux(base, &request.roots, &request.bundle_digest),
    }
}

const LINUX_BUNDLE: &str = "/etc/ssl/certs/ca-certificates.crt";

/// Foreign Linux distributions do not share Debian's update helper. Publish
/// the verified base-plus-platform bundle atomically at the conventional path.
fn install_linux(base: &Path, roots: &[String], digest: &str) -> io::Result<()> {
    install_linux_at(
        base,
        roots,
        digest,
        Path::new(STATE),
        Path::new(LINUX_BUNDLE),
    )
}

fn install_linux_at(
    base: &Path,
    roots: &[String],
    digest: &str,
    state: &Path,
    bundle: &Path,
) -> io::Result<()> {
    install_nixos_at(base, roots, digest, state)?;
    let parent = bundle
        .parent()
        .ok_or_else(|| io::Error::other("invalid trust bundle path"))?;
    fs::create_dir_all(parent)?;
    if bundle.symlink_metadata().is_ok() {
        fs::remove_file(bundle)?;
    }
    symlink(state.join("current/ca-bundle.pem"), bundle)
}

fn read_frame(stream: &mut impl Read) -> io::Result<Request> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME {
        return Err(io::Error::other("invalid frame"));
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|_| io::Error::other("invalid frame"))
}

fn write_frame(stream: &mut impl Write, receipt: &Receipt<'_>) -> io::Result<()> {
    let body = serde_json::to_vec(receipt)?;
    let length = u32::try_from(body.len()).map_err(|_| io::Error::other("invalid frame"))?;
    stream.write_all(&length.to_be_bytes())?;
    stream.write_all(&body)
}

fn notify_ready() -> io::Result<()> {
    match std::env::var_os("NOTIFY_SOCKET") {
        Some(path) => {
            UnixDatagram::unbound()?.send_to(b"READY=1", PathBuf::from(path))?;
            Ok(())
        }
        None => Ok(()),
    }
}

fn listener() -> io::Result<RawFd> {
    // AF_VSOCK is independent of guest IP routing and the CA being installed.
    // SAFETY: socket takes only integer arguments and returns a new descriptor
    // or -1; no memory is shared with the kernel.
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "AF_VSOCK (40) fits sa_family_t (u16)"
    )]
    let address = libc::sockaddr_vm {
        svm_family: libc::AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: PORT,
        svm_cid: libc::VMADDR_CID_ANY,
        svm_zero: [0; 4],
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "sockaddr_vm is 16 bytes, far below socklen_t::MAX"
    )]
    // SAFETY: `address` is a fully initialised sockaddr_vm that outlives the
    // call, and the length passed is its exact size.
    let result = unsafe {
        libc::bind(
            fd,
            (&raw const address).cast(),
            size_of_val(&address) as libc::socklen_t,
        )
    };
    // SAFETY: `fd` is the socket created above and is still owned here.
    if result < 0 || unsafe { libc::listen(fd, 1) } < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: `fd` is owned here and is closed exactly once before return.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

fn serve(store: &Store, boot: &Boot) -> io::Result<()> {
    let fd = listener()?;
    event("awaiting");
    loop {
        // SAFETY: sockaddr_vm is plain old data; all-zero bytes are valid.
        let mut peer: libc::sockaddr_vm = unsafe { std::mem::zeroed() };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "sockaddr_vm is 16 bytes, far below socklen_t::MAX"
        )]
        let mut size = size_of_val(&peer) as libc::socklen_t;
        // SAFETY: `peer` and `size` are live, writable and correctly sized for
        // the address accept4 stores; `fd` is the listening socket.
        let connection = unsafe {
            libc::accept4(
                fd,
                (&raw mut peer).cast(),
                &raw mut size,
                libc::SOCK_CLOEXEC,
            )
        };
        if connection < 0 {
            continue;
        }
        // SAFETY: accept4 returned a new descriptor that nothing else owns;
        // the File takes sole ownership and closes it on drop.
        let mut stream = unsafe { File::from_raw_fd(connection) };
        let timeout = libc::timeval {
            tv_sec: 5,
            tv_usec: 0,
        };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "timeval is 16 bytes, far below socklen_t::MAX"
        )]
        // SAFETY: `timeout` is initialised, outlives the call and the length
        // is its exact size; `connection` is owned by `stream`.
        let receive_timeout = unsafe {
            libc::setsockopt(
                connection,
                libc::SOL_SOCKET,
                libc::SO_RCVTIMEO,
                (&raw const timeout).cast(),
                size_of_val(&timeout) as libc::socklen_t,
            )
        };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "timeval is 16 bytes, far below socklen_t::MAX"
        )]
        // SAFETY: as above, for the send timeout.
        let send_timeout = unsafe {
            libc::setsockopt(
                connection,
                libc::SOL_SOCKET,
                libc::SO_SNDTIMEO,
                (&raw const timeout).cast(),
                size_of_val(&timeout) as libc::socklen_t,
            )
        };
        if receive_timeout < 0 || send_timeout < 0 {
            event("rejected");
            continue;
        }
        if i32::from(peer.svm_family) != libc::AF_VSOCK || peer.svm_cid != libc::VMADDR_CID_HOST {
            event("rejected");
            continue;
        }
        let result = (|| -> io::Result<()> {
            let request = read_frame(&mut stream)?;
            validate(&request, boot)?;
            event("installing");
            install(store, &request)?;
            notify_ready()?;
            let receipt = Receipt {
                version: 1,
                state: "installed",
                placement_id: &boot.placement_id,
                execution_epoch: boot.execution_epoch,
                boot_challenge: &boot.boot_challenge,
                boot_id: &boot.boot_id,
                nonce: &request.nonce,
                bundle_digest: &request.bundle_digest,
            };
            write_frame(&mut stream, &receipt)?;
            event("installed");
            Ok(())
        })();
        if result.is_err() {
            event("failed");
        }
    }
}

/// @cc [owner:ghuntley,label:security] trustd-store-mode-closed
/// The trust daemon MUST accept only the explicit NixOS, Ubuntu or generic
/// Linux store modes and MUST reject missing, extra or non-absolute base
/// arguments before opening a vsock listener.
fn parse_store(args: &[String]) -> Option<Store> {
    Some(match args {
        [_, mode, base] if mode == "nixos" && Path::new(base).is_absolute() => {
            Store::Nixos(PathBuf::from(base))
        }
        // Arch and RPM based Linux guests use the same public CA layout as
        // Ubuntu after image assembly. Keep this explicit mode separate from
        // the Ubuntu compatibility name so image units cannot accidentally
        // select the NixOS store strategy or infer a layout from a filename.
        [_, mode] if mode == "ubuntu" => Store::Ubuntu,
        [_, mode, base] if mode == "linux" && Path::new(base).is_absolute() => {
            Store::Linux(PathBuf::from(base))
        }
        _ => return None,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(store) = parse_store(&args) else {
        std::process::exit(2);
    };
    if boot()
        .and_then(|identity| serve(&store, &identity))
        .is_err()
    {
        event("unavailable");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_linux_store_mode_is_explicit_and_closed() {
        let linux = vec!["trustd".into(), "linux".into(), "/etc/ssl/base.pem".into()];
        assert!(matches!(parse_store(&linux), Some(Store::Linux(_))));
        let ubuntu = vec!["trustd".into(), "ubuntu".into()];
        assert!(matches!(parse_store(&ubuntu), Some(Store::Ubuntu)));
        let nixos = vec!["trustd".into(), "nixos".into(), "/etc/ssl/base.pem".into()];
        assert!(matches!(parse_store(&nixos), Some(Store::Nixos(_))));
        for invalid in [
            vec!["trustd".into()],
            vec!["trustd".into(), "linux".into()],
            vec!["trustd".into(), "nixos".into(), "relative.pem".into()],
            vec!["trustd".into(), "unknown".into()],
        ] {
            assert!(parse_store(&invalid).is_none());
        }
    }

    const ROOT: &str = "-----BEGIN CERTIFICATE-----\nMIIBtzCCAV6gAwIBAgIUOpitPww4NwgxuzwC1oxPB/Gpg8MwCgYIKoZIzj0EAwIw\nKDEmMCQGA1UEAwwdS2l0dGVucyBCcmFkeSBGbGVldCBSb290IDIwMjYwHhcNMjYw\nOTIzMTYyMDM1WhcNNDYwOTIzMTYyMDM1WjAoMSYwJAYDVQQDDB1LaXR0ZW5zIEJy\nYWR5IEZsZWV0IFJvb3QgMjAyNjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMib\nHDeGFDKi39ig2QB1+aWXNuAXAwY91rGVo+rzQShaFqC67Y9ddhyaTQvaDXX4ujEJ\nVpIJT81ni4fsMmCUsVGjZjBkMB8GA1UdIwQYMBaAFLau7cHyiye1Ox9U1K/ORgkj\nTBnZMBIGA1UdEwEB/wQIMAYBAf8CAQEwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQW\nBBS2ru3B8osntTsfVNSvzkYJI0wZ2TAKBggqhkjOPQQDAgNHADBEAiBfYDBSWPjH\nrS4wtatDxLgxzIEwndQ/I+YOZm9PvBIvWgIgbCEL0DvCPBRFxZvd+suKe5H4/KTA\ntLwIGKUFzyRgGgE=\n-----END CERTIFICATE-----\n";

    fn example() -> (Boot, Request) {
        let boot = Boot {
            placement_id: "11111111-1111-4111-8111-111111111111".into(),
            execution_epoch: 1,
            boot_challenge: "a".repeat(64),
            boot_id: "22222222-2222-4222-8222-222222222222".into(),
        };
        let fingerprint = Sha256::digest(ROOT.as_bytes());
        let request = Request {
            version: 1,
            placement_id: boot.placement_id.clone(),
            execution_epoch: boot.execution_epoch,
            boot_challenge: boot.boot_challenge.clone(),
            nonce: "b".repeat(64),
            bundle_digest: hex::encode(Sha256::digest(fingerprint)),
            roots: vec![ROOT.into()],
        };
        (boot, request)
    }

    #[test]
    fn only_exact_boot_and_root_set_validate() {
        let (boot, mut request) = example();
        assert!(validate(&request, &boot).is_ok());
        request.execution_epoch += 1;
        assert!(validate(&request, &boot).is_err());
        request.execution_epoch -= 1;
        request.roots.push(ROOT.into());
        assert!(validate(&request, &boot).is_err());
        request.roots.pop();
        request.bundle_digest = "0".repeat(64);
        assert!(validate(&request, &boot).is_err());
    }

    #[test]
    fn rejects_wrong_boot_and_empty_roots() {
        let boot = Boot {
            placement_id: "11111111-1111-4111-8111-111111111111".into(),
            execution_epoch: 1,
            boot_challenge: "a".repeat(64),
            boot_id: "22222222-2222-4222-8222-222222222222".into(),
        };
        let request = Request {
            version: 1,
            placement_id: boot.placement_id.clone(),
            execution_epoch: 1,
            boot_challenge: boot.boot_challenge.clone(),
            nonce: "b".repeat(64),
            bundle_digest: "c".repeat(64),
            roots: vec![],
        };
        assert!(validate(&request, &boot).is_err());
    }

    #[test]
    fn bounded_frames_reject_every_truncated_length_prefix() {
        for length in [0, MAX_FRAME + 1] {
            let input = u32::try_from(length).unwrap().to_be_bytes().to_vec();
            assert!(read_frame(&mut input.as_slice()).is_err());
        }
        for size in 1..64_u32 {
            let mut bytes = size.to_be_bytes().to_vec();
            bytes.extend(std::iter::repeat_n(b' ', (size - 1) as usize));
            assert!(read_frame(&mut bytes.as_slice()).is_err());
        }
    }

    #[test]
    fn boot_identity_shapes_reject_mutation_at_every_position() {
        let challenge = "a".repeat(64);
        for index in 0..challenge.len() {
            let mut mutation = challenge.clone().into_bytes();
            mutation[index] = b'z';
            assert!(!valid_hex(std::str::from_utf8(&mutation).unwrap(), 64));
        }
        let placement = "11111111-1111-4111-8111-111111111111";
        for index in [8, 13, 18, 23] {
            let mut mutation = placement.as_bytes().to_vec();
            mutation[index] = b'1';
            assert!(!valid_uuid(std::str::from_utf8(&mutation).unwrap()));
        }
    }

    const OTHER: &str = "-----BEGIN CERTIFICATE-----\nb3RoZXI=\n-----END CERTIFICATE-----\n";

    struct Fixture {
        _root: tempfile::TempDir,
        state: PathBuf,
        parent: PathBuf,
        certs: PathBuf,
        bundle: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let root = tempfile::tempdir().unwrap();
            let state = root.path().join("state");
            let parent = root.path().join("ca-certificates");
            let certs = root.path().join("certs");
            fs::create_dir_all(&certs).unwrap();
            let bundle = certs.join("ca-certificates.crt");
            fs::write(
                &bundle,
                "-----BEGIN CERTIFICATE-----\ndistro\n-----END CERTIFICATE-----\n",
            )
            .unwrap();
            Fixture {
                _root: root,
                state,
                parent,
                certs,
                bundle,
            }
        }

        fn store(&self) -> UbuntuStore<'_> {
            UbuntuStore {
                state: &self.state,
                parent: &self.parent,
                certs: &self.certs,
                bundle: &self.bundle,
            }
        }

        /// Emulates update-ca-certificates --fresh: drop every overalls link,
        /// relink the managed roots and rebuild the bundle with them appended.
        fn update(&self, calls: &std::cell::Cell<u32>) -> io::Result<()> {
            calls.set(calls.get() + 1);
            for entry in fs::read_dir(&self.certs)? {
                let path = entry?.path();
                if path
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("overalls-")
                {
                    fs::remove_file(path)?;
                }
            }
            let mut bundle =
                b"-----BEGIN CERTIFICATE-----\ndistro\n-----END CERTIFICATE-----\n".to_vec();
            let managed = self.parent.join("overalls-platform");
            let mut names: Vec<_> = fs::read_dir(&managed)?
                .map(|entry| entry.unwrap().file_name())
                .collect();
            names.sort();
            for name in names {
                let file = managed.join(&name);
                let stem = name.to_string_lossy().trim_end_matches(".crt").to_owned();
                symlink(&file, self.certs.join(format!("{stem}.pem")))?;
                bundle.extend(fs::read(&file)?);
            }
            fs::write(&self.bundle, bundle)
        }

        fn install(
            &self,
            roots: &[String],
            calls: &std::cell::Cell<u32>,
        ) -> io::Result<UbuntuInstall> {
            let digest = hex::encode(Sha256::digest(roots.concat()));
            install_ubuntu_at(&self.store(), roots, &digest, &|| self.update(calls))
        }
    }

    #[test]
    fn ubuntu_identical_delivery_is_a_verified_no_op() {
        let fixture = Fixture::new();
        let calls = std::cell::Cell::new(0);
        let roots = vec![ROOT.to_owned(), OTHER.to_owned()];
        assert_eq!(
            fixture.install(&roots, &calls).unwrap(),
            UbuntuInstall::Replaced
        );
        assert_eq!(calls.get(), 1);
        let bundle = fs::read(&fixture.bundle).unwrap();
        assert_eq!(
            fixture.install(&roots, &calls).unwrap(),
            UbuntuInstall::Current
        );
        assert_eq!(
            calls.get(),
            1,
            "a current store MUST NOT rerun update-ca-certificates"
        );
        assert_eq!(fs::read(&fixture.bundle).unwrap(), bundle);
    }

    #[test]
    fn ubuntu_rotation_and_every_drift_take_the_full_path() {
        let fixture = Fixture::new();
        let calls = std::cell::Cell::new(0);
        let both = vec![ROOT.to_owned(), OTHER.to_owned()];
        let one = vec![ROOT.to_owned()];
        fixture.install(&both, &calls).unwrap();
        // Rotation removes the second root's file, link and bundle block.
        assert_eq!(
            fixture.install(&one, &calls).unwrap(),
            UbuntuInstall::Replaced
        );
        let managed = fixture.parent.join("overalls-platform");
        assert!(!managed.join("overalls-1.crt").exists());
        assert!(fs::read_link(fixture.certs.join("overalls-1.pem")).is_err());
        assert!(!contains_pem(
            &fs::read(&fixture.bundle).unwrap(),
            OTHER.as_bytes()
        ));
        assert_eq!(
            fixture.install(&one, &calls).unwrap(),
            UbuntuInstall::Current
        );

        let drifts: [&dyn Fn(); 5] = [
            &|| fs::write(managed.join("overalls-0.crt"), OTHER).unwrap(),
            &|| fs::write(managed.join("extra.crt"), OTHER).unwrap(),
            &|| fs::write(&fixture.bundle, "").unwrap(),
            &|| fs::remove_file(fixture.certs.join("overalls-0.pem")).unwrap(),
            &|| fs::write(fixture.state.join("installed"), "0".repeat(64)).unwrap(),
        ];
        for drift in drifts {
            let before = calls.get();
            drift();
            assert_eq!(
                fixture.install(&one, &calls).unwrap(),
                UbuntuInstall::Replaced
            );
            assert_eq!(calls.get(), before + 1);
            assert_eq!(
                fixture.install(&one, &calls).unwrap(),
                UbuntuInstall::Current
            );
        }
    }

    #[test]
    fn ubuntu_failed_rebuild_withdraws_the_marker() {
        let fixture = Fixture::new();
        let calls = std::cell::Cell::new(0);
        let one = vec![ROOT.to_owned()];
        fixture.install(&one, &calls).unwrap();
        let both = vec![ROOT.to_owned(), OTHER.to_owned()];
        let digest = hex::encode(Sha256::digest(both.concat()));
        let failed = install_ubuntu_at(&fixture.store(), &both, &digest, &|| {
            Err(io::Error::other("update failed"))
        });
        assert!(failed.is_err());
        assert!(!fixture.state.join("installed").exists());
        // Neither the old nor the new set may now pass as current.
        assert_eq!(
            fixture.install(&one, &calls).unwrap(),
            UbuntuInstall::Replaced
        );
    }

    #[test]
    fn installed_bundle_is_publicly_readable_and_repairs_old_modes() {
        let temporary = tempfile::tempdir().unwrap();
        let base = temporary.path().join("base.pem");
        fs::write(&base, ROOT).unwrap();
        let state = temporary.path().join("state");
        let digest = "a".repeat(64);
        install_nixos_at(&base, &[ROOT.into()], &digest, &state).unwrap();
        let destination = state.join(format!("bundle-{digest}"));
        let bundle = destination.join("ca-bundle.pem");
        assert_eq!(
            fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert_eq!(
            fs::metadata(&bundle).unwrap().permissions().mode() & 0o777,
            0o644
        );
        fs::set_permissions(&destination, fs::Permissions::from_mode(0o700)).unwrap();
        install_nixos_at(&base, &[ROOT.into()], &digest, &state).unwrap();
        assert_eq!(
            fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }
}
