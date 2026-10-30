use std::fs;
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
use tempfile::tempdir;

#[test]
fn command_and_environment_canary_never_enter_persistent_diagnostics() {
    let home = tempdir().unwrap();
    let state = home.path().join("state");
    fs::create_dir(home.path().join(".ssh")).unwrap();
    fs::write(
        home.path().join(".ssh/config"),
        "Host *\n  ServerAliveInterval 15\n",
    )
    .unwrap();
    let canary = "SYNTHETIC_COMMAND_SECRET_314159";
    let output = Command::new(env!("CARGO_BIN_EXE_overalls"))
        .args(["proxy", "--host", canary])
        .env("HOME", home.path())
        .env("XDG_STATE_HOME", &state)
        .env("SYNTHETIC_SECRET", canary)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let fixture_bin = home.path().join("bin");
    fs::create_dir(&fixture_bin).unwrap();
    let mock_id = fixture_bin.join("id");
    fs::write(
        &mock_id,
        "#!/bin/sh\ntest \"$1\" = -un || exit 1\nprintf 'local-alias\\n'\n",
    )
    .unwrap();
    let mock_ssh = fixture_bin.join("ssh");
    fs::write(
        &mock_ssh,
        "#!/bin/sh\nif test \"$1\" = -F; then exit 1; fi\ntest \"$1\" = -T && test \"$2\" = -p && test \"$3\" = 22 && test \"$4\" = -o && test \"$5\" = \"UserKnownHostsFile=$HOME/.ssh/known_hosts\" && test \"$6\" = -o && test \"$7\" = GlobalKnownHostsFile=/dev/null && test \"$8\" = -o && test \"$9\" = StrictHostKeyChecking=yes && test \"${10}\" = -o && test \"${11}\" = HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com && test \"${12}\" = -l && test \"${13}\" = local-alias && test \"${14}\" = -- && test \"${15}\" = 127.0.0.1 && test \"${16}\" = whoami && test \"${17}\" = --json || exit 1\nprintf '%s\\n' '{\"version\":1,\"status\":\"succeeded\",\"result\":{\"guest_username\":\"geoffrey.huntley\",\"public_key\":\"ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIE10h2nLdSYgJPONwlhCys6F4ZgL1Qnc09ncBUr9NQnx\"}}'\n",
    )
    .unwrap();
    for path in [&mock_id, &mock_ssh] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let fixture_path = format!(
        "{}:{}",
        fixture_bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let tls = home.path().join("tls.pem");
    let tls_key = home.path().join("tls.key");
    assert!(Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=IP:127.0.0.1",
            "-addext",
            "basicConstraints=critical,CA:FALSE",
            "-keyout"
        ])
        .arg(&tls_key)
        .arg("-out")
        .arg(&tls)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success());
    fs::write(fixture_bin.join("ssh-trust.json"), serde_json::to_vec(&serde_json::json!({
        "version":1,"ca":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "management_host":"127.0.0.1","zone":"vm.example","retirement":2421446400_u64
    })).unwrap()).unwrap();
    let mut server = Server(
        Command::new("openssl")
            .args([
                "s_server",
                "-quiet",
                "-WWW",
                "-accept",
                &format!("127.0.0.1:{port}"),
                "-cert",
            ])
            .arg(&tls)
            .arg("-key")
            .arg(&tls_key)
            .current_dir(home.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline && server.0.try_wait().unwrap().is_none());
        std::thread::yield_now();
    }
    let origin = format!("https://127.0.0.1:{port}");
    let setup = Command::new(env!("CARGO_BIN_EXE_overalls"))
        .args(["config-ssh", "--origin", &origin, "--zone", "vm.example"])
        .env("HOME", home.path())
        .env("PATH", &fixture_path)
        .env("SSL_CERT_FILE", &tls)
        .env("XDG_STATE_HOME", &state)
        .env("SYNTHETIC_SECRET", canary)
        .output()
        .unwrap();
    assert!(
        setup.status.success(),
        "{}",
        String::from_utf8_lossy(&setup.stderr)
    );
    let profile = fs::read_to_string(home.path().join(".ssh/config")).unwrap();
    assert!(profile.starts_with("# BEGIN OVERALLS SSH\nHost *.vm.example\n"));
    assert!(profile.contains("  User geoffrey.huntley\n"));
    assert!(profile.contains("Host *\n  ServerAliveInterval 15\n"));
    let resolved = Command::new("ssh")
        .args([
            "-G",
            "-F",
            home.path().join(".ssh/config").to_str().unwrap(),
            "vm-0123456789abcdef0123456789abcdef.vm.example",
        ])
        .output()
        .unwrap();
    assert!(resolved.status.success());
    assert!(String::from_utf8_lossy(&resolved.stdout).contains(" proxy --host "));

    // A real downloaded process must not delegate to the prior executable,
    // whether configuration succeeds or CA trust is refused.
    let managed = home.path().join(".local/bin/overalls");
    let prior = b"prior executable sentinel\n";
    fs::write(&managed, prior).unwrap();
    let known_hosts = home.path().join(".ssh/known_hosts");
    let trusted = fs::read_to_string(&known_hosts).unwrap();
    for refused in [false, true] {
        if refused {
            fs::write(
                &known_hosts,
                trusted.replace("ssh-ed25519 ", "ssh-ed25519 invalid"),
            )
            .unwrap();
        }
        let before = fs::read(&known_hosts).unwrap();
        let staged = Command::new(env!("CARGO_BIN_EXE_overalls"))
            .args([
                "config-ssh",
                "--origin",
                &origin,
                "--zone",
                "vm.example",
                "--staged-installer",
            ])
            .env("HOME", home.path())
            .env("PATH", &fixture_path)
            .env("SSL_CERT_FILE", &tls)
            .env("XDG_STATE_HOME", &state)
            .output()
            .unwrap();
        assert_eq!(
            staged.status.success(),
            !refused,
            "{}",
            String::from_utf8_lossy(&staged.stderr)
        );
        assert_eq!(fs::read(&managed).unwrap(), prior);
        assert_eq!(fs::read(&known_hosts).unwrap(), before);
        assert_eq!(
            fs::read_to_string(home.path().join(".ssh/config")).unwrap(),
            profile
        );
    }
    let logs = state.join("overalls/logs");
    let mut found = false;
    for entry in fs::read_dir(logs).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|part| part == "jsonl") {
            found = true;
        }
        let bytes = fs::read(path).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains(canary));
    }
    assert!(found);
}
