//! Live IPv4 facts from the IP Helper tables, for the readiness probe
//! (ADR-0171). Mirrors the Linux readiness checks: the delivered `/32` is
//! preferred on an interface, that interface has an on-link host route to the
//! gateway and a default route through it.

use crate::sys::windows::iphlp::{ipv4_of, with_ipv4_route_rows, with_unicast_ipv4_rows};
use std::io;
use std::net::Ipv4Addr;
use windows_sys::Win32::Networking::WinSock::IpDadStatePreferred;

/// One preferred unicast IPv4 address with its prefix and interface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Address {
    pub address: Ipv4Addr,
    pub prefix_length: u8,
    pub interface_index: u32,
}

/// One IPv4 route.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    pub destination: Ipv4Addr,
    pub prefix_length: u8,
    pub next_hop: Ipv4Addr,
    pub interface_index: u32,
}

/// Preferred (DAD complete) unicast IPv4 addresses of every interface.
pub fn addresses() -> io::Result<Vec<Address>> {
    with_unicast_ipv4_rows(|rows| {
        rows.iter()
            .filter(|row| row.DadState == IpDadStatePreferred)
            .filter_map(|row| {
                ipv4_of(&row.Address).map(|address| Address {
                    address,
                    prefix_length: row.OnLinkPrefixLength,
                    interface_index: row.InterfaceIndex,
                })
            })
            .collect()
    })
}

/// Every IPv4 route.
pub fn routes() -> io::Result<Vec<Route>> {
    with_ipv4_route_rows(|rows| {
        rows.iter()
            .filter_map(|row| {
                Some(Route {
                    destination: ipv4_of(&row.DestinationPrefix.Prefix)?,
                    prefix_length: row.DestinationPrefix.PrefixLength,
                    next_hop: ipv4_of(&row.NextHop)?,
                    interface_index: row.InterfaceIndex,
                })
            })
            .collect()
    })
}

/// @cc [owner:ghuntley,label:recovery] windows-network-ready-exact-facts
/// configured MUST be true only when some interface holds `address` as a
/// preferred `/32`, that same interface has an on-link (`0.0.0.0` next hop)
/// host route to `gateway` and a default route whose next hop is `gateway`.
pub fn configured(address: Ipv4Addr, gateway: Ipv4Addr) -> io::Result<bool> {
    let addresses = addresses()?;
    let routes = routes()?;
    Ok(evaluate(&addresses, &routes, address, gateway))
}

/// The pure decision behind `configured`.
pub fn evaluate(
    addresses: &[Address],
    routes: &[Route],
    address: Ipv4Addr,
    gateway: Ipv4Addr,
) -> bool {
    addresses
        .iter()
        .filter(|entry| entry.address == address && entry.prefix_length == 32)
        .any(|entry| {
            let on_link = routes.iter().any(|route| {
                route.interface_index == entry.interface_index
                    && route.destination == gateway
                    && route.prefix_length == 32
                    && route.next_hop == Ipv4Addr::UNSPECIFIED
            });
            let default = routes.iter().any(|route| {
                route.interface_index == entry.interface_index
                    && route.destination == Ipv4Addr::UNSPECIFIED
                    && route.prefix_length == 0
                    && route.next_hop == gateway
            });
            on_link && default
        })
}
