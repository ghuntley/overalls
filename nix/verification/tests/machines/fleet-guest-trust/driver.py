"""Strict native NixOS and Ubuntu trust, refusal and restart evidence."""

import ipaddress
import json
import os
import re
import shlex
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory

from test_driver.machine import QemuMachine as TrustMachine

root = "/var/lib/overalls-fleet"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


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
    raise AssertionError("Guest-trust fixture condition timed out; private output withheld")


def execution_ready_snapshot() -> str:
    return sql(
        "SELECT COALESCE(json_agg(json_build_object("
        "'id', id, 'sequence', report_sequence, "
        "'age_seconds', extract(epoch FROM clock_timestamp() - reported_at), "
        "'execution_ready', inventory->>'execution_ready', "
        "'terminal_protocol', inventory->>'terminal_protocol', "
        "'session_present', connection_session_id IS NOT NULL) ORDER BY id), '[]') "
        "FROM compute_hosts"
    )


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="guest-trust-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/guest-trust-request.json"
        m1.copy_from_host(str(path), target)
        status, output = m1.execute("fleet-op " + target + " 2>/dev/null", timeout=180)
        assert status == 0, "Guest-trust operator failed; private output withheld"
        m1.succeed("rm " + target)
    rows = [
        line.removeprefix("FLEET_OK ")
        for line in output.splitlines()
        if line.startswith("FLEET_OK ")
    ]
    assert len(rows) == 1
    parsed: object = json.loads(rows[0])
    return object_fields(parsed)


def admit_request(request: dict[str, object]) -> dict[str, object]:
    accepted: dict[str, object] = {}

    def probe() -> bool:
        result = operator(request)
        if result["accepted"] is False:
            assert result == {"accepted": False, "reason": "insufficient_capacity"}
            return False
        assert result["accepted"] is True
        accepted.update(result)
        return True

    eventually(probe, timeout=300)
    return accepted


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
        transfer(m1, envelope, machine, root + "/credential.json")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
        machine.succeed("fleet-seal-lilly")
        machine.succeed("touch " + root + "/ready")
        machine.succeed("systemctl restart overalls-secrets-lilly.service")
        machine.succeed("systemctl restart lilly.service")
        machine.wait_for_unit("lilly.service")
    try:
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
                )
                == "2"
            ),
            timeout=300,
        )
    except AssertionError:
        print("execution_ready_snapshot: " + execution_ready_snapshot(), flush=True)
        raise
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
    users = operator(dict(action="default-oss-users", output=root + "/users.json"))


def identifier(value: object) -> str:
    assert isinstance(value, str) and str(uuid.UUID(value)) == value
    return value


def image_identifier(value: object) -> str:
    assert isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value)
    return value


def observed(vm_id: str, expected: str) -> None:
    assert str(uuid.UUID(vm_id)) == vm_id

    def reached() -> bool:
        state = sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
        assert state != "failed", "Native trust guest failed"
        return state == expected

    eventually(reached, timeout=600)


def receipt(machine: TrustMachine, placement: str, distribution: str, mode: str = "check") -> str:
    status, output = machine.execute(
        "fleet-guest-trust " + placement + " " + distribution + " " + mode, timeout=180
    )
    assert status == 0, "Native trust probe failed; guest output withheld"
    rows = [
        line.removeprefix("TRUST_OK ")
        for line in output.splitlines()
        if line.startswith("TRUST_OK ")
    ]
    assert len(rows) == 1
    return identifier(rows[0])


