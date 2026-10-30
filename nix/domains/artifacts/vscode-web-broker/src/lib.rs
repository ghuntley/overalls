//! Closed guest editor admission and immutable execution/package binding.

use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;

mod boot;
pub mod mmds;
mod validate;
#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub mod windows_ipc;
pub mod windows_model;
#[cfg(windows)]
pub mod windows_pipe;

pub use boot::{parse_boot, read_preface, ready, validate, webview_template};
pub use validate::{hex, label_matches, username, uuid};

pub const MAX_PREFACE: usize = 2048;
pub const PORT: u16 = 4444;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Descriptor {
    pub protocol: u8,
    pub commit: String,
    pub release: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Preface {
    pub version: u8,
    pub binding: Binding,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub vm_id: String,
    pub host_id: String,
    pub placement_id: String,
    pub session_id: String,
    pub execution_epoch: u64,
    pub generation: u64,
    pub label: String,
    pub service: String,
    pub port: u16,
    pub user_id: String,
    pub guest_account_id: String,
    pub uid: u32,
    pub username: String,
    pub editor_protocol: u8,
    pub editor_commit: String,
    pub editor_release: String,
    pub editor_origin: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Boot {
    pub placement_id: String,
    pub execution_epoch: u64,
    pub address: Ipv4Addr,
    pub gateway: Ipv4Addr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Frame,
    Binding,
    Boot,
    Package,
    Origin,
    Account,
    Custody,
    Startup,
    Readiness,
    Capacity,
    Transport,
}

impl Refusal {
    pub fn name(self) -> &'static str {
        match self {
            Self::Frame => "frame",
            Self::Binding => "binding",
            Self::Boot => "boot",
            Self::Package => "package",
            Self::Origin => "origin",
            Self::Account => "account",
            Self::Custody => "custody",
            Self::Startup => "startup",
            Self::Readiness => "readiness",
            Self::Capacity => "capacity",
            Self::Transport => "transport",
        }
    }
}

#[cfg(test)]
mod tests;
