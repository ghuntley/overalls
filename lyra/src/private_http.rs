use std::fs::File;
use std::io::{self, Read};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;
const MAX_CA_BUNDLE: usize = 2 * 1024 * 1024;
/// The reviewed native system trust location; Linux retains its existing path.
pub const SYSTEM_CA_BUNDLE: &str = if cfg!(target_os = "freebsd") {
    "/etc/ssl/cert.pem"
} else if cfg!(any(target_os = "illumos", target_os = "solaris")) {
    "/etc/ssl/cacert.pem"
} else {
    "/etc/ssl/certs/ca-certificates.crt"
};
const PRIVATE_ENDPOINT: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(169, 254, 254, 1), 443));
pub fn read_bounded(reader: impl Read, maximum: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take((maximum + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > maximum {
        return Err(io::Error::other("response too large"));
    }
    Ok(bytes)
}
pub fn client() -> io::Result<reqwest::blocking::Client> {
    client_for(
        "ssh.integration.internal",
        Duration::from_secs(3),
        Duration::from_secs(2),
    )
}

// @cc [owner:ghuntley,label:security;deployment] otel-private-tls-verification
// Guest diagnostics MUST use the same bounded private root bundle and exact
// hostname verification as SSH, with only the fixed OTLP hostname resolved.
pub fn telemetry_client() -> io::Result<reqwest::blocking::Client> {
    client_for(
        "otel.integration.internal",
        Duration::from_secs(2),
        Duration::from_secs(1),
    )
}

// @cc [owner:ghuntley,label:security;deployment] native-executor-private-tls
// Native executor RPCs MUST use the bounded image trust bundle and verify the
// exact llm.internal hostname at the fixed private endpoint, with no proxy or
// redirects. A malformed or missing bundle MUST refuse before any request.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub(crate) fn executor_client(timeout: Duration) -> io::Result<reqwest::blocking::Client> {
    client_for("llm.internal", timeout, timeout.min(Duration::from_secs(2)))
}

fn client_for(
    hostname: &'static str,
    timeout: Duration,
    connect_timeout: Duration,
) -> io::Result<reqwest::blocking::Client> {
    let path =
        std::env::var("OVERALLS_SSH_CA_BUNDLE").unwrap_or_else(|_| SYSTEM_CA_BUNDLE.to_owned());
    let pem = read_bounded(File::open(path)?, MAX_CA_BUNDLE)?;
    let certificates = reqwest::Certificate::from_pem_bundle(&pem)
        .map_err(|_| io::Error::other("invalid private TLS trust bundle"))?;
    if certificates.is_empty() || certificates.len() > 512 {
        return Err(io::Error::other("invalid private TLS trust bundle"));
    }
    // @cc [owner:ghuntley,label:security;deployment] ssh-private-tls-verification
    // The guest MUST verify the private chain and exact HTTPS hostname with the
    // image's trust bundle for both deployed and newly issued leaves. The
    // client MUST NOT disable certificate or hostname verification.
    // The deployed leaf also has a broad SAN that Rustls rejects before its
    // valid integration-zone SAN; native TLS verifies the latter on guests
    // (OpenSSL on Linux, schannel on Windows guests, ADR-0171).
    #[cfg(any(target_os = "linux", windows))]
    let builder = reqwest::blocking::Client::builder().use_native_tls();
    #[cfg(not(any(target_os = "linux", windows)))]
    let builder = reqwest::blocking::Client::builder().use_rustls_tls();
    let builder = certificates.into_iter().fold(
        builder.tls_built_in_root_certs(false),
        reqwest::blocking::ClientBuilder::add_root_certificate,
    );
    builder
        .no_proxy()
        .resolve(hostname, PRIVATE_ENDPOINT)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(timeout)
        .connect_timeout(connect_timeout)
        .build()
        .map_err(|_| io::Error::other("private TLS client unavailable"))
}
