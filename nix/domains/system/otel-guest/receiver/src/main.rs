//! Audi-only Unix socket server for bounded OTLP/HTTP protobuf payloads.

use overalls_otel_guest_receiver::{parse_binding, sanitize_metrics, sanitize_traces, IntakeLimit};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MAX_BODY: usize = 1_048_576;
const MAX_HEADERS: usize = 8192;
const MAX_CONCURRENT: usize = 16;

fn peer_uid(stream: &UnixStream) -> std::io::Result<u32> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: credentials points to a writable ucred of exactly length bytes.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 || length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(std::io::Error::last_os_error());
    }
    Ok(credentials.uid)
}

fn read_line(stream: &mut UnixStream, limit: usize) -> Result<Vec<u8>, &'static str> {
    let mut line = Vec::new();
    loop {
        if line.len() >= limit {
            return Err("line_limit");
        }
        let mut byte = [0u8];
        stream.read_exact(&mut byte).map_err(|_| "read")?;
        line.push(byte[0]);
        if line.ends_with(b"\r\n") {
            return Ok(line);
        }
    }
}

fn read_request(stream: &mut UnixStream) -> Result<(&'static str, String, Vec<u8>), &'static str> {
    let line = read_line(stream, 128)?;
    let path = match line.as_slice() {
        b"POST /v1/metrics HTTP/1.1\r\n" => "/v1/metrics",
        b"POST /v1/traces HTTP/1.1\r\n" => "/v1/traces",
        _ => return Err("route"),
    };
    let mut consumed = line.len();
    let mut binding = None;
    let mut content_type = None;
    let mut transfer_encoding = None;
    let mut content_length = false;
    loop {
        let header = read_line(stream, MAX_HEADERS - consumed)?;
        consumed += header.len();
        if header == b"\r\n" {
            break;
        }
        let header = std::str::from_utf8(&header).map_err(|_| "header_utf8")?;
        let (name, value) = header[..header.len() - 2]
            .split_once(':')
            .ok_or("header_shape")?;
        let value = value.trim();
        match name.to_ascii_lowercase().as_str() {
            "x-overalls-binding" if binding.is_none() => binding = Some(value.to_owned()),
            "x-overalls-binding" => return Err("duplicate_binding"),
            "content-type" if content_type.is_none() => content_type = Some(value.to_owned()),
            "content-type" => return Err("duplicate_content_type"),
            "transfer-encoding" if transfer_encoding.is_none() => {
                transfer_encoding = Some(value.to_owned())
            }
            "transfer-encoding" => return Err("duplicate_transfer_encoding"),
            "content-length" => content_length = true,
            "content-encoding" => return Err("content_encoding"),
            _ => {}
        }
    }
    if content_type.as_deref() != Some("application/x-protobuf")
        || !transfer_encoding
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case("chunked"))
        || content_length
    {
        return Err("headers");
    }
    let binding = binding.ok_or("binding")?;
    let mut body = Vec::new();
    loop {
        let line = read_line(stream, 16)?;
        let size = std::str::from_utf8(&line[..line.len() - 2])
            .ok()
            .and_then(|value| usize::from_str_radix(value, 16).ok())
            .ok_or("chunk_size")?;
        if size == 0 {
            let mut terminator = [0u8; 2];
            stream.read_exact(&mut terminator).map_err(|_| "trailer")?;
            if terminator != *b"\r\n" {
                return Err("trailer");
            }
            break;
        }
        if size > MAX_BODY - body.len() {
            return Err("body_limit");
        }
        let start = body.len();
        body.resize(start + size + 2, 0);
        stream.read_exact(&mut body[start..]).map_err(|_| "body")?;
        if body[start + size..] != *b"\r\n" {
            return Err("chunk_end");
        }
        body.truncate(start + size);
    }
    Ok((path, binding, body))
}

fn forward(path: &str, body: &[u8]) -> Result<(), &'static str> {
    let mut collector = TcpStream::connect_timeout(
        &"127.0.0.1:4318".parse().map_err(|_| "address")?,
        Duration::from_secs(3),
    )
    .map_err(|_| "collector")?;
    collector
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "timeout")?;
    collector
        .set_write_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "timeout")?;
    write!(
        collector,
        "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:4318\r\nContent-Type: application/x-protobuf\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .map_err(|_| "write")?;
    collector.write_all(body).map_err(|_| "write")?;
    let line = {
        let mut line = Vec::new();
        loop {
            if line.len() >= 128 {
                return Err("response");
            }
            let mut byte = [0u8];
            collector.read_exact(&mut byte).map_err(|_| "response")?;
            line.push(byte[0]);
            if line.ends_with(b"\r\n") {
                break line;
            }
        }
    };
    if line.starts_with(b"HTTP/1.1 200 ") || line.starts_with(b"HTTP/1.0 200 ") {
        Ok(())
    } else {
        Err("collector_status")
    }
}

