//! Bounded Unix OTLP ingress. All refusals use closed outcomes; no payload logs.
#![deny(unsafe_code)]
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceResponse;
use overalls_trace_spool::{sys, Error, Schema, Store, BODY_LIMIT};
use prost::Message;
use serde::Deserialize;
use std::ffi::CString;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    service: String,
    host: String,
    revision: String,
    producer_user: String,
    producer_unit: String,
    producer_cgroup: String,
    state: PathBuf,
    socket: PathBuf,
    sink: PathBuf,
    metrics: PathBuf,
    schema: PathBuf,
    quota_bytes: u64,
    pending_quota_bytes: u64,
    retention_seconds: u64,
}

fn now_ns() -> Result<u64, Error> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::Storage)?
        .as_nanos()
        .try_into()
        .map_err(|_| Error::Storage)
}

fn ticks(pid: libc::pid_t) -> Result<u64, Error> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).map_err(|_| Error::Foreign)?;
    stat.rsplit_once(") ")
        .and_then(|(_, rest)| rest.split_whitespace().nth(19))
        .and_then(|s| s.parse().ok())
        .ok_or(Error::Foreign)
}

fn authenticate(stream: &UnixStream, config: &Config) -> Result<(libc::pid_t, u64), Error> {
    let credentials = sys::peer_credentials(stream)
        .filter(|credentials| credentials.pid > 0)
        .ok_or(Error::Foreign)?;
    let user = CString::new(config.producer_user.as_str()).map_err(|_| Error::Invalid)?;
    if sys::user_uid(&user) != Some(credentials.uid) {
        return Err(Error::Foreign);
    }
    let before = ticks(credentials.pid)?;
    let cgroup = std::fs::read_to_string(format!("/proc/{}/cgroup", credentials.pid))
        .map_err(|_| Error::Foreign)?;
    let matches = cgroup.lines().any(|line| {
        line.strip_prefix("0::")
            .is_some_and(|path| path == config.producer_cgroup)
    });
    if !matches || ticks(credentials.pid)? != before {
        return Err(Error::Foreign);
    }
    Ok((credentials.pid, before))
}

fn read_before(
    stream: &mut UnixStream,
    bytes: &mut [u8],
    deadline: Instant,
) -> Result<usize, Error> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .ok_or(Error::Invalid)?;
    stream
        .set_read_timeout(Some(remaining))
        .map_err(|_| Error::Invalid)?;
    stream.read(bytes).map_err(|_| Error::Invalid)
}

fn request(stream: &mut UnixStream) -> Result<Vec<u8>, Error> {
    let deadline = Instant::now() + Duration::from_millis(250);
    let mut bytes = Vec::new();
    let mut chunk = [0; 4096];
    let split = loop {
        let length = read_before(stream, &mut chunk, deadline)?;
        if length == 0 {
            return Err(Error::Invalid);
        }
        bytes.extend_from_slice(&chunk[..length]);
        if let Some(split) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            if split > 4096 {
                return Err(Error::Capacity);
            }
            break split;
        }
        if bytes.len() > 4096 {
            return Err(Error::Capacity);
        }
    };
    let headers = std::str::from_utf8(&bytes[..split]).map_err(|_| Error::Invalid)?;
    let mut lines = headers.split("\r\n");
    if lines.next() != Some("POST /v1/traces HTTP/1.1") {
        return Err(Error::Invalid);
    }
    let mut length = None;
    let mut content_type = false;
    for line in lines {
        let (name, value) = line.split_once(':').ok_or(Error::Invalid)?;
        match name.to_ascii_lowercase().as_str() {
            "content-length" => {
                if length.is_some() || !value.trim().bytes().all(|b| b.is_ascii_digit()) {
                    return Err(Error::Invalid);
                }
                length = Some(value.trim().parse::<usize>().map_err(|_| Error::Invalid)?);
            }
            "content-type" => {
                if content_type || value.trim() != "application/x-protobuf" {
                    return Err(Error::Invalid);
                }
                content_type = true;
            }
            "transfer-encoding" => return Err(Error::Invalid),
            _ => {}
        }
    }
    let length = length.ok_or(Error::Invalid)?;
    if length == 0 || length > BODY_LIMIT || !content_type {
        return Err(Error::Capacity);
    }
    let mut body = bytes.split_off(split + 4);
    if body.len() > length {
        return Err(Error::Invalid);
    }
    let prefetched = body.len();
    body.resize(length, 0);
    let mut received = prefetched;
    while received < length {
        let count = read_before(stream, &mut body[received..], deadline)?;
        if count == 0 {
            return Err(Error::Invalid);
        }
        received += count;
    }
    Ok(body)
}

