//! Host-only native kernel attestation daemon.
#![deny(unsafe_code)]

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    std::process::exit(match lyra::guest::kernel_probe::run(os) {
        Ok(()) => 0,
        Err(_) => 1,
    });
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}
