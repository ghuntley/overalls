//! One certificate installation path for ephemeral guest and persistent gateway keys.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use fs2::FileExt;
use lyra::{
    guest::ssh_platform::Platform,
    private_http,
    ssh_certificate::{self, Issued, RENEWAL_WINDOW},
    ssh_files,
};
use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use serde::Deserialize;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream, ToSocketAddrs};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Gateway {
    role: Role,
    origin: String,
    key_dir: PathBuf,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Role {
    Porsche,
    Audi,
}

#[derive(Debug, PartialEq, Eq)]
enum Installation {
    Missing,
    Current,
    Renewal,
}
// @cc [owner:ghuntley,label:security;observability] host-certificate-fixed-failure-stage
// A failed gateway certificate request MUST emit only one of these fixed stage
// names. It MUST NOT include credentials, URLs, request bodies, response
// bodies, filesystem paths or native error text in the service journal.
fn unavailable(stage: &'static str) -> io::Error {
    eprintln!("SSH host certificate unavailable: {stage}");
    ssh_certificate::invalid()
}

fn now() -> io::Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ssh_certificate::invalid())?
        .as_secs())
}
fn key(directory: &Path, guest: bool) -> io::Result<String> {
    let private = directory.join("ssh_host_ed25519_key");
    if !private.try_exists()? && guest {
        let status = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(unavailable("key-generate"));
        }
    }
    ssh_files::read(&private, 16_384).map_err(|_| unavailable("key-read"))?;
    let output = Command::new("ssh-keygen")
        .args(["-y", "-f"])
        .arg(&private)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() || output.stdout.len() > 4096 {
        return Err(unavailable("key-export"));
    }
    let public = String::from_utf8(output.stdout)
        .map_err(|_| unavailable("key-format"))?
        .split_whitespace()
        .take(2)
        .collect::<Vec<_>>()
        .join(" ");
    ssh_certificate::public_key(&public).map_err(|_| unavailable("key-format"))?;
    Ok(public)
}
fn existing(directory: &Path, key: &str, now: u64) -> Installation {
    let result = (|| -> io::Result<bool> {
        let value: Issued = serde_json::from_slice(&ssh_files::read(
            &directory.join("certificate.json"),
            20_000,
        )?)?;
        let line = String::from_utf8(ssh_files::read(
            &directory.join("ssh_host_ed25519_key-cert.pub"),
            16_384,
        )?)
        .map_err(|_| ssh_certificate::invalid())?;
        if value.version != 1 || value.certificate != line {
            return Err(ssh_certificate::invalid());
        }
        let cert = ssh_certificate::verify(&line, &value.ca, key, &value.principal, now)?;
        Ok(cert.valid_before() > now + RENEWAL_WINDOW)
    })();
    match result {
        Ok(true) => Installation::Current,
        Ok(false) => Installation::Renewal,
        Err(_) => Installation::Missing,
    }
}
fn credential(name: &str) -> io::Result<PathBuf> {
    std::env::var_os("CREDENTIALS_DIRECTORY")
        .map(|directory| PathBuf::from(directory).join(name))
        .ok_or_else(ssh_certificate::invalid)
}
struct GatewayClient {
    host: String,
    port: u16,
    tls: Arc<ClientConfig>,
}

