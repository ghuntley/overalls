"""Typed account retirement journey on the fleet's real service and guest topology."""

import base64
import hashlib
import ipaddress
import json
import os
import shlex
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory, mkdtemp
from typing import Literal, TypedDict

from test_driver.machine import QemuMachine as LifecycleMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-account-lifecycle"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


class TransferEndpoint(TypedDict):
    address: str
    port: int
    host_key: str


def transfer_endpoint(machine: LifecycleMachine, address: str) -> TransferEndpoint:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-enrolled-transfer-identity
    Relocation setup MUST enroll the actual host's canonical IPv4 listener and
    Ed25519 public key after the native transfer service starts. Missing or
    malformed identity MUST fail setup without fabricating transfer authority.
    """
    assert str(ipaddress.IPv4Address(address)) == address
    assert "inet " + address + "/24" in machine.succeed("ip -4 -o address show dev eth2")
    machine.wait_for_unit("lilly-transfer-sshd.service")
    machine.wait_for_open_port(2223)
    public = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").split()
    assert len(public) >= 2 and public[0] == "ssh-ed25519"
    blob = base64.b64decode(public[1], validate=True)
    assert len(blob) == 51 and blob[:19] == b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    assert base64.b64encode(blob).decode("ascii") == public[1]
    return {"address": address, "port": 2223, "host_key": " ".join(public[:2])}


def object_fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        result[key] = field
    return result


def string_fields(value: object) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, field in object_fields(value).items():
        assert isinstance(field, str)
        result[key] = field
    return result


def sql(statement: str) -> str:
    return db.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc " + shlex.quote(statement)
    ).strip()


def eventually(probe: Callable[[], bool], timeout: int = 180) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(1)
    raise AssertionError("Account lifecycle fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="account-lifecycle-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/account-lifecycle-request.json"
        m1.copy_from_host(str(path), target)
        output = m1.succeed("fleet-op " + target, timeout=180)
        m1.succeed("rm " + target)
    rows = [
        line.removeprefix("FLEET_OK ")
        for line in output.splitlines()
        if line.startswith("FLEET_OK ")
    ]
    assert len(rows) == 1
    parsed: object = json.loads(rows[0])
    return object_fields(parsed)


def current_placement(vm_id: str) -> tuple[LifecycleMachine, str]:
    assert str(uuid.UUID(vm_id)) == vm_id
    parsed: object = json.loads(
        sql(
            "SELECT json_build_object('host_id',p.host_id,'placement_id',p.id) FROM compute_virtual_machines v JOIN compute_workload_placements p ON p.id=v.current_placement_id WHERE v.id='"
            + vm_id
            + "'"
        )
    )
    placement = string_fields(parsed)
    placement_id = placement["placement_id"]
    assert str(uuid.UUID(placement_id)) == placement_id
    machine = next(
        host for host in provisioners if host_bindings[host.name]["host"] == placement["host_id"]
    )
    return machine, placement_id


def running(vm_id: str) -> None:
    assert str(uuid.UUID(vm_id)) == vm_id

    def observed() -> bool:
        state = sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
        assert state != "failed", "Real profile guest failed to start"
        return state == "running"

    eventually(observed, timeout=600)


def fresh_admission_reports(required_hosts: int = 2) -> None:
    """@cc [owner:ghuntley,label:verification;capacity] lifecycle-live-admission-reports
    Creation readiness MUST observe fresh, enabled native host and pool reports.
    Waiting MUST NOT fabricate capacity, physical readiness or reservations.
    """
    assert required_hosts in (1, 2)
    eventually(
        lambda: (
            int(
                sql(
                    "SELECT count(DISTINCT h.id) FROM compute_hosts h JOIN compute_storage_pools p ON p.host_id=h.id "
                    "WHERE h.enabled AND h.inventory->>'execution_ready'='true' "
                    "AND h.reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds' "
                    "AND p.reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
                )
            )
            >= required_hosts
        ),
        timeout=180,
    )


def provision_after_capacity(
    request: dict[str, object], required_hosts: int = 2
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;capacity] lifecycle-refused-admission-retry
    Only a closed insufficient_capacity refusal may be retried, using the same
    request key and bounded fixture calls. Accepted or unknown outcomes MUST NOT
    be retried; real telemetry and startup reservations MUST remain unchanged.
    """
    result: dict[str, object] = {}

    def attempt() -> bool:
        nonlocal result
        result = operator(request)
        if result.get("accepted") is True:
            return True
        assert result == {"accepted": False, "reason": "insufficient_capacity"}, (
            "Admission failed without a closed capacity refusal"
        )
        return False

    fresh_admission_reports(required_hosts)
    eventually(attempt, timeout=180)
    return result


def separate_shared_guest(
    vm_id: str, owner_id: str, faulted_host: LifecycleMachine
) -> tuple[LifecycleMachine, str]:
    """@cc [owner:ghuntley,label:verification] lifecycle-independent-shared-transport
    Before stopping the owned guest's provisioner, the shared guest MUST run on
    a different host. Co-location MUST be resolved through public relocation;
    terminal success and the actual destination placement MUST be observed before
    recording native storage/process identity or injecting the fault.
    """
    host, placement = current_placement(vm_id)
    if host.name == faulted_host.name:
        request: dict[str, object] = {
            "action": "relocate",
            "owner_id": owner_id,
            "vm_id": vm_id,
            "key": str(uuid.uuid4()),
        }
        move: dict[str, object] = {}

        def admit() -> bool:
            nonlocal move
            move = operator(request)
            if move.get("accepted") is True:
                return True
            assert move in (
                {"accepted": False, "reason": "insufficient_capacity"},
                {"accepted": False, "reason": "source_unavailable"},
            ), "Shared guest relocation failed without a closed readiness refusal"
            return False

        fresh_admission_reports()
        eventually(admit, timeout=180)
        relocation_id = identifier(move["id"])
        destination = identifier(move["destination_placement_id"])

        def complete() -> bool:
            phase = sql(f"SELECT phase FROM compute_relocations WHERE id='{relocation_id}'")
            assert phase not in ("failed", "cancelled"), "Shared guest relocation did not succeed"
            return (
                phase == "complete"
                and sql(
                    f"SELECT finished_at IS NOT NULL FROM compute_relocations WHERE id='{relocation_id}'"
                )
                == "t"
            )

        eventually(complete, timeout=600)
        running(vm_id)
        host, placement = current_placement(vm_id)
        assert placement == destination
    assert host.name != faulted_host.name
    return host, placement


