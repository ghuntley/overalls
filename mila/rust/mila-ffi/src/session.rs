//! Blocking native session entry points. Call from a native worker thread.
use mila_session::ApplicationSession;
use mila_transport::{
    decode_trust_document,
    ssh::{DeviceSigner, PtyChunk, PtySession, SshError},
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// Status codes never include command bodies, signatures or credentials.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStatus {
    Ok = 0,
    Invalid = -4,
    SmallBuffer = -3,
    InvalidHandle = -10,
    Transport = -11,
    NotLoaded = -12,
    Busy = -13,
    Internal = -14,
}
/// Callback runs synchronously during connect; sign SHA256(message) with P256.
/// Write exactly 64 bytes of big-endian r||s and return zero for success.
pub type SignCallback = unsafe extern "C" fn(usize, *const u8, usize, *mut u8) -> i32;
struct CallbackSigner {
    callback: SignCallback,
    context: usize,
}
impl DeviceSigner for CallbackSigner {
    async fn sign(&mut self, message: &[u8]) -> Result<[u8; 64], SshError> {
        let mut signature = [0; 64];
        // SAFETY: connect caller guarantees the callback/context for its duration.
        if unsafe {
            (self.callback)(
                self.context,
                message.as_ptr(),
                message.len(),
                signature.as_mut_ptr(),
            )
        } != 0
        {
            return Err(SshError::Signature);
        }
        Ok(signature)
    }
}
struct Entry {
    session: ApplicationSession,
}
struct TerminalEntry {
    owner: u64,
    terminal: PtySession,
}
#[derive(Default)]
struct Registry {
    next: u64,
    entries: HashMap<u64, Arc<Mutex<Option<Entry>>>>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
#[derive(Default)]
struct TerminalRegistry {
    next: u64,
    entries: HashMap<u64, Arc<Mutex<Option<TerminalEntry>>>>,
}
static TERMINALS: OnceLock<Mutex<TerminalRegistry>> = OnceLock::new();
static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, std::io::Error>> = OnceLock::new();
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(Mutex::default)
}
fn terminals() -> &'static Mutex<TerminalRegistry> {
    TERMINALS.get_or_init(Mutex::default)
}
fn terminal_entry(handle: u64) -> Result<Arc<Mutex<Option<TerminalEntry>>>, SessionStatus> {
    terminals()
        .lock()
        .map_err(|_| SessionStatus::Internal)?
        .entries
        .get(&handle)
        .cloned()
        .ok_or(SessionStatus::InvalidHandle)
}

