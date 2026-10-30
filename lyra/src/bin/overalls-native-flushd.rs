//! Boot-bound native filesystem flush daemon (vsock port 1026).

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn run() -> std::io::Result<()> {
    use lyra::{guest::flush, native_guest, native_vsock::Listener};
    let (boot, _, _) = native_guest::identity()?;
    let listener = Listener::bind(flush::PORT, 1)?;
    loop {
        let Ok(mut connection) = listener.accept() else {
            continue;
        };
        // Malformed input, a rejected peer and a reset affect one connection.
        let _ = flush::answer(&mut connection, &boot, native_guest::flush_root);
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    std::process::exit(i32::from(run().is_err()));
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}
