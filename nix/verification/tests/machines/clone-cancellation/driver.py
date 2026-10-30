"""Typed bounded clone-cancellation journey on the fleet's real service and guest topology."""

import ipaddress
import json
import os
import shlex
import subprocess
import time
import uuid
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory

from test_driver.machine import QemuMachine as CloneMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-clone-cancellation"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


@contextmanager
def record_observations() -> Iterator[None]:
    """@cc [owner:ghuntley,label:verification;security] clone-observation-failure-capture
    Only the disposable capture/cancellation/control interval may arm recording.
    Before failure teardown, disarm and copy each private bounded ring outside
    Nix outputs without printing sample bytes. Collection failures MUST preserve
    the original exception. Successful runs MUST discard the host-local rings.
    Failure builds require --keep-failed to retain the private builder directory.
    """
    observation_root = "/run/clone-zfs-observations"
    try:
        for machine in provisioners:
            machine.succeed("install -d -m 700 " + observation_root)
            machine.succeed("chown --reference=/run/lilly " + observation_root)
            machine.succeed("install -m 600 /dev/null " + observation_root + "/armed")
            machine.succeed("chown --reference=/run/lilly " + observation_root + "/armed")
        yield
    except Exception:
        disarmed: list[CloneMachine] = []
        for machine in provisioners:
            try:
                # The recorder checks armed again under this lock before saving.
                # Once disarmed and drained, no late reader can replace a sample.
                machine.succeed("rm -f " + observation_root + "/armed", timeout=10)
                machine.succeed("flock -w 5 " + observation_root + "/lock true", timeout=10)
                disarmed.append(machine)
            except Exception:
                print("Fixture ZFS recorder disarm failed for " + machine.name)
        for machine in disarmed:
            try:
                private = Path(os.environ["NIX_BUILD_TOP"]) / "clone-zfs-private"
                assert not private.resolve().is_relative_to(machine.out_dir.resolve())
                private.mkdir(mode=0o700, exist_ok=True)
                destination = private / machine.name
                destination.mkdir(mode=0o700)
                machine.copy_from_machine(observation_root, str(destination))
                print("Private bounded ZFS samples captured for " + machine.name)
            except Exception:
                print("Private ZFS sample collection failed for " + machine.name)
        raise
    finally:
        for machine in provisioners:
            # Framework teardown remains authoritative if a machine is unreachable.
            try:
                machine.execute("rm -rf -- " + observation_root, timeout=10)
            except Exception:
                print("Fixture ZFS recorder cleanup deferred to teardown for " + machine.name)