/// Remove every terminal capability owned by a closing parent session before
/// disconnecting that session. This fences terminal operations that could
/// otherwise outlive their authenticated SSH connection.
fn take_owned_terminals(owner: u64) -> Result<Vec<PtySession>, SessionStatus> {
    let candidates = terminals()
        .lock()
        .map_err(|_| SessionStatus::Internal)?
        .entries
        .iter()
        .map(|(handle, entry)| (*handle, entry.clone()))
        .collect::<Vec<_>>();
    let mut collected = Vec::with_capacity(candidates.len());
    for (handle, entry) in candidates {
        let owned = entry
            .try_lock()
            .map_err(|_| SessionStatus::Busy)?
            .as_ref()
            .is_some_and(|value| value.owner == owner);
        if !owned {
            continue;
        }
        let removed = terminals()
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .entries
            .remove(&handle);
        if let Some(removed) = removed {
            let mut guard = removed.try_lock().map_err(|_| SessionStatus::Busy)?;
            if let Some(entry) = guard.take() {
                collected.push(entry.terminal);
            }
        }
    }
    Ok(collected)
}
fn runtime() -> Result<&'static tokio::runtime::Runtime, SessionStatus> {
    if tokio::runtime::Handle::try_current().is_ok() {
        return Err(SessionStatus::Busy);
    }
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
        })
        .as_ref()
        .map_err(|_| SessionStatus::Internal)
}
fn guarded(f: impl FnOnce() -> Result<(), SessionStatus>) -> SessionStatus {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).map_or(SessionStatus::Internal, |r| {
        r.err().unwrap_or(SessionStatus::Ok)
    })
}
unsafe fn bytes<'a>(ptr: *const u8, len: usize, max: usize) -> Result<&'a [u8], SessionStatus> {
    if ptr.is_null() || len == 0 || len > max {
        return Err(SessionStatus::Invalid);
    }
    Ok(std::slice::from_raw_parts(ptr, len))
}
fn entry(handle: u64) -> Result<Arc<Mutex<Option<Entry>>>, SessionStatus> {
    registry()
        .lock()
        .map_err(|_| SessionStatus::Internal)?
        .entries
        .get(&handle)
        .cloned()
        .ok_or(SessionStatus::InvalidHandle)
}
unsafe fn output(
    data: &[u8],
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> Result<(), SessionStatus> {
    if written.is_null() {
        return Err(SessionStatus::Invalid);
    }
    *written = data.len();
    if capacity < data.len() {
        return Err(SessionStatus::SmallBuffer);
    }
    if out.is_null() {
        return Err(SessionStatus::Invalid);
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), out, data.len());
    Ok(())
}
/// @cc [owner:ghuntley,label:security] mila-session-ffi-authentication
/// Connect MUST validate a bounded trust document and host certificate before invoking
/// the external signer. It MUST NOT retain callback context after returning or expose private keys.
/// # Safety
/// Input pointers reference their declared readable lengths; out_handle is writable.
/// Callback and context remain valid until return and must not unwind or retain message pointers.
/// The caller supplies its previously pinned trust document, not unreviewed replacement trust.
#[no_mangle]
pub unsafe extern "C" fn mila_session_connect(
    trust: *const u8,
    trust_len: usize,
    host: *const u8,
    host_len: usize,
    public_key: *const u8,
    public_key_len: usize,
    port: u16,
    timeout_ms: u32,
    callback: Option<SignCallback>,
    context: usize,
    out_handle: *mut u64,
) -> SessionStatus {
    guarded(|| {
        if out_handle.is_null() {
            return Err(SessionStatus::Invalid);
        }
        *out_handle = 0;
        if port == 0 || !(1..=120_000).contains(&timeout_ms) {
            return Err(SessionStatus::Invalid);
        }
        let host =
            std::str::from_utf8(bytes(host, host_len, 180)?).map_err(|_| SessionStatus::Invalid)?;
        let public = std::str::from_utf8(bytes(public_key, public_key_len, 1024)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| SessionStatus::Internal)?
            .as_secs();
        let trust = decode_trust_document(bytes(trust, trust_len, 8192)?, host, now)
            .map_err(|_| SessionStatus::Invalid)?;
        let signer = CallbackSigner {
            callback: callback.ok_or(SessionStatus::Invalid)?,
            context,
        };
        let runtime = runtime()?;
        let session = runtime
            .block_on(ApplicationSession::connect(
                trust,
                port,
                public,
                signer,
                Duration::from_millis(timeout_ms.into()),
            ))
            .map_err(|_| SessionStatus::Transport)?;
        let mut registry = registry().lock().map_err(|_| SessionStatus::Internal)?;
        if registry.entries.len() >= 64 {
            return Err(SessionStatus::Busy);
        }
        let id = registry
            .next
            .checked_add(1)
            .ok_or(SessionStatus::Internal)?;
        registry.next = id;
        registry
            .entries
            .insert(id, Arc::new(Mutex::new(Some(Entry { session }))));
        *out_handle = id;
        Ok(())
    })
}
/// Refresh (more=0) or continue (more=1) a validated machine listing.
/// Use listing separately to copy results without repeating network operations.
#[no_mangle]
pub extern "C" fn mila_session_read_machines(handle: u64, more: u8) -> SessionStatus {
    guarded(|| {
        if more > 1 {
            return Err(SessionStatus::Invalid);
        }
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(async {
                if more == 1 {
                    session.more_machines().await
                } else {
                    session.refresh_machines().await
                }
            })
            .map_err(|_| SessionStatus::Transport)?;
        Ok(())
    })
}

