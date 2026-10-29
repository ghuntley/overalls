//! Test-only probe for `openat2` resolution.
//!
//! Some build sandboxes filter `openat2` to ENOSYS. hostd's production paths
//! fail closed there, so the tests that need beneath-root resolution skip with
//! an explicit message instead; `cargo test` on a host and the machine tests
//! still run them.

use rustix::fs::{openat2, Mode, OFlags, ResolveFlags, CWD};
use rustix::io::Errno;

/// True when this kernel or sandbox refuses `openat2` with ENOSYS; prints why
/// the calling test is skipped.
pub(crate) fn unavailable(test: &str) -> bool {
    let refused = matches!(
        openat2(
            CWD,
            ".",
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty(),
            ResolveFlags::BENEATH
        ),
        Err(Errno::NOSYS)
    );
    if refused {
        eprintln!("skipping {test}: openat2 is unavailable (ENOSYS) in this sandbox");
    }
    refused
}
