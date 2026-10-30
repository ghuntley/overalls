# @cc [owner:ghuntley,label:verification;security] fleet-audi-physical-web-path
# DNS, certificate issuance, browser grants and guest bytes MUST traverse the
# actual releases and nested Firecracker guest. Pebble MUST validate real Audi
# DNS proofs; no synthetic route or execution observation is injected. TLS trust
# MUST remain verified. Private browser URLs/cookies MUST stay inside the client.
import re
from typing import Protocol


class AudiMachineLike(MachineLike, Protocol):
    pass


def audi_ready(machine: AudiMachineLike, role: str) -> bool:
    """@cc [owner:ghuntley,label:verification] fleet-audi-live-role-health
    Readiness MUST come from the deployed private socket and match the exact
    role/version envelope. Unit activity alone MUST NOT establish readiness.
    """
    path = "/run/audi-dns/status.sock" if role == "dns" else "/run/audi/status.sock"
    probe = (
        "import socket,json; s=socket.socket(socket.AF_UNIX); s.settimeout(7); "
        "s.connect(" + repr(path) + "); "
        "f=s.makefile('rb'); data=f.readline(4097); "
        "assert len(data)<=4096 and data.endswith(b'\\n'); "
        "print(data.decode()); s.close()"
    )
    code, output = machine.execute("python3 -c " + shlex.quote(probe), timeout=10)
    if code:
        return False
    value = json.loads(output)
    assert set(value) == {"version", "role", "ready"}
    assert type(value["version"]) is int and value["version"] == 1
    assert value["role"] == role and type(value["ready"]) is bool
    return value["ready"]


def wait_audi_stream(unit: str, marker: str) -> None:
    def ready() -> bool:
        state = client.succeed(
            "systemctl show " + shlex.quote(unit) + " --property=ActiveState --value"
        ).strip()
        assert state != "failed", "Audi stream fixture failed before readiness: " + unit
        return client.execute("test -f " + shlex.quote(marker))[0] == 0

    eventually(ready, timeout=20)


with subtest("independent Audi DNS nodes and local gateways obtain runtime credentials"):
    for machine in [m2, m3]:
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path)
        )
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        address = client.succeed(
            "python3 -c "
            + shlex.quote("import socket; print(socket.gethostbyname(" + repr(machine.name) + "))")
        ).strip()
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1,
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=host_bindings[machine.name]["host"],
                addresses=[address],
                output=path,
            ),
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)
    transfer(m1, root + "/audi-root.pem", client, root + "/audi-root.pem")
    for machine in (m2, m3):
        eventually(lambda machine=machine: audi_ready(machine, "dns"), timeout=60)
    for machine in provisioners:
        eventually(lambda machine=machine: audi_ready(machine, "gateway"), timeout=60)
        assert machine.execute("test ! -e /var/lib/audi/certificates")[0] == 0
    # The real ACME state machine advances on minute scheduler ticks through
    # order, DNS proof, finalization and download after DNS enrollment completes.
    eventually(
        lambda: sql("SELECT count(*) FROM ingress_fleet_certificates WHERE status='active'") == "1",
        timeout=360,
    )
    assert (
        sql(
            "SELECT count(*) FROM ingress_fleet_certificate_accounts WHERE encrypted_private_key IS NOT NULL"
        )
        == "1"
    )
    assert (
        sql(
            "SELECT count(*) FROM ingress_fleet_certificates WHERE status='active' AND encrypted_private_key_pem IS NOT NULL AND encrypted_chain_pem IS NOT NULL"
        )
        == "1"
    )
    try:
        eventually(
            lambda: (
                sql(
                    "SELECT count(DISTINCT host_id) FROM ingress_fleet_certificate_installations WHERE generation=1"
                )
                == str(len(provisioners))
            ),
            timeout=60,
        )
    except AssertionError:
        for machine in provisioners:
            print(
                machine.name,
                machine.succeed(
                    "journalctl -u audi.service --no-pager -o cat -n 200 "
                    "| grep -E 'audi.fleet_certificate_|audi.control_exchange_failed' || true"
                ),
            )
        raise