/// Execute a bounded authenticated machine mutation on an existing session.
/// Inputs are UTF-8 and never interpreted by a shell; the session constructs a
/// catalogued Porsche command and requires a caller supplied request id.
#[no_mangle]
pub unsafe extern "C" fn mila_session_machine_action(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    action: *const u8,
    action_len: usize,
    request_id: *const u8,
    request_id_len: usize,
) -> SessionStatus {
    guarded(|| {
        let machine = std::str::from_utf8(bytes(machine, machine_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let action = std::str::from_utf8(bytes(action, action_len, 32)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let request_id = std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.machine_action(machine, action, request_id))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                mila_session::SessionError::MutationRefused => SessionStatus::Invalid,
                _ => SessionStatus::Invalid,
            })?;
        Ok(())
    })
}

/// Execute an authenticated bounded machine creation.
#[no_mangle]
pub unsafe extern "C" fn mila_session_machine_create(
    handle: u64,
    name: *const u8,
    name_len: usize,
    cpu: u32,
    memory: u64,
    disk: u64,
    request_id: *const u8,
    request_id_len: usize,
) -> SessionStatus {
    guarded(|| {
        let name =
            std::str::from_utf8(bytes(name, name_len, 128)?).map_err(|_| SessionStatus::Invalid)?;
        let request_id = std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.machine_create(name, cpu, memory, disk, request_id))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}

/// Execute a bounded authenticated machine resize.
#[no_mangle]
pub unsafe extern "C" fn mila_session_machine_resize(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    cpu: u32,
    memory: u64,
    disk: u64,
    request_id: *const u8,
    request_id_len: usize,
) -> SessionStatus {
    guarded(|| {
        let machine = std::str::from_utf8(bytes(machine, machine_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let request_id = std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.machine_resize(machine, cpu, memory, disk, request_id))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                mila_session::SessionError::MutationRefused => SessionStatus::Invalid,
                _ => SessionStatus::Invalid,
            })
    })
}

/// Execute an authenticated sharing mutation. `add` selects add/remove; role is
/// required for add and must be null for remove. All strings are bounded UTF-8.
#[no_mangle]
pub unsafe extern "C" fn mila_session_share_mutation(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    email: *const u8,
    email_len: usize,
    role: *const u8,
    role_len: usize,
    add: u8,
    request_id: *const u8,
    request_id_len: usize,
) -> SessionStatus {
    guarded(|| {
        if add > 1 || (add == 0 && role_len != 0) {
            return Err(SessionStatus::Invalid);
        }
        let machine = std::str::from_utf8(bytes(machine, machine_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let email = std::str::from_utf8(bytes(email, email_len, 320)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let role = if role_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(role, role_len, 32)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let request_id = std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.share_mutation(machine, email, role, add == 1, request_id))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}

/// Execute a bounded authenticated thread action. `command` is one of the
/// closed thread command names; identifiers and payloads are validated by the
/// session before a single SSH channel is opened.
#[no_mangle]
pub unsafe extern "C" fn mila_session_thread_action(
    handle: u64,
    thread: *const u8,
    thread_len: usize,
    command: *const u8,
    command_len: usize,
    secondary: *const u8,
    secondary_len: usize,
    input: *const u8,
    input_len: usize,
    request_id: *const u8,
    request_id_len: usize,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let thread = if thread_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(thread, thread_len, 128)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let command = std::str::from_utf8(bytes(command, command_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let secondary = if secondary_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(secondary, secondary_len, 128)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let input = if input_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(input, input_len, 64 * 1024)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let request = if request_id_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime
            .block_on(session.thread_action(thread, command, secondary, input, request))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })?;
        output(&data, out, capacity, written)
    })
}

#[no_mangle]
pub unsafe extern "C" fn mila_session_ssh_keys(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime.block_on(session.ssh_keys()).map_err(|e| match e {
            mila_session::SessionError::Transport(_) => SessionStatus::Transport,
            _ => SessionStatus::Invalid,
        })?;
        output(&data, out, capacity, written)
    })
}

/// Return the bounded `whoami --json` envelope, including approval-required
/// replies whose command exit status is non-zero.
#[no_mangle]
pub unsafe extern "C" fn mila_session_whoami(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime.block_on(session.whoami()).map_err(|e| match e {
            mila_session::SessionError::Transport(_) => SessionStatus::Transport,
            _ => SessionStatus::Invalid,
        })?;
        output(&data, out, capacity, written)
    })
}

