//! IP Helper tables.

use std::io;
use std::net::Ipv4Addr;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::NetworkManagement::IpHelper::{
    FreeMibTable, GetIpForwardTable2, GetUnicastIpAddressTable, MIB_IPFORWARD_ROW2,
    MIB_IPFORWARD_TABLE2, MIB_UNICASTIPADDRESS_ROW, MIB_UNICASTIPADDRESS_TABLE,
};
use windows_sys::Win32::Networking::WinSock::{AF_INET, SOCKADDR_INET};

/// The IPv4 address of `address`, or `None` for any other family.
pub fn ipv4_of(address: &SOCKADDR_INET) -> Option<Ipv4Addr> {
    // SAFETY: reading the family discriminant of a union the kernel filled.
    if unsafe { address.si_family } != AF_INET {
        return None;
    }
    // SAFETY: the family says the IPv4 member is the active one; S_addr is
    // the raw network-order address.
    let raw = unsafe { address.Ipv4.sin_addr.S_un.S_addr };
    Some(Ipv4Addr::from(u32::from_be(raw)))
}

/// Run `visit` over the kernel's IPv4 unicast address rows, then free the table.
pub fn with_unicast_ipv4_rows<R>(
    visit: impl FnOnce(&[MIB_UNICASTIPADDRESS_ROW]) -> R,
) -> io::Result<R> {
    let mut table: *mut MIB_UNICASTIPADDRESS_TABLE = null_mut();
    // SAFETY: `table` receives a kernel-allocated table freed below.
    let status = unsafe { GetUnicastIpAddressTable(AF_INET, &raw mut table) };
    if status != ERROR_SUCCESS || table.is_null() {
        return Err(io::Error::from_raw_os_error(status.cast_signed()));
    }
    // SAFETY: the table is valid until FreeMibTable.
    let count = unsafe { (*table).NumEntries } as usize;
    // SAFETY: as above; this only takes the address of the row array.
    let first = unsafe { (*table).Table.as_ptr() };
    // SAFETY: `Table` holds NumEntries initialised rows until FreeMibTable;
    // the slice does not outlive `visit`.
    let rows = unsafe { std::slice::from_raw_parts(first, count) };
    let found = visit(rows);
    // SAFETY: the table came from GetUnicastIpAddressTable and is freed once.
    unsafe { FreeMibTable(table.cast()) };
    Ok(found)
}

/// Run `visit` over the kernel's IPv4 route rows, then free the table.
pub fn with_ipv4_route_rows<R>(visit: impl FnOnce(&[MIB_IPFORWARD_ROW2]) -> R) -> io::Result<R> {
    let mut table: *mut MIB_IPFORWARD_TABLE2 = null_mut();
    // SAFETY: `table` receives a kernel-allocated table freed below.
    let status = unsafe { GetIpForwardTable2(AF_INET, &raw mut table) };
    if status != ERROR_SUCCESS || table.is_null() {
        return Err(io::Error::from_raw_os_error(status.cast_signed()));
    }
    // SAFETY: the table is valid until FreeMibTable.
    let count = unsafe { (*table).NumEntries } as usize;
    // SAFETY: as above; this only takes the address of the row array.
    let first = unsafe { (*table).Table.as_ptr() };
    // SAFETY: `Table` holds NumEntries initialised rows until FreeMibTable;
    // the slice does not outlive `visit`.
    let rows = unsafe { std::slice::from_raw_parts(first, count) };
    let found = visit(rows);
    // SAFETY: the table came from GetIpForwardTable2 and is freed once.
    unsafe { FreeMibTable(table.cast()) };
    Ok(found)
}