def assert_no_shared_retirement_deletion(vm_id: str, placement_id: str, before: int) -> None:
    """@cc [owner:ghuntley,label:verification;storage] lifecycle-no-shared-retirement-deletion
    Retirement MUST add no delete operation for a shared-only VM and MUST NOT
    target its retained current placement. Completed setup relocation's source
    cleanup MUST be included in the pre-retirement baseline, never silently
    excluded from the comparison or mistaken for a retirement side effect.
    """
    identifier(vm_id)
    identifier(placement_id)
    assert before >= 0
    assert sql(
        f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}' AND kind='delete'"
    ) == str(before), "Retirement added deletion intent for the shared-only VM"
    assert (
        sql(
            f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}' "
            f"AND placement_id='{placement_id}' AND kind='delete'"
        )
        == "0"
    ), "Retirement targeted the retained shared placement for deletion"


def private_frontend_ready(host: LifecycleMachine) -> bool:
    """@cc [owner:ghuntley,label:verification] lifecycle-real-private-readiness
    Recovery readiness MUST come from the actual bounded Audi status response.
    Missing sockets or a false ready flag MUST NOT count as recovered service.
    """
    probe = (
        "import socket; peer=socket.socket(socket.AF_UNIX); peer.settimeout(3); "
        "peer.connect('/run/audi-private/status.sock'); "
        "stream=peer.makefile('rb'); data=stream.readline(4097); "
        "assert len(data)<=4096 and data.endswith(b'\\n'); "
        "print(data.decode()); peer.close()"
    )
    status, output = host.execute("python3 -c " + shlex.quote(probe), timeout=5)
    if status:
        return False
    parsed: object = json.loads(output)
    fields = object_fields(parsed)
    assert set(fields) == {"version", "role", "ready"}
    assert type(fields["version"]) is int and fields["version"] == 1
    assert fields["role"] == "private" and type(fields["ready"]) is bool
    return fields["ready"] is True


with subtest("boot real fleet with persistent ZFS and nested KVM"):
    for machine in provisioners:
        for member, source in (("primary", "system0"), ("secondary", "system1")):
            subprocess.run(
                [
                    qemu_img,
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    str(Path(storage_images) / (source + ".qcow2")),
                    str(machine.state_dir / ("fleet-" + member + ".qcow2")),
                ],
                check=True,
            )
    start_all()
    db.wait_for_unit("postgresql-setup.service")
    for machine in marshalls + provisioners + [proxy, client]:
        machine.wait_for_unit("network.target")
        machine.succeed("install -d -m 700 " + root)
    for machine in [db, *marshalls, *provisioners, proxy, client, egress]:
        machine.wait_for_unit("chronyd.service")
        if machine != db:
            machine.wait_until_succeeds("chronyc waitsync 1 0.01 0 1", timeout=90)
    for machine in marshalls:
        for filename in ("marshall.env", "ca.crt"):
            transfer(db, root + "/" + filename, machine, root + "/" + filename)
        for filename in ("tls.crt", "tls.key"):
            transfer(db, f"{root}/{machine.name}/{filename}", machine, root + "/" + filename)
    m1.succeed("fleet-op migrate", timeout=180)
    for machine in marshalls:
        machine.succeed("touch " + root + "/ready")
        machine.wait_for_unit("marshall-" + machine.name + ".service")
        machine.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://{machine.name}:4443/health/ready",
            timeout=120,
        )
    proxy.succeed("install -d -m 750 -o root -g haproxy /var/lib/overalls-fleet-proxy")
    transfer(db, root + "/proxy/full.pem", proxy, "/var/lib/overalls-fleet-proxy/full.pem")
    transfer(db, root + "/ca.crt", proxy, "/var/lib/overalls-fleet-proxy/ca.crt")
    proxy.succeed(
        "chgrp haproxy /var/lib/overalls-fleet-proxy/* && chmod 640 /var/lib/overalls-fleet-proxy/*"
    )
    proxy.succeed("touch " + root + "/ready")
    proxy.wait_for_unit("haproxy.service")
    transfer(db, root + "/ca.crt", client, root + "/ca.crt")
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
        timeout=60,
    )

with subtest("authenticated native observations supply admission capacity"):
    for machine in provisioners:
        machine.wait_for_unit("fleet-storage.service")
        machine.succeed("test -c /dev/kvm")
        observed_value: object = json.loads(machine.succeed("fleet-host-identity"))
        observed = object_fields(observed_value)
        binding = host_bindings[machine.name]
        endpoint = transfer_endpoint(machine, binding["ip"])
        request: dict[str, object] = dict(
            version=3,
            name=machine.name,
            architecture="x86_64",
            machine_id=observed["machine_id"],
            transfer_endpoint=endpoint,
            overhead_cores=1,
            overhead_memory_bytes=1073741824,
            credential_ttl_seconds=7200,
            pools=[
                dict(
                    name="guests",
                    storage=observed["storage"],
                    overhead_bytes=536870912,
                )
            ],
        )
        envelope = root + "/" + machine.name + "-credential.json"
        operator(
            dict(
                action="enroll",
                host_id=binding["host"],
                pool_id=binding["pool"],
                request=request,
                output=envelope,
            )
        )
        persisted_endpoint: object = json.loads(
            sql(
                "SELECT transfer_endpoint::text FROM compute_hosts WHERE id='"
                + binding["host"]
                + "'"
            )
        )
        assert object_fields(persisted_endpoint) == endpoint
        transfer(m1, envelope, machine, root + "/credential.json")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
        machine.succeed("fleet-seal-lilly")
        machine.succeed("touch " + root + "/ready")
        machine.wait_for_unit("lilly.service")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
            )
            == "2"
        ),
        timeout=300,
    )
    for binding in host_bindings.values():
        operator(dict(action="enable", host_id=binding["host"], enabled=True))
    # The installed guest has the real boot trust receiver and guest-account
    # bootstrap. Bring up their existing private-service prerequisites before
    # creating any VM; a base image without that receiver cannot satisfy Lilly.
    for machine in (m2, m3):
        path = root + "/audi-" + machine.name + ".token"
        operator(dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path))
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 "
        f"https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        binding = host_bindings[machine.name]
        for role in ("ziggy", "galileo"):
            token_path = root + "/" + machine.name + "-" + role + ".token"
            m1.succeed(f"fleet-op {role}-rotate {binding['host']} 7200 {token_path}", timeout=180)
            transfer(m1, token_path, machine, root + "/" + role + ".token")
            machine.succeed("fleet-seal-" + role)
        transfer(m1, root + "/audi-root.pem", machine, "/run/galileo-audi-root.pem")
        machine.succeed("chmod 0444 /run/galileo-audi-root.pem")
        machine.succeed("fleet-seal-audi-private")
        machine.wait_for_unit("ziggy.service")
        machine.wait_for_unit("galileo.service")
        machine.wait_for_unit("audi-private.service")
        address = str(
            ipaddress.IPv4Address(
                client.succeed(
                    "python3 -c "
                    + shlex.quote(
                        "import socket; print(socket.gethostbyname(" + repr(machine.name) + "))"
                    )
                ).strip()
            )
        )
        path = root + "/audi-" + machine.name + ".token"
        operator(
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=binding["host"],
                addresses=[address],
                output=path,
            )
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)