#[no_mangle]
pub unsafe extern "C" fn mila_session_ssh_key_revoke(
    handle: u64,
    key: *const u8,
    key_len: usize,
    request: *const u8,
    request_len: usize,
) -> SessionStatus {
    guarded(|| {
        let key =
            std::str::from_utf8(bytes(key, key_len, 128)?).map_err(|_| SessionStatus::Invalid)?;
        let request = std::str::from_utf8(bytes(request, request_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.ssh_key_revoke(key, request))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn mila_session_web_show(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let machine = std::str::from_utf8(bytes(machine, machine_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime
            .block_on(session.web_show(machine))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })?;
        output(&data, out, capacity, written)
    })
}

#[no_mangle]
pub unsafe extern "C" fn mila_session_web_set(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    port: u16,
    public: u8,
    revision: u64,
    request_id: *const u8,
    request_id_len: usize,
) -> SessionStatus {
    guarded(|| {
        if public > 1 {
            return Err(SessionStatus::Invalid);
        }
        let machine = std::str::from_utf8(bytes(machine, machine_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let request_id = std::str::from_utf8(bytes(request_id, request_id_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.web_set(machine, port, public == 1, revision, request_id))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}

/// Read the authenticated caller's notification devices.
#[no_mangle]
pub unsafe extern "C" fn mila_session_device_ls(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime.block_on(session.device_ls()).map_err(|e| match e {
            mila_session::SessionError::Transport(_) => SessionStatus::Transport,
            _ => SessionStatus::Invalid,
        })?;
        output(&data, out, capacity, written)
    })
}

/// Register this device for push notifications. `susan_reply` is Susan's
/// key-issuance JSON; Rust validates it (closed members, base64url push key,
/// unexpired ISO-8601 `expires_at`) and sends the push key to Porsche on stdin
/// only. `platform`: 0=iOS, 1=Android, 2=macOS, 3=Windows. A zero-length label
/// is omitted. The bounded Porsche JSON result is copied to `out`.
///
/// # Safety
/// Input pointers reference their declared readable lengths (`label` may be
/// null when `label_len` is zero); `out`/`written` follow [`mila_session_listing`].
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn mila_session_device_register(
    handle: u64,
    platform: u8,
    susan_reply: *const u8,
    susan_reply_len: usize,
    enc_pubkey: *const u8,
    enc_pubkey_len: usize,
    label: *const u8,
    label_len: usize,
    now: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let platform = match platform {
            0 => mila_model::DevicePlatform::Ios,
            1 => mila_model::DevicePlatform::Android,
            2 => mila_model::DevicePlatform::Macos,
            3 => mila_model::DevicePlatform::Windows,
            _ => return Err(SessionStatus::Invalid),
        };
        let reply = mila_runtime::PushRegistrationReply::decode_susan(
            bytes(susan_reply, susan_reply_len, 4096)?,
            now,
        )
        .map_err(|_| SessionStatus::Invalid)?;
        let enc_pubkey = std::str::from_utf8(bytes(enc_pubkey, enc_pubkey_len, 64)?)
            .map_err(|_| SessionStatus::Invalid)?;
        if !mila_protocol::device_public_key_valid(enc_pubkey) {
            return Err(SessionStatus::Invalid);
        }
        let label = if label_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(bytes(label, label_len, 256)?)
                    .map_err(|_| SessionStatus::Invalid)?,
            )
        };
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = runtime
            .block_on(session.device_register(platform, &reply.push_key, enc_pubkey, label))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })?;
        output(&data, out, capacity, written)
    })
}