/// @cc [owner:ghuntley,label:recovery;security] trace-forward-complete-otlp-ack
/// Only a bounded, completely framed successful HTTP reply containing a valid
/// OTLP response with absent or zero rejected spans MAY retire pending custody.
/// Invalid/truncated replies and nonzero rejected counts MUST retain pending
/// custody. Zero-rejection warning text MUST remain private.
fn forward(body: &[u8], socket: &Path) -> Result<(), Error> {
    let mut stream = UnixStream::connect(socket).map_err(|_| Error::Storage)?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| Error::Storage)?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| Error::Storage)?;
    write!(stream, "POST /v1/traces HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-protobuf\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).map_err(|_| Error::Storage)?;
    stream.write_all(body).map_err(|_| Error::Storage)?;
    let mut reply = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut chunk = [0; 4097];
    loop {
        let count = read_before(&mut stream, &mut chunk[..4097 - reply.len()], deadline)?;
        if count == 0 {
            break;
        }
        reply.extend_from_slice(&chunk[..count]);
        if reply.len() > 4096 {
            return Err(Error::Invalid);
        }
    }
    if reply.len() > 4096 {
        return Err(Error::Invalid);
    }
    let split = reply
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .ok_or(Error::Invalid)?;
    let header = std::str::from_utf8(&reply[..split]).map_err(|_| Error::Invalid)?;
    let mut lines = header.split("\r\n");
    let mut status_line = lines.next().ok_or(Error::Invalid)?.split_whitespace();
    if !matches!(status_line.next(), Some("HTTP/1.0" | "HTTP/1.1")) {
        return Err(Error::Invalid);
    }
    let status = status_line.next().ok_or(Error::Invalid)?;
    if status != "200" && status != "202" && status != "204" {
        return Err(Error::Storage);
    }
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let (key, value) = line.split_once(':').ok_or(Error::Invalid)?;
        if key.is_empty()
            || !key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(Error::Invalid);
        }
        let value = value.trim();
        if key.eq_ignore_ascii_case("content-length") {
            if length.is_some()
                || value.is_empty()
                || !value.bytes().all(|byte| byte.is_ascii_digit())
            {
                return Err(Error::Invalid);
            }
            length = Some(value.parse::<usize>().map_err(|_| Error::Invalid)?);
        } else if key.eq_ignore_ascii_case("transfer-encoding") {
            if chunked || !value.eq_ignore_ascii_case("chunked") {
                return Err(Error::Invalid);
            }
            chunked = true;
        } else if key.eq_ignore_ascii_case("content-type")
            && !value.eq_ignore_ascii_case("application/x-protobuf")
        {
            return Err(Error::Invalid);
        }
    }
    let response = &reply[split + 4..];
    if chunked && length.is_some() || length.is_some_and(|length| length != response.len()) {
        return Err(Error::Invalid);
    }
    let decoded_chunks;
    let response = if chunked {
        decoded_chunks = response_chunks(response)?;
        decoded_chunks.as_slice()
    } else {
        response
    };
    let response = ExportTraceServiceResponse::decode(response).map_err(|_| Error::Invalid)?;
    if response
        .partial_success
        .is_some_and(|partial| partial.rejected_spans != 0)
    {
        return Err(Error::Invalid);
    }
    Ok(())
}