def lifecycle(request: dict[str, object]) -> dict[str, object]:
    return operator({"action": "account-lifecycle", "request": request})


def identifier(value: object) -> str:
    assert isinstance(value, str) and str(uuid.UUID(value)) == value
    return value


def browser_signal(name: str) -> None:
    client.succeed("sudo -u tester touch " + browser_root + "/" + name)


def browser_wait(name: str, timeout: int = 120) -> None:
    def reached() -> bool:
        if client.execute("systemctl is-failed --quiet lifecycle-browser.service")[0] == 0:
            status, stage = client.execute("cat " + browser_root + "/failure-stage")
            if (
                status == 0
                and len(stage) < 120
                and all(character.isalpha() or character in " -()\n" for character in stage)
            ):
                raise AssertionError("Account lifecycle browser failed at " + stage.strip())
            raise AssertionError("Account lifecycle browser failed before stage reporting")
        return client.execute("test -f " + browser_root + "/" + name)[0] == 0

    eventually(reached, timeout)


def private_transfer(source_name: str, destination_name: str) -> None:
    transfer(m1, root + "/lifecycle-" + source_name, client, browser_root + "/" + destination_name)
    client.succeed(
        f"chown tester:users {browser_root}/{destination_name} && chmod 600 {browser_root}/{destination_name}"
    )


def ssh_arguments(role: str) -> list[str]:
    return [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + browser_root + "/known_hosts",
        "-i",
        browser_root + "/" + role,
    ]


def discover(role: str, user_id: str) -> tuple[str, int]:
    """@cc [owner:ghuntley,label:verification] lifecycle-persisted-ssh-discovery
    Guest names MUST come from real authenticated Porsche whoami, then match the
    durable allocation. Discovery MUST NOT derive the name from a reused email.
    """
    arguments = [
        *ssh_arguments(role),
        "-o",
        "HostKeyAlias=control.example.test",
        "fixture@m1",
        "whoami --json",
    ]
    client.succeed(
        "sudo -u tester "
        + shlex.join(arguments)
        + " >"
        + browser_root
        + "/whoami.json 2>"
        + browser_root
        + "/whoami.err"
    )
    parsed: object = json.loads(client.succeed("cat " + browser_root + "/whoami.json"))
    receipt = object_fields(parsed)
    assert receipt["version"] == 1 and receipt["status"] == "succeeded"
    identity = object_fields(receipt["result"])
    assert identity["id"] == user_id
    name = identity["guest_username"]
    assert isinstance(name, str) and 1 <= len(name) <= 32
    assert all(character in "abcdefghijklmnopqrstuvwxyz0123456789_.-" for character in name)
    value = sql(
        f"SELECT username,uid FROM account_guest_accounts WHERE user_id='{user_id}' AND retired_at IS NULL"
    )
    stored, raw_uid = value.split("|")
    assert name == stored
    uid = int(raw_uid)
    assert 200000 <= uid <= 999999
    assert name == "u" + str(uid)
    return name, uid


def guest_host(vm_id: str) -> str:
    label = sql(f"SELECT label FROM ingress_endpoints WHERE vm_id='{vm_id}'")
    assert label.startswith("v-") and all(
        char in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in label
    )
    return label + ".apps.example.test"


def login_inventory(vm_id: str) -> tuple[int, int]:
    fields = sql(
        f"SELECT (SELECT count(*) FROM ingress_sessions WHERE vm_id='{vm_id}'),(SELECT count(*) FROM ssh_guest_logins WHERE vm_id='{vm_id}')"
    ).split("|")
    assert len(fields) == 2
    return int(fields[0]), int(fields[1])