/// Revoke one authenticated caller-owned notification device.
#[no_mangle]
pub unsafe extern "C" fn mila_session_device_rm(
    handle: u64,
    device: *const u8,
    device_len: usize,
) -> SessionStatus {
    guarded(|| {
        let device = std::str::from_utf8(bytes(device, device_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.device_rm(
                device,
                &format!("porsche-{}", uuid::Uuid::new_v4().simple()),
            ))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}

/// Enable or disable one authenticated caller-owned notification device.
#[no_mangle]
pub unsafe extern "C" fn mila_session_device_prefs(
    handle: u64,
    device: *const u8,
    device_len: usize,
    enabled: u8,
) -> SessionStatus {
    guarded(|| {
        if enabled > 1 {
            return Err(SessionStatus::Invalid);
        }
        let device = std::str::from_utf8(bytes(device, device_len, 128)?)
            .map_err(|_| SessionStatus::Invalid)?;
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
        runtime
            .block_on(session.device_prefs(
                device,
                enabled == 1,
                &format!("porsche-{}", uuid::Uuid::new_v4().simple()),
            ))
            .map_err(|e| match e {
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })
    })
}
/// Decode one bounded UTF-8 argument.
unsafe fn text<'a>(ptr: *const u8, len: usize, max: usize) -> Result<&'a str, SessionStatus> {
    std::str::from_utf8(bytes(ptr, len, max)?).map_err(|_| SessionStatus::Invalid)
}

/// Run one JSON-returning session operation and copy its validated output.
unsafe fn json_operation<F>(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
    operation: F,
) -> Result<(), SessionStatus>
where
    F: for<'s> FnOnce(
        &'s mut ApplicationSession,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Vec<u8>, mila_session::SessionError>> + 's>,
    >,
{
    let runtime = runtime()?;
    let entry = entry(handle)?;
    let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
    let session = &mut locked.as_mut().ok_or(SessionStatus::InvalidHandle)?.session;
    let data = runtime
        .block_on(operation(session))
        .map_err(|error| match error {
            mila_session::SessionError::Transport(_) => SessionStatus::Transport,
            _ => SessionStatus::Invalid,
        })?;
    output(&data, out, capacity, written)
}

/// Read one mutation receipt by its client request id (`request show`).
/// # Safety
/// Inputs reference their declared readable lengths; out/written follow `output`.
#[no_mangle]
pub unsafe extern "C" fn mila_session_request_show(
    handle: u64,
    request_id: *const u8,
    request_id_len: usize,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let request_id = text(request_id, request_id_len, 64)?;
        json_operation(handle, out, capacity, written, |session| {
            Box::pin(session.request_show(request_id))
        })
    })
}

/// Open or rejoin the caller's personal terminal session (`terminal new`).
/// # Safety
/// Inputs reference their declared readable lengths; out/written follow `output`.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_new(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    request_id: *const u8,
    request_id_len: usize,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let machine = text(machine, machine_len, 128)?;
        let request_id = text(request_id, request_id_len, 64)?;
        json_operation(handle, out, capacity, written, |session| {
            Box::pin(session.terminal_new(machine, request_id))
        })
    })
}

/// Close one of the caller's server terminal sessions (`terminal kill`).
/// # Safety
/// Inputs reference their declared readable lengths; out/written follow `output`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn mila_session_terminal_end(
    handle: u64,
    machine: *const u8,
    machine_len: usize,
    terminal: *const u8,
    terminal_len: usize,
    request_id: *const u8,
    request_id_len: usize,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let machine = text(machine, machine_len, 128)?;
        let terminal = text(terminal, terminal_len, 64)?;
        let request_id = text(request_id, request_id_len, 64)?;
        json_operation(handle, out, capacity, written, |session| {
            Box::pin(session.terminal_kill(machine, terminal, request_id))
        })
    })
}

