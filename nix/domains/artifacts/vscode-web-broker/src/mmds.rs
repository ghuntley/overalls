//! Firmware boot identity from Firecracker MMDS v2 (ADR-0170/0171).
//!
//! Adapted from `lyra/src/guest/mmds.rs`; the broker keeps an independent,
//! dependency-free client with stricter framing and one deadline for both
//! requests. Metadata and session-token bytes never enter diagnostics.

use crate::{Boot, Refusal, hex, parse_boot};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::time::{Duration, Instant};

const ADDRESS: Ipv4Addr = Ipv4Addr::new(169, 254, 169, 254);
const MAX_RESPONSE: usize = 8192;
const MAX_TOKEN: usize = 512;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u8,
    placement: String,
    execution_epoch: u64,
    boot_challenge: String,
    ipv4: String,
    prefix_length: u8,
    gateway: String,
    mac: String,
}

/// Validated network identity and an opaque namespace for this physical boot.
/// The challenge is never retained or exposed to callers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub boot: Boot,
    state_key: String,
}

impl Identity {
    pub fn state_key(&self) -> &str {
        &self.state_key
    }
}

/// @cc [owner:ghuntley,label:security] editor-mmds-physical-network-identity
/// A document MUST have exactly Lilly's version-1 fields, a valid boot
/// challenge, and the placement/epoch/profile address accepted by `parse_boot`.
/// Its prefix MUST be 32 and its gateway and MAC MUST match the address's
/// deterministic Lilly network identity. Invalid, duplicate or unknown fields
/// MUST refuse; neither the challenge nor metadata text may be returned.
/// The opaque state namespace MUST change when the physical boot challenge,
/// placement or execution epoch changes, including reboot at the same epoch.
pub fn parse_document(body: &[u8]) -> Result<Identity, Refusal> {
    if body.is_empty() || body.len() > MAX_RESPONSE {
        return Err(Refusal::Boot);
    }
    let document: Document = serde_json::from_slice(body).map_err(|_| Refusal::Boot)?;
    if document.version != 1 || document.prefix_length != 32 || !hex(&document.boot_challenge, 64) {
        return Err(Refusal::Boot);
    }
    // The broker shares the kernel-guest validator, including reserved slots
    // and supported profile networks, instead of creating another authority.
    let boot = parse_boot(&format!(
        "lilly.placement={} lilly.execution_epoch={} lilly.ipv4={}",
        document.placement, document.execution_epoch, document.ipv4
    ))?;
    let [first, profile, high, low] = boot.address.octets();
    let expected_mac = format!("02:fc:{first:02x}:{profile:02x}:{high:02x}:{low:02x}");
    if document.placement != boot.placement_id
        || document.ipv4 != boot.address.to_string()
        || document.gateway != boot.gateway.to_string()
        || document.mac != expected_mac
    {
        return Err(Refusal::Boot);
    }
    let mut hash = Sha256::new();
    hash.update(b"overalls-windows-editor-physical-boot-v1\0");
    hash.update(boot.placement_id.as_bytes());
    hash.update(boot.execution_epoch.to_be_bytes());
    hash.update(document.boot_challenge.as_bytes());
    let state_key = hash
        .finalize()
        .iter()
        .fold(String::with_capacity(64), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        });
    Ok(Identity { boot, state_key })
}

struct ResponseHead {
    status: u16,
    body_start: usize,
    body_length: usize,
}

