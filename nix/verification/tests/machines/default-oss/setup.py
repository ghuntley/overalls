"""Typed shared fleet setup: boot, enrollment, private services and seeded users."""

import base64
import ipaddress
import json
import os
import shlex
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TypedDict

from test_driver.machine import QemuMachine as ProfileMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-default-oss"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


class TransferEndpoint(TypedDict):
    address: str
    port: int
    host_key: str


def transfer_endpoint(machine: ProfileMachine, address: str) -> TransferEndpoint:
    """@cc [owner:ghuntley,label:verification;security] default-oss-enrolled-transfer-identity
    When `enroll_transfer_endpoints` is set, enrollment MUST pin the actual
    host's Ed25519 public key and configured IPv4 transfer listener after its
    service starts, and the persisted endpoint MUST equal that pin. Without an
    enrolled endpoint Marshall refuses relocation as source_unavailable; missing
    identity MUST fail setup rather than bypass admission.
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
    raise AssertionError("Default-profile fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="default-oss-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/default-oss-request.json"
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


def current_placement(vm_id: str) -> tuple[ProfileMachine, str]:
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
    started = time.monotonic()
    dumped = False

    def observed() -> bool:
        nonlocal dumped
        state = sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
        # Dump before Lilly removes a failed VM's boot log.
        if (
            state != "running"
            and not dumped
            and (state == "failed" or time.monotonic() - started > 100)
        ):
            dumped = True
            dump_guest_diagnostics(provisioners)
        assert state != "failed", "Real profile guest failed to start"
        return state == "running"

    eventually(observed, timeout=600)


# @cc [owner:ghuntley,label:verification;recovery] customer-cli-observation-boundary
# Native Customer lifecycle assertions MUST read only durable fleet SQL,
# systemd cgroup/unit state, ZFS dataset identity and the real guest terminal
# probe; no fixture may inject outcomes or mutate intent to reach them.
def observed_state(vm_id: str) -> str:
    assert str(uuid.UUID(vm_id)) == vm_id
    return sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")


def intent_snapshot() -> tuple[str, ...]:
    # Complete durable intent inventory relevant to lifecycle admission: SSH
    # receipts, operations, reservations, grants, admin audit and VM identities.
    return (
        sql("SELECT count(*) FROM ssh_requests"),
        sql("SELECT count(*) FROM compute_operations"),
        sql("SELECT count(*) FROM compute_reservations"),
        sql("SELECT count(*) FROM access_grants"),
        sql("SELECT count(*) FROM access_grants_versions"),
        sql("SELECT count(*) FROM account_admin_events"),
        sql("SELECT coalesce(json_agg(id ORDER BY id), '[]') FROM compute_virtual_machines"),
        sql(
            "SELECT coalesce(json_agg(id ORDER BY id), '[]') FROM compute_virtual_machines_versions"
        ),
    )


def porsche(
    command: str, role: str = "owner", expected_error: str | None = None
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;security] default-profile-porsche-transport
    Commands MUST traverse OpenSSH, packaged Porsche and authenticated Marshall.
    Refusals MUST be parsed application denials, never accepted transport errors.
    Raw rejection output stays private because onboarding can contain a token.
    """
    arguments = [
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "HostKeyAlias=control.example.test",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + browser_root + "/known_hosts",
        "-i",
        browser_root + "/" + role,
        "fixture@m1",
        command + " --json",
    ]
    output_path = browser_root + "/receipt.json"
    status, _ = client.execute(
        "sudo -u tester " + shlex.join(arguments) + " >" + output_path + " 2>/dev/null", timeout=680
    )
    # Never relay raw SSH output; project only a bounded, validated receipt.
    program = (
        "import json; v=json.load(open("
        + repr(output_path)
        + ")); assert v.get('version')==1; print(json.dumps({k:v[k] for k in ('status','error','request_id','operation_id','result') if k in v}))"
    )
    parsed: object = json.loads(client.succeed("python3 -c " + shlex.quote(program)))
    receipt = object_fields(parsed)
    if expected_error is not None:
        assert status != 0
        assert receipt.get("error") == expected_error
    else:
        assert status == 0 and receipt.get("status") == "succeeded", (
            "Porsche profile operation did not succeed"
        )
    return receipt


def result_id(receipt: dict[str, object]) -> str:
    value = object_fields(receipt["result"])["id"]
    assert isinstance(value, str) and str(uuid.UUID(value)) == value
    return value


def ordinary_accounts() -> None:
    assert (
        sql(
            "SELECT count(*) FROM users WHERE email LIKE 'owner-%' OR email LIKE 'member-%' OR email LIKE 'stranger-%'"
        )
        == "3"
    )
    assert (
        sql(
            "SELECT count(*) FROM users WHERE administrator AND (email LIKE 'owner-%' OR email LIKE 'member-%' OR email LIKE 'stranger-%')"
        )
        == "0"
    )
    assert (
        sql(
            "SELECT count(*) FROM users WHERE administrator AND email='profile-bootstrap@example.test'"
        )
        == "1"
    )


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
        request: dict[str, object] = dict(
            version=3,
            name=machine.name,
            architecture="x86_64",
            machine_id=observed["machine_id"],
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
        endpoint: TransferEndpoint | None = None
        if enroll_transfer_endpoints:
            endpoint = transfer_endpoint(machine, binding["ip"])
            request["transfer_endpoint"] = endpoint
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
        if endpoint is not None:
            persisted: object = json.loads(
                sql(
                    "SELECT transfer_endpoint::text FROM compute_hosts WHERE id='"
                    + str(uuid.UUID(binding["host"]))
                    + "'"
                )
            )
            assert object_fields(persisted) == endpoint
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
        # Credential provisioning can start Audi while Ziggy's first boot is
        # still failing. A later successful Ziggy restart does not replay the
        # failed dependent start job. Initialize Audi after its real services
        # are ready, retaining the bounded readiness assertion below.
        machine.succeed("systemctl start audi-private.service", timeout=900)
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
    users = operator(dict(action="default-oss-users", output=root + "/users.json"))
    ordinary_accounts()
