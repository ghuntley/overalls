use crate::{ARGV_TOTAL_LIMIT, CONSUMER_ARGS_LIMIT, PRODUCER_ARGS_LIMIT, RATE_LIMIT};
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;

/// A validated invocation.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub timeout_ms: u64,
    /// Bytes per second; zero is unthrottled.
    pub rate: u64,
    /// An inherited descriptor receiving the progress counter.
    pub progress: Option<i32>,
    /// The uid (and equal gid) each side drops to; None keeps the helper's.
    pub producer_uid: Option<u32>,
    pub consumer_uid: Option<u32>,
    pub producer: Vec<OsString>,
    pub consumer: Vec<OsString>,
}

/// Strict decimal: nonempty, no leading zeros, digits only, then bounds.
fn number(text: &OsStr, min: i64, max: i64) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: i64 = text.parse().ok()?;
    (min..=max).contains(&value).then_some(value)
}

/// `-` or a strict decimal in `min..=max`.
#[expect(
    clippy::option_option,
    reason = "three outcomes by design: invalid (None), dash (Some(None)) or a bounded value"
)]
fn optional(text: &OsStr, min: i64, max: i64) -> Option<Option<i64>> {
    if text.as_bytes() == b"-" {
        return Some(None);
    }
    number(text, min, max).map(Some)
}

/// Accepted side uids: never root, never the overflow uid.
pub const SIDE_UIDS: std::ops::RangeInclusive<i64> = 1..=4_294_967_294;
/// Accepted inherited progress descriptors.
pub const PROGRESS_FDS: std::ops::RangeInclusive<i64> = 3..=1023;

/// @cc [owner:ghuntley,label:security] transfer-cli-bounded-absolute
/// The command line MUST be: timeout (1000..=86400000 ms), rate
/// (0..=1073741824 bytes/s), progress descriptor (`-` or 3..=1023), producer
/// uid and consumer uid (`-` or 1..=4294967294, never root), producer count,
/// then absolute producer argv and absolute consumer argv whose byte span
/// never exceeds 65536. Anything else is a usage error. The caller (hostd)
/// derives every argv itself; this helper reads no environment settings.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [timeout, rate, progress, producer_uid, consumer_uid, producers, rest @ ..] = arguments
    else {
        return None;
    };
    let timeout_ms: u64 = u64::try_from(number(timeout, 1000, 86_400_000)?).ok()?;
    let rate = u64::try_from(number(rate, 0, RATE_LIMIT)?).ok()?;
    let progress = optional(progress, *PROGRESS_FDS.start(), *PROGRESS_FDS.end())?
        .and_then(|fd| i32::try_from(fd).ok());
    let uid = |text: &OsStr| -> Option<Option<u32>> {
        match optional(text, *SIDE_UIDS.start(), *SIDE_UIDS.end())? {
            None => Some(None),
            Some(uid) => Some(Some(u32::try_from(uid).ok()?)),
        }
    };
    let producer_uid = uid(producer_uid)?;
    let consumer_uid = uid(consumer_uid)?;
    let producer_count = usize::try_from(number(
        producers,
        1,
        i64::try_from(PRODUCER_ARGS_LIMIT).ok()?,
    )?)
    .ok()?;
    if rest.len() < producer_count + 1 || rest.len() - producer_count > CONSUMER_ARGS_LIMIT {
        return None;
    }
    let (producer, consumer) = rest.split_at(producer_count);
    if !producer[0].as_os_str().as_bytes().starts_with(b"/")
        || !consumer[0].as_os_str().as_bytes().starts_with(b"/")
    {
        return None;
    }
    if producer
        .iter()
        .chain(consumer.iter())
        .any(|arg| arg.is_empty() || arg.as_os_str().as_bytes().contains(&0))
    {
        return None;
    }
    let argument_bytes: usize = producer
        .iter()
        .chain(consumer.iter())
        .map(|arg| arg.as_os_str().as_bytes().len() + 1)
        .sum();
    if argument_bytes > ARGV_TOTAL_LIMIT {
        return None;
    }
    Some(Request {
        timeout_ms,
        rate,
        progress,
        producer_uid,
        consumer_uid,
        producer: producer.to_vec(),
        consumer: consumer.to_vec(),
    })
}