def guest_command(
    vm_id: str,
    role: str,
    name: str,
    command: str,
    refusal: Literal["unknown", "unshared", "old-name"] | None = None,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-real-guest-authority
    Both SSH layers MUST validate native CA certificates. Commands MUST use
    persisted discovery names; stale requested names are explicit negative cases.
    Outer refusals MUST have the specific key/access guidance and unchanged
    ingress/login inventories. Inner refusal MUST reach public-key authentication
    with an accepted ingress and no guest login. Raw output stays private.
    """
    host, _ = current_placement(vm_id)
    hostname = guest_host(vm_id)
    gateway_key = host.succeed("cat /var/lib/audi/keys/ssh_host_ed25519_key.pub").split()[1]
    digest = (
        base64.b32encode(hashlib.sha256(base64.b64decode(gateway_key, validate=True)).digest())
        .decode()
        .lower()
        .rstrip("=")
    )
    alias = "audi-" + digest + ".ssh.control.example.test"
    proxy_command = shlex.join(
        [
            *ssh_arguments(role),
            "-o",
            "HostKeyAlias=" + alias,
            "audi@" + host.name,
            "connect",
            hostname.split(".")[0],
        ]
    )
    arguments = [
        *ssh_arguments(role),
        "-o",
        "ProxyCommand=" + proxy_command,
        name + "@" + hostname,
        command,
    ]
    before = login_inventory(vm_id)
    invocation = (
        "sudo -u tester timeout 45 "
        + shlex.join(arguments)
        + " >"
        + browser_root
        + "/guest.out 2>"
        + browser_root
        + "/guest.err"
    )
    if refusal is None:
        client.wait_until_succeeds(invocation, timeout=90)
        client.succeed(
            "test "
            + shlex.quote("LIFECYCLE_GUEST_OK")
            + ' = "$(cat '
            + browser_root
            + '/guest.out)"'
        )
        after = login_inventory(vm_id)
        assert after[0] > before[0] and after[1] > before[1]
    else:
        status, _ = client.execute(invocation, timeout=50)
        assert status == 255, "SSH authority refusal did not return the expected status"
        message = {
            "unknown": "We don't recognize this SSH key:",
            "unshared": "This SSH connection could not be authorized.",
            "old-name": "Permission denied (publickey)",
        }[refusal]
        client.succeed("grep -Fq " + shlex.quote(message) + " " + browser_root + "/guest.err")
        after = login_inventory(vm_id)
        assert after[1] == before[1]
        if refusal == "old-name":
            assert after[0] > before[0]
        else:
            assert after == before


def identity_command(name: str, uid: int, additional: str = "true") -> str:
    return (
        f'test "$(id -un)" = {name} && test "$(id -u)" = {uid} '
        f'&& test "$HOME" = /home/{name} && test "$PWD" = "$HOME" '
        f'&& touch "$HOME/identity-write" && ({additional}) && printf LIFECYCLE_GUEST_OK'
    )


def guest_stream_arguments(vm_id: str, role: str, name: str) -> list[str]:
    host, _ = current_placement(vm_id)
    hostname = guest_host(vm_id)
    gateway_key = host.succeed("cat /var/lib/audi/keys/ssh_host_ed25519_key.pub").split()[1]
    digest = (
        base64.b32encode(hashlib.sha256(base64.b64decode(gateway_key, validate=True)).digest())
        .decode()
        .lower()
        .rstrip("=")
    )
    alias = "audi-" + digest + ".ssh.control.example.test"
    proxy_command = shlex.join(
        [
            *ssh_arguments(role),
            "-o",
            "HostKeyAlias=" + alias,
            "audi@" + host.name,
            "connect",
            hostname.split(".")[0],
        ]
    )
    return [
        *ssh_arguments(role),
        "-o",
        "ProxyCommand=" + proxy_command,
        name + "@" + hostname,
    ]


def guest_stream_open(vm_id: str, role: str, name: str, unit: str, marker: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-real-live-guest-stream
    The fixture MUST open a real per-user Audi SSH stream with the ordinary
    brokered client path; the ready marker proves live guest output before any
    retirement signal. A stream that cannot open MUST fail the journey here.
    """
    arguments = [
        *guest_stream_arguments(vm_id, role, name),
        "while true; do printf '" + marker + "\\n'; sleep .1; done",
    ]
    program = (
        "import os,subprocess,pathlib; os.environ['PATH']='/run/current-system/sw/bin'; "
        "os.environ['HOME']='/home/tester'; "
        f"os.environ['CURL_CA_BUNDLE']='{browser_root}/ca.crt'; "
        f"os.environ['SSL_CERT_FILE']='{browser_root}/ca.crt'; "
        "p=subprocess.Popen("
        + repr(arguments)
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); "
        "assert p.stdout is not None; "
        "line=p.stdout.readline(); "
        "assert line == b'" + marker + "\\n', 'stream did not produce live guest output'; "
        f"pathlib.Path('{browser_root}/{unit}-ready').touch(); "
        "p.communicate(timeout=180); assert p.returncode != 0"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit="
        + unit
        + " --property=User=tester --property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null "
        "/run/current-system/sw/bin/python3 -c " + shlex.quote(program)
    )

    def streaming() -> bool:
        assert client.execute("systemctl is-failed --quiet " + unit + ".service")[0] != 0, (
            unit + " failed before producing live guest output"
        )
        return client.execute("test -f " + browser_root + "/" + unit + "-ready")[0] == 0

    eventually(streaming, timeout=30)


def guest_stream_closed(unit: str, bound: int) -> float:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-stream-lease-closure
    Retirement MUST terminate the already-open stream through Marshall's lease
    renewal denial, well inside this bound; timeout-driven death MUST NOT count.
    """
    started = time.monotonic()
    client.wait_for_unit(unit + ".service", timeout=bound)
    assert (
        client.succeed(
            "systemctl show " + unit + ".service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    assert (
        client.succeed("systemctl show " + unit + ".service --property=Result --value").strip()
        == "success"
    )
    return time.monotonic() - started


def managed_ssh(invocation: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-managed-ssh-diagnostics
    A failed managed SSH attempt MUST preserve bounded private output before
    teardown. Only fixed failure categories may enter the test log; copied
    stderr/stdout MUST remain outside the public test result directory.
    """
    completed = False
    try:
        status, _ = client.execute(invocation, timeout=60)
        signals: list[str] = []
        if status != 0:
            for category in (
                "CLI startup failed",
                "SSH proxy unavailable",
                "Host key verification failed",
                "Permission denied",
                "Connection refused",
                "Connection timed out",
                "Could not resolve hostname",
            ):
                if (
                    client.execute(
                        "grep -Fq " + shlex.quote(category) + " " + browser_root + "/lyra.err"
                    )[0]
                    == 0
                ):
                    signals.append(category)
        assert status == 0, {"status": status, "signals": signals}
        client.succeed('test "$(cat ' + browser_root + '/lyra.out)" = LIFECYCLE_GUEST_OK')
        completed = True
    finally:
        if not completed:
            try:
                directory = Path(mkdtemp(prefix="account-lifecycle-ssh-private-"))
                for name in ("lyra.out", "lyra.err"):
                    source = browser_root + "/" + name
                    bounded = source + ".bounded"
                    client.succeed(
                        "umask 077; head -c 65536 " + source + " >" + bounded + " && sync"
                    )
                    client.copy_from_machine(bounded, str(directory))
                    with (directory / (name + ".bounded")).open("rb") as artifact:
                        os.fsync(artifact.fileno())
                descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            except Exception:
                print("Managed SSH private diagnostic copy failed; original failure retained")


def terminal_input(role: str, vm_id: str, name: str, uid: int) -> None:
    value = json.dumps({"vm": vm_id, "name": name, "uid": uid})
    path = browser_root + "/" + role + "-terminal.json"
    client.succeed(
        "printf '%s' " + shlex.quote(value) + " >" + path + " && chown tester:users " + path
    )
    browser_signal(role + "-terminal-ready")
    browser_wait(role + "-terminal-passed", timeout=180)