# @cc [owner:ghuntley,label:verification;security] fleet-native-boot-trust-oracle
# Both real distributions MUST install the host's exact roots and report current
# durable boot receipts. A wrong-boot exchange MUST fail without changing the
# installed bundle or guest service state. Restart MUST produce a new boot UUID
# while retaining the placement and data marker; fixture state is not authority.
with subtest("NixOS and Ubuntu boot trust survives refused stale delivery and renews on restart"):
    owner_id = identifier(users["owner_id"])
    used_hosts: set[str] = set()
    native_guests: dict[str, tuple[TrustMachine, str, str]] = {}
    # Ubuntu's minimum fits the historical 4 GiB root; the NixOS root is derived
    # from its real manifest minimum (whole GiB, at least 4 GiB) by the fixture.
    root_bytes: dict[str, int] = {"ubuntu": 4294967296, "nixos": nixos_guest_disk_bytes}
    for distribution, image_field in (("ubuntu", "image_id"), ("nixos", "alternative_image_id")):
        image_id = image_identifier(users[image_field])
        request: dict[str, object] = dict(
            action="provision",
            owner_id=owner_id,
            image_id=image_id,
            profile="oss",
            disk_bytes=root_bytes[distribution],
            key=str(uuid.uuid4()),
        )
        result = admit_request(request)
        assert result["accepted"] is True
        vm_id = identifier(result["vm_id"])
        placement = identifier(result["placement_id"])
        host_id = identifier(result["host_id"])
        assert host_id not in used_hosts
        used_hosts.add(host_id)
        host = next(
            machine for machine in provisioners if host_bindings[machine.name]["host"] == host_id
        )
        native_guests[distribution] = (host, host_id, image_id)
        observed(vm_id, "running")
        first_boot = receipt(host, placement, distribution, "seed")
        assert receipt(host, placement, distribution) == first_boot
        for kind, state in (("stop", "stopped"), ("start", "running")):
            assert operator(
                dict(
                    action="lifecycle",
                    owner_id=owner_id,
                    vm_id=vm_id,
                    kind=kind,
                    key=str(uuid.uuid4()),
                )
            ) == {"requested": True}
            observed(vm_id, state)
        assert (
            sql(f"SELECT current_placement_id FROM compute_virtual_machines WHERE id='{vm_id}'")
            == placement
        )
        assert receipt(host, placement, distribution) != first_boot
        assert (
            sql(
                f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}' AND status='completed'"
            )
            == "3"
        )

        operator(dict(action="enable", host_id=host_id, enabled=False))
    assert len(used_hosts) == 2

with subtest("real enlarged fixture pool admits three trust-enabled NixOS guests"):
    # The final loop iteration is NixOS. The other host stays disabled and its
    # Ubuntu guest remains running. Admission observes actual native headroom.
    host, host_id, image_id = native_guests["nixos"]
    operator(dict(action="enable", host_id=host_id, enabled=True))
    for _ in range(2):
        extra_request: dict[str, object] = dict(
            action="provision",
            owner_id=owner_id,
            image_id=image_id,
            profile="oss",
            disk_bytes=nixos_guest_disk_bytes,
            key=str(uuid.uuid4()),
        )
        accepted = admit_request(extra_request)
        assert identifier(accepted["host_id"]) == host_id
        extra_vm = identifier(accepted["vm_id"])
        extra_placement = identifier(accepted["placement_id"])
        observed(extra_vm, "running")
        receipt(host, extra_placement, "nixos", "seed")
    # Each hold is the root plus the 1 GiB workload bundle (VMShape.reservation/1).
    expected_holds = f"3|{3 * (nixos_guest_disk_bytes + 1073741824)}"
    assert (
        sql(
            "SELECT count(*) FROM compute_virtual_machines AS vm "
            "JOIN compute_workload_placements AS placement "
            "ON placement.id=vm.current_placement_id AND placement.vm_id=vm.id "
            f"WHERE placement.host_id='{host_id}' AND vm.observed_state='running'"
        )
        == "3"
    )
    assert (
        sql(
            f"SELECT count(*) || '|' || sum(disk_bytes) FROM compute_reservations WHERE host_id='{host_id}' AND disk_held"
        )
        == expected_holds
    )
    before = sql("SELECT count(*) FROM compute_virtual_machines")
    assert before == "4"
    # Settled virtual promises do not consume admission headroom (ADR-0050).
    # A valid root larger than the entire actual quota cannot fit even on an
    # otherwise idle pool; this expectation is independent of Budget arithmetic.
    quota_bytes = int(host.succeed("zfs get -Hpo value quota zroot/lilly").strip())
    assert quota_bytes == storage_budget
    impossible_root_bytes = 68719476736
    assert impossible_root_bytes > quota_bytes
    rejected: dict[str, object] = dict(
        action="provision",
        owner_id=owner_id,
        image_id=image_id,
        profile="oss",
        disk_bytes=impossible_root_bytes,
        key=str(uuid.uuid4()),
    )
    assert operator(rejected) == {"accepted": False, "reason": "insufficient_capacity"}
    assert sql("SELECT count(*) FROM compute_virtual_machines") == before
    assert (
        sql(
            f"SELECT count(*) || '|' || sum(disk_bytes) FROM compute_reservations WHERE host_id='{host_id}' AND disk_held"
        )
        == expected_holds
    )
