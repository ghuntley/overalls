use fs2::FileExt;
use lyra::platform::{open_private, restrict_directory, restrict_file};
use serde_json::json;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const SEGMENT_BYTES: u64 = 5 * 1024 * 1024;

#[derive(Clone, Copy)]
pub(crate) enum Event {
    Configured,
    ProxyAgentSelected,
    ProxyStarted,
    ProxyEnded,
    LookupFailed,
    UpdateStarted,
    UpdateStaged,
    UpdateActivated,
    UpdateFailed,
    UpdateRolledBack,
    FetchStarted,
    FetchCompleted,
    FetchFailed,
}

impl Event {
    fn name(self) -> &'static str {
        match self {
            Self::Configured => "lyra.configured",
            Self::ProxyAgentSelected => "lyra.proxy_agent_selected",
            Self::ProxyStarted => "lyra.proxy_started",
            Self::ProxyEnded => "lyra.proxy_ended",
            Self::LookupFailed => "lyra.lookup_failed",
            Self::UpdateStarted => "lyra.update_started",
            Self::UpdateStaged => "lyra.update_staged",
            Self::UpdateActivated => "lyra.update_activated",
            Self::UpdateFailed => "lyra.update_failed",
            Self::UpdateRolledBack => "lyra.update_rolled_back",
            Self::FetchStarted => "lyra.fetch_started",
            Self::FetchCompleted => "lyra.fetch_completed",
            Self::FetchFailed => "lyra.fetch_failed",
        }
    }
}

/// UTC calendar date `YYYY-MM-DD` of a Unix time, by the civil-from-days
/// algorithm (proleptic Gregorian), identical to `gmtime_r` on every platform.
fn date(seconds: i64) -> io::Result<String> {
    let days = seconds.div_euclid(86_400);
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    if !(0..=9999).contains(&year) {
        return Err(io::Error::other("clock unavailable"));
    }
    Ok(format!("{year:04}-{month:02}-{day:02}"))
}

fn directory() -> io::Result<PathBuf> {
    let path = crate::config::state_dir()?.join("logs");
    fs::create_dir_all(&path)?;
    restrict_directory(&path)?;
    Ok(path)
}

/// @cc [owner:ghuntley,label:security] lyra-log-fixed-fields
/// This API MUST accept only a closed event and numeric data. No SSH payload,
/// argument, environment value, hostname or arbitrary error text may enter it.
pub(crate) fn emit(event: Event, value: Option<u64>) -> io::Result<()> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?;
    let seconds = i64::try_from(now.as_secs()).map_err(io::Error::other)?;
    let dir = directory()?;
    let lock = open_private(
        &dir.join(".lock"),
        OpenOptions::new().create(true).truncate(false).write(true),
    )?;
    lock.lock_exclusive()?;
    let today = date(seconds)?;
    let oldest = date(seconds - 6 * 86_400)?;
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if let Some(day) = name
            .strip_prefix("overalls-")
            .and_then(|rest| rest.get(..10))
        {
            if day < oldest.as_str() && name.ends_with(".jsonl") {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    let current = dir.join(format!("overalls-{today}.jsonl"));
    let previous = dir.join(format!("overalls-{today}.1.jsonl"));
    let mut line =
        json!({"timestamp_ms": now.as_millis(), "event": event.name(), "value": value}).to_string();
    line.push('\n');
    if current
        .metadata()
        .is_ok_and(|m| m.len() + line.len() as u64 > SEGMENT_BYTES)
    {
        let _ = fs::remove_file(&previous);
        fs::rename(&current, &previous)?;
    }
    let mut output = open_private(&current, OpenOptions::new().append(true).create(true))?;
    restrict_file(&output)?;
    output.write_all(line.as_bytes())?;
    FileExt::unlock(&lock)?;
    Ok(())
}

pub(crate) fn path() -> io::Result<PathBuf> {
    directory()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates_match_the_proleptic_gregorian_calendar() {
        assert_eq!(date(0).unwrap(), "1970-01-01");
        assert_eq!(date(951_782_400).unwrap(), "2000-02-29");
        assert_eq!(date(1_709_208_000).unwrap(), "2024-02-29");
        assert_eq!(date(1_792_022_399).unwrap(), "2026-10-14");
        assert_eq!(date(1_792_022_400).unwrap(), "2026-10-15");
        assert_eq!(date(-86_400).unwrap(), "1969-12-31");
    }
    #[test]
    fn date_is_utc() {
        assert_eq!(date(0).unwrap(), "1970-01-01");
    }
}
