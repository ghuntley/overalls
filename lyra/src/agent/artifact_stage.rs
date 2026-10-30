//! Guest staging of artifact files for large uploads.
//!
//! Marshall asks the executor to stream named guest files in fixed-size,
//! digest-checked chunks over the fenced `artifact_chunk` RPC. File contents,
//! paths and digests never enter diagnostics.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

/// Bytes read per chunk; only a file's last chunk may be shorter.
pub(super) const CHUNK_BYTES: usize = 196_608;
/// Guest-side ceiling on the per-file limit Marshall may request: a supporting
/// file is bounded only by Marshall's 64 MiB per-publish limit (the page by its
/// 16 MiB page limit, which Marshall enforces when chunks arrive).
const MAX_FILE_BYTES: u64 = 67_108_864;
/// Guest-side ceiling on the total limit Marshall may request.
const MAX_TOTAL_BYTES: u64 = 67_108_864;
/// Most files one stage command may name.
const MAX_FILES: usize = 255;

/// Closed failure reasons of `artifact_stage`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Failure {
    PathInvalid,
    NotRegularFile,
    TooLarge,
    IoError,
    UploadRefused,
}

impl Failure {
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::PathInvalid => "path_invalid",
            Self::NotRegularFile => "not_regular_file",
            Self::TooLarge => "too_large",
            Self::IoError => "io_error",
            Self::UploadRefused => "upload_refused",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Arguments {
    publish_request_id: String,
    max_file_bytes: u64,
    max_total_bytes: u64,
    files: Vec<FileArgument>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileArgument {
    file_index: u32,
    source_path: String,
}

/// Fence and command identity copied into every chunk request.
pub(super) struct Identity<'a> {
    pub executor_id: &'a str,
    pub fence_epoch: u64,
    pub command_id: &'a str,
}

/// Body of one `artifact_chunk` RPC (closed wire shape).
#[derive(Serialize)]
pub(super) struct ChunkRequest<'a> {
    pub executor_id: &'a str,
    pub fence_epoch: u64,
    pub command_id: &'a str,
    pub publish_request_id: &'a str,
    pub file_index: u32,
    pub chunk_index: u32,
    pub sha256: String,
    pub data: String,
}

/// Only `{"accepted": true}` acknowledges a chunk.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ChunkResponse {
    pub accepted: bool,
}

/// @cc [owner:ghuntley,label:security;recovery] lyra-artifact-stage-bounded
/// `artifact_stage` MUST validate every source path with the platform absolute
/// path rule, refuse symlinks, nonregular files and sizes over the requested or
/// guest ceilings before any upload, and re-check the opened descriptor. Files
/// MUST stream in 196_608-byte chunks (only the last may be shorter), each
/// acknowledged by `{"accepted": true}`; any other outcome or a lost lease ends
/// the command with `upload_refused`. Failures use only the closed reasons;
/// paths, bytes and digests MUST NOT enter diagnostics.
pub(super) fn run(
    raw: &Value,
    identity: &Identity<'_>,
    heartbeat: &mut impl FnMut() -> bool,
    send: &mut impl FnMut(&ChunkRequest<'_>) -> bool,
) -> Result<Value, Failure> {
    let arguments = validate(raw)?;
    let mut total = 0_u64;
    for file in &arguments.files {
        let size = inspect(&file.source_path)?;
        if size > arguments.max_file_bytes {
            return Err(Failure::TooLarge);
        }
        total = total.saturating_add(size);
        if total > arguments.max_total_bytes {
            return Err(Failure::TooLarge);
        }
    }

    let mut staged = Vec::with_capacity(arguments.files.len());
    let mut remaining_total = arguments.max_total_bytes;
    for file in &arguments.files {
        let limit = arguments.max_file_bytes.min(remaining_total);
        let mut source = open(&file.source_path, limit)?;
        let summary = stream(
            &mut source,
            limit,
            &arguments.publish_request_id,
            file.file_index,
            identity,
            heartbeat,
            send,
        )?;
        remaining_total -= summary.bytes;
        staged.push(json!({
            "file_index": file.file_index,
            "bytes": summary.bytes,
            "sha256": summary.sha256,
            "chunks": summary.chunks,
        }));
    }
    Ok(json!({"files": staged}))
}

/// Parse the closed argument shape; a malformed request names no usable path.
fn validate(raw: &Value) -> Result<Arguments, Failure> {
    let arguments =
        serde_json::from_value::<Arguments>(raw.clone()).map_err(|_| Failure::PathInvalid)?;
    if !super::valid_identifier(&arguments.publish_request_id)
        || arguments.files.is_empty()
        || arguments.files.len() > MAX_FILES
        || arguments.max_file_bytes == 0
        || arguments.max_total_bytes == 0
    {
        return Err(Failure::PathInvalid);
    }
    if arguments.max_file_bytes > MAX_FILE_BYTES || arguments.max_total_bytes > MAX_TOTAL_BYTES {
        return Err(Failure::TooLarge);
    }
    let mut indexes = BTreeSet::new();
    for file in &arguments.files {
        if file.file_index as usize >= MAX_FILES
            || !indexes.insert(file.file_index)
            || !super::absolute_guest_path(&file.source_path)
        {
            return Err(Failure::PathInvalid);
        }
    }
    Ok(arguments)
}

/// Size of a regular, non-link file at `path`.
fn inspect(path: &str) -> Result<u64, Failure> {
    let metadata = fs::symlink_metadata(path).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => Failure::PathInvalid,
        _ => Failure::IoError,
    })?;
    if !metadata.file_type().is_file() {
        return Err(Failure::NotRegularFile);
    }
    Ok(metadata.len())
}

