//! Readiness daemon for native FreeBSD and illumos guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::{
        kernel_probe,
        readiness::{self, Probe},
    };
    use lyra::native_guest;
    use lyra::native_vsock::{self, Listener};
    use std::io::{self, Write};
    use std::net::Ipv4Addr;

    struct Live<'a> {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
        os: &'static str,
        kernel_digest: String,
        kernel_build_id: String,
        listener: &'a Listener,
    }
    impl Probe for Live<'_> {
        fn ready(&mut self) -> io::Result<bool> {
            Ok(native_guest::services_ready()?
                && native_guest::network_ready(self.address, self.gateway)?
                && native_guest::writable_root().is_ok()
                && kernel_probe::verified_build_id(self.listener)
                    .is_ok_and(|current| current == self.kernel_build_id)
                && kernel_probe::kernel_sha256(self.os)
                    .is_ok_and(|current| current == self.kernel_digest))
        }
    }

    let Ok((boot, address, gateway)) = native_guest::identity() else {
        std::process::exit(1);
    };
    let Ok(listener) = Listener::bind(readiness::PORT, 4) else {
        std::process::exit(2);
    };
    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let Ok(kernel_digest) = kernel_probe::kernel_sha256(os) else {
        std::process::exit(3);
    };
    let Ok(kernel_build_id) = kernel_probe::verified_build_id(&listener) else {
        std::process::exit(4);
    };
    let mut probe = Live {
        address,
        gateway,
        os,
        kernel_digest,
        kernel_build_id,
        listener: &listener,
    };
    loop {
        let Ok(mut connection) = listener.accept() else {
            continue;
        };
        if let Ok(Some(response)) = readiness::answer(
            connection.peer_cid,
            native_vsock::HOST_CID,
            &boot,
            &mut probe,
        ) {
            let _ = connection.write_all(&response);
        }
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}