with subtest("real guest HTTP reaches public primary ingress only after certificate readiness"):
    vm = provision_when_available(m1, "standard")
    await_running(vm["vm_id"])
    before = process_snapshot(vm)
    host_for(vm).wait_until_succeeds(
        "fleet-audi-guest " + shlex.quote(vm["placement_id"]), timeout=180
    )
    print("Audi scenario stage: guest-ready")
    policy = operator(
        m1,
        dict(
            action="audi-policy", owner_id=users["owner_id"], vm_id=vm["vm_id"], visibility="public"
        ),
    )
    print("Audi scenario stage: policy")
    hostname = str(policy["label"]) + ".apps.example.test"
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM ingress_routes WHERE vm_id='{vm['vm_id']}' AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    print("Audi scenario stage: route")
    # Live route reports expire after five seconds; Audi caps each A TTL to
    # that remaining lifetime even though its static address TTL is 20 seconds.
    for server in ("m2", "m3"):
        for transport in ("", "+tcp"):
            client.wait_until_succeeds(
                f"dig @{server} {hostname} A +noall +answer {transport} | grep -Eq '[[:space:]][0-5][[:space:]]+IN[[:space:]]+A[[:space:]]'"
            )
    # @cc [owner:ghuntley,label:verification;concurrency] audi-public-route-convergence
    # The journey MUST obtain the exact guest body over verified public TLS
    # within 60 seconds. DNS lookup success MUST NOT stand in for a current
    # independently expiring route at the subsequent HTTP request.
    client.wait_until_succeeds(
        f"curl --fail --show-error --silent --cacert {root}/audi-root.pem https://{hostname}/ > /run/audi-public-response"
        " && grep -qx audi-guest /run/audi-public-response",
        timeout=60,
    )
    status = client.succeed(
        f"curl --silent --output /dev/null --write-out '%{{http_code}}' --cacert {root}/audi-root.pem https://p3000-{policy['label']}.apps.example.test/"
    ).strip()
    assert status == "303", "Alternate app unexpectedly allowed anonymous traffic"
    assert process_snapshot(vm) == before

# @cc [owner:ghuntley,label:verification] audi-slo-policy-fixture-isolation
# The SLO variant MUST put the guest into the same private policy state needed
# for SSH without depending on the separate live HTTP revocation assertion.
if not otel_audi_ssh_enabled:
    with subtest("changing public access to private closes a live guest response"):
        stream = (
            "import subprocess,pathlib; p=subprocess.Popen("
            + repr(
                [
                    "/run/current-system/sw/bin/curl",
                    "--no-buffer",
                    "--silent",
                    "--show-error",
                    "--max-time",
                    "30",
                    "--cacert",
                    root + "/audi-root.pem",
                    "https://" + hostname + "/stream",
                ]
            )
            + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); assert p.stdout.readline() == b'audi-guest\\n'; "
            "pathlib.Path('/run/audi-stream-ready').touch(); p.communicate(timeout=30); assert p.returncode != 0"
        )
        client.succeed(
            "systemd-run --quiet --no-block --unit=audi-stream --property=Type=oneshot --property=RemainAfterExit=yes "
            "--property=StandardOutput=null --property=StandardError=null python3 -c "
            + shlex.quote(stream)
        )
        wait_audi_stream("audi-stream.service", "/run/audi-stream-ready")
        operator(
            m1,
            dict(
                action="audi-policy",
                owner_id=users["owner_id"],
                vm_id=vm["vm_id"],
                visibility="private",
            ),
        )
        client.wait_for_unit("audi-stream.service", timeout=8)
        assert (
            client.succeed(
                "systemctl show audi-stream.service --property=ExecMainStatus --value"
            ).strip()
            == "0"
        )
        assert process_snapshot(vm) == before
else:
    operator(
        m1,
        dict(
            action="audi-policy",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            visibility="private",
        ),
    )

with subtest("real browser identity grants private HTTP and WebSockets on exact app hosts"):
    client.succeed(
        "install -d -m 700 -o tester -g users /var/lib/fleet-audi /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    for name in ("ca.crt", "audi-root.pem"):
        client.succeed(f"install -m 644 {root}/{name} /var/lib/fleet-audi/{name}")
        client.succeed(
            f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n {name} -t 'C,,' -i /var/lib/fleet-audi/{name}"
        )
    operator(
        m1,
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/audi-users.json",
        ),
    )
    transfer(m1, root + "/audi-users.json", client, "/var/lib/fleet-audi/users.json")
    target = request_file(client, dict(hostname=hostname))
    client.succeed(f"install -m 600 -o tester -g users {target} /var/lib/fleet-audi/target.json")
    client.succeed(
        "chown tester:users /var/lib/fleet-audi/users.json && chmod 600 /var/lib/fleet-audi/users.json"
    )
    client.succeed("sudo -u tester env HOME=/home/tester fleet-audi-browser", timeout=120)
    assert process_snapshot(vm) == before