/// Open without following a final link and re-check the descriptor, so a path
/// swapped after [`inspect`] cannot substitute another object.
fn open(path: &str, limit: u64) -> Result<File, Failure> {
    let file = crate::ssh_files::open_no_follow(Path::new(path)).map_err(|_| Failure::IoError)?;
    let metadata = file.metadata().map_err(|_| Failure::IoError)?;
    if !metadata.is_file() {
        return Err(Failure::NotRegularFile);
    }
    if metadata.len() > limit {
        return Err(Failure::TooLarge);
    }
    Ok(file)
}

#[derive(Debug, PartialEq, Eq)]
struct Summary {
    bytes: u64,
    sha256: String,
    chunks: u32,
}

/// Stream `source` as chunks, enforcing `limit` even if the file grows.
fn stream(
    source: &mut impl Read,
    limit: u64,
    publish_request_id: &str,
    file_index: u32,
    identity: &Identity<'_>,
    heartbeat: &mut impl FnMut() -> bool,
    send: &mut impl FnMut(&ChunkRequest<'_>) -> bool,
) -> Result<Summary, Failure> {
    let mut whole = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK_BYTES];
    let mut bytes = 0_u64;
    let mut chunks = 0_u32;
    loop {
        let filled = fill(source, &mut buffer).map_err(|_| Failure::IoError)?;
        if filled == 0 {
            break;
        }
        bytes += filled as u64;
        if bytes > limit {
            return Err(Failure::TooLarge);
        }
        if !heartbeat() {
            return Err(Failure::UploadRefused);
        }
        let chunk = &buffer[..filled];
        whole.update(chunk);
        let request = ChunkRequest {
            executor_id: identity.executor_id,
            fence_epoch: identity.fence_epoch,
            command_id: identity.command_id,
            publish_request_id,
            file_index,
            chunk_index: chunks,
            sha256: hex::encode(Sha256::digest(chunk)),
            data: STANDARD.encode(chunk),
        };
        if !send(&request) {
            return Err(Failure::UploadRefused);
        }
        chunks += 1;
        if filled < CHUNK_BYTES {
            break;
        }
    }
    Ok(Summary {
        bytes,
        sha256: hex::encode(whole.finalize()),
        chunks,
    })
}

/// Read until `buffer` is full or the source ends.
fn fill(source: &mut impl Read, buffer: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match source.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(count) => filled += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(filled)
}

#[cfg(test)]
mod tests {
    use super::{
        fill, run, stream, validate, ChunkRequest, ChunkResponse, Failure, Identity, CHUNK_BYTES,
    };
    use serde_json::{json, Value};
    use sha2::{Digest, Sha256};
    use std::io::Read;

    const ID: &str = "11111111-1111-4111-8111-111111111111";

