use thiserror::Error;

/// Terminal attachment request and bounded watch subscription.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalAttachRequest {
    pub machine_id: uuid::Uuid,
    pub session_id: uuid::Uuid,
    pub from: u64,
    pub columns: u16,
    pub rows: u16,
    pub read_write: bool,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WatchRequest {
    pub machines: Vec<uuid::Uuid>,
    pub threads: Vec<uuid::Uuid>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub enum RequestRefusal {
    #[error("too many filters")]
    TooManyFilters,
    #[error("invalid dimensions")]
    InvalidDimensions,
}
impl WatchRequest {
    pub const MAX_FILTERS: usize = 64;
    pub fn new(
        mut machines: Vec<uuid::Uuid>,
        mut threads: Vec<uuid::Uuid>,
    ) -> Result<Self, RequestRefusal> {
        machines.sort();
        machines.dedup();
        threads.sort();
        threads.dedup();
        if machines.len() + threads.len() > Self::MAX_FILTERS {
            return Err(RequestRefusal::TooManyFilters);
        }
        Ok(Self { machines, threads })
    }
}
impl TerminalAttachRequest {
    pub fn validate(&self) -> Result<(), RequestRefusal> {
        if self.columns == 0 || self.columns > 4096 || self.rows == 0 || self.rows > 512 {
            Err(RequestRefusal::InvalidDimensions)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WatchEvent {
    Watching {
        session_id: uuid::Uuid,
        machines: Vec<uuid::Uuid>,
        threads: Vec<uuid::Uuid>,
    },
    Heartbeat,
    MachineChanged(uuid::Uuid),
    TerminalSessionsChanged(uuid::Uuid),
    ThreadChanged(uuid::Uuid),
    Resync,
    Session {
        id: uuid::Uuid,
        authenticated: bool,
    },
    Unknown,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
#[error("invalid watch line: {0}")]
pub struct WatchFormat(pub &'static str);
pub const MAX_WATCH_LINE_BYTES: usize = 65_536;
pub fn decode_watch_line(line: &[u8]) -> Result<WatchEvent, WatchFormat> {
    if line.len() > MAX_WATCH_LINE_BYTES {
        return Err(WatchFormat("too long"));
    }
    let v: serde_json::Value = serde_json::from_slice(line).map_err(|_| WatchFormat("json"))?;
    let o = v.as_object().ok_or(WatchFormat("object"))?;
    if o.get("version").and_then(|v| v.as_u64()) != Some(1) {
        return Err(WatchFormat("version"));
    }
    let event = o
        .get("event")
        .and_then(|v| v.as_str())
        .ok_or(WatchFormat("event"))?;
    let id = |k: &str| {
        o.get(k)
            .and_then(|v| v.as_str())
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .ok_or(WatchFormat("field"))
    };
    let ids = |k: &str| -> Result<Vec<uuid::Uuid>, WatchFormat> {
        let a = o
            .get(k)
            .and_then(|v| v.as_array())
            .ok_or(WatchFormat("field"))?;
        if a.len() > WatchRequest::MAX_FILTERS {
            return Err(WatchFormat("field"));
        }
        a.iter()
            .map(|v| {
                v.as_str()
                    .and_then(|s| uuid::Uuid::parse_str(s).ok())
                    .ok_or(WatchFormat("field"))
            })
            .collect()
    };
    Ok(match event {
        "watching" => WatchEvent::Watching {
            session_id: id("session_id")?,
            machines: ids("machines")?,
            threads: ids("threads")?,
        },
        "heartbeat" => WatchEvent::Heartbeat,
        "machine" => WatchEvent::MachineChanged(id("id")?),
        "terminal_session" => WatchEvent::TerminalSessionsChanged(id("machine_id")?),
        "thread" => WatchEvent::ThreadChanged(id("id")?),
        "resync" => WatchEvent::Resync,
        "session" => WatchEvent::Session {
            id: id("id")?,
            authenticated: o.get("status").and_then(|v| v.as_str()) == Some("authenticated"),
        },
        _ => WatchEvent::Unknown,
    })
}
