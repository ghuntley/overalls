//! MMDS-bound static networking for native firmware guests.

use crate::guest::mmds::{self, Document};
use crate::native_guest;
use serde::Serialize;
use std::fs;
use std::io::{self, Read};
use std::net::Ipv4Addr;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const RUN_DIR: &str = "/var/run/overalls";
const BOOTSTRAP_ADDRESS: &str = "169.254.169.1";
const MMDS_ADDRESS: &str = "169.254.169.254";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    FreeBsd,
    Illumos,
}

impl Os {
    fn interface(self) -> &'static str {
        match self {
            Self::FreeBsd => "vtnet0",
            Self::Illumos => "vioif0",
        }
    }

    fn ifconfig(self) -> &'static str {
        match self {
            Self::FreeBsd => "/sbin/ifconfig",
            Self::Illumos => "/usr/sbin/ifconfig",
        }
    }

    fn route(self) -> &'static str {
        match self {
            Self::FreeBsd => "/sbin/route",
            Self::Illumos => "/usr/sbin/route",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Network {
    address: Ipv4Addr,
    gateway: Ipv4Addr,
    paired: Option<Ipv4Addr>,
}

/// @cc [owner:ghuntley,label:security] native-network-mmds-authority
/// Network effects beyond the temporary MMDS link MUST require a validated
/// version-1 document matching the actual interface MAC, a supported profile
/// address outside reserved slots, prefix 32 and that profile's exact gateway.
/// Only Inception MUST receive the paired 10.41 address at the same slot.
pub fn network(document: &Document, interface_mac: &str) -> io::Result<Network> {
    document.clone().validate()?;
    let invalid = || io::Error::other("invalid native network identity");
    let address: Ipv4Addr = document.ipv4.parse().map_err(|_| invalid())?;
    let gateway: Ipv4Addr = document.gateway.parse().map_err(|_| invalid())?;
    let [first, profile, high, low] = address.octets();
    let slot = u16::from_be_bytes([high, low]);
    if first != 10
        || ![10, 20, 30, 40].contains(&profile)
        || !(2..=65534).contains(&slot)
        || gateway != Ipv4Addr::new(10, profile, 0, 1)
        || mac(&document.mac).is_none()
        || mac(&document.mac) != mac(interface_mac)
    {
        return Err(invalid());
    }
    Ok(Network {
        address,
        gateway,
        paired: (profile == 40).then_some(Ipv4Addr::new(10, 41, high, low)),
    })
}

fn mac(value: &str) -> Option<[u8; 6]> {
    let mut result = [0_u8; 6];
    let fields: Vec<&str> = value.split(':').collect();
    if fields.len() != result.len()
        || fields
            .iter()
            .any(|field| field.len() != 2 || !field.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return None;
    }
    for (byte, field) in result.iter_mut().zip(fields) {
        *byte = u8::from_str_radix(field, 16).ok()?;
    }
    Some(result)
}

fn command(program: &str, arguments: &[&str]) -> io::Result<bool> {
    let mut child = Command::new(program)
        .args(arguments)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status.success());
        }
        if started.elapsed() >= Duration::from_secs(15) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::other("native network operation timed out"));
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn required(program: &str, arguments: &[&str]) -> io::Result<()> {
    if command(program, arguments)? {
        Ok(())
    } else {
        Err(io::Error::other("native network operation failed"))
    }
}

