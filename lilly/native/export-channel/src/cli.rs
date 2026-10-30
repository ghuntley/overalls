use crate::build;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// Validated bridge invocation: absolute socket path plus key; the SSH-side
/// command arrives through `SSH_ORIGINAL_COMMAND` only.
#[derive(Debug, Eq, PartialEq)]
pub struct BridgeRequest {
    pub socket: PathBuf,
    pub key: String,
    pub command: String,
}

pub fn parse_bridge(
    arguments: &[OsString],
    original_command: Option<&OsStr>,
) -> Option<BridgeRequest> {
    let [socket, key] = arguments else {
        return None;
    };
    if !socket.as_os_str().as_bytes().starts_with(b"/") {
        return None;
    }
    let key = key.to_str()?;
    let command = original_command?.to_str()?;
    let request = build(key, command)?;
    Some(BridgeRequest {
        socket: PathBuf::from(socket),
        key: request.key,
        command: request.command,
    })
}

/// Validated serve invocation: a trusted account name and fixed worker argv.
#[derive(Debug, Eq, PartialEq)]
pub struct ServeRequest {
    pub account: String,
    pub worker: Vec<OsString>,
}

pub fn parse_serve(arguments: &[OsString]) -> Option<ServeRequest> {
    if arguments.len() < 2 || arguments.len() > 31 {
        return None;
    }
    let account = arguments[0].to_str()?;
    let worker = &arguments[1..];
    if worker.is_empty() || !worker[0].as_os_str().as_bytes().starts_with(b"/") {
        return None;
    }
    Some(ServeRequest {
        account: account.to_string(),
        worker: worker.to_vec(),
    })
}
