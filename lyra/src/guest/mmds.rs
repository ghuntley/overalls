//! Lilly's boot identity for firmware-booted guests, read from Firecracker's
//! MMDS (ADR-0170, ADR-0171).
//!
//! Kernel guests read the same identity from their command line. Firmware
//! guests fetch `/lilly` over MMDS version 2: a session token from
//! `PUT /latest/api/token`, then `GET /lilly` with that token. The client is a
//! bounded HTTP/1.1 exchange over one TCP connection per request with no
//! dependency, because MMDS is plain HTTP inside the VMM and the agents must
//! not carry a TLS stack for it. The token is never logged or persisted.

use serde::Deserialize;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::time::Duration;

/// Firecracker's MMDS endpoint.
pub const ADDRESS: Ipv4Addr = Ipv4Addr::new(169, 254, 169, 254);
const MAXIMUM_RESPONSE: usize = 8192;

/// The `lilly` document Lilly seeds before launch (version 1).
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Document {
    pub version: u8,
    #[serde(default, deserialize_with = "deserialize_git_identity")]
    pub git_identity: Option<super::git_identity::GitIdentity>,
    pub placement: String,
    pub execution_epoch: u64,
    pub boot_challenge: String,
    pub ipv4: String,
    pub prefix_length: u8,
    pub gateway: String,
    pub mac: String,
}

fn deserialize_git_identity<'de, D>(
    deserializer: D,
) -> Result<Option<super::git_identity::GitIdentity>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    super::git_identity::GitIdentity::deserialize(deserializer).map(Some)
}

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

impl Document {
    /// @cc [owner:ghuntley,label:security] mmds-document-validated
    /// A document MUST be version 1 with a lowercase UUID placement, a positive
    /// epoch, a 64-hex lowercase challenge, dotted IPv4 address and gateway, a
    /// prefix length of 32 and a 17-character MAC; anything else is refused
    /// before any field is used.
    pub fn validate(self) -> io::Result<Self> {
        let invalid = || io::Error::other("invalid lilly document");
        if self.version != 1
            || !valid_uuid(&self.placement)
            || self.execution_epoch == 0
            || !valid_hex(&self.boot_challenge, 64)
            || self.ipv4.parse::<Ipv4Addr>().is_err()
            || self.prefix_length != 32
            || self.gateway.parse::<Ipv4Addr>().is_err()
            || self.mac.len() != 17
        {
            return Err(invalid());
        }
        if let Some(identity) = &self.git_identity {
            identity.validate()?;
        }
        Ok(self)
    }

    /// Parse and validate the body MMDS serves for `GET /lilly`: the `lilly`
    /// subtree itself, not the `{"lilly": {...}}` object Lilly seeds.
    pub fn parse(body: &[u8]) -> io::Result<Self> {
        let document: Document =
            serde_json::from_slice(body).map_err(|_| io::Error::other("invalid lilly document"))?;
        document.validate()
    }
}

/// One bounded HTTP/1.1 request; returns the status code and body.
fn exchange(
    address: SocketAddrV4,
    request: &[u8],
    timeout: Duration,
) -> io::Result<(u16, Vec<u8>)> {
    let mut stream = TcpStream::connect_timeout(&address.into(), timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(request)?;
    // MMDS may keep the connection open after answering, so read until the
    // declared body has arrived (or the server closes) instead of to EOF.
    let mut raw = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        if raw.len() > MAXIMUM_RESPONSE {
            return Err(io::Error::other("oversized MMDS response"));
        }
        if response_complete(&raw) {
            break;
        }
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..read]);
    }
    parse_response(&raw)
}