/// Attach a bounded PTY to one named terminal session of one machine. The
/// returned terminal handle is owned by the parent session and is fenced when
/// that session closes, exactly like `mila_session_terminal_attach`.
/// # Safety
/// Inputs reference their declared readable lengths; out_terminal_handle is writable.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_attach_session(
    session_handle: u64,
    machine: *const u8,
    machine_len: usize,
    terminal: *const u8,
    terminal_len: usize,
    columns: u32,
    rows: u32,
    out_terminal_handle: *mut u64,
) -> SessionStatus {
    guarded(|| {
        if out_terminal_handle.is_null()
            || !(1..=4096).contains(&columns)
            || !(1..=512).contains(&rows)
        {
            return Err(SessionStatus::Invalid);
        }
        let machine = text(machine, machine_len, 128)?;
        let terminal_id = text(terminal, terminal_len, 64)?;
        let parent = entry(session_handle)?;
        let runtime = runtime()?;
        let mut parent_guard = parent.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut parent_guard
            .as_mut()
            .ok_or(SessionStatus::InvalidHandle)?
            .session;
        let terminal = runtime
            .block_on(session.attach_terminal(machine, terminal_id, columns, rows))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(SshError::Bounds) => SessionStatus::Invalid,
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })?;
        let mut table = terminals().lock().map_err(|_| SessionStatus::Internal)?;
        if table.entries.len() >= 64 {
            return Err(SessionStatus::Busy);
        }
        let id = table.next.checked_add(1).ok_or(SessionStatus::Internal)?;
        table.next = id;
        table.entries.insert(
            id,
            Arc::new(Mutex::new(Some(TerminalEntry {
                owner: session_handle,
                terminal,
            }))),
        );
        *out_terminal_handle = id;
        Ok(())
    })
}

/// Copy `{"error": CODE}` for the most recent refused command on this session,
/// or `{"error": null}`. Codes are closed server refusal identifiers only.
/// # Safety
/// out/written follow `output`.
#[no_mangle]
pub unsafe extern "C" fn mila_session_last_refusal(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let entry = entry(handle)?;
        let locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &locked.as_ref().ok_or(SessionStatus::InvalidHandle)?.session;
        let data = serde_json::to_vec(&serde_json::json!({ "error": session.last_refusal() }))
            .map_err(|_| SessionStatus::Internal)?;
        output(&data, out, capacity, written)
    })
}

/// Copy validated display JSON: {"machines":[snapshot rows],"has_more":bool}.
/// # Safety
/// out references capacity writable bytes; written is writable. Null out with zero
/// capacity queries required size and returns SmallBuffer. No NUL terminator is added.
#[no_mangle]
pub unsafe extern "C" fn mila_session_listing(
    handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let entry = entry(handle)?;
        let locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let listing = locked
            .as_ref()
            .ok_or(SessionStatus::InvalidHandle)?
            .session
            .listing()
            .ok_or(SessionStatus::NotLoaded)?;
        // Include the Rust policy projection with each live row so native clients
        // cannot accidentally present actions based on duplicated UI rules.
        let machines: Vec<_> = listing
            .machines()
            .iter()
            .map(|machine| serde_json::json!({
                "id": machine.id,
                "name": machine.name,
                "desired_state": machine.desired_state,
                "observed_state": machine.observed_state,
                "pinned": machine.pinned,
                "owner": machine.owner,
                "read": machine.read,
                "write": machine.write,
                "manage": machine.manage,
                "action_bits": machine.available_actions().into_iter().fold(0u16, |bits, action| bits | (1 << action as u16)),
            }))
            .collect();
        let data = serde_json::to_vec(
            &serde_json::json!({"machines": machines, "has_more": listing.has_more()}),
        )
        .map_err(|_| SessionStatus::Internal)?;
        output(&data, out, capacity, written)
    })
}
/// Copy the existing offline snapshot schema; incomplete/unloaded listing refuses.
/// # Safety
/// out references capacity writable bytes and written is writable, as for listing.
#[no_mangle]
pub unsafe extern "C" fn mila_session_snapshot(
    handle: u64,
    saved_at: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let entry = entry(handle)?;
        let locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let snapshot = locked
            .as_ref()
            .ok_or(SessionStatus::InvalidHandle)?
            .session
            .snapshot(saved_at)
            .map_err(|_| SessionStatus::Invalid)?
            .ok_or(SessionStatus::NotLoaded)?;
        let data = snapshot.encode().map_err(|_| SessionStatus::Invalid)?;
        output(&data, out, capacity, written)
    })
}