with subtest("native OpenSSH reaches the per-user guest account with the registered key"):
    if otel_audi_ssh_enabled:
        for source in provisioners:
            source.wait_for_unit("opentelemetry-collector.service")
            source.wait_for_unit("overalls-request-audi-ssh.service")
            source.wait_for_unit("overalls-request-audi-ssh-exporter.service")
            source.wait_until_succeeds("test -s /run/overalls-request-audi-ssh-source/slo.json")
    ssh_root = "/var/lib/fleet-audi"
    # @cc [owner:ghuntley,label:verification;security] fleet-ssh-independent-trust-setup
    # The SSH journey MUST install its verified control-plane trust independently
    # of the browser journey, which focused native scenarios may omit.
    client.succeed(f"install -d -m 700 -o tester -g users {ssh_root}")
    client.succeed(f"install -m 644 {root}/ca.crt {ssh_root}/ca.crt")
    client.succeed("install -d -m 700 -o tester -g users /home/tester/.ssh")
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/id_ed25519")
    platform_public = client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
    owner_id = users["owner_id"]
    assert isinstance(owner_id, str)
    remote_username = canonical_guest_name(owner_id)
    platform_key = operator(
        m1, dict(action="audi-ssh-key", owner_id=users["owner_id"], public_key=platform_public)
    )
    host = host_for(vm)
    host.succeed(
        "fleet-audi-guest ssh " + shlex.quote(vm["placement_id"]) + f" {root}/audi-guest-host.pub",
        timeout=180,
    )
    ssh_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    # This route-focused fixture preinstalls the same public HTTPS policy.
    # The installer journey separately exercises client setup and key selection.
    # ~/.config itself must belong to tester (Chromium's crash reporter).
    client.succeed(
        "install -d -m 700 -o tester -g users /home/tester/.config /home/tester/.config/overalls"
    )
    client.succeed(
        "printf %s "
        + shlex.quote(
            json.dumps({"origin": "https://control.example.test", "zone": "apps.example.test"})
        )
        + " >/home/tester/.config/overalls/config.json"
    )
    client.succeed(
        f"curl -fsS --cacert {ssh_root}/ca.crt https://control.example.test/bin/ssh-trust.json "
        ">/home/tester/.ssh/overalls-trust.json"
    )
    client.succeed(
        "chown tester:users /home/tester/.config/overalls/config.json /home/tester/.ssh/overalls-trust.json"
    )
    operator(
        m1,
        dict(
            action="audi-ssh-profile",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            output=root + "/audi-ssh.conf",
        ),
    )
    transfer(m1, root + "/audi-ssh.conf", client, ssh_root + "/ssh.conf")
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority *.apps.example.test " + ssh_ca)
        + f" >{ssh_root}/guest-known-hosts"
    )
    client.succeed(f"chown tester:users {ssh_root}/ssh.conf {ssh_root}/guest-known-hosts")
    ssh_arguments = [
        "/run/current-system/sw/bin/ssh",
        "-F",
        ssh_root + "/ssh.conf",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + ssh_root + "/guest-known-hosts",
        "-i",
        "/home/tester/.ssh/id_ed25519",
        remote_username + "@" + hostname,
    ]
    ssh_environment = (
        f"sudo -u tester env HOME=/home/tester CURL_CA_BUNDLE={ssh_root}/ca.crt "
        f"SSL_CERT_FILE={ssh_root}/ca.crt "
    )
    ssh_status, ssh_hostname = client.execute(
        ssh_environment + shlex.join([*ssh_arguments, "cat /proc/sys/kernel/hostname"]),
        timeout=30,
    )
    if ssh_status != 0:
        host.succeed(
            "fleet-audi-guest ssh-diagnostics " + shlex.quote(vm["placement_id"]),
            timeout=30,
        )
    assert ssh_status == 0 and ssh_hostname.strip() == "lilly-guest"
    if otel_audi_ssh_enabled:
        # @cc [owner:ghuntley,label:verification;security] audi-ssh-native-collector-outcome
        # The source MUST be the authorized Firecracker guest session above.
        # The Rust exporter and restricted host collector MUST expose its
        # successful count with collector-assigned application provenance.
        collector_address = "10.90.0.1" if host.name == "l1" else "10.90.0.2"
        metric_url = f"http://{collector_address}:9464/metrics"
        for metric in ("requests", "successes"):
            host.wait_until_succeeds(
                f"curl -fsS {shlex.quote(metric_url)} | "
                + "awk '/^overalls_outer_audi_ssh_"
                + metric
                + '_total\\{/ && /service_name="audi_ssh"/ && /overalls_telemetry_origin="application"/ '
                + "{if ($NF + 0 >= 1) found=1} END {exit !found}'",
                timeout=90,
            )
    # @cc [owner:ghuntley,label:verification] audi-native-slo-journey-boundary
    # The focused variant MUST end only after both real collector counters pass.
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, "id -un"])).strip()
        == remote_username
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, "pwd"])).strip()
        == "/home/" + remote_username
    )
    # @cc [owner:ghuntley,label:verification;security] audi-interactive-guest-shell
    # A real user MUST obtain a guest PTY and execute commands in their own
    # login shell; command-only SSH success is insufficient evidence.
    interactive_arguments = [*ssh_arguments[:-1], "-tt", ssh_arguments[-1]]
    interactive_output = client.succeed(
        "printf '%s\\n' "
        + shlex.quote("test -t 0 && printf '%s%s\\n' OVERALLS_INTERACTIVE _SHELL; exit")
        + " | "
        + ssh_environment
        + shlex.join(interactive_arguments),
        timeout=30,
    )
    assert "OVERALLS_INTERACTIVE_SHELL" in interactive_output
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        ),
    )
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/member_id")
    member_public = client.succeed("cat /home/tester/.ssh/member_id.pub").strip()
    member_key = operator(
        m1, dict(action="audi-ssh-key", owner_id=users["member_id"], public_key=member_public)
    )
    client.succeed(
        "mv /home/tester/.ssh/id_ed25519 /home/tester/.ssh/owner_id && "
        "mv /home/tester/.ssh/id_ed25519.pub /home/tester/.ssh/owner_id.pub && "
        "cp /home/tester/.ssh/member_id /home/tester/.ssh/id_ed25519 && "
        "cp /home/tester/.ssh/member_id.pub /home/tester/.ssh/id_ed25519.pub && "
        "chown tester:users /home/tester/.ssh/id_ed25519* && "
        "chmod 600 /home/tester/.ssh/id_ed25519"
    )
    member_id = users["member_id"]
    assert isinstance(member_id, str)
    member_name = canonical_guest_name(member_id)
    member_arguments = [
        argument.replace(remote_username + "@" + hostname, member_name + "@" + hostname)
        for argument in ssh_arguments
    ]
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*member_arguments, "id -un"]), timeout=60
        ).strip()
        == member_name
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*member_arguments, "pwd"])).strip()
        == "/home/" + member_name
    )
    assert (
        int(
            sql(
                "SELECT count(*) FROM ssh_guest_logins WHERE "
                f"vm_id='{vm['vm_id']}' AND user_id='{users['member_id']}' "
                f"AND key_id='{member_key['id']}'"
            )
        )
        >= 2
    )
    # @cc [owner:ghuntley,label:verification;security] audi-share-revocation-closes-live-ssh
    # Removing a member's Cedar grant MUST terminate an already authenticated
    # Audi stream, while preserving the VM and its separate account home.
    live_member = (
        "import os,subprocess,pathlib; os.environ['PATH']='/run/current-system/sw/bin'; "
        "os.environ['HOME']='/home/tester'; os.environ['CURL_CA_BUNDLE']='/var/lib/fleet-audi/ca.crt'; "
        "os.environ['SSL_CERT_FILE']='/var/lib/fleet-audi/ca.crt'; "
        "p=subprocess.Popen("
        + repr([*member_arguments, "while true; do printf 'audi-share-live\\n'; sleep .1; done"])
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); "
        "assert p.stdout.readline() == b'audi-share-live\\n'; "
        "pathlib.Path('/var/lib/fleet-audi/ssh-share-live-ready').touch(); "
        "p.communicate(timeout=15); assert p.returncode != 0"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-ssh-share-live --property=User=tester "
        "--property=Type=oneshot --property=RemainAfterExit=yes --property=StandardOutput=null "
        "--property=StandardError=null /run/current-system/sw/bin/python3 -c "
        + shlex.quote(live_member)
    )
    wait_audi_stream("audi-ssh-share-live.service", "/var/lib/fleet-audi/ssh-share-live-ready")
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="revoked",
            key=str(uuid.uuid4()),
        ),
    )
    client.wait_for_unit("audi-ssh-share-live.service", timeout=8)
    assert (
        client.succeed(
            "systemctl show audi-ssh-share-live.service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    client.fail(ssh_environment + shlex.join([*member_arguments, "true"]) + " >/dev/null 2>&1")
    client.succeed(
        "mv /home/tester/.ssh/owner_id /home/tester/.ssh/id_ed25519 && "
        "mv /home/tester/.ssh/owner_id.pub /home/tester/.ssh/id_ed25519.pub"
    )
    client.wait_until_succeeds(
        ssh_environment
        + shlex.join(
            [
                *ssh_arguments,
                f"test -d /home/{member_name} && test $(stat -c %a /home/{member_name}) = 700",
            ]
        ),
        timeout=30,
    )
    assert process_snapshot(vm) == before

with subtest("guest reopens SSH after a later successful roster refresh"):
    unit = "ssh.service" if ubuntu_enabled else "sshd.service"
    host.succeed(
        "fleet-audi-guest ssh-recover " + shlex.quote(vm["placement_id"]) + " " + shlex.quote(unit),
        timeout=180,
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_arguments, "id -un"])).strip()
        == remote_username
    )
    assert process_snapshot(vm) == before

