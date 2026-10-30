//! Bounded current-boot native flush protocol (vsock port 1026).

use crate::guest::readiness::Boot;
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, BufReader, Read, Write};

pub const PORT: u32 = 1026;
pub const MAX_LINE: usize = 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    operation: String,
    nonce: String,
    placement_id: String,
    execution_epoch: u64,
    boot_challenge: String,
}

#[derive(Serialize)]
struct Receipt<'a> {
    version: u8,
    state: &'static str,
    nonce: &'a str,
    boot_id: &'a str,
    placement_id: &'a str,
    execution_epoch: u64,
    boot_challenge: &'a str,
}

/// @cc [owner:ghuntley,label:security;recovery] native-flush-bounded-current-boot
/// `answer` MUST read at most 1025 bytes, require one complete newline-terminated
/// current-boot sync request with exactly the six documented keys and lowercase
/// 64-hex nonce, and call sync only after validation. Invalid requests MUST NOT
/// produce a receipt or a sync effect. Only a successful sync yields a reply.
pub fn answer(
    stream: &mut (impl Read + Write),
    boot: &Boot,
    sync: impl FnOnce() -> io::Result<()>,
) -> io::Result<()> {
    let mut line = Vec::new();
    BufReader::new((&mut *stream).take((MAX_LINE + 1) as u64)).read_until(b'\n', &mut line)?;
    if line.len() > MAX_LINE || !line.ends_with(b"\n") {
        return Err(io::Error::other("invalid flush frame"));
    }
    let request: Request = serde_json::from_slice(&line)?;
    if request.version != 1
        || request.operation != "sync"
        || request.nonce.len() != 64
        || !request
            .nonce
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || request.placement_id != boot.placement_id
        || request.execution_epoch != boot.execution_epoch
        || request.boot_challenge != boot.boot_challenge
    {
        return Err(io::Error::other("invalid flush request"));
    }
    let mut receipt = serde_json::to_vec(&Receipt {
        version: 1,
        state: "flushed",
        nonce: &request.nonce,
        boot_id: &boot.boot_id,
        placement_id: &boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: &boot.boot_challenge,
    })?;
    receipt.push(b'\n');
    if receipt.len() > MAX_LINE {
        return Err(io::Error::other("oversized flush response"));
    }
    sync()?;
    stream.write_all(&receipt)?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::Cursor;

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    fn request() -> serde_json::Value {
        serde_json::json!({"version":1,"operation":"sync","nonce":"a".repeat(64),
            "placement_id":boot().placement_id,"execution_epoch":7,"boot_challenge":"b".repeat(64)})
    }

    struct Stream {
        input: Cursor<Vec<u8>>,
        output: Vec<u8>,
    }
    impl Read for Stream {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            self.input.read(bytes)
        }
    }
    impl Write for Stream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.output.write(bytes)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    fn stream(input: Vec<u8>) -> Stream {
        Stream {
            input: Cursor::new(input),
            output: Vec::new(),
        }
    }
    fn encode(value: &serde_json::Value) -> Vec<u8> {
        let mut bytes = serde_json::to_vec(value).unwrap();
        bytes.push(b'\n');
        bytes
    }

    #[test]
    fn validated_request_syncs_once_and_returns_a_closed_boot_receipt() {
        let mut stream = stream(encode(&request()));
        let calls = Cell::new(0);
        answer(&mut stream, &boot(), || {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .unwrap();
        assert_eq!(calls.get(), 1);
        let value: serde_json::Value = serde_json::from_slice(&stream.output).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 7);
        assert_eq!(value["state"], "flushed");
        assert_eq!(value["nonce"], "a".repeat(64));
        assert_eq!(value["boot_id"], boot().boot_id);
    }

    #[test]
    fn malformed_stale_and_unbounded_requests_never_sync() {
        let mut inputs = vec![vec![b'x'; MAX_LINE + 100], b"{}".to_vec()];
        for (key, value) in [
            ("version", serde_json::json!(2)),
            ("operation", serde_json::json!("freeze")),
            ("nonce", serde_json::json!("A".repeat(64))),
            ("execution_epoch", serde_json::json!(8)),
            (
                "placement_id",
                serde_json::json!("dddddddd-dddd-4ddd-8ddd-000000000202"),
            ),
            ("boot_challenge", serde_json::json!("c".repeat(64))),
            ("extra", serde_json::json!(true)),
        ] {
            let mut mutation = request();
            mutation[key] = value;
            inputs.push(encode(&mutation));
        }
        let mut missing_newline = encode(&request());
        missing_newline.pop();
        inputs.push(missing_newline);
        for input in inputs {
            let mut stream = stream(input);
            assert!(answer(&mut stream, &boot(), || panic!("invalid request synced")).is_err());
            assert_eq!(stream.output, Vec::<u8>::new());
            assert!(stream.input.position() <= (MAX_LINE + 1) as u64);
        }
    }

    #[test]
    fn failed_sync_does_not_acknowledge_flush() {
        let mut stream = stream(encode(&request()));
        assert!(answer(&mut stream, &boot(), || Err(io::Error::other(
            "sync failed"
        )))
        .is_err());
        assert_eq!(stream.output, Vec::<u8>::new());
    }
}