@contextmanager
def record_report_rejections(interval: str) -> Iterator[None]:
    """@cc [owner:ghuntley,label:verification;security] clone-report-guard-failure-capture
    Arm only the disposable admission or clone interval. On failure, disarm all
    three replicas, drain bounded staging files and privately collect finite guard
    rejections outside Nix outputs. Never print evidence or replace the original
    exception. First rejection per stage is retained, not a timeline or outcome.
    Successful intervals discard evidence; failed builds require --keep-failed.
    """
    assert interval in {"admission", "clone"}
    roots = {
        machine.name: "/run/marshall-" + machine.name + "/clone-report-rejections"
        for machine in marshalls
    }
    try:
        for machine in marshalls:
            directory = roots[machine.name]
            runtime = "/run/marshall-" + machine.name
            machine.succeed("install -d -m 700 " + directory)
            machine.succeed("chown --reference=" + runtime + " " + directory)
            machine.succeed("install -m 600 /dev/null " + directory + "/armed")
            machine.succeed("chown --reference=" + runtime + " " + directory + "/armed")
        yield
    except Exception:
        drained: list[CloneMachine] = []
        for machine in marshalls:
            directory = roots[machine.name]
            try:
                machine.succeed("rm -f " + directory + "/armed", timeout=10)
                machine.wait_until_succeeds(
                    'test -z "$(find ' + directory + " -maxdepth 1 -name '*.tmp' -print -quit)\"",
                    timeout=10,
                )
                drained.append(machine)
            except Exception:
                print("Fixture report rejection drain failed for " + machine.name)
        for machine in drained:
            try:
                private = Path(os.environ["NIX_BUILD_TOP"]) / "clone-report-private" / interval
                assert not private.resolve().is_relative_to(machine.out_dir.resolve())
                private.parent.mkdir(mode=0o700, exist_ok=True)
                private.mkdir(mode=0o700, exist_ok=True)
                destination = private / machine.name
                destination.mkdir(mode=0o700)
                machine.copy_from_machine(roots[machine.name], str(destination))
                print("Private finite report guard evidence captured for " + machine.name)
            except Exception:
                print("Private report guard collection failed for " + machine.name)
        raise
    finally:
        for machine in marshalls:
            try:
                machine.execute("rm -rf -- " + roots[machine.name], timeout=10)
            except Exception:
                print("Fixture report guard cleanup deferred to teardown for " + machine.name)


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
    raise AssertionError("Clone fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="clone-cancellation-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/clone-cancellation-request.json"
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


def current_placement(vm_id: str) -> tuple[CloneMachine, str]:
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


def workload_identity(vm_id: str) -> str:
    """@cc [owner:ghuntley,label:verification] clone-cancellation-native-placement-identity
    Identity comparisons MUST read host and pool from the VM's current placement;
    calculated resource attributes MUST NOT be treated as persisted VM columns.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    return sql(
        "SELECT jsonb_build_array(v.owner_id,v.profile,v.image_id,p.host_id,p.pool_id,v.current_placement_id,v.execution_epoch) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p ON p.id=v.current_placement_id "
        f"WHERE v.id='{vm_id}'"
    )


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

with (
    record_report_rejections("admission"),
    subtest("authenticated native observations supply admission capacity"),
):
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


def browser_signal(name: str) -> None:
    def ready() -> bool:
        status, _ = client.execute("test -e " + browser_root + "/" + name + ".ready")
        if status == 0:
            return True
        alive, _ = client.execute("systemctl is-active --quiet clone-browser-fixture.service")
        if alive != 0:
            # Only the helper's fixed stage/category record leaves the client.
            _, failure = client.execute(
                'grep -m1 \'"event": "clone_browser_failed"\' ' + browser_root + "/browser.log"
            )
            raise AssertionError("Clone browser exited before checkpoint: " + failure.strip())
        return False

    eventually(ready, timeout=600)


def resume_browser(name: str) -> None:
    client.succeed("touch " + browser_root + "/" + name + ".go")


def clone_id(name: str) -> str:
    assert name in ("cancel-captured-copy", "revoked-queued-copy", "successful-clone-control")
    value = sql(f"SELECT id FROM compute_clone_requests WHERE name='{name}'")
    assert str(uuid.UUID(value)) == value
    return value


def clone_checkpoint(clone: str, *, after_public_cancellation: bool = False) -> tuple[str, bool]:
    """@cc [owner:ghuntley,label:verification;security] clone-native-failure-diagnostics
    A retryable label MUST match a bound offered/incomplete effect in its valid
    phase, with source snapshot headroom, destination disk/compute and exact host
    slots retained. Source compute MAY release after observed restoration. Only
    copy/adopt may remain abandoned after this fixture's captured cancellation.
    Final states MUST clear failure. Checks MUST read one database snapshot and
    report only closed phase/failure labels, never effect payloads or keys.
    """
    assert str(uuid.UUID(clone)) == clone
    parsed: object = json.loads(
        sql(f"""
            SELECT jsonb_build_object(
              'phase', r.phase, 'failure', r.failure,
              'cancelled', r.cancel_requested_at IS NOT NULL,
              'unpublished', r.published_at IS NULL,
              'captured', r.snapshot IS NOT NULL,
              'capture_valid', EXISTS (
                SELECT 1 FROM compute_clone_effects e
                WHERE e.clone_request_id=r.id AND e.kind='capture' AND e.endpoint='source'
                  AND e.host_id=r.source_host_id AND e.offered_at IS NOT NULL
                  AND e.status='completed' AND e.completed_at IS NOT NULL AND e.result=r.snapshot
              ),
              'pending_valid', r.active AND r.finished_at IS NULL AND r.published_at IS NULL
                AND EXISTS (
                  SELECT 1 FROM compute_clone_effects e
                  WHERE e.clone_request_id=r.id AND r.failure=e.kind || '_unconfirmed'
                    AND e.status='offered' AND e.offered_at IS NOT NULL
                    AND e.completed_at IS NULL AND e.result IS NULL
                    AND e.payload->'specification'=r.specification
                    AND e.host_id=CASE e.endpoint WHEN 'source' THEN r.source_host_id
                      WHEN 'destination' THEN r.destination_host_id END
                    AND (e.kind,e.endpoint) IN (
                      ('prepare','destination'), ('probe','source'), ('connect','destination'),
                      ('capture','source'), ('copy','destination'), ('adopt','destination'),
                      ('revoke','source'), ('revoke','destination'),
                      ('discard','destination'), ('prune','source'))
                    AND (
                      (r.cancel_requested_at IS NULL AND (
                        (r.phase='preparing' AND e.kind IN ('prepare','probe','connect') AND r.snapshot IS NULL)
                        OR (r.phase='capturing' AND e.kind='capture' AND r.snapshot IS NULL)
                        OR (r.phase='copying' AND e.kind='copy' AND r.snapshot IS NOT NULL)
                        OR (r.phase='publishing' AND e.kind='adopt' AND r.snapshot IS NOT NULL)))
                      OR (r.phase='cancelling' AND r.cancel_requested_at IS NOT NULL
                        AND r.snapshot IS NOT NULL AND r.source_restored_at IS NOT NULL
                        AND e.kind IN ('copy','adopt','revoke','discard','prune'))
                    )
                ),
              'commitments', EXISTS (
                SELECT 1 FROM compute_reservations h
                WHERE h.vm_id=r.source_vm_id
                  AND h.placement_id::text=r.specification->'source'->>'placement_id'
                  AND h.host_id=r.source_host_id AND h.disk_held
                  AND h.temporary_disk_bytes=6442450944
                  AND (r.source_restored_at IS NOT NULL OR h.compute_held)
              ) AND EXISTS (
                SELECT 1 FROM compute_reservations h
                WHERE h.vm_id=r.destination_vm_id
                  AND h.placement_id::text=r.specification->'destination'->>'placement_id'
                  AND h.host_id=r.destination_host_id
                  AND h.disk_held AND h.compute_held AND h.disk_bytes=6442450944
              ) AND (
                SELECT count(*)=CASE WHEN r.source_host_id=r.destination_host_id THEN 1 ELSE 2 END
                  AND bool_and(s.released_at IS NULL AND s.host_id IN (r.source_host_id,r.destination_host_id))
                  AND count(DISTINCT s.host_id)=count(*)
                FROM compute_transfer_slots s WHERE s.clone_request_id=r.id
              )
            ) FROM compute_clone_requests r WHERE r.id='{clone}'
        """)
    )
    state = object_fields(parsed)
    phase = state["phase"]
    assert isinstance(phase, str) and phase in (
        "queued",
        "preparing",
        "stopping",
        "capturing",
        "copying",
        "publishing",
        "cleaning",
        "cancelling",
        "complete",
        "cancelled",
        "failed",
    )
    failure = state["failure"]
    known_failures = {
        kind + "_unconfirmed"
        for kind in (
            "prepare",
            "probe",
            "connect",
            "capture",
            "copy",
            "adopt",
            "revoke",
            "discard",
            "prune",
        )
    } | {
        "source_restart_failed",
        "retry_source_restart",
        "destination_start_failed",
        "forbidden",
        "vm_deleted",
        "placement_changed",
        "vm_busy",
        "workload_not_stable",
        "source_unavailable",
        "insufficient_capacity",
        "address_pool_exhausted",
        "profile_image_mismatch",
    }
    label = failure if isinstance(failure, str) and failure in known_failures else "unknown"
    retryable_storage = isinstance(failure, str) and failure.endswith("_storage_busy")
    cancellation_cleanup = (
        phase == "cancelling"
        and isinstance(failure, str)
        and failure.endswith("_cleanup_unconfirmed")
    )
    assert state["cancelled"] is after_public_cancellation and state["unpublished"] is True
    assert failure is None or (
        state["commitments"] is True
        and (state["pending_valid"] is True or retryable_storage or cancellation_cleanup)
    ), f"Native clone progress lacks bound pending evidence: phase={phase}, failure={label}"
    captured = state["captured"]
    assert isinstance(captured, bool)
    if captured:
        assert state["capture_valid"] is True
    return phase, captured


def advance(clone: str, *, after_public_cancellation: bool = False) -> str:
    operator(dict(action="clone-advance", request_id=clone))
    phase, _captured = clone_checkpoint(clone, after_public_cancellation=after_public_cancellation)
    return phase


def snapshot_ready(clone: str) -> bool:
    """@cc [owner:ghuntley,label:verification] clone-native-capture-receipt-required
    A stored snapshot MUST match an offered, completed source-host capture
    receipt before this checkpoint succeeds. Cancellation and publication MUST
    still be absent; unrelated pending copy/adopt cannot substitute for capture.
    """
    phase, captured = clone_checkpoint(clone)
    if captured:
        assert phase in ("copying", "publishing")
    return captured


def capture_step(clone: str) -> bool:
    if snapshot_ready(clone):
        return True
    advance(clone)
    return snapshot_ready(clone)


def destination(clone: str) -> str:
    value = sql(f"SELECT destination_vm_id FROM compute_clone_requests WHERE id='{clone}'")
    assert str(uuid.UUID(value)) == value
    return value


def check_guest(machine: CloneMachine, placement: str) -> None:
    machine.succeed(f"fleet-resize-guest check {placement} 1 5368709120", timeout=180)


with subtest("owner creates and seeds a real shareable source"):
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n clone-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    transfer(m1, root + "/users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    client.succeed(
        "systemd-run --unit=clone-browser-fixture --property=User=tester --setenv=HOME=/home/tester --setenv=PATH=/run/current-system/sw/bin /bin/sh -c "
        + shlex.quote("fleet-clone-cancellation-browser >" + browser_root + "/browser.log 2>&1")
    )
    browser_signal("created")
    vm_id = client.succeed("cat " + browser_root + "/vm-id").strip()
    assert str(uuid.UUID(vm_id)) == vm_id
    running(vm_id)
    host, placement = current_placement(vm_id)
    source_dataset = "zroot/lilly/vm-" + placement
    source_guid = host.succeed("zfs get -Hp -o value guid " + source_dataset).strip()
    source_identity = workload_identity(vm_id)
    host.succeed(f"fleet-resize-guest seed {placement} 1 5368709120", timeout=180)
    check_guest(host, placement)
    # @cc [owner:ghuntley,label:verification] clone-native-dispatch-gate
    # Only the disposable fixture's clone job scheduling may be delayed. Native
    # effect receipts, lifecycle jobs, phases and reservations MUST remain real.
    # Explicit stepping MUST pause after observed capture/restoration for public
    # cancellation/withdrawal, then resume admitted recovery. The successful
    # control MUST run after removing this automatic-dispatch gate.
    sql("""
        CREATE FUNCTION fixture_defer_clone_jobs() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.worker = 'Marshall.Compute.Workers.Clone' THEN
            NEW.scheduled_at := clock_timestamp() + interval '1 day';
            NEW.state := 'scheduled';
          END IF;
          RETURN NEW;
        END; $$;
        CREATE TRIGGER fixture_defer_clone_jobs BEFORE INSERT ON oban_jobs
        FOR EACH ROW EXECUTE FUNCTION fixture_defer_clone_jobs();
    """)
    resume_browser("created")
    browser_signal("submitted")
    first = clone_id("cancel-captured-copy")
    queued = clone_id("revoked-queued-copy")
    assert sql(f"SELECT phase FROM compute_clone_requests WHERE id='{first}'") == "queued"
    assert sql(f"SELECT phase FROM compute_clone_requests WHERE id='{queued}'") == "queued"
    assert (
        sql(
            "SELECT count(*)=2 AND bool_and(state='scheduled' "
            "AND scheduled_at > clock_timestamp() + interval '1 hour') "
            "FROM oban_jobs WHERE worker='Marshall.Compute.Workers.Clone'"
        )
        == "t"
    )

with record_observations(), record_report_rejections("clone"):
    with subtest("real capture restores the source before public cancellation"):
        activated = operator(dict(action="clone-activate", request_id=first))
        assert activated["activation_preconditions_observed"] is True
        clone_checkpoint(first)
        eventually(lambda: capture_step(first), timeout=300)
        running(vm_id)
        assert advance(first) in ("copying", "publishing")
        assert (
            sql(
                f"SELECT source_restored_at IS NOT NULL AND published_at IS NULL FROM compute_clone_requests WHERE id='{first}'"
            )
            == "t"
        )
        host.succeed("zfs list " + source_dataset + "@lilly-b")
        assert host.succeed(
            "zfs get -Hp -o value guid " + source_dataset + "@lilly-b"
        ).strip() == sql(
            f"SELECT snapshot->'descriptor'->'stream'->>'to_guid' FROM compute_clone_requests WHERE id='{first}'"
        )
        check_guest(host, placement)
        copied = destination(first)
        copied_host, copied_placement = current_placement(copied)
        copied_dataset = "zroot/lilly/vm-" + copied_placement
        # Native receive may already have finished, but publication requires another
        # coordinator boundary and cannot race past this observed checkpoint.
        client.succeed("printf %s " + shlex.quote(first) + " >" + browser_root + "/cancel-id")
        client.succeed("chown tester:users " + browser_root + "/cancel-id")
        resume_browser("submitted")
        browser_signal("cancelled")
        assert (
            sql(
                f"SELECT phase='cancelling' AND published_at IS NULL AND cancel_requested_at IS NOT NULL FROM compute_clone_requests WHERE id='{first}'"
            )
            == "t"
        )
        assert (
            sql(f"SELECT temporary_disk_bytes FROM compute_reservations WHERE vm_id='{vm_id}'")
            == "6442450944"  # 5 GiB guest drive plus the 1 GiB portable boot bundle.
        )
        assert (
            sql(
                f"SELECT disk_held AND disk_bytes=6442450944 FROM compute_reservations WHERE vm_id='{copied}'"
            )
            == "t"
        )
        assert sql(
            f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{first}' AND released_at IS NULL"
        ) in ("1", "2")
        resume_browser("cancelled")
        browser_signal("revoked")
        assert (
            sql(f"SELECT count(*) FROM access_grants WHERE vm_id='{vm_id}' AND archived_at IS NULL")
            == "0"
        )

    with subtest("revoked requester recovery reclaims only the unfinished copy and proven holds"):
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
        stopped_generation = sql(
            f"SELECT generation FROM compute_virtual_machines WHERE id='{vm_id}'"
        )
        eventually(
            lambda: advance(first, after_public_cancellation=True) == "cancelled", timeout=300
        )
        assert (
            sql(
                f"SELECT desired_state || ':' || observed_state || ':' || generation::text FROM compute_virtual_machines WHERE id='{vm_id}'"
            )
            == "stopped:stopped:" + stopped_generation
        )
        assert operator(
            dict(
                action="lifecycle",
                owner_id=users["owner_id"],
                vm_id=vm_id,
                kind="start",
                key=str(uuid.uuid4()),
            )
        ) == {"requested": True}
        running(vm_id)
        check_guest(host, placement)
        assert workload_identity(vm_id) == source_identity
        assert host.succeed("zfs get -Hp -o value guid " + source_dataset).strip() == source_guid
        host.fail("zfs list " + source_dataset + "@lilly-b")
        copied_host.fail("zfs list " + copied_dataset)
        assert (
            sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{copied}'")
            == "t"
        )
        assert (
            sql(
                f"SELECT temporary_disk_bytes=0 AND disk_held FROM compute_reservations WHERE vm_id='{vm_id}'"
            )
            == "t"
        )
        assert (
            sql(
                f"SELECT NOT compute_held AND NOT disk_held FROM compute_reservations WHERE vm_id='{copied}'"
            )
            == "t"
        )
        assert (
            sql(
                f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{first}' AND released_at IS NULL"
            )
            == "0"
        )
        assert (
            sql(
                f"SELECT count(*) FROM compute_clone_effects WHERE clone_request_id='{first}' AND completed_at IS NOT NULL AND kind IN ('revoke','discard','prune')"
            )
            == "4"
        )
        assert (
            sql(
                f"SELECT count(*) FROM compute_network_addresses WHERE vm_id='{copied}' AND archived_at IS NULL"
            )
            == "0"
        )
        operations_before = sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}'")
        result = operator(dict(action="clone-advance", request_id=queued))
        assert result["phase"] == "failed" and result["failure"] == "forbidden"
        never_allocated = destination(queued)
        assert (
            sql(f"SELECT count(*) FROM compute_virtual_machines WHERE id='{never_allocated}'")
            == "0"
        )
        assert (
            sql(f"SELECT count(*) FROM compute_clone_effects WHERE clone_request_id='{queued}'")
            == "0"
        )
        assert (
            sql(f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{queued}'")
            == "0"
        )
        assert (
            sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}'")
            == operations_before
        )
        check_guest(host, placement)
        sql(
            "DROP TRIGGER fixture_defer_clone_jobs ON oban_jobs; DROP FUNCTION fixture_defer_clone_jobs()"
        )
        resume_browser("revoked")

    with subtest("ordinary automatic dispatch still completes a public clone with copied data"):
        browser_signal("complete")
        control = clone_id("successful-clone-control")
        control_vm = destination(control)
        running(control_vm)
        control_host, control_placement = current_placement(control_vm)
        check_guest(control_host, control_placement)
        assert (
            sql(
                f"SELECT phase='complete' AND published_at IS NOT NULL AND failure IS NULL FROM compute_clone_requests WHERE id='{control}'"
            )
            == "t"
        )
        assert (
            sql(f"SELECT owner_id FROM compute_virtual_machines WHERE id='{control_vm}'")
            == users["owner_id"]
        )
        assert (
            control_host.succeed(
                "zfs get -Hp -o value guid zroot/lilly/vm-" + control_placement
            ).strip()
            != source_guid
        )
        resume_browser("complete")
        client.wait_until_succeeds("test -e " + browser_root + "/done", timeout=30)
        # The transient unit vanishes once the browser exits after "done";
        # stopping it is only needed if it is still running.
        client.succeed(
            "systemctl stop clone-browser-fixture.service"
            " || ! systemctl is-active --quiet clone-browser-fixture.service"
        )