/// Open a bounded interactive terminal attached to an authenticated session.
#[no_mangle]
pub extern "C" fn mila_session_terminal_attach(
    session_handle: u64,
    columns: u32,
    rows: u32,
    out_terminal_handle: *mut u64,
) -> SessionStatus {
    guarded(|| {
        if out_terminal_handle.is_null()
            || !(1..=4096).contains(&columns)
            || !(1..=512).contains(&rows)
        {
            return Err(SessionStatus::Invalid);
        }
        // Validate the parent before opening a network channel.
        let parent = entry(session_handle)?;
        let runtime = runtime()?;
        let mut parent_guard = parent.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &mut parent_guard
            .as_mut()
            .ok_or(SessionStatus::InvalidHandle)?
            .session;
        let terminal = runtime
            .block_on(session.open_pty(columns, rows))
            .map_err(|error| match error {
                mila_session::SessionError::Transport(SshError::Bounds) => SessionStatus::Invalid,
                mila_session::SessionError::Transport(_) => SessionStatus::Transport,
                _ => SessionStatus::Invalid,
            })?;
        let mut table = terminals().lock().map_err(|_| SessionStatus::Internal)?;
        if table.entries.len() >= 64 {
            return Err(SessionStatus::Busy);
        }
        let id = table.next.checked_add(1).ok_or(SessionStatus::Internal)?;
        table.next = id;
        table.entries.insert(
            id,
            Arc::new(Mutex::new(Some(TerminalEntry {
                owner: session_handle,
                terminal,
            }))),
        );
        // SAFETY: checked non-null above.
        unsafe {
            *out_terminal_handle = id;
        }
        Ok(())
    })
}

/// Poll one bounded output chunk. An empty chunk is a valid no-data/closed result.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_poll(
    terminal_handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> SessionStatus {
    guarded(|| {
        let runtime = runtime()?;
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let terminal = &mut guard.as_mut().ok_or(SessionStatus::InvalidHandle)?.terminal;
        let data = runtime
            .block_on(terminal.read())
            .map_err(|_| SessionStatus::Transport)?;
        unsafe { output(&data, out, capacity, written) }
    })
}

/// Terminal read outcome reported beside [`mila_session_terminal_read`] output.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalReadEvent {
    /// `written` bytes of PTY output were copied.
    Data = 0,
    /// No output arrived within the session timeout; the channel is still open.
    Idle = 1,
    /// The server or client closed the channel; no further output will arrive.
    Closed = 2,
}

/// Poll one bounded chunk and classify it, so native reconnect logic can tell
/// an idle PTY from a closed one and from a lost transport (`Transport`).
///
/// # Safety
/// `out` references `capacity` writable bytes; `written` and `event` are writable.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_read(
    terminal_handle: u64,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
    event: *mut TerminalReadEvent,
) -> SessionStatus {
    guarded(|| {
        if event.is_null() || written.is_null() {
            return Err(SessionStatus::Invalid);
        }
        let runtime = runtime()?;
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let terminal = &mut guard.as_mut().ok_or(SessionStatus::InvalidHandle)?.terminal;
        let (data, kind) = match runtime.block_on(terminal.read()) {
            Ok(data) if !data.is_empty() => (data, TerminalReadEvent::Data),
            Ok(_) if terminal.is_closed() => (Vec::new(), TerminalReadEvent::Closed),
            Ok(_) | Err(SshError::Timeout) => (Vec::new(), TerminalReadEvent::Idle),
            Err(_) => return Err(SessionStatus::Transport),
        };
        unsafe { output(&data, out, capacity, written)? };
        unsafe { *event = kind };
        Ok(())
    })
}

/// Smallest output buffer accepted by [`mila_session_terminal_read_within`].
/// Data is consumed from the channel, so a buffer that could not hold one
/// maximal chunk is refused before reading.
pub const MILA_TERMINAL_READ_CAPACITY: usize = 1 << 20;