fn gateway_client(config: &Gateway) -> io::Result<GatewayClient> {
    let url = reqwest::Url::parse(&config.origin).map_err(|_| unavailable("gateway-url"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(unavailable("gateway-url"));
    }
    let ca_path = credential("ca.pem").map_err(|_| unavailable("gateway-credential"))?;
    let ca_bytes =
        ssh_files::read(&ca_path, 2_097_152).map_err(|_| unavailable("gateway-credential"))?;
    let host = url
        .host_str()
        .ok_or_else(|| unavailable("gateway-url"))?
        .to_owned();
    let port = url
        .port_or_known_default()
        .ok_or_else(|| unavailable("gateway-url"))?;
    let roots = roots_from_pem(&ca_bytes)?;
    // The gateway listener is a deliberately small HTTP/1.1 service. Connect
    // to IPv4 explicitly while retaining the hostname for TLS SNI and
    // certificate verification, exactly as the inner Python publisher does.
    let tls = ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(GatewayClient {
        host,
        port,
        tls: Arc::new(tls),
    })
}

fn roots_from_pem(bytes: &[u8]) -> io::Result<RootCertStore> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let text = std::str::from_utf8(bytes).map_err(|_| unavailable("gateway-ca"))?;
    let mut remaining = text;
    let mut roots = RootCertStore::empty();
    let mut count = 0;
    while let Some((_, after)) = remaining.split_once(BEGIN) {
        let (encoded, rest) = after
            .split_once(END)
            .ok_or_else(|| unavailable("gateway-ca"))?;
        let value: String = encoded.chars().filter(|c| !c.is_whitespace()).collect();
        let der = STANDARD
            .decode(value)
            .map_err(|_| unavailable("gateway-ca"))?;
        roots
            .add(CertificateDer::from(der))
            .map_err(|_| unavailable("gateway-ca"))?;
        count += 1;
        remaining = rest;
    }
    if count == 0 {
        return Err(unavailable("gateway-ca"));
    }
    Ok(roots)
}
fn post_gateway(
    client: &GatewayClient,
    url: &str,
    body: &serde_json::Value,
    token: Option<&str>,
) -> io::Result<Vec<u8>> {
    let parsed = reqwest::Url::parse(url).map_err(|_| unavailable("gateway-url"))?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some(client.host.as_str())
        || parsed.port_or_known_default() != Some(client.port)
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(unavailable("gateway-url"));
    }
    let path = if parsed.path().is_empty() {
        "/"
    } else {
        parsed.path()
    };
    let body = serde_json::to_vec(body).map_err(|_| unavailable("gateway-json"))?;
    if let Some(token) = token {
        if !(1..=80).contains(&token.len())
            || token.bytes().any(|byte| matches!(byte, b'\r' | b'\n' | 0))
        {
            return Err(unavailable("gateway-token"));
        }
    }
    let address = if client.host == "localhost" {
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, client.port))
    } else {
        (client.host.as_str(), client.port)
            .to_socket_addrs()
            .map_err(|_| unavailable("gateway-dns"))?
            .find(SocketAddr::is_ipv4)
            .ok_or_else(|| unavailable("gateway-dns"))?
    };
    let stream = TcpStream::connect_timeout(&address, Duration::from_secs(5))
        .map_err(|_| unavailable("gateway-connect"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .and_then(|()| stream.set_write_timeout(Some(Duration::from_secs(10))))
        .map_err(|_| unavailable("gateway-connect"))?;
    let server_name = ServerName::try_from(client.host.clone())
        .map_err(|_| unavailable("gateway-tls-hostname"))?;
    let connection = ClientConnection::new(Arc::clone(&client.tls), server_name)
        .map_err(|_| unavailable("gateway-tls"))?;
    let mut stream = StreamOwned::new(connection, stream);
    while stream.conn.is_handshaking() {
        stream
            .conn
            .complete_io(&mut stream.sock)
            .map_err(|_| unavailable("gateway-tls"))?;
    }
    let authorization = token.map(|value| format!("Authorization: Bearer {value}\r\n"));
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {}:{}\r\nContent-Type: application/json\r\nAccept-Encoding: identity\r\n{}Content-Length: {}\r\nConnection: close\r\n\r\n",
        client.host,
        client.port,
        authorization.as_deref().unwrap_or(""),
        body.len()
    );
    stream
        .write_all(request.as_bytes())
        .and_then(|()| stream.write_all(&body))
        .and_then(|()| stream.flush())
        .map_err(|_| unavailable("gateway-connect"))?;
    let (status, response) = read_response(&mut stream)?;
    if !(200..300).contains(&status) {
        return Err(unavailable("gateway-http"));
    }
    Ok(response)
}

fn post_private(
    client: &reqwest::blocking::Client,
    url: &str,
    body: &serde_json::Value,
) -> io::Result<Vec<u8>> {
    let response = client
        .post(url)
        .header("content-type", "application/json")
        .body(serde_json::to_vec(body)?)
        .send()
        .map_err(|_| ssh_certificate::invalid())?;
    if !response.status().is_success() {
        return Err(ssh_certificate::invalid());
    }
    private_http::read_bounded(response, 20_000)
}