fn handle(mut stream: UnixStream, audi_uid: u32, limit: &Mutex<IntakeLimit>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
    let status = if peer_uid(&stream).ok() != Some(audi_uid) {
        403
    } else {
        match read_request(&mut stream) {
            Ok((path, header, body)) => match parse_binding(&header) {
                Ok(binding) => {
                    let admitted = limit
                        .lock()
                        .ok()
                        .map(|mut guard| guard.admit(&binding, body.len(), Instant::now()));
                    match admitted {
                        Some(true) => {
                            let clean = if path == "/v1/metrics" {
                                sanitize_metrics(&body, &binding)
                            } else {
                                sanitize_traces(&body, &binding)
                            };
                            match clean {
                                Ok(payload) => match forward(path, &payload) {
                                    Ok(()) => 200,
                                    Err(_) => 503,
                                },
                                Err(_) => 400,
                            }
                        }
                        Some(false) => 429,
                        None => 503,
                    }
                }
                Err(_) => 400,
            },
            Err(_) => 400,
        }
    };
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        _ => "Bad Request",
    };
    let _ = write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let _ = stream.shutdown(Shutdown::Both);
}

fn audi_uid() -> Result<u32, &'static str> {
    let name = std::ffi::CString::new("audi").map_err(|_| "name")?;
    // SAFETY: name is a NUL terminated CString; passwd pointer is read immediately.
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        return Err("audi_user");
    }
    // SAFETY: getpwnam returned a non-null pointer, and no other libc account lookup occurs.
    Ok(unsafe { (*entry).pw_uid })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("socket path required")?;
    let path = Path::new(&path);
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660))?;
    let uid = audi_uid()?;
    let active = Arc::new(AtomicUsize::new(0));
    let limit = Arc::new(Mutex::new(IntakeLimit::new(Instant::now())));
    for stream in listener.incoming() {
        let stream = stream?;
        if active.fetch_add(1, Ordering::AcqRel) >= MAX_CONCURRENT {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        let active = Arc::clone(&active);
        let limit = Arc::clone(&limit);
        std::thread::spawn(move || {
            handle(stream, uid, &limit);
            active.fetch_sub(1, Ordering::AcqRel);
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    fn request(chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut bytes = b"POST /v1/metrics HTTP/1.1\r\nHost: otel.integration.internal\r\nContent-Type: application/x-protobuf\r\nTransfer-Encoding: chunked\r\nX-Overalls-Binding: e30\r\n\r\n".to_vec();
        for chunk in chunks {
            bytes.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
            bytes.extend_from_slice(chunk);
            bytes.extend_from_slice(b"\r\n");
        }
        bytes.extend_from_slice(b"0\r\n\r\n");
        bytes
    }

    fn parse(bytes: Vec<u8>) -> Result<(&'static str, String, Vec<u8>), &'static str> {
        let (mut read, mut write) = UnixStream::pair().expect("local socket pair");
        std::thread::spawn(move || write.write_all(&bytes).expect("write fixture"));
        read_request(&mut read)
    }

    /// @cc [owner:ghuntley,label:verification] otel-receiver-chunk-boundary-property
    /// Generated chunk boundaries MUST reassemble to exactly the concatenated payload.
    #[hegel::test(test_cases = 256)]
    fn chunk_boundaries_preserve_payload(tc: TestCase) {
        let chunks = tc.draw(
            gs::vecs(gs::vecs(gs::integers::<u8>()).min_size(1).max_size(99))
                .min_size(1)
                .max_size(19),
        );
        let expected: Vec<u8> = chunks.iter().flatten().copied().collect();
        let (_, _, body) = parse(request(&chunks)).expect("valid chunked request");
        assert_eq!(body, expected);
    }

    #[test]
    fn duplicate_binding_is_refused() {
        let mut bytes = request(&[vec![1]]);
        let at = bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .expect("headers");
        bytes.splice(at..at, b"\r\nX-Overalls-Binding: e30".iter().copied());
        assert!(parse(bytes).is_err());
    }

    #[test]
    fn declared_length_with_chunks_is_refused() {
        let mut bytes = request(&[vec![1]]);
        let at = bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .expect("headers");
        bytes.splice(at..at, b"\r\nContent-Length: 1".iter().copied());
        assert!(parse(bytes).is_err());
    }
}
