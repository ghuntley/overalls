//! Every-boot root expansion with no caller-selected device or pool.
#![deny(unsafe_code)]

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> std::process::ExitCode {
    use lyra::native_growth::{self, Os};
    let os = if cfg!(target_os = "freebsd") {
        Os::FreeBsd
    } else {
        Os::Illumos
    };
    if std::env::args_os().len() != 1 || native_growth::run(os).is_err() {
        eprintln!("native_root_growth_failed");
        std::process::ExitCode::FAILURE
    } else {
        std::process::ExitCode::SUCCESS
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> std::process::ExitCode {
    std::process::ExitCode::from(64)
}