def admit_resize_with_stopped_provisioner(host: LifecycleMachine, owner: str, vm: str) -> str:
    """@cc [owner:ghuntley,label:verification] retirement-real-fresh-resize
    The barrier MUST pause only fixture dispatch after release startup. Admission
    MUST use the real final host report and public resize action while the actual
    Lilly cgroup is stopped by signal. Prevent restart before fault injection,
    then kill and fully stop Lilly before retirement without resuming execution.
    Any expected signal-failure reset MUST follow proof that all captured PIDs
    are gone and the service cgroup has no remaining processes.
    The fixture MUST NOT forge freshness, workflow state or capacity.
    """
    barrier_id = str(uuid.uuid4())
    barrier = "/tmp/shared/fleet-barrier-" + barrier_id
    target = root + "/lifecycle-resize-request.json"
    request = {
        "action": "resize",
        "owner_id": owner,
        "vm_id": vm,
        "key": str(uuid.uuid4()),
        "barrier": barrier_id,
    }
    with TemporaryDirectory(prefix="account-lifecycle-resize-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        m1.copy_from_host(str(path), target)
    m1.succeed("install -d -m 700 " + barrier)
    m1.succeed(
        "systemd-run --unit=lifecycle-resize --setenv=PATH=/run/current-system/sw/bin fleet-op "
        + target
    )

    def fixture_ready() -> bool:
        assert m1.execute("systemctl is-failed --quiet lifecycle-resize.service")[0] != 0, (
            "Native resize fixture failed before dispatch"
        )
        return m1.execute("test -f " + barrier + "/m1.ready")[0] == 0

    eventually(fixture_ready, timeout=90)
    # This disposable fault override leaves the real collector running and
    # prevents restart after abrupt death. Do it before the fresh report; a
    # runtime mask could lose to NixOS's /etc unit link in unit search order.
    original_restart = host.succeed("systemctl show -p Restart --value lilly.service").strip()
    assert original_restart == "on-failure"
    fault_override = "/run/systemd/system/lilly.service.d/99-lifecycle-fault.conf"
    host.succeed("install -d /run/systemd/system/lilly.service.d")
    host.succeed("printf '[Service]\\nRestart=no\\n' >" + fault_override)
    host.succeed("systemctl daemon-reload")
    assert host.succeed("systemctl show -p Restart --value lilly.service").strip() == "no"
    host_id = host_bindings[host.name]["host"]
    previous_sequence = int(sql(f"SELECT report_sequence FROM compute_hosts WHERE id='{host_id}'"))
    assert previous_sequence > 0

    def newly_reported() -> bool:
        assert fixture_ready()
        # The real collector stamps the start of a mandatory one-second ZFS
        # interval. Await a newer report with time left in public admission's
        # unchanged five-second window; never replace the observed timestamp.
        return (
            sql(
                f"SELECT report_sequence > {previous_sequence} AND reported_at > (clock_timestamp() AT TIME ZONE 'UTC') - interval '3 seconds' FROM compute_hosts WHERE id='{host_id}'"
            )
            == "t"
        )

    eventually(newly_reported, timeout=90)
    host.succeed("systemctl kill --kill-whom=all --signal=SIGSTOP lilly.service")
    frozen_pids = {
        int(value)
        for value in host.succeed(
            "find /sys/fs/cgroup/system.slice/lilly.service -name cgroup.procs -exec cat {} +"
        ).split()
    }
    assert frozen_pids and all(pid > 0 for pid in frozen_pids)
    states = host.succeed("ps -o pid=,stat= -p " + ",".join(map(str, sorted(frozen_pids))))
    stopped_pids: set[int] = set()
    for line in states.splitlines():
        raw_pid, state = line.split()
        assert state.startswith("T"), "Every provisioner cgroup process must be stopped"
        stopped_pids.add(int(raw_pid))
    assert stopped_pids == frozen_pids
    m1.succeed("touch " + barrier + "/release")

    def resize_finished() -> bool:
        assert m1.execute("systemctl is-failed --quiet lifecycle-resize.service")[0] != 0, (
            "Native resize action failed; private output withheld"
        )
        return (
            m1.succeed("systemctl show -p SubState --value lifecycle-resize.service").strip()
            == "dead"
        )

    eventually(resize_finished, timeout=90)
    assert (
        m1.succeed("systemctl show -p ExecMainStatus --value lifecycle-resize.service").strip()
        == "0"
    )
    output = m1.succeed("journalctl -u lifecycle-resize.service --output=cat --no-pager")
    rows = [
        line.removeprefix("FLEET_OK ")
        for line in output.splitlines()
        if line.startswith("FLEET_OK ")
    ]
    assert len(rows) == 1
    parsed: object = json.loads(rows[0])
    # systemd sends SIGCONT during ordinary stop. Kill the still-stopped cgroup
    # first, with restart disabled, so accepted resize cannot start during stop.
    assert (
        host.succeed("ps -o pid=,stat= -p " + ",".join(map(str, sorted(frozen_pids)))).split()
        == states.split()
    ), "Provisioner processes must remain stopped until abrupt death"
    host.succeed("systemctl kill --kill-whom=all --signal=SIGKILL lilly.service")
    host.succeed("systemctl stop lilly.service")
    assert host.succeed("systemctl show -p MainPID --value lilly.service").strip() == "0"
    status, survivors = host.execute("ps -o pid= -p " + ",".join(map(str, sorted(frozen_pids))))
    assert status == 1 and not survivors.strip(), "Every captured provisioner process must be gone"
    group_status, group_events = host.execute(
        "cat /sys/fs/cgroup/system.slice/lilly.service/cgroup.events"
    )
    if group_status == 0:
        events: dict[str, str] = {}
        for line in group_events.splitlines():
            key, value = line.split()
            events[key] = value
        assert events["populated"] == "0", "No descendant provisioner process may survive"
    else:
        # systemd can remove an empty cgroup at any point after stop. A failed
        # read counts only when the directory is now demonstrably absent.
        host.succeed("test ! -d /sys/fs/cgroup/system.slice/lilly.service")
    state = host.succeed("systemctl show -p ActiveState --value lilly.service").strip()
    assert state in {"failed", "inactive"}
    if state == "failed":
        assert host.succeed("systemctl show -p Result --value lilly.service").strip() == "signal"
        host.succeed("systemctl reset-failed lilly.service")
    assert host.succeed("systemctl show -p ActiveState --value lilly.service").strip() == "inactive"
    host.succeed("rm " + fault_override)
    host.succeed("systemctl daemon-reload")
    assert (
        host.succeed("systemctl show -p Restart --value lilly.service").strip() == original_restart
    )
    return identifier(object_fields(parsed)["id"])


with subtest("installed bootstrap and verified browser invitation create an ordinary identity"):
    m1.succeed("fleet-op gateway-prepare " + root + "/porsche.token")
    m1.succeed("fleet-op gateway-configure fleet " + root + "/porsche.token")
    m1.succeed("systemctl start porsche.service")
    m1.wait_for_open_port(22)
    identities = lifecycle({"operation": "seed", "output": root + "/lifecycle-admin-token"})
    admin_id = identifier(identities["admin_id"])
    survivor_id = identifier(identities["survivor_id"])
    image_id = identities["image_id"]
    assert isinstance(image_id, str)
    assert sql("SELECT completed FROM account_admin_bootstrap") == "t"
    assert sql("SELECT count(*) FROM users WHERE email='retirement-invited@example.test'") == "0"
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n lifecycle-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    for role in ("invited", "survivor", "fresh"):
        client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {browser_root}/{role}")
    host_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote(
            "@cert-authority control.example.test,*.ssh.control.example.test,*.apps.example.test "
            + host_ca
        )
        + " >"
        + browser_root
        + "/known_hosts"
    )
    private_transfer("admin-token", "admin-token")
    private_transfer("admin-token-survivor", "survivor-token")
    client.succeed(
        "systemd-run --unit=lifecycle-browser --property=User=tester --setenv=HOME=/home/tester fleet-account-lifecycle-browser"
    )
    browser_wait("invitation-sent")
    assert sql("SELECT count(*) FROM users WHERE email='retirement-invited@example.test'") == "0"
    assert lifecycle({"operation": "outbox", "output": root + "/lifecycle-invitation-token"}) == {
        "written": True
    }
    private_transfer("invitation-token", "invitation-token")
    browser_signal("invitation-ready")
    browser_wait("owned-create-ready", timeout=180)
    old_id = identifier(sql("SELECT id FROM users WHERE email='retirement-invited@example.test'"))
    # The web form opens agent setup threads, and Customer VMs have no agent
    # root (ADR-0099), so the invited user's Customer machine is admitted through
    # the real authorized action as that user; the browser then proves it owns
    # and can open it.
    owned = provision_after_capacity(
        {
            "action": "provision",
            "owner_id": old_id,
            "image_id": image_id,
            "profile": "customer",
            "disk_bytes": 5_368_709_120,
            "key": str(uuid.uuid4()),
        }
    )
    assert owned["accepted"] is True
    owned_id = identifier(owned["vm_id"])
    client.succeed("printf '%s' " + shlex.quote(owned_id) + " >" + browser_root + "/owned-id")
    client.succeed("chown tester:users " + browser_root + "/owned-id")
    browser_signal("owned-create-go")
    browser_wait("owned-admitted")
    assert sql(f"SELECT administrator,mfa_enabled FROM users WHERE id='{old_id}'") == "f|t"
    assert (
        sql(f"SELECT profile,owner_id FROM compute_virtual_machines WHERE id='{owned_id}'")
        == "customer|" + old_id
    )
    assert (
        sql(f"SELECT count(*) FROM ssh_keys WHERE user_id='{old_id}' AND archived_at IS NULL")
        == "1"
    )
    assert sql(f"SELECT count(*) FROM account_passkeys WHERE user_id='{old_id}'") == "1"
    assert (
        sql(
            "SELECT count(*) FROM tokens WHERE subject=(SELECT 'user?id='||id FROM users WHERE email='retirement-bootstrap@example.test')"
        )
        == "0"
    )