fn response_chunks(mut bytes: &[u8]) -> Result<Vec<u8>, Error> {
    let mut body = Vec::new();
    loop {
        let split = bytes
            .windows(2)
            .position(|part| part == b"\r\n")
            .ok_or(Error::Invalid)?;
        let size = std::str::from_utf8(&bytes[..split]).map_err(|_| Error::Invalid)?;
        if size.is_empty() || size.len() > 8 || !size.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(Error::Invalid);
        }
        let size = usize::from_str_radix(size, 16).map_err(|_| Error::Invalid)?;
        bytes = &bytes[split + 2..];
        if size == 0 {
            return if bytes == b"\r\n" {
                Ok(body)
            } else {
                Err(Error::Invalid)
            };
        }
        let end = size.checked_add(2).ok_or(Error::Invalid)?;
        if bytes.len() < end || &bytes[size..end] != b"\r\n" {
            return Err(Error::Invalid);
        }
        body.extend_from_slice(&bytes[..size]);
        bytes = &bytes[end..];
    }
}

fn metrics(path: &Path, body: &str) -> Result<(), Error> {
    let stage = path.with_extension("new");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o640)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&stage)
        .map_err(|_| Error::Storage)?;
    let metadata = file.metadata().map_err(|_| Error::Storage)?;
    if !metadata.is_file() || metadata.uid() != sys::geteuid() || metadata.nlink() != 1 {
        return Err(Error::Storage);
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o640))
        .map_err(|_| Error::Storage)?;
    file.write_all(body.as_bytes())
        .map_err(|_| Error::Storage)?;
    std::fs::rename(stage, path).map_err(|_| Error::Storage)
}

