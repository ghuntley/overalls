//! Boot identity for firmware-booted Windows, FreeBSD and illumos guests, read
//! from Firecracker's MMDS version 2 (ADR-0170, ADR-0171, ADR-0190).
//!
//! Kernel guests read `lilly.boot_challenge`, `lilly.placement` and
//! `lilly.execution_epoch` from the command line; firmware guests read the same
//! values from the `lilly` document Lilly seeds into MMDS. This mirrors Lyra's
//! `guest::mmds` client: one bounded HTTP/1.1 exchange per request, a fresh
//! session token per fetch, and `GET /lilly` answered with the subtree itself.
//! Only std networking is used, so the decoder is unit tested on Linux too.
#![cfg_attr(not(any(windows, target_os = "freebsd", target_os = "illumos")), allow(dead_code))]
use serde::Deserialize;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::time::{Duration, Instant};

const ADDRESS: Ipv4Addr = Ipv4Addr::new(169, 254, 169, 254);
const MAXIMUM_RESPONSE: usize = 8192;

/// The fields terminald needs from the `lilly` document (version 1); the
/// other fields Lilly seeds are accepted and ignored here.
#[derive(Debug, Deserialize)]
struct Document {
  version: u8,
  placement: String,
  execution_epoch: u64,
  boot_challenge: String,
}

/// @cc [owner:ghuntley,label:security] windows-terminald-mmds-identity
/// Firmware guest identity MUST come only from a version-1 `lilly` document that MMDS
/// serves for `GET /lilly` (the subtree, not an envelope) after a fresh
/// version-2 session token; the token MUST NOT be logged or retained, and the
/// result is still checked by `validate_boot_identity` before any key derives.
fn decode(body: &[u8]) -> Option<(String, String, String)> {
  let document: Document = serde_json::from_slice(body).ok()?;
  if document.version != 1 || document.execution_epoch == 0 {
    return None;
  }
  Some((document.boot_challenge, document.placement, document.execution_epoch.to_string()))
}

fn response_complete(raw: &[u8]) -> bool {
  let Some(split) = raw.windows(4).position(|window| window == b"\r\n\r\n") else { return false };
  let head = String::from_utf8_lossy(&raw[..split]);
  let length = head.split("\r\n").skip(1).find_map(|line| {
    let (name, value) = line.split_once(':')?;
    name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().ok()).flatten()
  });
  length.is_some_and(|length| raw.len() - split - 4 >= length)
}

fn parse_response(raw: &[u8]) -> Option<(u16, Vec<u8>)> {
  let split = raw.windows(4).position(|window| window == b"\r\n\r\n")?;
  let head = std::str::from_utf8(&raw[..split]).ok()?;
  let mut lines = head.split("\r\n");
  let mut status_line = lines.next()?.splitn(3, ' ');
  let version = status_line.next()?;
  if version != "HTTP/1.1" && version != "HTTP/1.0" {
    return None;
  }
  let status: u16 = status_line.next()?.parse().ok()?;
  let mut length = None;
  for line in lines {
    if let Some((name, value)) = line.split_once(':') {
      if name.eq_ignore_ascii_case("content-length") {
        length = Some(value.trim().parse::<usize>().ok()?);
      }
    }
  }
  let body = &raw[split + 4..];
  let body = match length {
    Some(length) if length <= body.len() => &body[..length],
    Some(_) => return None,
    None => body,
  };
  Some((status, body.to_vec()))
}

fn exchange(address: SocketAddrV4, request: &[u8], timeout: Duration) -> io::Result<(u16, Vec<u8>)> {
  let mut stream = TcpStream::connect_timeout(&address.into(), timeout)?;
  stream.set_read_timeout(Some(timeout))?;
  stream.set_write_timeout(Some(timeout))?;
  stream.write_all(request)?;
  // MMDS keeps connections open after answering: stop at Content-Length.
  let mut raw = Vec::new();
  let mut chunk = [0u8; 4096];
  while !response_complete(&raw) {
    if raw.len() > MAXIMUM_RESPONSE {
      return Err(io::Error::other("oversized MMDS response"));
    }
    let read = stream.read(&mut chunk)?;
    if read == 0 {
      break;
    }
    raw.extend_from_slice(&chunk[..read]);
  }
  parse_response(&raw).ok_or_else(|| io::Error::other("invalid MMDS response"))
}

fn fetch_once(address: SocketAddrV4, timeout: Duration) -> io::Result<(String, String, String)> {
  let token_request = format!(
    "PUT /latest/api/token HTTP/1.1\r\nHost: {}\r\nX-metadata-token-ttl-seconds: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    address.ip()
  );
  let (status, token) = exchange(address, token_request.as_bytes(), timeout)?;
  let token = String::from_utf8(token).map_err(|_| io::Error::other("invalid MMDS token"))?;
  let token = token.trim();
  if status != 200 || token.is_empty() || token.len() > 512
    || !token.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"=/+-_".contains(&byte)) {
    return Err(io::Error::other("MMDS token unavailable"));
  }
  let document_request = format!(
    "GET /lilly HTTP/1.1\r\nHost: {}\r\nX-metadata-token: {token}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
    address.ip()
  );
  let (status, body) = exchange(address, document_request.as_bytes(), timeout)?;
  if status != 200 {
    return Err(io::Error::other("MMDS document unavailable"));
  }
  decode(&body).ok_or_else(|| io::Error::other("invalid lilly document"))
}