with subtest("real Customer and shared-only OSS guests precede offline busy cleanup"):
    running(owned_id)
    survivor = provision_after_capacity(
        {
            "action": "provision",
            "owner_id": survivor_id,
            "image_id": image_id,
            "profile": "oss",
            "disk_bytes": 5_368_709_120,
            "key": str(uuid.uuid4()),
        }
    )
    assert survivor["accepted"] is True
    shared_id = identifier(survivor["vm_id"])
    running(shared_id)
    assert lifecycle({"operation": "share", "vm_id": shared_id, "owner_id": survivor_id}) == {
        "shared": True,
        "user_id": old_id,
    }
    lifecycle({"operation": "stale-link", "output": root + "/lifecycle-stale-token"})
    private_transfer("stale-token", "stale-token")
    client.succeed("printf '%s' " + shlex.quote(old_id) + " >" + browser_root + "/old-id")
    client.succeed("chown tester:users " + browser_root + "/old-id")
    owned_host, owned_placement = current_placement(owned_id)
    shared_host, shared_placement = separate_shared_guest(shared_id, survivor_id, owned_host)
    # Public relocation legitimately deletes its former source placement. Only
    # operations added after this completed setup can be retirement side effects.
    shared_delete_count = int(
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{shared_id}' AND kind='delete'")
    )
    shared_guid = shared_host.succeed(
        "zfs get -H -o value guid zroot/lilly/vm-" + shared_placement
    ).strip()
    shared_pid = shared_host.succeed(
        "systemctl show -p MainPID --value lilly-vm-" + shared_placement + ".service"
    ).strip()
    assert shared_guid.isdecimal() and shared_pid.isdecimal() and int(shared_pid) > 0
    for host, placement in ((owned_host, owned_placement), (shared_host, shared_placement)):
        host.succeed("zfs list zroot/lilly/vm-" + placement)
        host.succeed("systemctl is-active lilly-vm-" + placement + ".service")
    old_name, old_uid = discover("invited", old_id)
    survivor_name, survivor_uid = discover("survivor", survivor_id)
    assert old_name == "u" + str(old_uid)
    guest_command(
        shared_id,
        "invited",
        old_name,
        identity_command(old_name, old_uid, 'printf retired-home-marker > "$HOME/retired-marker"'),
    )
    guest_command(
        shared_id, "survivor", survivor_name, identity_command(survivor_name, survivor_uid)
    )
    terminal_input("invited", owned_id, old_name, old_uid)
    # A stopped provisioner is not physical guest death. Accepted resize remains
    # busy until that service returns; neither condition can authorize release.
    resize_id = admit_resize_with_stopped_provisioner(owned_host, old_id, owned_id)
    owned_host.succeed("systemctl is-active lilly-vm-" + owned_placement + ".service")
    browser_signal("retire-now")
    browser_wait("wrong-confirmation-refused")
    assert sql(f"SELECT count(*) FROM account_user_deletions WHERE user_id='{old_id}'") == "0"
    assert sql(f"SELECT deleted_at IS NULL FROM users WHERE id='{old_id}'") == "t"
    # A live guest stream opened as the invited member on the shared VM proves
    # the stream is admitted before retirement. Browser retirement alone must
    # close it through lease renewal denial, before any durable cleanup advance
    # drains the expired grant and key rows.
    guest_stream_open(
        shared_id, "invited", old_name, "lifecycle-invited-live", "lifecycle-invite-live"
    )
    browser_signal("confirm-retire")
    browser_wait("retired")
    invitation_closure = guest_stream_closed("lifecycle-invited-live", 45)
    print("retirement closed the invited live guest stream in seconds", invitation_closure)
    # The still-running shared guest reconciles the expiry on its roster timer:
    # the retired account's shadow expiry and sudo policy are gone while its
    # home stays owned by the historical UID, with no VM restart involved.
    guest_command(
        shared_id,
        "survivor",
        survivor_name,
        identity_command(
            survivor_name,
            survivor_uid,
            f'test "$(sudo -n getent shadow {old_name} | cut -d: -f8)" = 1'
            f" && sudo -n test ! -e /etc/sudoers.d/overalls_uid_{old_uid}"
            f' && test "$(sudo -n stat -c %u /home/{old_name})" = {old_uid}',
        ),
    )
    deletion_id = identifier(sql(f"SELECT id FROM account_user_deletions WHERE user_id='{old_id}'"))
    assert (
        sql(f"SELECT deleted_at IS NOT NULL,administrator FROM users WHERE id='{old_id}'") == "t|f"
    )
    assert (
        sql(
            f"SELECT count(*) FROM tokens WHERE subject='user?id={old_id}' AND purpose<>'revocation'"
        )
        == "0"
    )
    assert (
        sql(
            f"SELECT count(*) FROM account_admin_events WHERE kind='user_delete' AND actor_id='{admin_id}' AND target_id='{old_id}'"
        )
        == "1"
    )
    for _ in range(3):
        outcome = lifecycle({"operation": "advance", "deletion_id": deletion_id})
        assert outcome == {"complete": False, "remaining": 1}
        assert (
            sql(
                f"SELECT completed_at IS NULL,blocked FROM account_user_deletions WHERE id='{deletion_id}'"
            )
            == "t|t"
        )
        assert sql(f"SELECT disk_held FROM compute_reservations WHERE vm_id='{owned_id}'") == "t"
        owned_host.succeed("zfs list zroot/lilly/vm-" + owned_placement)
        owned_host.succeed("systemctl is-active lilly-vm-" + owned_placement + ".service")
    assert (
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{owned_id}' AND kind='delete'")
        == "0"
    )