# @cc [owner:ghuntley,label:verification;recovery] audi-lilly-crash-preserves-live-ingress
# ADR-0187/ADR-0192: established real SSH and HTTP streams run in detached
# lilly-ingress-bridge scopes outside lilly.service. A killed packaged Lilly
# process MUST leave the same bridge processes, both live streams and the
# independent guest VMM running; bytes MUST keep arriving after the restarted
# Lilly re-adopts the bridges and past the 30 s adoption grace. Recovery MUST
# still admit fresh authenticated connections with the unchanged strict SSH
# profile and verified HTTPS certificate.
with subtest("Lilly process crash preserves live ingress bridges and the guest"):
    operator(
        m1,
        dict(
            action="audi-policy", owner_id=users["owner_id"], vm_id=vm["vm_id"], visibility="public"
        ),
    )
    client.wait_until_succeeds(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem "
        f"https://{hostname}/ | grep -qx audi-guest",
        timeout=60,
    )
    client.wait_until_succeeds(ssh_environment + shlex.join([*ssh_arguments, "true"]), timeout=60)
    bridge_pids = "pgrep -u lilly -f '/lilly-ingress-bridge --detached 5 3 4' || true"
    idle_bridges = set(host.succeed(bridge_pids).split())
    http_out = "/run/audi-crash-http.out"
    ssh_out = "/var/lib/fleet-audi/crash-ssh.out"
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-crash-http "
        f"--property=StandardOutput=file:{http_out} --property=StandardError=null "
        + shlex.join(
            [
                "/run/current-system/sw/bin/curl",
                "--no-buffer",
                "--silent",
                "--show-error",
                "--cacert",
                root + "/audi-root.pem",
                "https://" + hostname + "/stream",
            ]
        )
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-crash-ssh --property=User=tester "
        "--property=Environment=PATH=/run/current-system/sw/bin "
        "--property=Environment=HOME=/home/tester "
        "--property=Environment=CURL_CA_BUNDLE=/var/lib/fleet-audi/ca.crt "
        "--property=Environment=SSL_CERT_FILE=/var/lib/fleet-audi/ca.crt "
        f"--property=StandardOutput=file:{ssh_out} --property=StandardError=null "
        + shlex.join([*ssh_arguments, "while true; do printf 'audi-crash-live\\n'; sleep .1; done"])
    )
    client.wait_until_succeeds(f"grep -qx audi-guest {http_out}", timeout=60)
    client.wait_until_succeeds(f"grep -qx audi-crash-live {ssh_out}", timeout=60)

    def live_bridges() -> set[str]:
        return set(host.succeed(bridge_pids).split()) - idle_bridges

    eventually(lambda: len(live_bridges()) >= 2, timeout=30)
    stream_bridges = live_bridges()
    for pid in stream_bridges:
        cgroup = host.succeed(f"cat /proc/{pid}/cgroup").strip()
        assert re.fullmatch(
            r"0::/lilly_ingress\.slice/lilly-ingress-[0-9a-f]{32}\.scope", cgroup
        ), cgroup

    def streams_flowing() -> None:
        for unit in ("audi-crash-http.service", "audi-crash-ssh.service"):
            client.succeed("systemctl is-active --quiet " + unit)
        sizes = client.succeed(f"stat -c %s {http_out} {ssh_out}").split()
        client.wait_until_succeeds(
            f"test $(stat -c %s {http_out}) -gt {sizes[0]} "
            f"&& test $(stat -c %s {ssh_out}) -gt {sizes[1]}",
            timeout=10,
        )
        for pid in stream_bridges:
            host.succeed(f"kill -0 {pid}")

    lilly_before = host.succeed("systemctl show lilly.service --property=MainPID --value").strip()
    assert int(lilly_before) > 0
    profile_before_crash = client.succeed("sha256sum " + ssh_root + "/ssh.conf").strip()
    epoch = host.succeed("date +%s").strip()
    host.succeed("systemctl kill --signal=KILL --kill-whom=main lilly.service")
    streams_flowing()
    assert process_snapshot(vm) == before
    host.wait_until_succeeds(
        'systemctl is-active --quiet lilly.service && test "$(systemctl show lilly.service '
        f'--property=MainPID --value)" != {lilly_before}',
        timeout=120,
    )
    lilly_after = host.succeed("systemctl show lilly.service --property=MainPID --value").strip()
    assert int(lilly_after) > 0 and lilly_after != lilly_before
    host.wait_until_succeeds(
        f"journalctl -u lilly.service -o cat --since @{epoch} "
        '| grep -E \'"event":"lilly.ingress_bridges_adopted".*"adopting":[1-9]\'',
        timeout=120,
    )
    streams_flowing()
    # Past the adoption grace the keepers guard the bridges rather than end them.
    client.succeed("sleep 35")
    streams_flowing()
    assert process_snapshot(vm) == before
    client.wait_until_succeeds(ssh_environment + shlex.join([*ssh_arguments, "true"]), timeout=90)
    client.wait_until_succeeds(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem "
        f"https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )
    assert client.succeed("sha256sum " + ssh_root + "/ssh.conf").strip() == profile_before_crash
    # Closing the clients ends their bridges by themselves.
    client.succeed("systemctl stop audi-crash-http.service audi-crash-ssh.service")
    for pid in stream_bridges:
        host.wait_until_fails(f"kill -0 {pid}", timeout=60)
    assert process_snapshot(vm) == before
    operator(
        m1,
        dict(
            action="audi-policy",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            visibility="private",
        ),
    )

with subtest("revoking the platform SSH key closes the nested session and preserves the VM"):
    command = "while true; do printf 'audi-ssh-live\\n'; sleep .1; done"
    live = (
        "import os,subprocess,pathlib; os.environ['PATH']='/run/current-system/sw/bin'; "
        "os.environ['HOME']='/home/tester'; os.environ['CURL_CA_BUNDLE']='/var/lib/fleet-audi/ca.crt'; "
        "os.environ['SSL_CERT_FILE']='/var/lib/fleet-audi/ca.crt'; "
        "p=subprocess.Popen("
        + repr([*ssh_arguments, command])
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); assert p.stdout.readline() == b'audi-ssh-live\\n'; "
        "pathlib.Path('/var/lib/fleet-audi/ssh-live').touch(); p.communicate(timeout=30); assert p.returncode != 0"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-ssh-live --property=User=tester "
        "--property=Type=oneshot --property=RemainAfterExit=yes --property=StandardOutput=null "
        "--property=StandardError=null /run/current-system/sw/bin/python3 -c " + shlex.quote(live)
    )
    wait_audi_stream("audi-ssh-live.service", "/var/lib/fleet-audi/ssh-live")
    operator(
        m1, dict(action="audi-ssh-revoke", owner_id=users["owner_id"], key_id=platform_key["id"])
    )
    client.wait_for_unit("audi-ssh-live.service", timeout=8)
    assert (
        client.succeed(
            "systemctl show audi-ssh-live.service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    client.fail(
        ssh_environment + shlex.join([*ssh_arguments, "true"]) + " >/dev/null 2>&1", timeout=30
    )
    assert process_snapshot(vm) == before

with subtest("guest marks cannot bypass same-host, cross-host or host isolation"):
    local = host_for(vm)
    remote = next(machine for machine in provisioners if machine != local)
    operator(m1, dict(action="enable", host_id=host_bindings[remote.name]["host"], enabled=False))
    try:
        sibling = provision_when_available(m1, "customer")
        assert sibling["host_id"] == vm["host_id"]
        await_running(sibling["vm_id"])
    finally:
        operator(
            m1, dict(action="enable", host_id=host_bindings[remote.name]["host"], enabled=True)
        )
    operator(m1, dict(action="enable", host_id=vm["host_id"], enabled=False))
    try:
        distant = provision_when_available(m1, "customer")
        assert distant["host_id"] != vm["host_id"]
        await_running(distant["vm_id"])
    finally:
        operator(m1, dict(action="enable", host_id=vm["host_id"], enabled=True))
    for peer in (sibling, distant):
        host_for(peer).wait_until_succeeds(
            "fleet-audi-guest " + shlex.quote(peer["placement_id"]), timeout=180
        )
    addresses = sql_json(
        "SELECT json_object_agg(vm_id, '10.' || CASE profile WHEN 'customer' THEN '10' WHEN 'standard' THEN '20' WHEN 'oss' THEN '30' END || '.' || (slot / 256)::text || '.' || (slot % 256)::text) FROM compute_network_addresses WHERE archived_at IS NULL"
    )
    host_addresses = [
        client.succeed(
            "python3 -c "
            + shlex.quote("import socket; print(socket.gethostbyname(" + repr(machine.name) + "))")
        ).strip()
        for machine in provisioners
    ]
    for machine in provisioners:
        machine.wait_for_unit("fleet-host-listener.service")
        client.succeed(f"curl --fail --silent http://{machine.name}:8080/ >/dev/null")
    for current in (vm, sibling, distant):
        targets = [
            addresses[peer["vm_id"]] for peer in (vm, sibling, distant) if peer != current
        ] + host_addresses
        machine = host_for(current)
        target_file = request_file(machine, dict(targets=targets))
        machine.succeed(
            "fleet-audi-guest isolation "
            + shlex.quote(current["placement_id"])
            + " "
            + shlex.quote(target_file),
            timeout=90,
        )
    assert process_snapshot(vm) == before

with subtest("Customer allows native owner SSH but rejects sharing and web exposure"):
    customer = sibling
    customer_host = host_for(customer)
    customer_policy = operator(
        m1,
        dict(
            action="customer-denial",
            owner_id=users["owner_id"],
            vm_id=customer["vm_id"],
            member_email=users["member_email"],
        ),
    )
    assert customer_policy["denied"]
    customer_name = str(customer_policy["label"]) + ".apps.example.test"
    # Restore the already-revoked fixture key solely for this owner probe.
    operator(
        m1, dict(action="audi-ssh-key", owner_id=users["owner_id"], public_key=platform_public)
    )
    customer_host.succeed(
        "fleet-audi-guest ssh "
        + shlex.quote(customer["placement_id"])
        + f" {root}/customer-host.pub",
        timeout=180,
    )
    operator(
        m1,
        dict(
            action="audi-ssh-profile",
            owner_id=users["owner_id"],
            vm_id=customer["vm_id"],
            output=root + "/customer-ssh.conf",
        ),
    )
    transfer(m1, root + "/customer-ssh.conf", client, ssh_root + "/customer-ssh.conf")
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority *.apps.example.test " + ssh_ca)
        + f" >{ssh_root}/customer-known-hosts"
    )
    client.succeed(
        f"chown tester:users {ssh_root}/customer-ssh.conf {ssh_root}/customer-known-hosts"
    )
    customer_arguments = [
        argument.replace(ssh_root + "/ssh.conf", ssh_root + "/customer-ssh.conf")
        .replace(ssh_root + "/guest-known-hosts", ssh_root + "/customer-known-hosts")
        .replace(remote_username + "@" + hostname, remote_username + "@" + customer_name)
        for argument in ssh_arguments
    ]
    client.wait_until_succeeds(
        ssh_environment + shlex.join([*customer_arguments, "true"]), timeout=90
    )
    client.fail(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem https://{customer_name}/"
    )
    assert process_snapshot(vm) == before