/// Whether `raw` holds complete headers and, when a Content-Length is
/// declared, the whole body.
fn response_complete(raw: &[u8]) -> bool {
    let Some(split) = raw.windows(4).position(|window| window == b"\r\n\r\n") else {
        return false;
    };
    let head = String::from_utf8_lossy(&raw[..split]);
    let length = head.split("\r\n").skip(1).find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("content-length")
            .then(|| value.trim().parse::<usize>().ok())
            .flatten()
    });
    match length {
        Some(length) => raw.len() - split - 4 >= length,
        None => false,
    }
}

/// Split a raw HTTP/1.1 response into its status and body, honouring
/// Content-Length when present.
pub fn parse_response(raw: &[u8]) -> io::Result<(u16, Vec<u8>)> {
    let invalid = || io::Error::other("invalid MMDS response");
    let split = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(invalid)?;
    let head = std::str::from_utf8(&raw[..split]).map_err(|_| invalid())?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().ok_or_else(invalid)?;
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().ok_or_else(invalid)?;
    if version != "HTTP/1.1" && version != "HTTP/1.0" {
        return Err(invalid());
    }
    let status: u16 = parts
        .next()
        .ok_or_else(invalid)?
        .parse()
        .map_err(|_| invalid())?;
    let mut length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                length = Some(value.trim().parse::<usize>().map_err(|_| invalid())?);
            }
        }
    }
    let body = &raw[split + 4..];
    let body = match length {
        Some(length) if length <= body.len() => &body[..length],
        Some(_) => return Err(invalid()),
        None => body,
    };
    Ok((status, body.to_vec()))
}

/// Fetch and validate the `lilly` document with a fresh version-2 session token.
pub fn fetch(timeout: Duration) -> io::Result<Document> {
    fetch_from(SocketAddrV4::new(ADDRESS, 80), timeout)
}

