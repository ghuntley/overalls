# @cc [owner:ghuntley,label:verification;security] audi-relocation-real-publication
# Moving a real guest MUST preserve its stable name, inner SSH identity and data.
# The unchanged strict client profile MUST obtain the destination gateway key
# through Marshall's verified HTTPS publication. Stale source addresses MUST NOT
# relay to the destination. SQL observations MUST NOT fabricate route readiness,
# relocation progress, credentials or guest execution.
# Stream termination may be a clean HTTP EOF or a transport error; reaching the
# client's timeout MUST NOT count as authority-driven termination.
with subtest("Audi stable names and strict nested SSH follow a real guest relocation"):
    # L2 adds one public fixture root; the guest must use its current host's set.
    extra_root_path: str = l2.succeed(
        "jq -r '.execution.guest_trust_roots[-1]' /run/lilly-release/config.json"
    ).strip()
    extra_root_b64: str = l2.succeed("base64 -w0 " + shlex.quote(extra_root_path)).strip()

    def assert_destination_trust(host_name: str) -> None:
        program: str = (
            "import base64,pathlib; expected=base64.b64decode("
            + repr(extra_root_b64)
            + "); actual=pathlib.Path('/etc/ssl/certs/ca-certificates.crt').read_bytes(); "
            + "assert (expected in actual) == "
            + repr(host_name == "l2")
        )
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_arguments, "python3 -c " + shlex.quote(program)]),
            timeout=60,
        )

    # Earlier scenarios suspended issuance and revoked the first platform key.
    # Resume the same issuer identity and enroll an independent new platform key.
    m1.succeed("systemctl kill --signal=CONT --kill-whom=main fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    client.succeed(
        "sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/relocation-key"
    )
    replacement = client.succeed("cat /home/tester/.ssh/relocation-key.pub").strip()
    relocation_key = operator(
        m1, dict(action="audi-ssh-key", owner_id=users["owner_id"], public_key=replacement)
    )
    client.succeed("sudo -u tester mv /home/tester/.ssh/id_ed25519 /home/tester/.ssh/revoked-key")
    client.succeed(
        "sudo -u tester mv /home/tester/.ssh/id_ed25519.pub /home/tester/.ssh/revoked-key.pub"
    )
    client.succeed(
        "sudo -u tester cp /home/tester/.ssh/relocation-key /home/tester/.ssh/id_ed25519"
    )
    client.succeed(
        "sudo -u tester cp /home/tester/.ssh/relocation-key.pub /home/tester/.ssh/id_ed25519.pub"
    )
    original = current_copy(vm["vm_id"])
    source = host_for(original)
    assert_destination_trust(source.name)
    source_address = client.succeed(
        "python3 -c "
        + shlex.quote("import socket; print(socket.gethostbyname(" + repr(source.name) + "))")
    ).strip()
    client.succeed(
        ssh_environment
        + shlex.join(
            [
                *ssh_arguments,
                "printf '%s\\n' home-retained > \"$HOME/audi-relocation-home-marker\" && sync",
            ]
        ),
        timeout=30,
    )
    # @cc [owner:ghuntley,label:verification;security] audi-relocation-home-ownership
    # The moved guest MUST retain each distinct account home, numeric owner and
    # restrictive mode, not merely the owner's ability to open a new SSH stream.
    home_command = f"stat -c '%u:%a' /home/{remote_username} /home/{member_name}"
    homes_before = client.succeed(
        ssh_environment + shlex.join([*ssh_arguments, home_command]), timeout=30
    ).splitlines()
    assert len(homes_before) == 2 and all(row.endswith(":700") for row in homes_before)
    profile_before = client.succeed("sha256sum /var/lib/fleet-audi/ssh.conf").strip()
    lookup = (
        f"curl --fail --silent --show-error --max-time 5 --cacert {root}/ca.crt "
        f"https://control.example.test/api/audi/v1/known-hosts/{policy['label']!s}"
    )
    key_before = client.succeed(lookup).strip()
    assert key_before

    live = (
        "import subprocess,pathlib; p=subprocess.Popen("
        + repr(
            [
                "/run/current-system/sw/bin/curl",
                "--no-buffer",
                "--silent",
                "--show-error",
                "--max-time",
                "1800",
                "--cacert",
                root + "/audi-root.pem",
                "https://" + hostname + "/stream",
            ]
        )
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); assert p.stdout.readline() == b'audi-guest\\n'; "
        "pathlib.Path('/run/audi-relocation-stream-ready').touch(); "
        "p.communicate(timeout=1800); assert p.returncode in (0, 18, 52, 56)"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-relocation-stream "
        "--property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null python3 -c "
        + shlex.quote(live)
    )
    wait_audi_stream("audi-relocation-stream.service", "/run/audi-relocation-stream-ready")

    move = relocate(vm["vm_id"])
    assert move["source_placement_id"] == original["placement_id"]
    try:
        destination = await_relocation(move, abort_on_readiness_failure=True)
    except AssertionError:
        diagnostic_host = host_for(
            PlacementRef(
                host_id=move["destination_host_id"],
                placement_id=move["destination_placement_id"],
            )
        )
        try:
            diagnostic_host.succeed(
                "fleet-audi-guest ssh-status " + shlex.quote(move["destination_placement_id"]),
                timeout=150,
            )
        except Exception:
            print('audi_guest_readiness_diagnostic: {"status":"unavailable"}', flush=True)
        raise
    assert destination["host_id"] != original["host_id"]
    assert destination["slot"] == original["slot"]
    destination_host = host_for(destination)
    destination_address = client.succeed(
        "python3 -c "
        + shlex.quote(
            "import socket; print(socket.gethostbyname(" + repr(destination_host.name) + "))"
        )
    ).strip()
    assert destination_address != source_address
    client.wait_for_unit("audi-relocation-stream.service", timeout=10)
    assert (
        client.succeed(
            "systemctl show audi-relocation-stream.service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )

    # Wait on real publication and both authoritative replicas, without writing
    # routing state or extending the production five-second authority bound.
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM ingress_routes WHERE "
                f"vm_id='{vm['vm_id']}' AND placement_id='{destination['placement_id']}' "
                "AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    try:
        # The fixture binds DNS on IPv4, while machine names also resolve to IPv6.
        # Query that listener explicitly so an IPv6 fallback error cannot become
        # part of dig's stdout and invalidate an otherwise exact address answer.
        for server in ("m2", "m3"):
            client.wait_until_succeeds(
                f'test "$(dig -4 @{server} {hostname} A +short)" = '
                + shlex.quote(destination_address),
                timeout=60,
            )
    except Exception:
        try:
            # Retain only bounded fixture DNS answers and selected publication facts;
            # never print service tokens, certificates, guest bytes or full DB rows.
            for server in ("m2", "m3"):
                code, answer = client.execute(
                    f"dig -4 @{server} {hostname} A +time=1 +tries=1 +noall +comments +answer",
                    timeout=5,
                )
                print(
                    "relocation_dns_"
                    + server
                    + ": "
                    + json.dumps(
                        {"exit": code, "answer": answer[:4096], "expected": destination_address}
                    )
                )
            print(
                "relocation_dns_route: "
                + json.dumps(
                    sql_json(
                        "SELECT json_build_object('label_matches',e.label="
                        + "'"
                        + str(policy["label"])
                        + "','addresses',s.addresses,'enabled',s.enabled,"
                        + "'service_generation_matches',s.generation=r.service_generation,"
                        + "'ssh_key_present',s.ssh_host_key IS NOT NULL,"
                        + "'host_enabled',h.enabled,'host_mode',h.maintenance_mode,"
                        + "'host_session_present',h.connection_session_id IS NOT NULL,"
                        + "'host_recent',h.reported_at BETWEEN (clock_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds' AND (clock_timestamp() AT TIME ZONE 'UTC'),"
                        + "'placement_matches',v.current_placement_id=r.placement_id,"
                        + "'epoch_matches',v.execution_epoch=r.execution_epoch,"
                        + "'generation_matches',v.generation=r.generation,"
                        + "'desired',v.desired_state,'observed',v.observed_state,"
                        + "'route_fresh',r.expires_at > (clock_timestamp() AT TIME ZONE 'UTC'),"
                        + "'certificate_fresh',r.certificate_expires_at > (clock_timestamp() AT TIME ZONE 'UTC')) "
                        + "FROM ingress_routes r JOIN ingress_services s ON s.id=r.service_id "
                        + "JOIN compute_hosts h ON h.id=s.host_id "
                        + "JOIN compute_virtual_machines v ON v.id=r.vm_id "
                        + "JOIN ingress_endpoints e ON e.vm_id=v.id "
                        + f"WHERE r.vm_id='{vm['vm_id']}'"
                    )
                )
            )
        except Exception:
            print('relocation_dns_diagnostics: {"status":"unavailable"}')
        raise
    key_after = client.succeed(lookup).strip()
    assert key_after and key_after != key_before
    assert client.succeed("sha256sum /var/lib/fleet-audi/ssh.conf").strip() == profile_before
    client.wait_until_succeeds(
        ssh_environment
        + shlex.join(
            [
                *ssh_arguments,
                'test "$(cat "$HOME/audi-relocation-home-marker")" = home-retained',
            ]
        ),
        timeout=60,
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, "whoami"])).strip()
        == remote_username
    )
    assert_destination_trust(destination_host.name)
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, "pwd"])).strip()
        == "/home/" + remote_username
    )
    # @cc [owner:ghuntley,label:verification;recovery] audi-relocation-user-ssh-commands
    # A new SSH connection after relocation MUST execute ordinary user commands
    # and see the same persistent home, not merely pass admission.
    home_listing = client.succeed(
        ssh_environment + shlex.join([*ssh_arguments, 'ls -A "$HOME"'])
    ).splitlines()
    assert "audi-relocation-home-marker" in home_listing
    assert (
        client.succeed(
            ssh_environment
            + shlex.join([*ssh_arguments, 'cat "$HOME/audi-relocation-home-marker"'])
        ).strip()
        == "home-retained"
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, home_command])).splitlines()
        == homes_before
    )
    eventually(
        lambda: (
            int(
                sql(
                    "SELECT count(*) FROM ssh_guest_logins WHERE "
                    f"vm_id='{vm['vm_id']}' AND user_id='{users['owner_id']}' "
                    f"AND key_id='{relocation_key['id']}' "
                    f"AND host_id='{destination['host_id']}' "
                    f"AND placement_id='{destination['placement_id']}'"
                )
            )
            >= 1
        ),
        timeout=30,
    )

    # A moved VM restarts its guest OS; launch the test application again through
    # its real console, then require TLS-verified bytes at the original name.
    destination_host.succeed(
        "fleet-audi-guest " + shlex.quote(destination["placement_id"]), timeout=180
    )
    client.wait_until_succeeds(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem "
        f"https://{hostname}/ | grep -qx audi-guest",
        timeout=60,
    )
    client.fail(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem "
        f"--resolve {hostname}:443:{source_address} https://{hostname}/ >/dev/null 2>&1",
        timeout=15,
    )

    # Force only the outer transport address back to the former source. Keep
    # the exact hostname, the installed profile, its HTTPS key lookup and the
    # strict verification options: the client's `overalls proxy` builds the
    # outer SSH command itself, so pin the name in a private mount namespace.
    # Hiding nscd makes glibc read the pinned hosts file for every lookup.
    def ssh_pinned(address: str, command: str) -> str:
        hosts = "/run/audi-relocation-hosts-" + address
        # Keep every other static name (the control origin among them).
        client.succeed(
            f"grep -vwF {shlex.quote(hostname)} /etc/hosts >{hosts}; "
            f"printf '%s %s\\n' {shlex.quote(address)} {shlex.quote(hostname)} >>{hosts}"
        )
        inner = (
            f"mount --bind {hosts} /etc/hosts && "
            "{ [ ! -d /run/nscd ] || mount -t tmpfs none /run/nscd; } && exec "
            + ssh_environment
            + shlex.join([*ssh_arguments, command])
        )
        return "unshare --mount --propagation private sh -c " + shlex.quote(inner)

    # Positive control: the pinned path reaches the guest at its current host,
    # so the stale refusal below cannot pass because pinning itself is broken.
    code, output = client.execute(ssh_pinned(destination_address, "id -un") + " 2>&1", timeout=60)
    assert code == 0 and output.strip() == remote_username, output[-2048:]
    client.fail(ssh_pinned(source_address, "true") + " >/dev/null 2>&1", timeout=30)

    # Move the same retained disk back so both addition and removal of the
    # destination-only root are observed in the effective guest bundle.
    return_move = relocate(vm["vm_id"])
    assert return_move["source_placement_id"] == destination["placement_id"]
    returned = await_relocation(return_move, abort_on_readiness_failure=True)
    assert returned["host_id"] == original["host_id"]
    client.wait_until_succeeds(ssh_environment + shlex.join([*ssh_arguments, "true"]), timeout=60)
    assert_destination_trust(source.name)
