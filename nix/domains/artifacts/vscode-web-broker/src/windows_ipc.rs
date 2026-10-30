//! Fixed local SYSTEM stream transport between the gateway and job custodian.
use crate::Refusal;
use crate::windows::{SystemPeer, package_file, require_system, system_pipe};
use crate::windows_model::{LocalPath, ProcessIdentity};
use crate::windows_pipe::Pipe;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::FromRawHandle;
use std::ptr::null_mut;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{INVALID_HANDLE_VALUE, LocalFree};
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX,
    SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Pipes::{
    CreateNamedPipeW, GetNamedPipeClientProcessId, GetNamedPipeServerProcessId, PIPE_READMODE_BYTE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    WaitNamedPipeW,
};

const EXECUTABLE: &str = r"C:\overalls\editor-broker\overalls-vscode-web-broker.exe";
const HELLO_LIMIT: usize = 128;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    version: u8,
    process: ProcessIdentity,
}

pub fn executable() -> Result<LocalPath, Refusal> {
    require_system()?;
    let expected = LocalPath::parse(EXECUTABLE)?;
    package_file(&expected)?;
    let current = std::env::current_exe().map_err(|_| Refusal::Package)?;
    if !current
        .to_str()
        .is_some_and(|path| path.eq_ignore_ascii_case(EXECUTABLE))
    {
        return Err(Refusal::Package);
    }
    Ok(expected)
}

pub fn name(physical_key: &str) -> Result<String, Refusal> {
    if !crate::hex(physical_key, 64) {
        return Err(Refusal::Boot);
    }
    Ok(format!(
        r"\\.\pipe\overalls-editor-custodian-{physical_key}"
    ))
}

/// @cc [owner:ghuntley,label:security] windows-custodian-local-endpoint
/// The first protected SYSTEM-only pipe instance MUST reserve the fixed boot
/// name before accepting requests. Remote clients MUST be rejected by the
/// kernel. No request may choose a pipe path, ACL, executable or process token.
pub fn listener(name: &str, first: bool) -> Result<Pipe, Refusal> {
    let reservation = Pipe::reserve().map_err(|_| Refusal::Capacity)?;
    let sddl: Vec<u16> = "O:SYG:SYD:P(A;;FA;;;SY)"
        .encode_utf16()
        .chain([0])
        .collect();
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
    let name: Vec<u16> = name.encode_utf16().chain([0]).collect();
    // SAFETY: `name` is a live NUL-terminated UTF-16 string and `attributes` points to the converted descriptor, both live for the call.
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX
                | FILE_FLAG_OVERLAPPED
                | if first {
                    FILE_FLAG_FIRST_PIPE_INSTANCE
                } else {
                    0
                },
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            65536,
            65536,
            0,
            &raw const attributes,
        )
    };
    // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
    unsafe { LocalFree(descriptor) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(Refusal::Custody);
    }
    // SAFETY: the newly created non-inheritable handle belongs to this listener.
    Pipe::from_file(unsafe { File::from_raw_handle(handle) }, reservation)
        .map_err(|_| Refusal::Transport)
}

pub fn connect(name: &str, deadline: Instant) -> Result<Pipe, Refusal> {
    let reservation = Pipe::reserve().map_err(|_| Refusal::Capacity)?;
    let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
    let wait = deadline
        .saturating_duration_since(Instant::now())
        .min(Duration::from_secs(2));
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the wait is capped at two seconds"
    )]
    let milliseconds = wait.as_millis() as u32;
    // SAFETY: `wide` is a live NUL-terminated UTF-16 pipe name.
    if wait.is_zero() || unsafe { WaitNamedPipeW(wide.as_ptr(), milliseconds) } == 0 {
        return Err(Refusal::Readiness);
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION)
        .open(name)
        .map_err(|_| Refusal::Transport)?;
    Pipe::from_file(file, reservation).map_err(|_| Refusal::Transport)
}

#[derive(Debug)]
pub struct Deadline<'a> {
    pub pipe: &'a mut Pipe,
    pub deadline: Instant,
}
impl Read for Deadline<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.pipe.read_deadline(bytes, self.deadline)
    }
}
impl Write for Deadline<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.pipe.write_deadline(bytes, self.deadline)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub fn write_frame<T: Serialize>(
    pipe: &mut Pipe,
    value: &T,
    maximum: usize,
    deadline: Instant,
) -> Result<(), Refusal> {
    let bytes = serde_json::to_vec(value).map_err(|_| Refusal::Frame)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Frame);
    }
    let length = u32::try_from(bytes.len()).map_err(|_| Refusal::Frame)?;
    let mut io = Deadline { pipe, deadline };
    io.write_all(&length.to_be_bytes())
        .and_then(|()| io.write_all(&bytes))
        .map_err(|_| Refusal::Transport)
}