/// @cc [owner:ghuntley,label:security] mmds-v2-token-per-fetch
/// Every fetch MUST obtain its own short-lived session token with
/// `X-metadata-token-ttl-seconds`, send it only as `X-metadata-token` on the
/// following `GET /lilly`, and MUST NOT log, persist or return it.
pub fn fetch_from(address: SocketAddrV4, timeout: Duration) -> io::Result<Document> {
    let token_request = format!(
        "PUT /latest/api/token HTTP/1.1\r\nHost: {}\r\nX-metadata-token-ttl-seconds: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        address.ip()
    );
    let (status, token) = exchange(address, token_request.as_bytes(), timeout)?;
    let token = String::from_utf8(token).map_err(|_| io::Error::other("invalid MMDS token"))?;
    let token = token.trim();
    if status != 200
        || token.is_empty()
        || token.len() > 512
        || !token.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || byte == b'='
                || byte == b'/'
                || byte == b'+'
                || byte == b'-'
                || byte == b'_'
        })
    {
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
    Document::parse(&body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;
    use std::net::TcpListener;

    const DOCUMENT: &str = r#"{"version":1,"placement":"dddddddd-dddd-4ddd-8ddd-000000000201","execution_epoch":7,"boot_challenge":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ipv4":"10.10.0.203","prefix_length":32,"gateway":"10.10.0.1","mac":"02:fc:0a:00:00:cb"}"#;

    #[test]
    fn optional_git_identity_is_validated_and_null_is_not_absence() {
        let mut document: serde_json::Value = serde_json::from_str(DOCUMENT).unwrap();
        document["git_identity"] =
            serde_json::json!({"version":1,"name":"Author","email":"author@example.test"});
        assert!(Document::parse(&serde_json::to_vec(&document).unwrap())
            .unwrap()
            .git_identity
            .is_some());
        for value in [
            serde_json::Value::Null,
            serde_json::json!({"version":1,"name":"Bad\nName","email":"author@example.test"}),
            serde_json::json!({"version":2,"name":"Author","email":"author@example.test"}),
        ] {
            document["git_identity"] = value;
            assert!(Document::parse(&serde_json::to_vec(&document).unwrap()).is_err());
        }
    }

    fn serve(listener: TcpListener) {
        serve_with(listener, false);
    }

    /// `linger` keeps each connection open after the response, as MMDS does.
    fn serve_with(listener: TcpListener, linger: bool) {
        std::thread::spawn(move || {
            for stream in listener.incoming().take(2) {
                let mut stream = stream.unwrap();
                std::thread::spawn(move || {
                    let mut reader = io::BufReader::new(stream.try_clone().unwrap());
                    let mut request = String::new();
                    let mut headers = Vec::new();
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).unwrap();
                        if line == "\r\n" || line.is_empty() {
                            break;
                        }
                        if request.is_empty() {
                            request = line.clone();
                        } else {
                            headers.push(line);
                        }
                    }
                    let response = if request.starts_with("PUT /latest/api/token") {
                        assert!(headers
                            .iter()
                            .any(|h| h.starts_with("X-metadata-token-ttl-seconds: 60")));
                        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nTOKEN123".to_string()
                    } else {
                        assert!(request.starts_with("GET /lilly"), "{request}");
                        assert!(headers
                            .iter()
                            .any(|h| h.starts_with("X-metadata-token: TOKEN123")));
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{DOCUMENT}",
                            DOCUMENT.len()
                        )
                    };
                    stream.write_all(response.as_bytes()).unwrap();
                    if linger {
                        std::thread::sleep(Duration::from_secs(8));
                    }
                });
            }
        });
    }

    #[test]
    fn fetches_with_a_session_token_and_validates() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let std::net::SocketAddr::V4(address) = listener.local_addr().unwrap() else {
            unreachable!()
        };
        serve(listener);
        let document = fetch_from(address, Duration::from_secs(5)).unwrap();
        assert_eq!(document.placement, "dddddddd-dddd-4ddd-8ddd-000000000201");
        assert_eq!(document.execution_epoch, 7);
        assert_eq!(document.ipv4, "10.10.0.203");
        assert_eq!(document.gateway, "10.10.0.1");
    }

    #[test]
    fn completes_without_waiting_for_the_server_to_close() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let std::net::SocketAddr::V4(address) = listener.local_addr().unwrap() else {
            unreachable!()
        };
        serve_with(listener, true);
        let started = std::time::Instant::now();
        let document = fetch_from(address, Duration::from_secs(5)).unwrap();
        assert_eq!(document.execution_epoch, 7);
        assert!(
            started.elapsed() < Duration::from_secs(4),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn refuses_invalid_documents_and_responses() {
        for broken in [
            DOCUMENT.replace("\"version\":1", "\"version\":2"),
            DOCUMENT.replace("\"prefix_length\":32", "\"prefix_length\":24"),
            DOCUMENT.replace("\"execution_epoch\":7", "\"execution_epoch\":0"),
            DOCUMENT.replace(
                "dddddddd-dddd-4ddd-8ddd-000000000201",
                "DDDDDDDD-dddd-4ddd-8ddd-000000000201",
            ),
            DOCUMENT.replace("\"mac\":\"02:fc:0a:00:00:cb\"", "\"mac\":\"02fc0a0000cb\""),
            DOCUMENT.replace("\"gateway\"", "\"gateway6\""),
            DOCUMENT.replace(
                ",\"mac\":\"02:fc:0a:00:00:cb\"",
                ",\"mac\":\"02:fc:0a:00:00:cb\",\"extra\":1",
            ),
            // MMDS serves the subtree for `GET /lilly`; the seeded envelope is refused.
            format!("{{\"lilly\":{DOCUMENT}}}"),
        ] {
            assert!(Document::parse(broken.as_bytes()).is_err(), "{broken}");
        }
        assert!(Document::parse(DOCUMENT.as_bytes()).is_ok());
        assert!(parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort").is_err());
        assert!(parse_response(b"garbage").is_err());
        assert_eq!(
            parse_response(b"HTTP/1.1 404 Not Found\r\n\r\nbody").unwrap(),
            (404, b"body".to_vec())
        );
    }
}
