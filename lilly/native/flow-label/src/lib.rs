#![deny(unsafe_code)]
#![doc = "Exact read-only kernel flow lookup; stdout is a private fixed-size protocol."]

pub const EXIT_FAILED: u8 = 1;

/// Why an exact read failed: transport, capability or inventory boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlowError {
    Unavailable,
}

/// Attribute numbers from `libnetfilter_conntrack.h` (enum `nf_conntrack_attr`).
pub const ATTR_ORIG_IPV4_SRC: u8 = 0;
pub const ATTR_ORIG_IPV4_DST: u8 = 1;
pub const ATTR_ORIG_PORT_SRC: u8 = 8;
pub const ATTR_ORIG_PORT_DST: u8 = 9;
pub const ATTR_L3PROTO: u8 = 15;
pub const ATTR_L4PROTO: u8 = 17;
pub const ATTR_CONNLABELS: u8 = 66;
/// `NFNL_SUBSYS_CTNETLINK`.
pub const CONNTRACK_SUBSYSTEM: u8 = 1;
/// `NFCT_T_NEW` | `NFCT_T_UPDATE` | `NFCT_T_DESTROY` (7).
pub const NFCT_T_ALL: i32 = 7;
/// `nf_conntrack_query` `NFCT_Q_GET` (3).
pub const NFCT_Q_GET: u32 = 3;
/// `NFCT_CB_FAILURE` (-1).
pub const CB_FAILURE: i32 = -1;
/// `NFCT_CB_CONTINUE` (1).
pub const CB_CONTINUE: i32 = 1;

mod cli;
#[allow(unsafe_code, reason = "label_shim arms the process alarm through libc")]
mod label_shim;
mod labels;
/// The kernel boundary: one connection handle, one ct, one callback registry.
#[allow(
    unsafe_code,
    reason = "nct is the typed FFI shim over libnetfilter_conntrack"
)]
mod nct;

pub use cli::{address, parse_cli, port, Query};
pub use labels::Labels;

/// One exact-lookup outcome.
#[derive(Debug)]
pub struct Lookup {
    pub query: Query,
    pub label: Option<Labels>,
    pub count: u32,
}

/// @cc [owner:ghuntley,label:security] native-flow-exact-kernel-label
/// A result MUST match the complete requested IPv4 TCP original tuple and
/// carry Lilly's bit-127 label marker. Missing, ambiguous or mismatched
/// results MUST produce no stdout. Output MUST contain only the 128-bit label,
/// never flow data.
pub fn lookup(query: Query) -> Result<Option<Labels>, FlowError> {
    let mut handle = nct::open().ok_or(FlowError::Unavailable)?;
    nct::set_recv_timeout(&handle, 1).map_err(|_| FlowError::Unavailable)?;
    label_shim::alarm_after_two_seconds();
    let mut ct = nct::new_ct().ok_or(FlowError::Unavailable)?;
    nct::set_query_tuple(&mut ct, &query);
    let mut lookup = Lookup {
        query,
        label: None,
        count: 0,
    };
    if !nct::register_get(&mut handle, nct::COLLECT, &mut lookup) {
        return Err(FlowError::Unavailable);
    }
    if !nct::query_get(&mut handle, &mut ct) {
        return Err(FlowError::Unavailable);
    }
    if lookup.count != 1 {
        return Err(FlowError::Unavailable);
    }
    Ok(lookup.label)
}

#[cfg(test)]
mod tests;