with subtest("control-plane outage expires live authority independently of DNS answer TTL"):
    operator(
        m1,
        dict(
            action="audi-policy", owner_id=users["owner_id"], vm_id=vm["vm_id"], visibility="public"
        ),
    )
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/audi-root.pem https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )
    client.succeed("rm -f /run/audi-stream-ready")
    # curl's own limit must outlast the lease so only lease expiry can end it.
    outage_stream = stream.replace("'--max-time', '30'", "'--max-time', '90'").replace(
        "communicate(timeout=30)", "communicate(timeout=90)"
    )
    assert "'--max-time', '90'" in outage_stream and "communicate(timeout=90)" in outage_stream
    client.succeed(
        "systemd-run --quiet --no-block --unit=audi-outage-stream --property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null python3 -c "
        + shlex.quote(outage_stream)
    )
    wait_audi_stream("audi-outage-stream.service", "/run/audi-stream-ready")
    try:
        for machine in marshalls:
            machine.succeed(
                f"systemctl kill --signal=STOP --kill-whom=main marshall-{machine.name}.service"
            )
        # With Marshall stopped no hint can arrive, so the stream ends when its
        # 30-second web lease (ADR-0142 push B) runs out unrenewed.
        client.wait_for_unit("audi-outage-stream.service", timeout=40)
        assert (
            client.succeed(
                "systemctl show audi-outage-stream.service --property=ExecMainStatus --value"
            ).strip()
            == "0"
        )
        for server in ("m2", "m3"):
            client.wait_until_succeeds(
                f"dig @{server} {hostname} A +time=1 +tries=1 | grep -q 'status: SERVFAIL'",
                timeout=10,
            )
        for machine in (m2, m3):
            assert audi_ready(machine, "dns") is False
        for machine in provisioners:
            assert audi_ready(machine, "gateway") is False
    finally:
        for machine in marshalls:
            machine.succeed(
                f"systemctl kill --signal=CONT --kill-whom=main marshall-{machine.name}.service"
            )
    eventually(fresh_hosts, timeout=120)
    for machine, role in [(m2, "dns"), (m3, "dns")] + [(host, "gateway") for host in provisioners]:
        eventually(lambda machine=machine, role=role: audi_ready(machine, role), timeout=60)
    assert process_snapshot(vm) == before
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/audi-root.pem https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )

with subtest(
    "the second independent Audi DNS node remains authoritative during first-node restart"
):
    # Recover both replicas from the preceding global outage before injecting
    # the independent single-node failure; browser DNS may still be cached.
    for server in ("m2", "m3"):
        client.wait_until_succeeds(
            f"dig @{server} {hostname} A +time=1 +tries=1 +noall +answer | grep -Eq '[[:space:]][0-5][[:space:]]+IN[[:space:]]+A[[:space:]]'",
            timeout=10,
        )
    m2.succeed("systemctl stop audi-dns.service")
    try:
        for attempt in range(3):
            answer = client.succeed(
                f"dig @m3 {hostname} A +time=1 +tries=1 +noall +comments +answer"
            )
            assert any(
                len(parts := line.split()) >= 4
                and parts[1].isdigit()
                and 0 <= int(parts[1]) <= 5
                and parts[2:4] == ["IN", "A"]
                for line in answer.splitlines()
            ), answer
            if attempt < 2:
                time.sleep(1)
    finally:
        m2.succeed("systemctl start audi-dns.service")
    m2.wait_for_unit("audi-dns.service")
    client.wait_until_succeeds(
        f"dig @m2 {hostname} A +noall +answer | grep -Eq '[[:space:]][0-5][[:space:]]+IN[[:space:]]+A[[:space:]]'"
    )