fn read_response(stream: &mut impl Read) -> io::Result<(u16, Vec<u8>)> {
    let mut headers = Vec::with_capacity(1024);
    let mut byte = [0_u8; 1];
    while !headers.ends_with(b"\r\n\r\n") {
        if headers.len() >= 8192 {
            return Err(unavailable("gateway-response"));
        }
        stream
            .read_exact(&mut byte)
            .map_err(|_| unavailable("gateway-response"))?;
        headers.push(byte[0]);
    }
    let header_end = headers.len() - 4;
    let text =
        std::str::from_utf8(&headers[..header_end]).map_err(|_| unavailable("gateway-response"))?;
    let mut lines = text.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| unavailable("gateway-response"))?;
    let mut length = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return Err(unavailable("gateway-response"));
        };
        if name.eq_ignore_ascii_case("content-encoding")
            && !value.trim().eq_ignore_ascii_case("identity")
        {
            return Err(unavailable("gateway-response"));
        }
        if name.eq_ignore_ascii_case("content-length") {
            if length.is_some() {
                return Err(unavailable("gateway-response"));
            }
            length = Some(
                value
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| unavailable("gateway-response"))?,
            );
        }
    }
    let mut body = Vec::new();
    if let Some(length) = length {
        if length > 20_000 {
            return Err(unavailable("gateway-response"));
        }
        body.resize(length, 0);
        stream
            .read_exact(&mut body)
            .map_err(|_| unavailable("gateway-response"))?;
    } else {
        // The request asks for connection close, so a legacy endpoint without
        // Content-Length can still be consumed without an unbounded read.
        stream
            .take(20_001)
            .read_to_end(&mut body)
            .map_err(|_| unavailable("gateway-response"))?;
        if body.len() > 20_000 {
            return Err(unavailable("gateway-response"));
        }
    }
    Ok((status, body))
}
// @cc [owner:ghuntley,label:security;recovery] host-certificate-atomic-installation
// Installation MUST validate an authenticated response before replacing the
// certificate. Guest private keys MUST remain in volatile runtime storage
// (/run on Linux, /var/run/overalls on native guests), never persistent disks.
// Failed renewal MUST retain a still-valid installed generation for retry.
fn run() -> io::Result<()> {
    #[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
    lyra::guest::mmds::fetch(Duration::from_secs(3))?;
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let gateway: Option<Gateway> = match args.as_slice() {
        [] => None,
        [path] => Some(serde_json::from_slice(&ssh_files::read(
            Path::new(path),
            8192,
        )?)?),
        _ => return Err(ssh_certificate::invalid()),
    };
    let directory = gateway.as_ref().map_or_else(
        || PathBuf::from(Platform::current().host_keys()),
        |c| c.key_dir.clone(),
    );
    if !directory.try_exists()? {
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    }
    let meta = fs::symlink_metadata(&directory)?;
    if !meta.is_dir() || meta.permissions().mode() & 0o077 != 0 {
        return Err(ssh_certificate::invalid());
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join("certificate.lock"))?;
    lock.try_lock_exclusive()?;
    let key = key(&directory, gateway.is_none())?;
    maintain(&directory, &key, now()?, gateway.is_some(), || {
        renew(&directory, &key, gateway.as_ref())
    })
}
// @cc [owner:ghuntley,label:security;recovery] gateway-principal-from-authority
// A gateway (`authority_decides`) MUST ask Marshall on every run even while
// its installed certificate is valid: the principal is Marshall's (the
// deployment's management host), and a certificate for a previous name stays
// cryptographically valid for years. A failed request MUST keep a still-valid
// installation. Guests skip the request while their per-boot certificate is
// current.
fn maintain(
    directory: &Path,
    key: &str,
    time: u64,
    authority_decides: bool,
    renew: impl FnOnce() -> io::Result<()>,
) -> io::Result<()> {
    if !authority_decides && matches!(existing(directory, key, time), Installation::Current) {
        return Ok(());
    }
    match renew() {
        Ok(()) => Ok(()),
        Err(error) => match existing(directory, key, time.max(now()?)) {
            Installation::Current | Installation::Renewal => Ok(()),
            Installation::Missing => Err(error),
        },
    }
}
fn renew(directory: &Path, key: &str, gateway: Option<&Gateway>) -> io::Result<()> {
    let response = if let Some(config) = gateway {
        let client = gateway_client(config)?;
        let token_path =
            credential("gateway.token").map_err(|_| unavailable("gateway-credential"))?;
        let token = String::from_utf8(
            ssh_files::read(&token_path, 128).map_err(|_| unavailable("gateway-credential"))?,
        )
        .map_err(|_| unavailable("gateway-token"))?;
        let token = token.trim();
        if token.is_empty()
            || token.len() > 80
            || token
                .chars()
                .any(|character| matches!(character, '\r' | '\n' | '\0'))
        {
            return Err(unavailable("gateway-token"));
        }
        let prefix = match config.role {
            Role::Audi => "audi",
            Role::Porsche => "ssh",
        };
        let root = format!("{}/api/{prefix}/v1", config.origin.trim_end_matches('/'));
        let body = serde_json::json!({"version":1,"public_key":key});
        if matches!(config.role, Role::Audi) {
            post_gateway(&client, &format!("{root}/host-key"), &body, Some(token))?;
        }
        post_gateway(
            &client,
            &format!("{root}/host-certificate"),
            &body,
            Some(token),
        )?
    } else {
        post_private(
            &private_http::client()?,
            "https://ssh.integration.internal/ssh/v1/host-certificate",
            &serde_json::json!({"public_key":key}),
        )?
    };
    let issued: Issued =
        serde_json::from_slice(&response).map_err(|_| unavailable("gateway-json"))?;
    if issued.version != 1 {
        return Err(unavailable("gateway-version"));
    }
    ssh_certificate::verify(
        &issued.certificate,
        &issued.ca,
        key,
        &issued.principal,
        now()?,
    )
    .map_err(|_| unavailable("gateway-certificate"))?;
    ssh_files::atomic(
        &directory.join("ssh_host_ed25519_key-cert.pub"),
        issued.certificate.as_bytes(),
    )
    .map_err(|_| unavailable("certificate-install"))?;
    ssh_files::atomic(
        &directory.join("certificate.json"),
        &serde_json::to_vec(&issued)?,
    )
    .map_err(|_| unavailable("certificate-install"))?;
    Ok(())
}
fn main() -> ExitCode {
    if run().is_ok() {
        ExitCode::SUCCESS
    } else {
        eprintln!("SSH host certificate unavailable");
        ExitCode::FAILURE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn renewal_outage_retains_valid_certificate_but_expiry_and_corruption_fail_closed() {
        let root = tempfile::tempdir().unwrap();
        let key = key(root.path(), true).unwrap();
        let ca = root.path().join("ca");
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
            .arg(&ca)
            .status()
            .unwrap()
            .success());
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-s"])
            .arg(&ca)
            .args([
                "-h",
                "-I",
                "renewal",
                "-n",
                "vm.example.test",
                "-V",
                "-5m:+3650d"
            ])
            .arg(root.path().join("ssh_host_ed25519_key.pub"))
            .status()
            .unwrap()
            .success());
        let line = fs::read_to_string(root.path().join("ssh_host_ed25519_key-cert.pub")).unwrap();
        let issued = Issued {
            version: 1,
            certificate: line.clone(),
            principal: "vm.example.test".into(),
            ca: fs::read_to_string(ca.with_extension("pub"))
                .unwrap()
                .trim()
                .into(),
        };
        ssh_files::atomic(
            &root.path().join("certificate.json"),
            &serde_json::to_vec(&issued).unwrap(),
        )
        .unwrap();
        let cert =
            ssh_certificate::verify(&line, &issued.ca, &key, &issued.principal, now().unwrap())
                .unwrap();
        assert_eq!(
            existing(root.path(), &key, cert.valid_before() - RENEWAL_WINDOW - 1),
            Installation::Current
        );
        assert_eq!(
            existing(root.path(), &key, cert.valid_before() - RENEWAL_WINDOW),
            Installation::Renewal
        );
        maintain(root.path(), &key, now().unwrap(), false, || {
            panic!("current guest certificates need no authority request")
        })
        .unwrap();
        // A gateway asks even while current (its principal may have moved),
        // and an unavailable authority keeps the valid installation.
        let mut asked = false;
        maintain(root.path(), &key, now().unwrap(), true, || {
            asked = true;
            Err(ssh_certificate::invalid())
        })
        .unwrap();
        assert!(asked);
        for gateway in [false, true] {
            maintain(root.path(), &key, cert.valid_before() - 1, gateway, || {
                Err(ssh_certificate::invalid())
            })
            .unwrap();
            assert!(
                maintain(root.path(), &key, cert.valid_before(), gateway, || Err(
                    ssh_certificate::invalid()
                ))
                .is_err()
            );
        }
        assert_eq!(
            fs::read_to_string(root.path().join("ssh_host_ed25519_key-cert.pub")).unwrap(),
            line
        );
        fs::write(root.path().join("ssh_host_ed25519_key-cert.pub"), "broken").unwrap();
        assert!(maintain(root.path(), &key, now().unwrap(), false, || Err(
            ssh_certificate::invalid()
        ))
        .is_err());
    }
}
