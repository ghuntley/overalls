//! Fixed numeric storage diagnostics; no application files or names are exported.
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::Command;
use std::time::Duration;

/// @cc [owner:ghuntley,label:security] storage-fixed-paths
/// Only aggregate allocated bytes for the two fixed telemetry stores and root
/// available bytes MAY leave this process. Failed reads MUST omit the metric.
fn measurements(du: &str) -> String {
    let mut result = String::new();
    for (store, path) in [
        ("metrics", "/var/lib/prometheus2"),
        ("traces", "/var/lib/tempo"),
    ] {
        if let Ok(output) = Command::new(du).args(["-s", "-B1", "--", path]).output() {
            if output.status.success() {
                if let Some(bytes) = String::from_utf8_lossy(&output.stdout)
                    .split_whitespace()
                    .next()
                    .and_then(|s| s.parse::<u64>().ok())
                {
                    // Writing to a String cannot fail.
                    let _ = writeln!(
                        result,
                        "overalls_telemetry_storage_used_bytes{{store=\"{store}\"}} {bytes}"
                    );
                }
            }
        }
    }
    let root = c"/";
    let mut info = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: statvfs receives a static NUL-terminated path and writable
    // storage for exactly one statvfs record.
    if unsafe { libc::statvfs(root.as_ptr(), info.as_mut_ptr()) } == 0 {
        // SAFETY: statvfs returned 0, so the kernel initialized every field.
        let info = unsafe { info.assume_init() };
        if let Some(bytes) = info.f_bavail.checked_mul(info.f_frsize) {
            // Writing to a String cannot fail.
            let _ = writeln!(result, "overalls_telemetry_root_available_bytes {bytes}");
        }
    }
    result
}

/// @cc [owner:ghuntley,label:security] storage-loopback-probe
/// The probe MUST bind only IPv4 loopback and return fixed aggregate metrics.
/// Request bytes and collection diagnostics MUST NOT enter logs or responses.
fn main() -> std::io::Result<()> {
    let du = std::env::args()
        .nth(1)
        .ok_or(std::io::ErrorKind::InvalidInput)?;
    let listener = TcpListener::bind("127.0.0.1:9465")?;
    for stream in listener.incoming() {
        let mut stream = stream?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        let mut request = [0u8; 1024];
        if stream.read(&mut request).is_err() {
            continue;
        }
        let body = measurements(&du);
        let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        let _ = stream.write_all(response.as_bytes());
    }
    Ok(())
}