fn header_name(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn response_head(raw: &[u8]) -> Result<Option<ResponseHead>, Refusal> {
    if raw.len() > MAX_RESPONSE {
        return Err(Refusal::Boot);
    }
    let Some(split) = raw.windows(4).position(|window| window == b"\r\n\r\n") else {
        return if raw.len() == MAX_RESPONSE {
            Err(Refusal::Boot)
        } else {
            Ok(None)
        };
    };
    let head = std::str::from_utf8(&raw[..split]).map_err(|_| Refusal::Boot)?;
    let mut lines = head.split("\r\n");
    let (version, status) = lines
        .next()
        .and_then(|line| line.split_once(' '))
        .ok_or(Refusal::Boot)?;
    let status_bytes = status.as_bytes();
    if !["HTTP/1.1", "HTTP/1.0"].contains(&version)
        || status_bytes.len() < 4
        || status_bytes[3] != b' '
        || !status_bytes[..3].iter().all(u8::is_ascii_digit)
        || !status_bytes[4..]
            .iter()
            .all(|byte| (32..=126).contains(byte))
    {
        return Err(Refusal::Boot);
    }
    let status: u16 = std::str::from_utf8(&status_bytes[..3])
        .map_err(|_| Refusal::Boot)?
        .parse()
        .map_err(|_| Refusal::Boot)?;
    if !(100..=599).contains(&status) {
        return Err(Refusal::Boot);
    }
    let mut names = BTreeSet::new();
    let mut length = None;
    for line in lines {
        let (name, value) = line.split_once(':').ok_or(Refusal::Boot)?;
        if name.is_empty()
            || !name.bytes().all(header_name)
            || !value
                .bytes()
                .all(|byte| byte == b'\t' || (32..=126).contains(&byte))
        {
            return Err(Refusal::Boot);
        }
        let name = name.to_ascii_lowercase();
        if name == "transfer-encoding" || !names.insert(name.clone()) {
            return Err(Refusal::Boot);
        }
        if name == "content-length" {
            let value = value.trim_matches([' ', '\t']);
            if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(Refusal::Boot);
            }
            let parsed: usize = value.parse().map_err(|_| Refusal::Boot)?;
            if parsed.to_string() != value {
                return Err(Refusal::Boot);
            }
            length = Some(parsed);
        }
    }
    let body_start = split + 4;
    let body_length = length.ok_or(Refusal::Boot)?;
    if body_length > MAX_RESPONSE - body_start {
        return Err(Refusal::Boot);
    }
    Ok(Some(ResponseHead {
        status,
        body_start,
        body_length,
    }))
}

fn remaining(deadline: Instant) -> Result<Duration, Refusal> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or(Refusal::Boot)
}

/// @cc [owner:ghuntley,label:security;capacity] editor-mmds-http-closed-framing
/// An exchange MUST reject duplicate headers, transfer encoding, malformed or
/// absent Content-Length, oversized and truncated responses, and bytes beyond
/// the declared body already received. It MUST finish on the declared body
/// without waiting for EOF. Every connect/read/write MUST use the remaining
/// shared deadline; a peer that trickles bytes MUST NOT renew the total budget.
fn exchange(
    address: SocketAddrV4,
    request: &[u8],
    deadline: Instant,
) -> Result<(u16, Vec<u8>), Refusal> {
    let mut stream = TcpStream::connect_timeout(&address.into(), remaining(deadline)?)
        .map_err(|_| Refusal::Boot)?;
    let mut pending = request;
    while !pending.is_empty() {
        stream
            .set_write_timeout(Some(remaining(deadline)?))
            .map_err(|_| Refusal::Boot)?;
        let written = stream.write(pending).map_err(|_| Refusal::Boot)?;
        if written == 0 {
            return Err(Refusal::Boot);
        }
        pending = &pending[written..];
    }
    let mut raw = Vec::new();
    let mut chunk = [0_u8; 4096];
    loop {
        remaining(deadline)?;
        if let Some(head) = response_head(&raw)? {
            let expected = head.body_start + head.body_length;
            if raw.len() > expected {
                return Err(Refusal::Boot);
            }
            if raw.len() == expected {
                return Ok((head.status, raw[head.body_start..].to_vec()));
            }
        }
        let capacity = (MAX_RESPONSE - raw.len()).min(chunk.len());
        if capacity == 0 {
            return Err(Refusal::Boot);
        }
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|_| Refusal::Boot)?;
        let count = stream
            .read(&mut chunk[..capacity])
            .map_err(|_| Refusal::Boot)?;
        if count == 0 {
            return Err(Refusal::Boot);
        }
        raw.extend_from_slice(&chunk[..count]);
    }
}