    fn identity() -> Identity<'static> {
        Identity {
            executor_id: "executor",
            fence_epoch: 7,
            command_id: ID,
        }
    }

    fn arguments(files: &Value) -> Value {
        json!({
            "publish_request_id": ID,
            "max_file_bytes": 16_777_216,
            "max_total_bytes": 67_108_864,
            "files": files,
        })
    }

    /// Records chunk sizes and indexes; payload bytes are checked, not kept.
    /// `(file_index, chunk_index, decoded length)` of each sent chunk.
    type Sent = Vec<(u32, u32, usize)>;

    fn collect(raw: &Value) -> (Result<Value, Failure>, Sent) {
        let mut seen = Vec::new();
        let result = run(raw, &identity(), &mut || true, &mut |request| {
            let decoded =
                base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &request.data)
                    .expect("chunk data is standard base64");
            assert_eq!(request.sha256, hex::encode(Sha256::digest(&decoded)));
            assert_eq!(request.publish_request_id, ID);
            assert_eq!(request.fence_epoch, 7);
            seen.push((request.file_index, request.chunk_index, decoded.len()));
            true
        });
        (result, seen)
    }

    #[test]
    fn stages_files_in_fixed_chunks_with_closed_result() {
        let directory = tempfile::tempdir().expect("tempdir");
        let large = directory.path().join("large.bin");
        let small = directory.path().join("small.txt");
        let content: Vec<u8> = (0..CHUNK_BYTES * 2 + 5)
            .map(|i| i.to_le_bytes()[0])
            .collect();
        std::fs::write(&large, &content).expect("write");
        std::fs::write(&small, b"hello").expect("write");

        let (result, seen) = collect(&arguments(&json!([
            {"file_index": 0, "source_path": large.to_str().expect("utf8")},
            {"file_index": 1, "source_path": small.to_str().expect("utf8")},
        ])));
        assert_eq!(
            seen,
            vec![
                (0, 0, CHUNK_BYTES),
                (0, 1, CHUNK_BYTES),
                (0, 2, 5),
                (1, 0, 5)
            ]
        );
        assert_eq!(
            result.expect("completed"),
            json!({"files": [
                {"file_index": 0, "bytes": content.len(), "sha256": hex::encode(Sha256::digest(&content)), "chunks": 3},
                {"file_index": 1, "bytes": 5, "sha256": hex::encode(Sha256::digest(b"hello")), "chunks": 1},
            ]})
        );
    }

    #[test]
    fn exact_multiple_and_empty_files_have_no_trailing_chunk() {
        let exact_bytes = vec![1_u8; CHUNK_BYTES];
        let mut exact = exact_bytes.as_slice();
        let summary = stream(
            &mut exact,
            u64::MAX,
            ID,
            0,
            &identity(),
            &mut || true,
            &mut |_| true,
        )
        .expect("streamed");
        assert_eq!(summary.chunks, 1);
        assert_eq!(summary.bytes, CHUNK_BYTES as u64);

        let mut empty: &[u8] = &[];
        let summary = stream(
            &mut empty,
            u64::MAX,
            ID,
            0,
            &identity(),
            &mut || true,
            &mut |_| true,
        )
        .expect("streamed");
        assert_eq!(summary.chunks, 0);
        assert_eq!(summary.sha256, hex::encode(Sha256::digest(b"")));
    }

    #[test]
    fn short_reads_still_fill_whole_chunks() {
        struct Trickle(usize);
        impl Read for Trickle {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                let count = buffer.len().min(self.0).min(1000);
                buffer[..count].fill(9);
                self.0 -= count;
                Ok(count)
            }
        }
        let mut buffer = vec![0_u8; CHUNK_BYTES];
        assert_eq!(
            fill(&mut Trickle(CHUNK_BYTES + 10), &mut buffer).expect("fill"),
            CHUNK_BYTES
        );
    }

    #[test]
    fn refuses_invalid_paths_and_shapes() {
        for files in [
            json!([{"file_index": 0, "source_path": "relative/file"}]),
            json!([{"file_index": 0, "source_path": format!("/{}", "a".repeat(4096))}]),
            json!([]),
            json!([{"file_index": 0, "source_path": "/a"}, {"file_index": 0, "source_path": "/b"}]),
            json!([{"file_index": 255, "source_path": "/a"}]),
            json!([{"file_index": 0, "source_path": "/a", "extra": 1}]),
        ] {
            assert_eq!(collect(&arguments(&files)).0, Err(Failure::PathInvalid));
        }
        let too_many: Vec<Value> = (0..256)
            .map(|index| json!({"file_index": index, "source_path": "/a"}))
            .collect();
        assert_eq!(
            collect(&arguments(&Value::Array(too_many))).0,
            Err(Failure::PathInvalid)
        );
        let mut bad_id = arguments(&json!([{"file_index": 0, "source_path": "/a"}]));
        bad_id["publish_request_id"] = json!("../x");
        assert_eq!(collect(&bad_id).0, Err(Failure::PathInvalid));
        let mut over_ceiling = arguments(&json!([{"file_index": 0, "source_path": "/a"}]));
        over_ceiling["max_total_bytes"] = json!(67_108_865);
        assert_eq!(collect(&over_ceiling).0, Err(Failure::TooLarge));
        let mut over_file_ceiling = arguments(&json!([{"file_index": 0, "source_path": "/a"}]));
        over_file_ceiling["max_file_bytes"] = json!(67_108_865);
        assert_eq!(collect(&over_file_ceiling).0, Err(Failure::TooLarge));
    }

    // Pin: the exact limits Marshall's staging request sends (per-publish bytes
    // for both bounds) pass validation rather than being refused as too large.
    #[test]
    fn marshall_publish_limits_are_accepted() {
        let mut request = arguments(&json!([{"file_index": 0, "source_path": "/a"}]));
        request["max_file_bytes"] = json!(67_108_864);
        request["max_total_bytes"] = json!(67_108_864);
        assert!(validate(&request).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinks_directories_and_oversize_before_upload() {
        let directory = tempfile::tempdir().expect("tempdir");
        let target = directory.path().join("target");
        std::fs::write(&target, b"0123456789").expect("write");
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).expect("symlink");
        let path = |p: &std::path::Path| p.to_str().expect("utf8").to_owned();

        let (result, seen) = collect(&arguments(&json!([
            {"file_index": 0, "source_path": path(&target)},
            {"file_index": 1, "source_path": path(&link)},
        ])));
        assert_eq!(result, Err(Failure::NotRegularFile));
        assert!(seen.is_empty(), "no chunk is sent before every file passes");

        let (result, _) = collect(&arguments(
            &json!([{"file_index": 0, "source_path": path(directory.path())}]),
        ));
        assert_eq!(result, Err(Failure::NotRegularFile));

        let (result, _) = collect(&arguments(
            &json!([{"file_index": 0, "source_path": path(&directory.path().join("missing"))}]),
        ));
        assert_eq!(result, Err(Failure::PathInvalid));

        let mut small_limit = arguments(&json!([{"file_index": 0, "source_path": path(&target)}]));
        small_limit["max_file_bytes"] = json!(9);
        assert_eq!(collect(&small_limit).0, Err(Failure::TooLarge));

        let mut total_limit = arguments(&json!([
            {"file_index": 0, "source_path": path(&target)},
            {"file_index": 1, "source_path": path(&target)},
        ]));
        total_limit["max_total_bytes"] = json!(19);
        assert_eq!(collect(&total_limit).0, Err(Failure::TooLarge));
    }

    #[test]
    fn growth_past_the_limit_is_too_large() {
        let grown = [0_u8; 20];
        let mut source: &[u8] = &grown;
        assert_eq!(
            stream(
                &mut source,
                10,
                ID,
                0,
                &identity(),
                &mut || true,
                &mut |_| true
            ),
            Err(Failure::TooLarge)
        );
    }

    #[test]
    fn refused_chunk_or_lost_lease_is_upload_refused() {
        let mut source: &[u8] = b"abc";
        assert_eq!(
            stream(
                &mut source,
                10,
                ID,
                0,
                &identity(),
                &mut || true,
                &mut |_| false
            ),
            Err(Failure::UploadRefused)
        );
        let mut source: &[u8] = b"abc";
        let mut sent = false;
        assert_eq!(
            stream(
                &mut source,
                10,
                ID,
                0,
                &identity(),
                &mut || false,
                &mut |_| {
                    sent = true;
                    true
                }
            ),
            Err(Failure::UploadRefused)
        );
        assert!(!sent, "no chunk is sent after the lease is lost");
    }

    #[test]
    fn chunk_wire_shapes_are_closed() {
        let request = ChunkRequest {
            executor_id: "e",
            fence_epoch: 1,
            command_id: ID,
            publish_request_id: ID,
            file_index: 2,
            chunk_index: 3,
            sha256: "00".into(),
            data: "AA==".into(),
        };
        let encoded = serde_json::to_value(&request).expect("encode");
        let mut keys: Vec<&str> = encoded
            .as_object()
            .expect("object")
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "chunk_index",
                "command_id",
                "data",
                "executor_id",
                "fence_epoch",
                "file_index",
                "publish_request_id",
                "sha256"
            ]
        );
        assert!(serde_json::from_str::<ChunkResponse>("{\"accepted\":true}").is_ok());
        assert!(serde_json::from_str::<ChunkResponse>("{\"accepted\":true,\"x\":1}").is_err());
        assert!(serde_json::from_str::<ChunkResponse>("{}").is_err());
    }

    #[test]
    fn failure_codes_are_closed() {
        let codes: Vec<&str> = [
            Failure::PathInvalid,
            Failure::NotRegularFile,
            Failure::TooLarge,
            Failure::IoError,
            Failure::UploadRefused,
        ]
        .into_iter()
        .map(Failure::code)
        .collect();
        assert_eq!(
            codes,
            [
                "path_invalid",
                "not_regular_file",
                "too_large",
                "io_error",
                "upload_refused"
            ]
        );
    }
}