fn fetch_from(address: SocketAddrV4, budget: Duration) -> Option<(String, String, String)> {
  let started = Instant::now();
  loop {
    match fetch_once(address, Duration::from_secs(5)) {
      Ok(identity) => return Some(identity),
      Err(_) if started.elapsed() < budget => std::thread::sleep(Duration::from_secs(2)),
      Err(_) => return None,
    }
  }
}

/// Fetch `(challenge, placement, epoch)`, retrying within `budget` while the
/// guest network and its MMDS route come up after boot.
pub fn fetch(budget: Duration) -> Option<(String, String, String)> {
  fetch_from(SocketAddrV4::new(ADDRESS, 80), budget)
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::io::BufRead;
  use std::net::TcpListener;
  use hegel::{generators as gs, TestCase};

  /// @cc [owner:ghuntley,label:verification;security] windows-terminald-mmds-response-framing
  /// A complete HTTP/1.x response MUST parse to exactly its status and its
  /// Content-Length body, ignoring later bytes; a body shorter than its declared
  /// length MUST be neither complete nor parsed, and arbitrary bytes MUST NOT panic.
  #[hegel::test(test_cases = 100)]
  fn responses_parse_exactly_their_declared_body(tc: TestCase) {
    let status = tc.draw(gs::integers::<u16>().min_value(100).max_value(599));
    let version = tc.draw(gs::sampled_from(&["HTTP/1.1", "HTTP/1.0"]));
    let body: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(256));
    let trailing: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(32));
    let header = tc.draw(gs::sampled_from(&["Content-Length", "content-length", "CONTENT-LENGTH"]));
    let mut raw = format!("{version} {status} OK\r\nServer: mmds\r\n{header}: {}\r\n\r\n", body.len()).into_bytes();
    let head = raw.len();
    raw.extend_from_slice(&body);
    let complete = raw.clone();
    raw.extend_from_slice(&trailing);
    assert!(response_complete(&raw));
    assert!(parse_response(&raw) == Some((status, body.clone())), "parsed response differs");
    if !body.is_empty() {
      let cut = tc.draw(gs::integers::<usize>().min_value(head).max_value(complete.len() - 1));
      assert!(!response_complete(&complete[..cut]));
      assert!(parse_response(&complete[..cut]).is_none());
    }
    let arbitrary: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(256));
    let _ = response_complete(&arbitrary);
    let _ = parse_response(&arbitrary);
  }

  const DOCUMENT: &str = r#"{"version":1,"placement":"dddddddd-dddd-4ddd-8ddd-000000000201","execution_epoch":7,"boot_challenge":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ipv4":"10.10.0.203","prefix_length":32,"gateway":"10.10.0.1","mac":"02:fc:0a:00:00:cb"}"#;

  fn serve(listener: TcpListener) {
    std::thread::spawn(move || {
      for stream in listener.incoming().take(2) {
        let mut stream = stream.unwrap();
        std::thread::spawn(move || {
        let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
        let mut request = String::new();
        let mut headers = Vec::new();
        loop {
          let mut line = String::new();
          reader.read_line(&mut line).unwrap();
          if line == "\r\n" || line.is_empty() { break; }
          if request.is_empty() { request = line.clone(); } else { headers.push(line); }
        }
        let response = if request.starts_with("PUT /latest/api/token") {
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nTOKEN123".to_string()
        } else {
          assert!(request.starts_with("GET /lilly"));
          assert!(headers.iter().any(|header| header.starts_with("X-metadata-token: TOKEN123")));
          format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{DOCUMENT}", DOCUMENT.len())
        };
        stream.write_all(response.as_bytes()).unwrap();
        // Keep the connection open as MMDS does; the client stops at Content-Length.
        std::thread::sleep(Duration::from_secs(3));
        });
      }
    });
  }

  #[test]
  fn fetches_the_subtree_with_a_session_token() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let std::net::SocketAddr::V4(address) = listener.local_addr().unwrap() else { unreachable!() };
    serve(listener);
    let started = Instant::now();
    let (challenge, placement, epoch) = fetch_once(address, Duration::from_secs(5)).unwrap();
    assert!(started.elapsed() < Duration::from_secs(3));
    assert_eq!(challenge, "b".repeat(64));
    assert_eq!(placement, "dddddddd-dddd-4ddd-8ddd-000000000201");
    assert_eq!(epoch, "7");
  }

  #[test]
  fn refuses_envelopes_versions_and_zero_epochs() {
    assert!(decode(DOCUMENT.as_bytes()).is_some());
    assert!(decode(format!("{{\"lilly\":{DOCUMENT}}}").as_bytes()).is_none());
    assert!(decode(DOCUMENT.replace("\"version\":1", "\"version\":2").as_bytes()).is_none());
    assert!(decode(DOCUMENT.replace("\"execution_epoch\":7", "\"execution_epoch\":0").as_bytes()).is_none());
    assert!(parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort").is_none());
  }
}
