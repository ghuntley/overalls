use super::{absolute_guest_path, rpc, valid_identifier, AgentError, LeaseRequest};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};

const MAX_BYTES: usize = 10 * 1024 * 1024;
const CHUNK_BYTES: usize = 262_144;

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Arguments {
    Download {
        path: String,
        attachment_id: String,
    },
    Upload {
        path: String,
        thread_id: String,
        idempotency_key: String,
    },
}

#[derive(Serialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
enum Transfer<'a> {
    Read {
        offset: usize,
    },
    Begin {
        size_bytes: usize,
        sha256: &'a str,
    },
    Chunk {
        attachment_id: &'a str,
        offset: usize,
        content_base64: String,
    },
    Finish {
        attachment_id: &'a str,
    },
}

#[derive(Serialize)]
struct Request<'a, 'b> {
    executor_id: &'a str,
    fence_epoch: u64,
    command_id: &'a str,
    transfer: &'a Transfer<'b>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Metadata {
    id: String,
    state: String,
    size_bytes: usize,
    sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChunkAck {
    id: String,
    offset: usize,
}

/// @cc [owner:ghuntley,label:security;recovery] guest-attachment-upload
/// Upload MUST read only a bounded regular absolute-path file, send bytes only
/// through fenced transfer RPCs, and return metadata only. RPC or heartbeat
/// failure MUST stop execution without claiming a successful tool result.
pub(super) fn run(
    lease: &LeaseRequest<'_>,
    command_id: &str,
    arguments: &Value,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<(&'static str, Value), AgentError> {
    execute_transfer(arguments, heartbeat, &mut |transfer| {
        rpc(
            "attachment/transfer",
            &Request {
                executor_id: lease.executor_id,
                fence_epoch: lease.fence_epoch,
                command_id,
                transfer,
            },
        )
    })
}

fn execute_transfer(
    arguments: &Value,
    heartbeat: &mut impl FnMut() -> bool,
    send: &mut impl FnMut(&Transfer<'_>) -> Result<Value, AgentError>,
) -> Result<(&'static str, Value), AgentError> {
    let (path, thread_id, idempotency_key) = match serde_json::from_value(arguments.clone()) {
        Ok(Arguments::Upload {
            path,
            thread_id,
            idempotency_key,
        }) => (path, thread_id, idempotency_key),
        Ok(Arguments::Download {
            path,
            attachment_id,
        }) => return download(&path, &attachment_id, heartbeat, send),
        Err(_) => return Ok(("failed", json!({"reason":"invalid_arguments"}))),
    };
    if !absolute_guest_path(&path)
        || !valid_identifier(&thread_id)
        || idempotency_key.is_empty()
        || idempotency_key.len() > 128
    {
        return Ok(("failed", json!({"reason": "invalid_arguments"})));
    }
    let Ok(bytes) = read_file(&path) else {
        return Ok(("failed", json!({"reason": "attachment_read_failed"})));
    };
    let sha256 = hex::encode(Sha256::digest(&bytes));
    if !heartbeat() {
        return Err(AgentError);
    }
    let metadata: Metadata = serde_json::from_value(send(&Transfer::Begin {
        size_bytes: bytes.len(),
        sha256: &sha256,
    })?)
    .map_err(|_| AgentError)?;
    if !valid_identifier(&metadata.id)
        || metadata.size_bytes != bytes.len()
        || metadata.sha256 != sha256
        || !matches!(metadata.state.as_str(), "uploading" | "available")
    {
        return Err(AgentError);
    }
    if metadata.state == "uploading" {
        for (index, chunk) in bytes.chunks(CHUNK_BYTES).enumerate() {
            if !heartbeat() {
                return Err(AgentError);
            }
            let offset = index * CHUNK_BYTES;
            let ack: ChunkAck = serde_json::from_value(send(&Transfer::Chunk {
                attachment_id: &metadata.id,
                offset,
                content_base64: STANDARD.encode(chunk),
            })?)
            .map_err(|_| AgentError)?;
            if ack.id != metadata.id || ack.offset != offset {
                return Err(AgentError);
            }
        }
        if !heartbeat() {
            return Err(AgentError);
        }
        let finished: Metadata = serde_json::from_value(send(&Transfer::Finish {
            attachment_id: &metadata.id,
        })?)
        .map_err(|_| AgentError)?;
        if finished.id != metadata.id
            || finished.state != "available"
            || finished.size_bytes != bytes.len()
            || finished.sha256 != sha256
        {
            return Err(AgentError);
        }
        return Ok((
            "completed",
            serde_json::to_value(finished).map_err(|_| AgentError)?,
        ));
    }
    Ok((
        "completed",
        serde_json::to_value(metadata).map_err(|_| AgentError)?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadChunk {
    id: String,
    state: String,
    size_bytes: usize,
    sha256: String,
    offset: usize,
    content_base64: String,
}

/// @cc [owner:ghuntley,label:security;durability] guest-attachment-download
/// Download MUST verify each response identity, offset, size and final digest
/// before atomically publishing a new file. Existing destinations MUST survive
/// failures. Bytes MUST NOT enter tool results or diagnostics.
fn download(
    path: &str,
    id: &str,
    heartbeat: &mut impl FnMut() -> bool,
    send: &mut impl FnMut(&Transfer<'_>) -> Result<Value, AgentError>,
) -> Result<(&'static str, Value), AgentError> {
    if !absolute_guest_path(path) || !valid_identifier(id) {
        return Ok(("failed", json!({"reason":"invalid_arguments"})));
    }
    let target = std::path::Path::new(path);
    let parent = target.parent().ok_or(AgentError)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(|_| AgentError)?;
    let mut offset = 0_usize;
    let mut expected: Option<(usize, String)> = None;
    let mut digest = Sha256::new();
    loop {
        if !heartbeat() {
            return Err(AgentError);
        }
        let response: ReadChunk =
            serde_json::from_value(send(&Transfer::Read { offset })?).map_err(|_| AgentError)?;
        if response.id != id
            || response.state != "available"
            || response.offset != offset
            || response.size_bytes > MAX_BYTES
            || response.size_bytes < offset
            || response.content_base64.len() > 349_528
        {
            return Err(AgentError);
        }
        let identity = (response.size_bytes, response.sha256.clone());
        if let Some(previous) = &expected {
            if previous != &identity {
                return Err(AgentError);
            }
        } else {
            expected = Some(identity);
        }
        let bytes = STANDARD
            .decode(&response.content_base64)
            .map_err(|_| AgentError)?;
        if bytes.len() != CHUNK_BYTES.min(response.size_bytes - offset) {
            return Err(AgentError);
        }
        temporary.write_all(&bytes).map_err(|_| AgentError)?;
        digest.update(&bytes);
        offset += bytes.len();
        if offset == response.size_bytes {
            if hex::encode(digest.finalize()) != response.sha256 || !heartbeat() {
                return Err(AgentError);
            }
            temporary.as_file().sync_all().map_err(|_| AgentError)?;
            temporary
                .persist_noclobber(target)
                .map_err(|_| AgentError)?;
            return Ok((
                "completed",
                json!({"id":id,"state":"available",
                "size_bytes":offset,"sha256":response.sha256}),
            ));
        }
    }
}

fn read_file(path: &str) -> Result<Vec<u8>, std::io::Error> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES as u64 {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > MAX_BYTES {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    const ID: &str = "11111111-1111-4111-8111-111111111111";

    #[test]
    fn upload_chunks_bytes_and_returns_only_verified_metadata() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        let bytes = vec![7_u8; CHUNK_BYTES + 3];
        file.write_all(&bytes).unwrap();
        let digest = hex::encode(Sha256::digest(&bytes));
        let mut received = Vec::new();
        let args = json!({"operation":"upload", "path":file.path(), "thread_id":ID, "idempotency_key":"key"});
        let result = execute_transfer(&args, &mut || true, &mut |transfer| match transfer {
            Transfer::Read { .. } => panic!("unexpected download"),
            Transfer::Begin { size_bytes, sha256 } => {
                assert_eq!(*size_bytes, bytes.len());
                assert_eq!(*sha256, digest);
                Ok(json!({"id":ID,"state":"uploading","size_bytes":bytes.len(),"sha256":digest}))
            }
            Transfer::Chunk {
                attachment_id,
                offset,
                content_base64,
            } => {
                assert_eq!(*attachment_id, ID);
                assert_eq!(*offset, received.len());
                let chunk = STANDARD.decode(content_base64).unwrap();
                assert!(chunk.len() <= CHUNK_BYTES);
                received.extend(chunk);
                Ok(json!({"id":ID,"offset":offset}))
            }
            Transfer::Finish { .. } => {
                Ok(json!({"id":ID,"state":"available","size_bytes":bytes.len(),"sha256":digest}))
            }
        })
        .unwrap();
        assert_eq!(received, bytes);
        assert_eq!(result.0, "completed");
        assert_eq!(result.1.as_object().unwrap().len(), 4);
    }

    #[test]
    fn oversized_file_and_revoked_heartbeat_never_send_bytes() {
        let file = tempfile::NamedTempFile::new().unwrap();
        file.as_file().set_len((MAX_BYTES + 1) as u64).unwrap();
        let args = json!({"operation":"upload", "path":file.path(), "thread_id":ID, "idempotency_key":"key"});
        assert_eq!(
            execute_transfer(&args, &mut || true, &mut |_| panic!("unexpected transfer"))
                .unwrap()
                .0,
            "failed"
        );
        file.as_file().set_len(0).unwrap();
        assert!(
            execute_transfer(&args, &mut || false, &mut |_| panic!("unexpected transfer")).is_err()
        );
    }
    #[test]
    fn download_verifies_before_publish_and_preserves_existing_files() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("download");
        let bytes = vec![9_u8; CHUNK_BYTES + 4];
        let sha = hex::encode(Sha256::digest(&bytes));
        let args = json!({"operation":"download", "path":target, "attachment_id":ID});
        let mut send = |transfer: &Transfer<'_>| match transfer {
            Transfer::Read { offset } => Ok(json!({"id":ID,"state":"available",
                "size_bytes":bytes.len(),"sha256":sha,"offset":offset,
                "content_base64":STANDARD.encode(&bytes[*offset..(*offset + CHUNK_BYTES).min(bytes.len())])})),
            _ => panic!("unexpected upload"),
        };
        let result = execute_transfer(&args, &mut || true, &mut send).unwrap();
        assert_eq!(result.0, "completed");
        assert_eq!(std::fs::read(&target).unwrap(), bytes);
        assert!(execute_transfer(&args, &mut || true, &mut send).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), bytes);
        std::fs::remove_file(&target).unwrap();
        assert!(
            execute_transfer(&args, &mut || true, &mut |_| Ok(json!({"id":ID,
            "state":"available","size_bytes":1,"sha256":sha,"offset":0,
            "content_base64":"eA=="})))
            .is_err()
        );
        assert!(!target.exists());
    }
}