with subtest("gateway restart restores readiness without the CA and preserves the VMM"):
    # Relocation later needs the same in-memory Pebble issuer identity. Suspend
    # that variant's CA so issuance is unavailable without regenerating roots.
    if relocation_enabled:
        m1.succeed("systemctl kill --signal=STOP --kill-whom=main fleet-audi-ca.service")
    else:
        m1.succeed("systemctl stop fleet-audi-ca.service")
    host = host_for(vm)
    host.succeed("systemctl restart audi.service")
    host.wait_for_unit("audi.service")
    eventually(lambda: audi_ready(host, "gateway"), timeout=60)
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM ingress_routes WHERE vm_id='{vm['vm_id']}' AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=60,
    )
    assert process_snapshot(vm) == before
    operator(
        m1,
        dict(
            action="audi-policy", owner_id=users["owner_id"], vm_id=vm["vm_id"], visibility="public"
        ),
    )
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/audi-root.pem https://{hostname}/ | grep -qx audi-guest",
        timeout=60,
    )

# @cc [owner:ghuntley,label:verification;recovery;security] audi-cloak-restart-without-ca
# A packaged gateway restart MUST reacquire the same wildcard generation from
# Marshall ciphertext after the issuer is unavailable. No certificate file may
# appear on the gateway and the guest VMM MUST remain unchanged.
with subtest("gateway restart reloads Cloak-backed wildcard without local certificate files"):
    host = host_for(vm)
    guest_before = process_snapshot(vm)
    fingerprint_before = sql(
        "SELECT fingerprint FROM ingress_fleet_certificates WHERE status='active'"
    )
    assert len(fingerprint_before) == 64
    host.succeed("systemctl restart audi.service")
    host.wait_for_unit("audi.service")
    eventually(lambda: audi_ready(host, "gateway"), timeout=60)
    client.wait_until_succeeds(
        f"curl --fail --silent --max-time 10 --cacert {root}/audi-root.pem "
        f"https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )
    assert (
        sql("SELECT fingerprint FROM ingress_fleet_certificates WHERE status='active'")
        == fingerprint_before
    )
    assert host.execute("test ! -e /var/lib/audi/certificates")[0] == 0
    assert process_snapshot(vm) == guest_before

with subtest(
    "gateway package updates and corrective revisions preserve the guest and healthy history"
):
    # @cc [owner:ghuntley,label:verification;recovery] fleet-audi-update-recovery
    # Actual source-built releases MUST switch through the real updater. A
    # running but unhealthy candidate MUST preserve lastHealthy; a corrective
    # revision MUST restore private health and guest traffic without a new VMM.
    host = host_for(vm)
    guest_before = process_snapshot(vm)
    repository, candidates = update_repository(host)
    original_release = host.succeed(
        "systemctl show -p WorkingDirectory --value audi.service"
    ).strip()
    revision = update_publish(host, repository, candidates["audi-updated"], "audi-release-upgrade")
    update_success(host)
    assert update_status(host)["lastHealthy"]["revision"] == revision
    healthy_release = host.succeed(
        "systemctl show -p WorkingDirectory --value audi.service"
    ).strip()
    assert healthy_release != original_release
    assert audi_ready(host, "gateway") is True
    assert process_snapshot(vm) == guest_before
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/audi-root.pem https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )

    rejected = update_publish(
        host, repository, candidates["audi-unhealthy"], "audi-health-regression"
    )
    code, _ = host.execute("systemctl start overalls-auto-update.service", timeout=300)
    assert code != 0
    status = update_status(host)
    assert status["candidate"]["revision"] == rejected
    assert status["failure"] == "health_timeout"
    assert status["lastHealthy"]["revision"] == revision
    host.succeed("systemctl is-active --quiet audi.service")
    assert audi_ready(host, "gateway") is False
    assert process_snapshot(vm) == guest_before

    corrected = update_publish(
        host, repository, candidates["audi-recovered"], "audi-corrective-release"
    )
    update_success(host)
    assert update_status(host)["lastHealthy"]["revision"] == corrected
    assert (
        host.succeed("systemctl show -p WorkingDirectory --value audi.service").strip()
        == healthy_release
    )
    assert audi_ready(host, "gateway") is True
    assert process_snapshot(vm) == guest_before
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/audi-root.pem https://{hostname}/ | grep -qx audi-guest",
        timeout=90,
    )