fn fetch_at(address: SocketAddrV4, timeout: Duration) -> Result<Identity, Refusal> {
    let deadline = Instant::now().checked_add(timeout).ok_or(Refusal::Boot)?;
    remaining(deadline)?;
    let request = format!(
        "PUT /latest/api/token HTTP/1.1\r\nHost: {}\r\nX-metadata-token-ttl-seconds: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        address.ip()
    );
    let (status, token) = exchange(address, request.as_bytes(), deadline)?;
    if status != 200
        || token.is_empty()
        || token.len() > MAX_TOKEN
        || !token
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"=/+-_".contains(byte))
    {
        return Err(Refusal::Boot);
    }
    let token = std::str::from_utf8(&token).map_err(|_| Refusal::Boot)?;
    let request = format!(
        "GET /lilly HTTP/1.1\r\nHost: {}\r\nX-metadata-token: {token}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        address.ip()
    );
    let (status, body) = exchange(address, request.as_bytes(), deadline)?;
    if status != 200 {
        return Err(Refusal::Boot);
    }
    let boot = parse_document(&body)?;
    remaining(deadline)?;
    Ok(boot)
}

/// @cc [owner:ghuntley,label:security] editor-mmds-v2-private-token
/// Each fetch MUST contact only Firecracker's fixed MMDS IPv4 endpoint, obtain
/// a fresh short-lived v2 token, and send it only on the following GET /lilly.
/// No proxy, redirect, retry or durable token state is allowed. Token and body
/// bytes MUST NOT enter diagnostics or returned error values. The supplied
/// timeout MUST bound both requests together.
pub fn fetch(timeout: Duration) -> Result<Identity, Refusal> {
    fetch_at(SocketAddrV4::new(ADDRESS, 80), timeout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::{SocketAddr, TcpListener};
    use std::sync::mpsc;
    use std::thread;

    const DOCUMENT: &str = r#"{"version":1,"placement":"dddddddd-dddd-4ddd-8ddd-000000000201","execution_epoch":7,"boot_challenge":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ipv4":"10.10.0.203","prefix_length":32,"gateway":"10.10.0.1","mac":"02:fc:0a:0a:00:cb"}"#;

    fn response(body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    fn address(listener: &TcpListener) -> SocketAddrV4 {
        let SocketAddr::V4(address) = listener.local_addr().unwrap() else {
            unreachable!()
        };
        address
    }

    fn read_request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut reader = BufReader::new(stream);
        let mut request = String::new();
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0);
            request.push_str(&line);
            assert!(request.len() <= 2048);
            if line == "\r\n" {
                return request;
            }
        }
    }

    #[test]
    fn document_matches_all_supported_profile_networks() {
        for profile in [10, 20, 30, 40] {
            let document = DOCUMENT
                .replace("10.10.", &format!("10.{profile}."))
                .replace("02:fc:0a:0a:", &format!("02:fc:0a:{profile:02x}:"));
            let boot = parse_document(document.as_bytes()).unwrap().boot;
            assert_eq!(boot.address, Ipv4Addr::new(10, profile, 0, 203));
            assert_eq!(boot.gateway, Ipv4Addr::new(10, profile, 0, 1));
            assert_eq!(boot.execution_epoch, 7);
        }
    }

    #[test]
    fn physical_boot_namespace_rotates_at_the_same_placement_and_epoch() {
        let first = parse_document(DOCUMENT.as_bytes()).unwrap();
        let second = parse_document(DOCUMENT.replace("bbbbbbbb", "cccccccc").as_bytes()).unwrap();
        assert_eq!(first.boot, second.boot);
        assert_ne!(first.state_key(), second.state_key());
        assert_eq!(first.state_key().len(), 64);
        assert_ne!(first.state_key(), "b".repeat(64));
        assert_eq!(first, parse_document(DOCUMENT.as_bytes()).unwrap());
    }

    #[test]
    fn malformed_or_mismatched_document_facts_refuse() {
        for broken in [
            DOCUMENT.replace("\"version\":1", "\"version\":2"),
            DOCUMENT.replace("\"version\":1", "\"version\":1,\"version\":1"),
            DOCUMENT.replace("\"prefix_length\":32", "\"prefix_length\":24"),
            DOCUMENT.replace("\"execution_epoch\":7", "\"execution_epoch\":0"),
            DOCUMENT.replace("10.10.0.1", "10.20.0.1"),
            DOCUMENT.replace("10.10.0.203", "10.10.0.1"),
            DOCUMENT.replace("10.10.0.203", "10.10.255.255"),
            DOCUMENT.replace("10.10.0.203", "10.50.0.203"),
            DOCUMENT.replace("02:fc:0a:0a:00:cb", "02:fc:0a:14:00:cb"),
            DOCUMENT.replace("02:fc:0a:0a:00:cb", "02:FC:0A:0A:00:CB"),
            DOCUMENT.replace("bbbbbbbb", "BBBBBBBB"),
            DOCUMENT.replace("dddddddd", "DDDDDDDD"),
            DOCUMENT.replace("\"mac\":", "\"unknown\":true,\"mac\":"),
            DOCUMENT.replace(
                "\"ipv4\":\"10.10.0.203\"",
                "\"ipv4\":\"10.10.0.203 lilly.ipv4=10.10.0.2\"",
            ),
            format!("{{\"lilly\":{DOCUMENT}}}"),
        ] {
            assert_eq!(parse_document(broken.as_bytes()), Err(Refusal::Boot));
        }
        assert_eq!(
            parse_document(&vec![b' '; MAX_RESPONSE + 1]),
            Err(Refusal::Boot)
        );
    }

    #[test]
    fn ambiguous_http_headers_and_lengths_refuse() {
        for raw in [
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\ncontent-length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nX-Fact: a\r\nx-fact: a\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 01\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999999999999\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length : 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\n Content-Length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nfolded\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nX-Fact: a\0b\r\n\r\nx",
            "HTTP/1.1 200 OK\r\n\r\nx",
            "HTTP/2 200 OK\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 0200 OK\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 \u{00e9}00 OK\r\nContent-Length: 1\r\n\r\nx",
            "HTTP/1.1 200 OK\nContent-Length: 1\r\n\r\nx",
        ] {
            assert!(response_head(raw.as_bytes()).is_err());
        }
        assert!(response_head(&vec![b'a'; MAX_RESPONSE]).is_err());
    }

    #[test]
    fn fresh_token_and_complete_body_do_not_wait_for_server_close() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = address(&listener);
        let (release, hold) = mpsc::channel::<()>();
        let server = thread::spawn(move || {
            let (mut first, _) = listener.accept().unwrap();
            let request = read_request(&mut first);
            assert!(request.starts_with("PUT /latest/api/token HTTP/1.1\r\n"));
            assert!(request.contains("X-metadata-token-ttl-seconds: 60\r\n"));
            first.write_all(&response("TOKEN123")).unwrap();
            // Keep both sockets alive until the client has completed.
            let (mut second, _) = listener.accept().unwrap();
            let request = read_request(&mut second);
            assert!(request.starts_with("GET /lilly HTTP/1.1\r\n"));
            assert!(request.contains("X-metadata-token: TOKEN123\r\n"));
            second.write_all(&response(DOCUMENT)).unwrap();
            hold.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let boot = fetch_at(endpoint, Duration::from_secs(1)).unwrap().boot;
        assert_eq!(boot.execution_epoch, 7);
        release.send(()).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn truncated_or_already_overlong_body_refuses() {
        for payload in [
            b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort".as_slice(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nextra".as_slice(),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let endpoint = address(&listener);
            let payload = payload.to_vec();
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                read_request(&mut stream);
                stream.write_all(&payload).unwrap();
            });
            assert_eq!(
                fetch_at(endpoint, Duration::from_secs(1)),
                Err(Refusal::Boot)
            );
            server.join().unwrap();
        }
    }

    #[test]
    fn trickling_bytes_do_not_renew_total_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = address(&listener);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_request(&mut stream);
            for byte in b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nTOKEN123" {
                if stream.write_all(&[*byte]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        assert_eq!(
            fetch_at(endpoint, Duration::from_millis(100)),
            Err(Refusal::Boot)
        );
        assert!(started.elapsed() < Duration::from_millis(600));
        server.join().unwrap();
    }

    #[test]
    fn zero_timeout_refuses_without_connecting() {
        assert_eq!(
            fetch_at(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1), Duration::ZERO),
            Err(Refusal::Boot)
        );
    }
}