with subtest("fresh same-email registration inherits nothing while old cleanup remains pinned"):
    # Respect the real shared recipient cooldown instead of mutating its clock.
    eventually(
        lambda: (
            sql(
                "SELECT clock_timestamp() > max(inserted_at) + interval '60 seconds' FROM account_auth_emails"
            )
            == "t"
        ),
        timeout=65,
    )
    browser_signal("request-replacement")
    browser_wait("replacement-invited")
    lifecycle({"operation": "outbox", "output": root + "/lifecycle-replacement-token"})
    private_transfer("replacement-token", "replacement-token")
    browser_signal("replacement-ready")
    browser_wait("replacement-registered")
    replacement_id = identifier(
        sql(
            "SELECT id FROM users WHERE email='retirement-invited@example.test' AND deleted_at IS NULL"
        )
    )
    assert replacement_id != old_id
    assert (
        sql(
            f"SELECT administrator,mfa_enabled,mfa_generation FROM users WHERE id='{replacement_id}'"
        )
        == "f|f|0"
    )
    for table, column in (
        ("ssh_keys", "user_id"),
        ("account_passkeys", "user_id"),
        ("access_grants", "user_id"),
        ("team_members", "user_id"),
        ("compute_virtual_machines", "owner_id"),
    ):
        assert sql(f"SELECT count(*) FROM {table} WHERE {column}='{replacement_id}'") == "0"
    assert (
        sql(
            f"SELECT user_id,completed_at IS NULL FROM account_user_deletions WHERE id='{deletion_id}'"
        )
        == old_id + "|t"
    )
    assert (
        sql(f"SELECT count(*) FROM ssh_keys WHERE user_id='{old_id}' AND archived_at IS NULL")
        == "0"
    )
    assert (
        sql(f"SELECT count(*) FROM access_grants WHERE user_id='{old_id}' AND archived_at IS NULL")
        == "0"
    )
    browser_signal("fresh-key-now")
    browser_wait("fresh-key-registered")
    fresh_name, fresh_uid = discover("fresh", replacement_id)
    assert fresh_name == "u" + str(fresh_uid)
    assert fresh_name != old_name
    assert fresh_uid != old_uid
    assert (
        sql(f"SELECT username,uid FROM account_guest_accounts WHERE user_id='{old_id}'")
        == f"{old_name}|{old_uid}"
    )
    assert discover("fresh", replacement_id) == (fresh_name, fresh_uid)
    # Give the new UUID its own real work before old cleanup completes. This
    # detects a cleanup implementation that follows the reused email identity.
    fresh_vm = provision_after_capacity(
        {
            "action": "provision",
            "owner_id": replacement_id,
            "image_id": image_id,
            "profile": "oss",
            "disk_bytes": 5_368_709_120,
            "key": str(uuid.uuid4()),
        },
        required_hosts=1,
    )
    assert fresh_vm["accepted"] is True
    fresh_vm_id = identifier(fresh_vm["vm_id"])
    running(fresh_vm_id)
    fresh_host, fresh_placement = current_placement(fresh_vm_id)
    guest_command(
        fresh_vm_id,
        "fresh",
        fresh_name,
        identity_command(fresh_name, fresh_uid, 'test ! -e "$HOME/retired-marker"'),
    )
    terminal_input("fresh", fresh_vm_id, fresh_name, fresh_uid)