fn output(program: &str, arguments: &[&str]) -> io::Result<String> {
    let mut child = Command::new(program)
        .args(arguments)
        .env_clear()
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let result = (|| {
        let mut pipe = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("missing native network output"))?;
        // SAFETY: pipe owns this descriptor; both fcntl calls only change its
        // status flags so a wedged system query cannot block startup forever.
        let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the owned pipe.
        if unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut bytes = Vec::new();
        let mut buffer = [0_u8; 4096];
        let started = Instant::now();
        loop {
            if started.elapsed() >= Duration::from_secs(15) {
                return Err(io::Error::other("native network query timed out"));
            }
            match pipe.read(&mut buffer) {
                Ok(0) => {
                    if let Some(status) = child.try_wait()? {
                        if !status.success() {
                            return Err(io::Error::other("native network query failed"));
                        }
                        return String::from_utf8(bytes)
                            .map_err(|_| io::Error::other("invalid native network output"));
                    }
                }
                Ok(count) => {
                    bytes.extend_from_slice(&buffer[..count]);
                    if bytes.len() > 16384 {
                        return Err(io::Error::other("oversized native network output"));
                    }
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

fn interface_mac(os: Os) -> io::Result<String> {
    let interface = output(os.ifconfig(), &[os.interface()])?;
    interface_mac_value(&interface)
        .ok_or_else(|| io::Error::other("native interface MAC unavailable"))
}

/// @cc [owner:ghuntley,label:security] native-interface-mac-normalization
/// A local ifconfig ether row MAY use one or two hexadecimal digits per octet.
/// Exactly six valid octets MUST normalize to the canonical two-digit form
/// before comparison with MMDS; malformed local output MUST refuse. External
/// metadata MUST retain its strict canonical MAC validation.
fn interface_mac_value(interface: &str) -> Option<String> {
    interface.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        if fields.next() != Some("ether") {
            return None;
        }
        let mut octets = fields.next()?.split(':');
        let mut bytes = [0_u8; 6];
        for byte in &mut bytes {
            let octet = octets.next()?;
            if !(1..=2).contains(&octet.len())
                || !octet.bytes().all(|value| value.is_ascii_hexdigit())
            {
                return None;
            }
            *byte = u8::from_str_radix(octet, 16).ok()?;
        }
        if octets.next().is_some() {
            return None;
        }
        Some(
            bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<Vec<_>>()
                .join(":"),
        )
    })
}

fn clear_ipv4(os: Os) -> io::Result<()> {
    match os {
        Os::FreeBsd => {
            let current = output(os.ifconfig(), &[os.interface()])?;
            for line in current.lines() {
                let mut fields = line.split_whitespace();
                if fields.next() == Some("inet") {
                    let address: Ipv4Addr = fields
                        .next()
                        .ok_or_else(|| io::Error::other("missing native address"))?
                        .parse()
                        .map_err(|_| io::Error::other("invalid native address"))?;
                    required(
                        os.ifconfig(),
                        &[os.interface(), "inet", &address.to_string(), "-alias"],
                    )?;
                }
            }
        }
        Os::Illumos => {
            if command(os.ifconfig(), &[os.interface(), "inet"])? {
                required(os.ifconfig(), &[os.interface(), "inet", "unplumb"])?;
            }
            required(os.ifconfig(), &[os.interface(), "inet", "plumb"])?;
        }
    }
    Ok(())
}

fn route(os: Os, arguments: &[&str]) -> io::Result<()> {
    let mut add = vec!["-n", "add"];
    add.extend_from_slice(arguments);
    // Bind indirect/default routes as well as link routes to the reviewed
    // interface; illumos otherwise leaves their netstat Interface field empty.
    add.extend_from_slice(&["-ifp", os.interface()]);
    if command(os.route(), &add)? {
        return Ok(());
    }
    add[1] = "change";
    required(os.route(), &add)
}

fn on_link(os: Os, destination: &str, address: &str) -> io::Result<()> {
    match os {
        Os::FreeBsd => route(os, &["-host", destination, "-iface", os.interface()]),
        // On illumos -interface takes this interface's local address as its
        // gateway operand, rather than an interface name (route(8)).
        Os::Illumos => route(os, &["-host", destination, address, "-interface"]),
    }
}

/// Read the configured native interface and IPv4 routing table with bounded
/// queries. Readiness uses complete fields rather than substring matches.
pub fn configured(os: Os, address: Ipv4Addr, gateway: Ipv4Addr) -> io::Result<bool> {
    let interface = output(os.ifconfig(), &[os.interface()])?;
    let routes = output("/usr/bin/netstat", &["-rn", "-f", "inet"])?;
    Ok(network_facts(
        &interface,
        &routes,
        os.interface(),
        address,
        gateway,
    ))
}

/// @cc [owner:ghuntley,label:recovery] native-network-readiness-exact-facts
/// Native network readiness MUST require the delivered address with a /32
/// netmask and both an on-link host route to the exact gateway and a default
/// route through that gateway on the same reviewed interface. Address or route
/// text appearing in another field, a different interface or /24 MUST refuse.
fn network_facts(
    interface: &str,
    routes: &str,
    name: &str,
    address: Ipv4Addr,
    gateway: Ipv4Addr,
) -> bool {
    let address = address.to_string();
    let gateway = gateway.to_string();
    let exact_address = interface.lines().any(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        fields.first() == Some(&"inet")
            && fields.get(1) == Some(&address.as_str())
            && fields.windows(2).any(|pair| {
                pair[0] == "netmask"
                    && ["0xffffffff", "ffffffff", "255.255.255.255"].contains(&pair[1])
            })
    });
    let entries: Vec<Vec<&str>> = routes
        .lines()
        .map(|line| line.split_whitespace().collect())
        .filter(|fields: &Vec<&str>| fields.len() >= 4 && fields[3..].contains(&name))
        .collect();
    let host_route = entries.iter().any(|fields| {
        (fields[0] == gateway || fields[0] == format!("{gateway}/32"))
            && fields[2].contains('U')
            && fields[2].contains('H')
            && !fields[2].contains('G')
    });
    let default_route = entries.iter().any(|fields| {
        ["default", "0.0.0.0/0"].contains(&fields[0])
            && fields[1] == gateway
            && fields[2].contains('U')
            && fields[2].contains('G')
    });
    exact_address && host_route && default_route
}

#[derive(Serialize)]
struct Evidence<'a> {
    version: u8,
    placement: &'a str,
    execution_epoch: u64,
    boot_challenge: &'a str,
    boot_id: &'a str,
    ipv4: String,
    prefix_length: u8,
    gateway: String,
}

fn private_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.uid() != 0 {
        return Err(io::Error::other("invalid native runtime directory"));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// @cc [owner:ghuntley,label:security;recovery] native-bootstrap-before-services
/// Bootstrap MUST run as root without DHCP, keep only validated static /32s,
/// disable interface IPv6, retain direct MMDS and host-gateway routes, and
/// publish its current boot identity atomically with mode 0600 under the
/// root-owned volatile mode-0700 runtime directory only after network success.
/// MMDS tokens and identity fields MUST NOT enter diagnostics or command output.
#[expect(
    clippy::too_many_lines,
    reason = "one ordered first-boot sequence; each step gates the next"
)]
pub fn run(os: Os) -> io::Result<()> {
    // SAFETY: geteuid only reads the current process credential.
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::Error::other("native bootstrap requires root"));
    }
    crate::native_growth::require_success(match os {
        Os::FreeBsd => crate::native_growth::Os::FreeBsd,
        Os::Illumos => crate::native_growth::Os::Illumos,
    })?;
    private_directory(Path::new(RUN_DIR))?;
    let evidence = Path::new(RUN_DIR).join("bootstrap.json");
    match fs::remove_file(&evidence) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    clear_ipv4(os)?;
    match os {
        Os::FreeBsd => required(os.ifconfig(), &[os.interface(), "inet6", "ifdisabled"])?,
        Os::Illumos => {
            if command(os.ifconfig(), &[os.interface(), "inet6"])? {
                required(os.ifconfig(), &[os.interface(), "inet6", "unplumb"])?;
            }
        }
    }
    required(
        os.ifconfig(),
        &[
            os.interface(),
            "inet",
            BOOTSTRAP_ADDRESS,
            "netmask",
            "255.255.0.0",
            "up",
        ],
    )?;
    let observed_mac = interface_mac(os)?;
    let started = Instant::now();
    let document = loop {
        match mmds::fetch(Duration::from_secs(5)) {
            Ok(document) => break document,
            Err(_) if started.elapsed() < Duration::from_mins(2) => {
                std::thread::sleep(Duration::from_secs(1));
            }
            Err(_) => return Err(io::Error::other("native metadata unavailable")),
        }
    };
    let network = network(&document, &observed_mac)?;
    let address = network.address.to_string();
    let gateway = network.gateway.to_string();
    required(
        os.ifconfig(),
        &[
            os.interface(),
            "inet",
            &address,
            "netmask",
            "255.255.255.255",
            "up",
        ],
    )?;
    if let Some(paired) = network.paired {
        let paired = paired.to_string();
        match os {
            Os::FreeBsd => required(
                os.ifconfig(),
                &[
                    os.interface(),
                    "inet",
                    &paired,
                    "netmask",
                    "255.255.255.255",
                    "alias",
                ],
            )?,
            Os::Illumos => required(
                os.ifconfig(),
                &[
                    os.interface(),
                    "addif",
                    &paired,
                    "netmask",
                    "255.255.255.255",
                    "up",
                ],
            )?,
        }
    }
    on_link(os, &gateway, &address)?;
    on_link(os, MMDS_ADDRESS, &address)?;
    route(os, &["default", &gateway])?;
    route(os, &["-host", "169.254.254.1", &gateway])?;
    if !configured(os, network.address, network.gateway)? {
        return Err(io::Error::other(
            "native static network verification failed",
        ));
    }
    let boot_id = native_guest::boot_id()?;
    let bytes = serde_json::to_vec(&Evidence {
        version: 1,
        placement: &document.placement,
        execution_epoch: document.execution_epoch,
        boot_challenge: &document.boot_challenge,
        boot_id: &boot_id,
        ipv4: address,
        prefix_length: 32,
        gateway,
    })
    .map_err(|_| io::Error::other("native identity encoding failed"))?;
    crate::ssh_files::atomic(&evidence, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document() -> Document {
        Document {
            git_identity: None,
            version: 1,
            placement: "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            execution_epoch: 7,
            boot_challenge: "b".repeat(64),
            ipv4: "10.10.0.203".into(),
            prefix_length: 32,
            gateway: "10.10.0.1".into(),
            mac: "02:fc:0a:00:00:cb".into(),
        }
    }

    #[test]
    fn network_refuses_foreign_mac_reserved_slots_and_gateway() {
        let good = document();
        assert!(network(&good, "02:FC:0A:00:00:CB").is_ok());
        assert!(network(&good, "02:fc:0a:00:00:cc").is_err());
        assert!(network(&good, "02:fc:0a:00:00:xx").is_err());
        for address in [
            "10.10.0.0",
            "10.10.0.1",
            "10.10.255.255",
            "10.41.1.2",
            "192.0.2.1",
        ] {
            let mut bad = good.clone();
            bad.ipv4 = address.into();
            assert!(network(&bad, &good.mac).is_err());
        }
        let mut bad = good.clone();
        bad.gateway = "10.20.0.1".into();
        assert!(network(&bad, &good.mac).is_err());
        bad = good.clone();
        bad.prefix_length = 24;
        assert!(network(&bad, &good.mac).is_err());
    }

    #[test]
    fn native_interface_mac_normalizes_actual_omnios_output_before_authority_check() {
        let interface =
            "vioif0: flags=1000843<UP,BROADCAST,RUNNING,MULTICAST,IPv4> mtu 1500 index 4\n\
                         inet 169.254.169.1 netmask ffff0000 broadcast 169.254.255.255\n\
                         ether 2:fc:a:0:0:cb \n";
        let observed = interface_mac_value(interface).unwrap();
        assert_eq!(observed, "02:fc:0a:00:00:cb");
        let mut document = document();
        assert!(network(&document, &observed).is_ok());
        document.mac = "02:fc:0a:00:00:cc".into();
        assert!(network(&document, &observed).is_err());
        document.mac = "2:fc:a:0:0:cb".into();
        assert!(network(&document, &observed).is_err());
        assert_eq!(
            interface_mac_value("vtnet0: flags=UP\n ether 02:FC:0A:00:00:CB\n"),
            Some(observed)
        );
    }

    #[test]
    fn native_interface_mac_refuses_malformed_local_octets() {
        for value in [
            "",
            "2:fc:a:0:cb",
            "2:fc:a:0:0:cb:1",
            "2:fc::0:0:cb",
            "002:fc:a:0:0:cb",
            "2:100:a:0:0:cb",
            "2:fc:a:0:0:cg",
            "2:fc:a:0:0:-1",
        ] {
            assert_eq!(interface_mac_value(&format!(" ether {value}\n")), None);
        }
        assert_eq!(interface_mac_value(" inet 2:fc:a:0:0:cb\n"), None);
    }

    #[test]
    fn only_inception_gets_its_exact_paired_slot() {
        for profile in [10, 20, 30, 40] {
            let mut document = document();
            document.ipv4 = format!("10.{profile}.3.9");
            document.gateway = format!("10.{profile}.0.1");
            let network = network(&document, &document.mac).unwrap();
            assert_eq!(
                network.paired,
                (profile == 40).then_some(Ipv4Addr::new(10, 41, 3, 9))
            );
        }
    }

    #[test]
    fn live_network_facts_refuse_wrong_masks_interfaces_and_indirect_gateways() {
        let address = Ipv4Addr::new(10, 10, 0, 203);
        let gateway = Ipv4Addr::new(10, 10, 0, 1);
        let interface =
            "vtnet0: flags=UP\n inet 10.10.0.203 netmask 0xffffffff broadcast 10.10.0.203\n";
        let routes = "default 10.10.0.1 UGS 0 0 vtnet0\n10.10.0.1 link#1 UHS 0 0 vtnet0\n";
        assert!(network_facts(interface, routes, "vtnet0", address, gateway));
        assert!(!network_facts(
            &interface.replace("0xffffffff", "0xffffff00"),
            routes,
            "vtnet0",
            address,
            gateway
        ));
        assert!(!network_facts(
            interface,
            &routes.replace("UHS", "UGHS"),
            "vtnet0",
            address,
            gateway
        ));
        assert!(!network_facts(
            interface,
            &routes.replace("vtnet0", "vtnet1"),
            "vtnet0",
            address,
            gateway
        ));
        assert!(!network_facts(
            &interface.replace("10.10.0.203", "10.10.0.2030"),
            routes,
            "vtnet0",
            address,
            gateway
        ));
        assert!(!network_facts(
            interface,
            &routes.replace("10.10.0.1", "10.10.0.10"),
            "vtnet0",
            address,
            gateway
        ));
        let illumos_interface =
            "vioif0: flags=UP\n inet 10.10.0.203 netmask ffffffff broadcast 10.10.0.203\n";
        let illumos_routes =
            "default 10.10.0.1 UG 1 0 vioif0\n10.10.0.1 10.10.0.203 UHL 1 0 vioif0\n";
        assert!(network_facts(
            illumos_interface,
            illumos_routes,
            "vioif0",
            address,
            gateway
        ));
    }
}