pub fn read_frame<T: DeserializeOwned>(
    pipe: &mut Pipe,
    maximum: usize,
    deadline: Instant,
) -> Result<T, Refusal> {
    let mut io = Deadline { pipe, deadline };
    let mut length = [0_u8; 4];
    io.read_exact(&mut length).map_err(|_| Refusal::Frame)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > maximum {
        return Err(Refusal::Frame);
    }
    let mut bytes = vec![0; length];
    io.read_exact(&mut bytes).map_err(|_| Refusal::Frame)?;
    serde_json::from_slice(&bytes).map_err(|_| Refusal::Frame)
}

fn peer_pid(pipe: &Pipe, server: bool) -> Result<u32, Refusal> {
    let handle = pipe.raw_handle().map_err(|_| Refusal::Custody)?;
    let mut pid = 0;
    let result = if server {
        // SAFETY: the pipe handle is open for the borrow of `pipe` and `pid` is a live writable local.
        unsafe { GetNamedPipeClientProcessId(handle, &raw mut pid) }
    } else {
        // SAFETY: the pipe handle is open for the borrow of `pipe` and `pid` is a live writable local.
        unsafe { GetNamedPipeServerProcessId(handle, &raw mut pid) }
    };
    if result == 0 || pid == 0 {
        return Err(Refusal::Custody);
    }
    Ok(pid)
}

/// @cc [owner:ghuntley,label:security] windows-custodian-mutual-kernel-peer
/// Both peers MUST pin the kernel pipe PID with an open process handle and
/// validate its creation time, SYSTEM token and fixed installed executable.
/// The closed versioned hello MUST match that kernel identity. Neither side
/// may impersonate the other or accept a caller-supplied process as authority.
pub fn authenticate(
    pipe: &mut Pipe,
    server: bool,
    executable: &LocalPath,
    deadline: Instant,
) -> Result<SystemPeer, Refusal> {
    system_pipe(pipe)?;
    let peer = SystemPeer::open(peer_pid(pipe, server)?, executable)?;
    let own = SystemPeer::open(std::process::id(), executable)?;
    write_frame(
        pipe,
        &Hello {
            version: 1,
            process: own.identity(),
        },
        HELLO_LIMIT,
        deadline,
    )?;
    let hello: Hello = read_frame(pipe, HELLO_LIMIT, deadline)?;
    if hello.version != 1
        || hello.process != peer.identity()
        || peer_pid(pipe, server)? != peer.identity().pid
    {
        return Err(Refusal::Custody);
    }
    peer.verify(executable)?;
    Ok(peer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn test_endpoint() -> String {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        name(&format!(
            "{:032x}{:032x}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
        .unwrap()
    }

    #[test]
    fn native_local_endpoint_is_exclusive_and_system_only() {
        require_system().expect("native custody tests require SYSTEM");
        let endpoint = test_endpoint();
        let pipe = listener(&endpoint, true).unwrap();
        system_pipe(&pipe).unwrap();
        assert!(matches!(listener(&endpoint, true), Err(Refusal::Custody)));
    }

    #[test]
    fn native_peer_handshake_refuses_forged_creation_time() {
        require_system().expect("native custody tests require SYSTEM");
        let executable =
            LocalPath::parse(std::env::current_exe().unwrap().to_str().unwrap()).unwrap();
        let endpoint = test_endpoint();
        let mut server = listener(&endpoint, true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let mut client = connect(&endpoint, deadline).unwrap();
                let _: Hello = read_frame(&mut client, HELLO_LIMIT, deadline).unwrap();
                let mut identity = SystemPeer::open(std::process::id(), &executable)
                    .unwrap()
                    .identity();
                identity.created += 1;
                write_frame(
                    &mut client,
                    &Hello {
                        version: 1,
                        process: identity,
                    },
                    HELLO_LIMIT,
                    deadline,
                )
                .unwrap();
            });
            server.accept().unwrap();
            assert!(matches!(
                authenticate(&mut server, true, &executable, deadline),
                Err(Refusal::Custody)
            ));
        });
    }

    #[test]
    fn native_peers_complete_exact_identity_handshake_before_stream_bytes() {
        require_system().expect("native custody tests require SYSTEM");
        let executable =
            LocalPath::parse(std::env::current_exe().unwrap().to_str().unwrap()).unwrap();
        let endpoint = test_endpoint();
        let mut server = listener(&endpoint, true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let mut client = connect(&endpoint, deadline).unwrap();
                let peer = authenticate(&mut client, false, &executable, deadline).unwrap();
                assert_eq!(peer.identity().pid, std::process::id());
                write_frame(&mut client, &7_u32, 128, deadline).unwrap();
            });
            server.accept().unwrap();
            let peer = authenticate(&mut server, true, &executable, deadline).unwrap();
            assert_eq!(peer.identity().pid, std::process::id());
            assert_eq!(read_frame::<u32>(&mut server, 128, deadline).unwrap(), 7);
        });
    }
}
