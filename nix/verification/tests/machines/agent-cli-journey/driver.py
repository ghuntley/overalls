"""Typed browser-approved CLI journey on the fleet's real service and guest topology."""

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

from test_driver.machine import QemuMachine as AgentMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-agent-cli"
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
    raise AssertionError("Agent CLI fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="agent-cli-private-") as directory:
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


def current_placement(vm_id: str) -> tuple[AgentMachine, str]:
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
        for filename in ("marshall.env", "ca.crt", "serper.key"):
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
    users = operator(dict(action="default-oss-users", output=root + "/users.json"))
    ordinary_accounts()


def checkpoint(name: str) -> None:
    client.wait_until_succeeds(
        f"test -f {browser_root}/{name}.ready || systemctl is-failed fleet-agent-cli-browser.service",
        timeout=660,
    )
    if client.execute(f"test -f {browser_root}/{name}.ready")[0] != 0:
        closed_agent_diagnostics(vm_id)
        raise AssertionError("Browser CLI journey failed; private content withheld")


def closed_agent_diagnostics(vm_id: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] cli-failure-closed-diagnostics
    Failure diagnostics MUST project only schema-constrained statuses/reasons,
    counts and booleans. Prompts, command arguments, results, credentials and
    arbitrary response fields MUST remain private, including failed runs.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    scoped = f"SELECT id FROM agent_roots WHERE vm_id='{vm_id}'"
    turns = f"SELECT id FROM agent_turns WHERE thread_id IN (SELECT id FROM agent_threads WHERE root_id IN ({scoped}))"
    for table, projection, condition, grouping in (
        (
            "agent_turns",
            "status,failure_reason,count(*) AS count",
            f"id IN ({turns})",
            "status,failure_reason",
        ),
        (
            "agent_commands",
            "status,count(*) AS count,count(*) FILTER (WHERE result ? 'contents') AS contents_count",
            f"turn_id IN ({turns})",
            "status",
        ),
        (
            "agent_model_calls",
            "status,count(*) AS count",
            f"turn_id IN ({turns})",
            "status",
        ),
        (
            "agent_executors",
            "invalidated_at IS NULL AS current,count(*) AS count",
            f"root_id IN ({scoped})",
            "invalidated_at IS NULL",
        ),
    ):
        counts = sql(
            f"SELECT coalesce(json_agg(row_to_json(d)),'[]'::json) FROM "
            f"(SELECT {projection} FROM {table} WHERE {condition} GROUP BY {grouping}) d"
        )
        print("Closed agent diagnostic " + table + ": " + counts, flush=True)


def resume(name: str) -> None:
    client.succeed(f"touch {browser_root}/{name}.continue")


def inventory(vm_id: str) -> dict[str, dict[str, str]]:
    """@cc [owner:ghuntley,label:verification] cli-native-refusal-inventory
    Approval GET and stale-form refusal MUST preserve exact persisted scoped
    session, turn, thread, audit, model, command and lifecycle-operation rows.
    Comparison uses row digests so prompt and result content cannot be logged.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    thread = f"SELECT t.id FROM agent_threads t JOIN agent_roots r ON r.id=t.root_id WHERE r.vm_id='{vm_id}'"
    turns = f"SELECT id FROM agent_turns WHERE thread_id IN ({thread})"
    tables = {
        "agent_cli_sessions": f"vm_id='{vm_id}'",
        "agent_audit_events": f"vm_id='{vm_id}'",
        "compute_operations": f"vm_id='{vm_id}'",
        "agent_threads": f"id IN ({thread})",
        "agent_turns": f"id IN ({turns})",
        "agent_model_calls": f"turn_id IN ({turns})",
        "agent_commands": f"turn_id IN ({turns})",
    }
    result: dict[str, dict[str, str]] = {}
    for table, condition in tables.items():
        parsed: object = json.loads(
            sql(
                "SELECT coalesce(json_agg(json_build_object('id', id, 'digest', md5(row_to_json(t)::text)) ORDER BY id),'[]'::json) "
                f"FROM {table} t WHERE {condition}"
            )
        )
        assert isinstance(parsed, list)
        rows: dict[str, str] = {}
        for value in parsed:
            row = string_fields(value)
            identifier = row["id"]
            assert str(uuid.UUID(identifier)) == identifier and identifier not in rows
            rows[identifier] = row["digest"]
        result[table] = rows
    return result


with subtest("ordinary browser shares a stopped real agent guest"):
    provisioned = operator(
        dict(
            action="provision",
            owner_id=users["owner_id"],
            image_id=users["image_id"],
            profile="standard",
            key=str(uuid.uuid4()),
            disk_bytes=6_442_450_944,
        )
    )
    assert provisioned["accepted"] is True
    vm_value = provisioned["vm_id"]
    assert isinstance(vm_value, str) and str(uuid.UUID(vm_value)) == vm_value
    vm_id = vm_value
    running(vm_id)
    machine, placement = current_placement(vm_id)
    machine.wait_until_succeeds(
        "fleet-galileo-guest agent-service " + shlex.quote(placement), timeout=180
    )
    machine.wait_until_succeeds(
        "fleet-galileo-guest agent-route " + shlex.quote(placement), timeout=180
    )
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM agent_executors WHERE root_id="
                f"(SELECT id FROM agent_roots WHERE vm_id='{vm_id}') AND invalidated_at IS NULL "
                "AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    assert operator(
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            kind="stop",
            key=str(uuid.uuid4()),
        )
    ) == {"requested": True}
    eventually(
        lambda: (
            sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
            == "stopped"
        )
    )
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n agent-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    transfer(m1, root + "/users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    client.succeed("printf '%s' " + shlex.quote(vm_id) + " >" + browser_root + "/vm-id")
    client.succeed(
        "systemd-run --quiet --no-block --unit=fleet-agent-cli-browser "
        "--property=User=tester --property=Group=users --property=Type=oneshot --property=RemainAfterExit=yes "
        "--setenv=HOME=/home/tester --setenv=PATH=/run/current-system/sw/bin "
        "/run/current-system/sw/bin/fleet-agent-cli-browser"
    )
    checkpoint("shared")
    ordinary_accounts()
    before_get = inventory(vm_id)
    resume("shared")

with subtest("browser GET cannot approve and explicit consent completes packaged CLI guest work"):
    checkpoint("completed-get")
    assert inventory(vm_id) == before_get
    assert before_get["agent_cli_sessions"] == {} and before_get["agent_turns"] == {}
    resume("completed-get")
    checkpoint("completed")
    assert (
        sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'") == "running"
    )
    thread_filter = f"thread_id IN (SELECT t.id FROM agent_threads t JOIN agent_roots r ON r.id=t.root_id WHERE r.vm_id='{vm_id}')"
    turn_id = sql(f"SELECT id FROM agent_turns WHERE {thread_filter} AND status='completed'")
    assert str(uuid.UUID(turn_id)) == turn_id
    assert (
        sql(
            f"SELECT count(*) FROM agent_model_calls WHERE turn_id='{turn_id}' AND status='completed'"
        )
        == "2"
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_commands WHERE turn_id='{turn_id}' AND status='completed' AND tool='read_file'"
        )
        == "1"
    )
    # Source guest configuration fixes /etc/hostname to lilly-guest plus newline.
    # Compare exact tool/path/result and current native executor as a count;
    # command arguments and tool contents must not enter driver diagnostics.
    assert (
        sql(
            "SELECT count(*) FROM agent_commands c JOIN agent_executors e ON e.id=c.executor_id "
            "JOIN compute_virtual_machines v ON v.id=e.vm_id "
            f"WHERE c.turn_id='{turn_id}' AND v.id='{vm_id}' AND c.status='completed' "
            "AND c.tool='read_file' AND c.arguments=jsonb_build_object('path','/etc/hostname') "
            "AND c.result=jsonb_build_object('contents','lilly-guest'||chr(10)) "
            "AND c.fence_epoch=e.fence_epoch AND e.placement_id=v.current_placement_id "
            "AND e.execution_epoch=v.execution_epoch"
        )
        == "1"
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_audit_events WHERE turn_id='{turn_id}' AND kind='wake_requested'"
        )
        == "1"
    )
    member = users["member_id"]
    assert isinstance(member, str) and str(uuid.UUID(member)) == member
    assert (
        sql(
            f"SELECT count(*) FROM agent_cli_sessions WHERE vm_id='{vm_id}' AND actor_id='{member}'"
        )
        == "1"
    )
    before_get = inventory(vm_id)
    resume("completed")

with subtest("a fresh approved CLI invocation preserves the profile child-agent refusal"):
    checkpoint("capability-get")
    assert inventory(vm_id) == before_get
    resume("capability-get")
    checkpoint("capability")
    denied = sql(
        f"SELECT id FROM agent_turns WHERE {thread_filter} AND status='failed' AND failure_reason='capability_denied'"
    )
    assert str(uuid.UUID(denied)) == denied
    # Context collection is a Marshall-owned pre-model step recorded as
    # internal context_* commands; the refused turn ran no guest tool.
    assert (
        sql(
            f"SELECT count(*) FROM agent_commands WHERE turn_id='{denied}' "
            "AND tool NOT IN ('context_inventory', 'context_read')"
        )
        == "0"
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_threads WHERE root_id=(SELECT id FROM agent_roots WHERE vm_id='{vm_id}') AND parent_thread_id IS NOT NULL"
        )
        == "0"
    )
    before_get = inventory(vm_id)
    resume("capability")

with subtest("ordinary owner withdrawal refuses a mounted approval without prompt or wake effects"):
    checkpoint("stale-get")
    assert inventory(vm_id) == before_get
    resume("stale-get")
    checkpoint("withdrawn")
    assert (
        sql(
            f"SELECT count(*) FROM access_grants WHERE vm_id='{vm_id}' AND user_id='{member}' AND archived_at IS NULL"
        )
        == "0"
    )
    assert (
        sql(
            f"SELECT count(*) FROM access_grants WHERE vm_id='{vm_id}' AND user_id='{member}' AND archived_at IS NOT NULL AND revoked_by_id IS NOT NULL"
        )
        == "1"
    )
    refused_inventory = inventory(vm_id)
    resume("withdrawn")
    checkpoint("refused")
    assert inventory(vm_id) == refused_inventory
    assert len(refused_inventory["agent_cli_sessions"]) == 2
    assert len(refused_inventory["agent_turns"]) == 2
    ordinary_accounts()
    resume("refused")
    client.wait_for_unit("fleet-agent-cli-browser.service")
    client.succeed("! pgrep -u tester -f 'overalls agent --machine'")