with subtest(
    "real resize recovery and reclamation release old holds without deleting shared-only guest"
):
    # Requires=lilly.service stops the private frontend with the provisioner.
    # Recovery MUST restore its real dependent service and live readiness before
    # waiting for guest execution; readiness or capacity MUST NOT be fabricated.
    owned_host.succeed("systemctl start lilly.service audi-private.service")
    owned_host.wait_for_unit("lilly.service")
    owned_host.wait_for_unit("audi-private.service")
    owned_host.wait_until_succeeds(
        "curl --fail --silent --unix-socket /run/ziggy/proxy.sock "
        "http://ziggy/health/ready | jq -e --arg host "
        + shlex.quote(host_bindings[owned_host.name]["host"])
        + " '(.version == 1) and (.role == \"ziggy\") and (.host_id == $host) and (.ready == true)'",
        timeout=90,
    )
    eventually(lambda: private_frontend_ready(owned_host), timeout=90)
    eventually(
        lambda: (
            sql(f"SELECT phase FROM compute_resize_requests WHERE id='{resize_id}'") == "complete"
        ),
        timeout=600,
    )

    def reclaimed() -> bool:
        outcome = lifecycle({"operation": "advance", "deletion_id": deletion_id})
        return outcome.get("complete") is True

    eventually(reclaimed, timeout=600)
    assert (
        sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{owned_id}'")
        == "t"
    )
    assert (
        sql(f"SELECT disk_held,compute_held FROM compute_reservations WHERE vm_id='{owned_id}'")
        == "f|f"
    )
    assert (
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{owned_id}' AND kind='delete'")
        == "1"
    )
    owned_host.fail("zfs list zroot/lilly/vm-" + owned_placement)
    owned_host.fail("systemctl is-active lilly-vm-" + owned_placement + ".service")
    assert (
        sql(
            f"SELECT owner_id,desired_state,observed_state,archived_at IS NULL FROM compute_virtual_machines WHERE id='{shared_id}'"
        )
        == survivor_id + "|running|running|t"
    )
    assert_no_shared_retirement_deletion(shared_id, shared_placement, shared_delete_count)
    shared_host.succeed("zfs list zroot/lilly/vm-" + shared_placement)
    assert (
        shared_host.succeed("zfs get -H -o value guid zroot/lilly/vm-" + shared_placement).strip()
        == shared_guid
    )
    assert (
        shared_host.succeed(
            "systemctl show -p MainPID --value lilly-vm-" + shared_placement + ".service"
        ).strip()
        == shared_pid
    )
    shared_host.succeed("fleet-default-oss-guest oss " + shared_placement, timeout=180)
    assert (
        sql(
            f"SELECT owner_id,desired_state,observed_state,archived_at IS NULL FROM compute_virtual_machines WHERE id='{fresh_vm_id}'"
        )
        == replacement_id + "|running|running|t"
    )
    assert (
        sql(
            f"SELECT count(*) FROM compute_operations WHERE vm_id='{fresh_vm_id}' AND kind='delete'"
        )
        == "0"
    )
    fresh_host.succeed("zfs list zroot/lilly/vm-" + fresh_placement)
    fresh_host.succeed("fleet-default-oss-guest oss " + fresh_placement, timeout=180)
    assert sql(f"SELECT deleted_at IS NULL FROM users WHERE id='{replacement_id}'") == "t"

with subtest("retired guest home stays reserved and explicit fresh sharing restores usable access"):
    preserved = (
        f'test "$(sudo stat -c %u /home/{old_name})" = {old_uid} '
        f'&& test "$(sudo cat /home/{old_name}/retired-marker)" = retired-home-marker '
        f'&& test "$(sudo getent passwd {old_name} | cut -d: -f3)" = {old_uid} '
        f'&& test "$(sudo getent shadow {old_name} | cut -d: -f8)" = 1 '
        f"&& sudo test ! -e /etc/sudoers.d/overalls_uid_{old_uid}"
    )
    guest_command(
        shared_id,
        "survivor",
        survivor_name,
        identity_command(survivor_name, survivor_uid, preserved),
    )
    guest_command(shared_id, "invited", old_name, "true", refusal="unknown")
    guest_command(shared_id, "fresh", fresh_name, "true", refusal="unshared")
    assert lifecycle({"operation": "share", "vm_id": shared_id, "owner_id": survivor_id}) == {
        "shared": True,
        "user_id": replacement_id,
    }
    guest_command(
        shared_id,
        "fresh",
        fresh_name,
        identity_command(fresh_name, fresh_uid, 'test ! -e "$HOME/retired-marker"'),
    )
    guest_command(shared_id, "fresh", old_name, "true", refusal="old-name")
    guest_command(
        shared_id,
        "survivor",
        survivor_name,
        identity_command(survivor_name, survivor_uid, preserved),
    )

with subtest("packaged Lyra config installs the discovered fresh identity and reaches its home"):
    client.succeed(
        "sudo -u tester mkdir -p /home/tester/.ssh /home/tester/.local/bin "
        "/home/tester/.local/state /home/tester/.config"
    )
    client.succeed(
        "sudo -u tester chmod 700 /home/tester/.ssh /home/tester/.local "
        "/home/tester/.local/bin /home/tester/.local/state /home/tester/.config"
    )
    client.succeed(
        f"install -m 600 -o tester -g users {browser_root}/fresh /home/tester/.ssh/fresh-key"
    )
    client.succeed(
        "install -m 755 -o tester -g users /run/current-system/sw/bin/overalls /home/tester/.local/bin/overalls"
    )
    management = (
        "Host control.example.test\n  HostName m1\n  IdentityFile ~/.ssh/fresh-key\n"
        "  IdentitiesOnly yes\n  BatchMode yes\n  StrictHostKeyChecking yes\n"
        "  HostKeyAlias control.example.test\n  GlobalKnownHostsFile /dev/null\n"
    )
    client.succeed(
        "printf '%s' "
        + shlex.quote(management)
        + " >/home/tester/.ssh/config && chown tester:users /home/tester/.ssh/config && chmod 600 /home/tester/.ssh/config"
    )
    environment = (
        "sudo -u tester env -u SSH_AUTH_SOCK HOME=/home/tester "
        "XDG_STATE_HOME=/home/tester/.local/state XDG_CONFIG_HOME=/home/tester/.config "
        f"SSL_CERT_FILE={browser_root}/ca.crt CURL_CA_BUNDLE={browser_root}/ca.crt "
    )
    client.succeed(
        environment
        + "overalls config-ssh --origin https://control.example.test --zone apps.example.test --staged-installer >"
        + browser_root
        + "/setup.out 2>"
        + browser_root
        + "/setup.err"
    )
    hostname = guest_host(fresh_vm_id)
    client.succeed(
        "sudo -u tester ssh -G " + hostname + " | grep -Fx " + shlex.quote("user " + fresh_name)
    )
    managed_ssh(
        environment
        + "ssh -T -o BatchMode=yes "
        + hostname
        + " "
        + shlex.quote(identity_command(fresh_name, fresh_uid))
        + " >"
        + browser_root
        + "/lyra.out 2>"
        + browser_root
        + "/lyra.err"
    )
    browser_signal("cleanup-complete")
    browser_wait("browser-passed")
    client.wait_until_succeeds(
        "test $(systemctl show -p SubState --value lifecycle-browser.service) = dead"
    )
    assert (
        client.succeed("systemctl show -p ExecMainStatus --value lifecycle-browser.service").strip()
        == "0"
    )
