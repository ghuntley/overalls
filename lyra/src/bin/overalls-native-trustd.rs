//! Boot-bound trust bundle installer for native guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::trust;
    use lyra::native_guest;
    use lyra::native_vsock::Listener;
    use std::path::Path;

    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let Ok((boot, _, _)) = native_guest::identity() else {
        std::process::exit(1);
    };
    let Ok(listener) = Listener::bind(trust::PORT, 1) else {
        std::process::exit(2);
    };
    loop {
        let Ok(mut connection) = listener.accept() else {
            continue;
        };
        let Ok(request) = trust::read_frame(&mut connection) else {
            continue;
        };
        let Ok((base, destination)) = native_guest::trust_paths(os) else {
            continue;
        };
        if native_guest::install_trust(
            Path::new(base),
            Path::new(destination),
            Path::new("/var/lib/overalls-trust"),
            &request,
            &boot,
        )
        .is_err()
        {
            continue;
        }
        let _ = trust::write_frame(&mut connection, &trust::receipt(&request, &boot));
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}