/// @cc [owner:ghuntley,label:capacity;recovery] trace-export-eager-success
/// Accepted backlog MUST drain without a fixed delay between successful durable
/// deliveries. Network I/O MUST remain outside the custody mutex. Maintenance
/// and health publication MUST run no faster than every 250ms during a drain;
/// failed forwarding or delivery storage MUST return to the idle/failure backoff.
fn drain_pending(store: &Mutex<Store>, sink: &Path, health: &Path) -> Result<(), Error> {
    let mut maintenance_due = Instant::now();
    loop {
        let candidate = {
            let mut state = store.lock().map_err(|_| Error::Poisoned)?;
            if Instant::now() >= maintenance_due {
                let now = now_ns()?;
                let expired = state.expire(now);
                let _ = metrics(health, &state.metrics(now));
                maintenance_due = Instant::now() + Duration::from_millis(250);
                expired?;
            }
            match state.pending()? {
                Some(batch) => Some((batch.id.clone(), state.body(&batch)?)),
                None => None,
            }
        };
        let Some((id, body)) = candidate else {
            return Ok(());
        };
        if let Err(error) = forward(&body, sink) {
            store
                .lock()
                .map_err(|_| Error::Poisoned)?
                .health
                .export_failures += 1;
            return Err(error);
        }
        store.lock().map_err(|_| Error::Poisoned)?.delivered(&id)?;
        std::thread::yield_now();
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "ordered daemon start-up: configuration, custody, socket ownership, then the accept loop"
)]
fn run(config: &Config, replay_only: bool) -> Result<(), Error> {
    let simple = |value: &str| {
        !value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_.@-".contains(&byte))
    };
    if !simple(&config.service)
        || !simple(&config.host)
        || !simple(&config.revision)
        || config.revision.len() > 64
        || !simple(&config.producer_user)
        || !simple(&config.producer_unit)
        || config.service.len() > 32
        || config.host.len() > 64
        || config.producer_user.len() > 64
        || config.producer_unit.len() > 120
        || !config.producer_unit.ends_with(".service")
        || !config.producer_cgroup.starts_with('/')
        || config.producer_cgroup.len() > 256
        || config.producer_cgroup.rsplit('/').next() != Some(config.producer_unit.as_str())
        || !config.producer_cgroup.split('/').skip(1).all(simple)
    {
        return Err(Error::Invalid);
    }
    let schema = Schema::load(&config.schema)?;
    if !schema.services.contains_key(&config.service) {
        return Err(Error::Invalid);
    }
    let mut store = Store::open(&config.state, config.quota_bytes, config.retention_seconds)?;
    store.set_pending_quota(config.pending_quota_bytes)?;
    store.bind(
        &config.service,
        &config.host,
        &config.producer_user,
        &config.producer_unit,
        &config.producer_cgroup,
    )?;
    if replay_only {
        store.replay()?;
    }
    if replay_only {
        return Ok(());
    }
    let parent = config.socket.parent().ok_or(Error::Storage)?;
    let metadata = std::fs::symlink_metadata(parent).map_err(|_| Error::Storage)?;
    if !metadata.is_dir() || metadata.uid() != sys::geteuid() || metadata.mode() & 0o007 != 0 {
        return Err(Error::Storage);
    }
    match std::fs::symlink_metadata(&config.socket) {
        Ok(metadata) => {
            if !std::os::unix::fs::FileTypeExt::is_socket(&metadata.file_type())
                || metadata.uid() != sys::geteuid()
            {
                return Err(Error::Storage);
            }
            std::fs::remove_file(&config.socket).map_err(|_| Error::Storage)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Error::Storage),
    }
    let listener = UnixListener::bind(&config.socket).map_err(|_| Error::Storage)?;
    std::fs::set_permissions(&config.socket, std::fs::Permissions::from_mode(0o660))
        .map_err(|_| Error::Storage)?;
    listener.set_nonblocking(true).map_err(|_| Error::Storage)?;
    let store = Arc::new(Mutex::new(store));
    let exporter_store = Arc::clone(&store);
    let sink = config.sink.clone();
    let health_path = config.metrics.clone();
    std::thread::spawn(move || loop {
        let _ = drain_pending(&exporter_store, &sink, &health_path);
        // Only an idle queue or a failed forward/storage attempt reaches here.
        std::thread::sleep(Duration::from_millis(250));
    });
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                stream
                    .set_read_timeout(Some(Duration::from_millis(250)))
                    .map_err(|_| Error::Storage)?;
                stream
                    .set_write_timeout(Some(Duration::from_millis(250)))
                    .map_err(|_| Error::Storage)?;
                let result = (|| {
                    let authenticated = authenticate(&stream, config);
                    // Drain the bounded request before a closed refusal, so
                    // Unix close cannot reset an unread request and erase the
                    // explicit status. No decoding/storage precedes authority.
                    let requested = request(&mut stream);
                    let producer = authenticated?;
                    let body = requested?;
                    if authenticate(&stream, config)? != producer {
                        return Err(Error::Foreign);
                    }
                    let body =
                        schema.sanitize(&body, &config.service, &config.host, &config.revision)?;
                    store
                        .lock()
                        .map_err(|_| Error::Storage)?
                        .accept(&body, now_ns()?)
                        .map(|_| ())
                })();
                let status = match result {
                    Ok(()) => "200 OK",
                    Err(Error::Foreign) => "403 Forbidden",
                    Err(Error::Invalid) => "400 Bad Request",
                    Err(Error::Capacity) => "429 Too Many Requests",
                    Err(Error::Storage | Error::Poisoned) => "503 Service Unavailable",
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return Err(Error::Storage),
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (path, replay) = match args.as_slice() {
        [path] => (path, false),
        [path, flag] if flag == "--replay" => (path, true),
        _ => std::process::exit(2),
    };
    let result = std::fs::read(path)
        .map_err(|_| Error::Storage)
        .and_then(|bytes| {
            if bytes.len() > 8192 {
                return Err(Error::Invalid);
            }
            serde_json::from_slice::<Config>(&bytes).map_err(|_| Error::Invalid)
        })
        .and_then(|config| run(&config, replay));
    if result.is_err() {
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry_proto::tonic::collector::trace::v1::ExportTracePartialSuccess;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Directory(PathBuf);

    impl Directory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "overalls-trace-export-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            std::fs::create_dir(path.join("state")).unwrap();
            std::fs::set_permissions(path.join("state"), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            Self(path)
        }

        fn store(&self) -> Store {
            Store::open(&self.0.join("state"), 8_388_608, 3600).unwrap()
        }
    }

    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn acknowledge_batches(
        listener: UnixListener,
        store: Arc<Mutex<Store>>,
        expected: BTreeMap<String, Vec<u8>>,
    ) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(2);
            let mut remaining = expected;
            while !remaining.is_empty() {
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "accepted backlog did not drain");
                        std::thread::yield_now();
                        continue;
                    }
                    Err(error) => panic!("collector accept failed: {error:?}"),
                };
                stream
                    .set_write_timeout(Some(Duration::from_millis(250)))
                    .unwrap();
                let body = request(&mut stream).unwrap();
                let id = remaining
                    .iter()
                    .find_map(|(id, expected)| (expected == &body).then(|| id.clone()))
                    .expect("unexpected accepted body");
                remaining.remove(&id);
                // A stalled Collector must not hold the admission/custody lock.
                assert!(store.try_lock().is_ok());
                stream.write_all(&protobuf_reply(0, "")).unwrap();
            }
        })
    }

    /// @cc [owner:ghuntley,label:verification;capacity;recovery] trace-export-backlog-regression
    /// A real Unix Collector MUST drain 32 accepted batches in under two seconds
    /// without holding the custody lock during network I/O. Delivery and reopen
    /// MUST preserve their immutable identities, timestamps and bytes for replay.
    #[test]
    fn successful_forwarding_drains_backlog_eagerly_and_retains_replay_archive() {
        let directory = Directory::new();
        let mut custody = directory.store();
        let accepted_at = now_ns().unwrap();
        let mut expected = BTreeMap::<String, Vec<u8>>::new();
        let mut timestamps = BTreeMap::<String, u64>::new();
        for index in 0..32u64 {
            let body = format!("reviewed-batch-{index:02}").into_bytes();
            let timestamp = accepted_at + index;
            let id = custody.accept(&body, timestamp).unwrap();
            timestamps.insert(id.clone(), timestamp);
            expected.insert(id, body);
        }
        let store = Arc::new(Mutex::new(custody));
        let socket = directory.0.join("collector.sock");
        let collector = acknowledge_batches(
            UnixListener::bind(&socket).unwrap(),
            Arc::clone(&store),
            expected.clone(),
        );
        let started = Instant::now();
        let result = drain_pending(&store, &socket, &directory.0.join("health.prom"));
        let elapsed = started.elapsed();
        let collector_result = collector.join();
        println!(
            "accepted_batches=32 drain_elapsed_us={}",
            elapsed.as_micros()
        );
        collector_result.unwrap();
        assert_eq!(result, Ok(()));
        assert!(elapsed < Duration::from_secs(2));
        {
            let mut custody = store.lock().unwrap();
            assert!(custody.pending().unwrap().is_none());
            assert_eq!(custody.health.exported, 32);
            assert_eq!(custody.health.export_failures, 0);
        }
        drop(store);
        let mut reopened = directory.store();
        assert!(reopened.pending().unwrap().is_none());
        reopened.replay().unwrap();
        while let Some(batch) = reopened.pending().unwrap() {
            let body = expected.remove(&batch.id).unwrap();
            assert_eq!(reopened.body(&batch).unwrap(), body);
            assert_eq!(batch.accepted_at_ns, timestamps[&batch.id]);
            assert_eq!(
                batch.expires_at_ns,
                batch.accepted_at_ns + 3_600_000_000_000
            );
            assert_eq!(batch.bytes, body.len() as u64 + 512);
            reopened.delivered(&batch.id).unwrap();
        }
        assert!(expected.is_empty());
    }

    #[test]
    fn forwarding_failure_returns_with_pending_custody_intact() {
        let directory = Directory::new();
        let mut custody = directory.store();
        let body = b"reviewed-pending";
        let id = custody.accept(body, now_ns().unwrap()).unwrap();
        let store = Mutex::new(custody);
        let started = Instant::now();
        assert_eq!(
            drain_pending(
                &store,
                &directory.0.join("absent.sock"),
                &directory.0.join("health.prom")
            ),
            Err(Error::Storage)
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        {
            let mut custody = store.lock().unwrap();
            let batch = custody.pending().unwrap().unwrap();
            assert_eq!(batch.id, id);
            assert_eq!(custody.body(&batch).unwrap(), body);
            assert_eq!(custody.health.export_failures, 1);
            assert_eq!(custody.health.exported, 0);
        }
        drop(store);
        let mut reopened = directory.store();
        assert_eq!(reopened.pending().unwrap().unwrap().id, id);
    }

    /// @cc [owner:ghuntley,label:verification;recovery] trace-export-storage-refusal-health
    /// Failed delivery storage MUST stop eager draining with pending custody
    /// intact. Failed expiry or an already poisoned store MUST still publish
    /// numeric poison evidence before returning to the failure backoff.
    #[test]
    fn delivery_and_expiry_storage_failures_preserve_pending_and_publish_poison() {
        for fail_expiry in [false, true] {
            let directory = Directory::new();
            let mut custody = directory.store();
            let accepted_at = if fail_expiry { 1 } else { now_ns().unwrap() };
            let body = b"reviewed-immutable".to_vec();
            let id = custody.accept(&body, accepted_at).unwrap();
            let database =
                rusqlite::Connection::open(directory.0.join("state/archive.sqlite")).unwrap();
            let table = if fail_expiry { "batches" } else { "pending" };
            database
                .execute_batch(&format!(
                    "CREATE TRIGGER refuse_storage BEFORE DELETE ON {table} BEGIN SELECT RAISE(FAIL, 'fixture storage refusal'); END"
                ))
                .unwrap();
            let store = Arc::new(Mutex::new(custody));
            let socket = directory.0.join("collector.sock");
            let collector = (!fail_expiry).then(|| {
                acknowledge_batches(
                    UnixListener::bind(&socket).unwrap(),
                    Arc::clone(&store),
                    BTreeMap::from([(id.clone(), body.clone())]),
                )
            });
            let health = directory.0.join("health.prom");
            let started = Instant::now();
            let result = drain_pending(&store, &socket, &health);
            let elapsed = started.elapsed();
            if let Some(collector) = collector {
                collector.join().unwrap();
            }
            assert_eq!(result, Err(Error::Storage));
            assert!(elapsed < Duration::from_secs(1));
            if fail_expiry {
                assert!(std::fs::read_to_string(&health)
                    .unwrap()
                    .contains("overalls_trace_spool_poisoned 1\n"));
            }
            assert_eq!(
                drain_pending(&store, &socket, &health),
                Err(Error::Poisoned)
            );
            let metrics = std::fs::read_to_string(&health).unwrap();
            assert!(metrics.contains("overalls_trace_spool_poisoned 1\n"));
            assert!(metrics.contains("overalls_trace_spool_storage_failures_total 1\n"));
            assert!(metrics.contains("overalls_trace_spool_exported_total 0\n"));
            assert!(metrics.contains("overalls_trace_spool_pending_batches 1\n"));
            database
                .execute_batch("DROP TRIGGER refuse_storage")
                .unwrap();
            drop(database);
            drop(store);
            let mut reopened = directory.store();
            let batch = reopened.pending().unwrap().unwrap();
            assert_eq!(batch.id, id);
            assert_eq!(reopened.body(&batch).unwrap(), body);
        }
    }

    /// @cc [owner:ghuntley,label:verification] trace-forward-fixture-deadlines
    /// Parser fixtures MUST join their Collector thread before checking the
    /// forwarding result. Missing clients MUST stop acceptance within two
    /// seconds; request and response I/O MUST each have a 250ms deadline.
    fn collector_reply(reply: &[u8]) -> Result<(), Error> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "overalls-trace-forward-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&directory).unwrap();
        let socket = directory.join("collector.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let reply = reply.to_vec();
        let collector = std::thread::spawn(move || -> Result<(), Error> {
            let accept_deadline = Instant::now() + Duration::from_secs(2);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= accept_deadline {
                            return Err(Error::Storage);
                        }
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(_) => return Err(Error::Storage),
                }
            };
            if request(&mut stream)? != b"reviewed" {
                return Err(Error::Invalid);
            }
            let write_deadline = Instant::now() + Duration::from_millis(250);
            let mut remaining = reply.as_slice();
            while !remaining.is_empty() {
                let timeout = write_deadline
                    .checked_duration_since(Instant::now())
                    .ok_or(Error::Storage)?;
                stream
                    .set_write_timeout(Some(timeout))
                    .map_err(|_| Error::Storage)?;
                let written = stream.write(remaining).map_err(|_| Error::Storage)?;
                if written == 0 {
                    return Err(Error::Storage);
                }
                remaining = &remaining[written..];
            }
            Ok(())
        });
        let result = forward(b"reviewed", &socket);
        let collector_result = collector.join();
        std::fs::remove_file(socket).unwrap();
        std::fs::remove_dir(directory).unwrap();
        collector_result.unwrap().unwrap();
        result
    }

    fn protobuf_reply(rejected_spans: i64, warning: &str) -> Vec<u8> {
        let body = ExportTraceServiceResponse {
            partial_success: Some(ExportTracePartialSuccess {
                rejected_spans,
                error_message: warning.to_owned(),
            }),
        }
        .encode_to_vec();
        let mut reply = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        reply.extend_from_slice(&body);
        reply
    }

    /// @cc [owner:ghuntley,label:verification;recovery] trace-forward-real-collector-success
    /// The exact pinned Collector 0.151.0 full-success reply MUST drain over the
    /// real Unix forwarding path. Zero-rejection warnings MUST also succeed;
    /// malformed, truncated and nonzero-rejection replies MUST refuse delivery.
    #[test]
    fn pinned_collector_reply_and_private_warning_confirm_complete_delivery() {
        assert_eq!(
            collector_reply(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\x0a\x00"),
            Ok(())
        );
        assert_eq!(
            collector_reply(&protobuf_reply(0, "private warning")),
            Ok(())
        );
        assert_eq!(
            collector_reply(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
            Ok(())
        );
        assert_eq!(
            collector_reply(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
            Ok(())
        );
        assert_eq!(
            collector_reply(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n\x0a\x00\r\n0\r\n\r\n"
            ),
            Ok(())
        );
        for reply in [
            protobuf_reply(1, "private refusal"),
            protobuf_reply(-1, "private invalid count"),
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n\x0a".to_vec(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n\x0a".to_vec(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n\x0a\x00".to_vec(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n\x0a\x00"
                .to_vec(),
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n\x0a\x00\r\n".to_vec(),
            protobuf_reply(0, &"w".repeat(4096)),
        ] {
            assert_eq!(collector_reply(&reply), Err(Error::Invalid));
        }
        assert_eq!(
            collector_reply(b"HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n"),
            Err(Error::Storage)
        );
    }

    #[test]
    fn prefetched_request_body_is_preserved_and_ambiguous_framing_refuses() {
        for (headers, expected) in [
            ("Content-Length: 3\r\n", Ok(b"abc".to_vec())),
            (
                "Content-Length: 3\r\nContent-Length: 3\r\n",
                Err(Error::Invalid),
            ),
            (
                "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n",
                Err(Error::Invalid),
            ),
            ("Content-Length: 2\r\n", Err(Error::Invalid)),
        ] {
            let (mut server, mut client) = UnixStream::pair().unwrap();
            write!(client, "POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\n{headers}\r\nabc").unwrap();
            assert_eq!(request(&mut server), expected);
        }
    }

    #[test]
    fn incomplete_request_has_absolute_deadline() {
        let (mut server, mut client) = UnixStream::pair().unwrap();
        write!(client, "POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: 3\r\n\r\na").unwrap();
        let before = Instant::now();
        assert_eq!(request(&mut server), Err(Error::Invalid));
        assert!(before.elapsed() >= Duration::from_millis(200));
        assert!(before.elapsed() < Duration::from_secs(1));
    }
}