/// @cc [owner:ghuntley,label:security;terminal] mila-session-terminal-read-states
/// Read MUST wait at most `wait_ms` (bounded to 1000), shorter than the session
/// timeout used by [`mila_session_terminal_read`], so a UI frame timer is not
/// blocked, and report through `event` the same [`TerminalReadEvent`] codes.
/// Undersized buffers and out-of-range waits MUST be refused before any
/// channel data is consumed, and stale handles MUST NOT write output.
/// # Safety
/// `out` is writable for `capacity` bytes; `written` and `event` are writable.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_read_within(
    terminal_handle: u64,
    wait_ms: u32,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
    event: *mut TerminalReadEvent,
) -> SessionStatus {
    guarded(|| {
        if out.is_null()
            || written.is_null()
            || event.is_null()
            || wait_ms > 1_000
            || capacity < MILA_TERMINAL_READ_CAPACITY
        {
            return Err(SessionStatus::Invalid);
        }
        let runtime = runtime()?;
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let terminal = &mut guard.as_mut().ok_or(SessionStatus::InvalidHandle)?.terminal;
        let chunk = runtime
            .block_on(terminal.read_within(Duration::from_millis(wait_ms.into())))
            .map_err(|_| SessionStatus::Transport)?;
        let (data, kind) = match chunk {
            PtyChunk::Data(data) => (data, TerminalReadEvent::Data),
            PtyChunk::Idle => (Vec::new(), TerminalReadEvent::Idle),
            PtyChunk::Closed => (Vec::new(), TerminalReadEvent::Closed),
        };
        unsafe {
            output(&data, out, capacity, written)?;
            *event = kind;
        }
        Ok(())
    })
}

/// Send bounded input bytes to a terminal.
#[no_mangle]
pub unsafe extern "C" fn mila_session_terminal_input(
    terminal_handle: u64,
    input: *const u8,
    input_len: usize,
) -> SessionStatus {
    guarded(|| {
        let input = unsafe { bytes(input, input_len, 1 << 20)? };
        let runtime = runtime()?;
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let terminal = &mut guard.as_mut().ok_or(SessionStatus::InvalidHandle)?.terminal;
        runtime
            .block_on(terminal.write(input))
            .map_err(|error| match error {
                SshError::Bounds => SessionStatus::Invalid,
                _ => SessionStatus::Transport,
            })?;
        Ok(())
    })
}

/// Resize a terminal using bounded dimensions.
#[no_mangle]
pub extern "C" fn mila_session_terminal_resize(
    terminal_handle: u64,
    columns: u32,
    rows: u32,
) -> SessionStatus {
    guarded(|| {
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SessionStatus::Invalid);
        }
        let runtime = runtime()?;
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let terminal = &mut guard.as_mut().ok_or(SessionStatus::InvalidHandle)?.terminal;
        runtime
            .block_on(terminal.resize(columns, rows))
            .map_err(|error| match error {
                SshError::Bounds => SessionStatus::Invalid,
                _ => SessionStatus::Transport,
            })?;
        Ok(())
    })
}

/// Close a terminal and remove its handle before network shutdown.
#[no_mangle]
pub extern "C" fn mila_session_terminal_kill(terminal_handle: u64) -> SessionStatus {
    guarded(|| {
        let terminal = terminal_entry(terminal_handle)?;
        let mut guard = terminal.try_lock().map_err(|_| SessionStatus::Busy)?;
        let mut terminal = guard.take().ok_or(SessionStatus::InvalidHandle)?.terminal;
        terminals()
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .entries
            .remove(&terminal_handle);
        runtime()?
            .block_on(terminal.close())
            .map_err(|_| SessionStatus::Transport)?;
        Ok(())
    })
}

/// @cc [owner:ghuntley,label:security] mila-session-ffi-handle-lifetime
/// Closed handles MUST never be reused. Close MUST remove authority before network
/// disconnect; concurrent operations either finish before close or refuse stale handles.
#[no_mangle]
pub extern "C" fn mila_session_close(handle: u64) -> SessionStatus {
    guarded(|| {
        let runtime = runtime()?;
        let entry = entry(handle)?;
        let mut locked = entry.try_lock().map_err(|_| SessionStatus::Busy)?;
        let owned_terminals = take_owned_terminals(handle)?;
        for mut terminal in owned_terminals {
            let _ = runtime.block_on(terminal.close());
        }
        let entry = locked.take().ok_or(SessionStatus::InvalidHandle)?;
        registry()
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .entries
            .remove(&handle);
        runtime
            .block_on(entry.session.close())
            .map_err(|_| SessionStatus::Transport)?;
        Ok(())
    })
}