with subtest(
    "DNS package health failures retain healthy history and recover through corrective updates"
):
    repository, candidates = update_repository(m2)
    original_release = m2.succeed(
        "systemctl show -p WorkingDirectory --value audi-dns.service"
    ).strip()
    revision = update_publish(m2, repository, candidates["audi-updated"], "audi-dns-upgrade")
    update_success(m2)
    assert update_status(m2)["lastHealthy"]["revision"] == revision
    healthy_release = m2.succeed(
        "systemctl show -p WorkingDirectory --value audi-dns.service"
    ).strip()
    assert healthy_release != original_release
    assert audi_ready(m2, "dns") is True

    rejected = update_publish(
        m2, repository, candidates["audi-unhealthy"], "audi-dns-health-regression"
    )
    code, _ = m2.execute("systemctl start overalls-auto-update.service", timeout=300)
    assert code != 0
    status = update_status(m2)
    assert status["candidate"]["revision"] == rejected
    assert status["failure"] == "health_timeout"
    assert status["lastHealthy"]["revision"] == revision
    m2.succeed("systemctl is-active --quiet audi-dns.service")
    assert audi_ready(m2, "dns") is False
    assert audi_ready(m3, "dns") is True
    client.wait_until_succeeds(
        f"dig @m3 {hostname} A +noall +answer | grep -Eq '[[:space:]][0-5][[:space:]]+IN[[:space:]]+A[[:space:]]'",
        timeout=30,
    )

    corrected = update_publish(
        m2, repository, candidates["audi-recovered"], "audi-dns-corrective-release"
    )
    update_success(m2)
    assert update_status(m2)["lastHealthy"]["revision"] == corrected
    assert (
        m2.succeed("systemctl show -p WorkingDirectory --value audi-dns.service").strip()
        == healthy_release
    )
    assert audi_ready(m2, "dns") is True
    client.wait_until_succeeds(
        f"dig @m2 {hostname} A +noall +answer | grep -Eq '[[:space:]][0-5][[:space:]]+IN[[:space:]]+A[[:space:]]'",
        timeout=30,
    )
    assert process_snapshot(vm) == guest_before
