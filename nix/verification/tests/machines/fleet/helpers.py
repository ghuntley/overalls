from collections.abc import Callable
from typing import Any, Protocol, TypedDict


class HostRef(TypedDict):
    host_id: str


class PlacementRef(HostRef, TypedDict):
    placement_id: str


class ProvisionedPlacement(PlacementRef, TypedDict):
    vm_id: str
    accepted: bool


class ProfiledPlacement(ProvisionedPlacement, TypedDict):
    profile: str


class MachineLike(Protocol):
    name: str

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...

    def fail(self, *commands: str, timeout: int | None = None) -> str: ...

    def execute(
        self,
        command: str,
        check_return: bool = True,
        check_output: bool = True,
        timeout: int | None = 900,
    ) -> tuple[int, str]: ...

    def wait_for_unit(self, unit: str, user: str | None = None, timeout: int = 900) -> None: ...

    def wait_until_succeeds(self, command: str, timeout: int = 900) -> str: ...

    def wait_until_fails(self, command: str, timeout: int = 900) -> str: ...

    def start(self) -> None: ...

    def crash(self) -> None: ...

    def shutdown(self) -> None: ...

    def copy_from_host(self, source: str, target: str) -> None: ...

    def copy_from_machine(self, source: str, target_dir: str = "") -> None: ...


def eventually(probe: Callable[[], object], timeout: float = 120) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(1)
    # Keep credentials, SQL parameters and terminal contents out of diagnostics.
    # Public capacity/freshness evidence explains legitimate pressure or staleness.
    print("Fleet capacity at timeout:", capacity_snapshot())
    raise AssertionError("Fleet condition timed out; private diagnostics withheld")


def request_file(machine: MachineLike, request: dict[str, object]) -> str:
    path = private / f"request-{uuid.uuid4()}.json"
    with open(path, "x", opener=lambda name, flags: os.open(name, flags, 0o600)) as file:
        json.dump(request, file)
    target = f"{root}/{path.name}"
    machine.copy_from_host(str(path), target)
    path.unlink()
    return target


def operator(machine: MachineLike, request: dict[str, object]) -> dict[str, object]:
    path = request_file(machine, request)
    try:
        output = machine.succeed("fleet-op " + shlex.quote(path), timeout=180)
    except Exception:
        print(
            sql_json(
                "SELECT json_agg(json_build_object('id',id,'enabled',enabled,'sequence',report_sequence,"
                "'age',extract(epoch FROM clock_timestamp() - reported_at),'inventory',inventory)) FROM compute_hosts"
            )
        )
        raise
    rows = [
        line.removeprefix("FLEET_OK ")
        for line in output.splitlines()
        if line.startswith("FLEET_OK ")
    ]
    assert len(rows) == 1
    result: dict[str, object] = json.loads(rows[0])
    return result


def durable_service_level_snapshot(
    machine: MachineLike, vm_id: str, *, require_ssh: bool = False
) -> str:
    """@cc [owner:ghuntley,label:verification;accounting] native-slo-fixed-projection
    This fixture MUST validate the fixed numeric-source digest and measurement
    booleans before comparison. It MUST call the production reconciler through
    the DB-sentinel-fenced operator, without fabricating physical/ready receipts.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    result = operator(machine, dict(action="service-levels", vm_id=vm_id))
    measured = result.get("measured")
    ssh_measured = result.get("ssh_measured")
    digest = result.get("totals_digest")
    assert isinstance(measured, bool) and isinstance(ssh_measured, bool)
    assert isinstance(digest, str)
    assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
    return digest if measured and (not require_ssh or ssh_measured) else ""


def sql(statement: str) -> str:
    return db.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc " + shlex.quote(statement)
    ).strip()


def canonical_guest_name(user_id: str) -> str:
    """@cc [owner:ghuntley,label:verification] fleet-durable-guest-name
    Guest logins MUST use the stored current account and match its permanent
    UID; fixture email addresses MUST NOT determine native Linux identity.
    """
    assert str(uuid.UUID(user_id)) == user_id
    query = f"SELECT username,uid FROM account_guest_accounts WHERE user_id='{user_id}' AND retired_at IS NULL"
    eventually(lambda: bool(sql(query)), timeout=60)
    name, raw_uid = sql(query).split("|")
    uid = int(raw_uid)
    assert 200000 <= uid <= 999999 and name == "u" + str(uid)
    return name


def sql_json(statement: str) -> Any:  # noqa: ANN401 - stdlib json.loads boundary
    # Parsed SQL JSON is the same stdlib boundary as json.loads; callers narrow
    # shapes with TypedDicts and runtime assertions at durable helpers.
    return json.loads(sql(statement))


def database_waits() -> object:
    # SQL text and parameters can contain credentials or terminal data. Retain
    # only server wait/lock metadata when a recovery assertion fails.
    return sql_json(
        "SELECT coalesce(json_agg(json_build_object('pid',pid,'application',application_name,"
        "'state',state,'wait_type',wait_event_type,'wait',wait_event,"
        "'transaction_age',extract(epoch FROM clock_timestamp()-xact_start),"
        "'blockers',pg_blocking_pids(pid))), '[]') FROM pg_stat_activity "
        "WHERE datname='marshall' AND application_name LIKE 'marshall:%' AND state <> 'idle'"
    )


def capacity_snapshot() -> object:
    return sql_json(
        "SELECT json_agg(json_build_object('host',h.id,'ready',h.inventory->>'execution_ready',"
        "'host_age',extract(epoch FROM (clock_timestamp() AT TIME ZONE 'UTC')-h.reported_at),"
        "'pool_age',extract(epoch FROM (clock_timestamp() AT TIME ZONE 'UTC')-p.reported_at),"
        "'cores',h.effective_cores,'memory',h.effective_memory_bytes,'free_bytes',p.free_bytes,"
        "'headroom',h.capacity,'pending',(SELECT count(*) FROM compute_reservations r WHERE r.host_id=h.id "
        "AND (r.startup_compute_held OR r.startup_disk_held)),"
        "'overhead_bytes',p.overhead_bytes,"
        "'compute_held',(SELECT count(*) FROM compute_reservations r WHERE r.host_id=h.id AND r.compute_held),"
        "'disk_held',(SELECT count(*) FROM compute_reservations r WHERE r.host_id=h.id AND r.disk_held))) "
        "FROM compute_hosts h JOIN compute_storage_pools p ON p.host_id=h.id"
    )


def synchronized(requests: list[dict[str, object]]) -> list[dict[str, object]]:
    barrier = str(uuid.uuid4())
    directory = Path(m1.shared_dir) / f"fleet-barrier-{barrier}"
    directory.mkdir(mode=0o700)
    with ThreadPoolExecutor(max_workers=3) as executor:
        pending = [
            executor.submit(operator, machine, dict(request, barrier=barrier))
            for machine, request in zip(marshalls, requests, strict=False)
        ]

        def arrived() -> bool:
            assert not any(future.done() for future in pending), (
                "An admission worker failed before the barrier"
            )
            return all((directory / f"m{number}.ready").is_file() for number in [1, 2, 3])

        eventually(arrived)
        # Leave time for the concurrent requests to acquire database locks before
        # the real five-second capacity deadline. Merely fresh-at-release reports
        # can expire in flight and legitimately deny an otherwise available slot.
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' "
                    "AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '3 seconds'"
                )
                == "2"
            )
        )
        print("Capacity before admission barrier:", capacity_snapshot())
        (directory / "release").touch()
        return [future.result(timeout=120) for future in pending]


def enrolled_provisioners() -> list[MachineLike]:
    """Provisioners enrolled at bootstrap time; the replacement host joins later."""
    replacement = globals().get("replacement_host")
    return [m for m in provisioners if m.name != replacement]


def fresh_hosts() -> bool:
    return sql(
        "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' "
        "AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
    ) == str(len(enrolled_provisioners()))


def vm_state(vm: str) -> str:
    assert str(uuid.UUID(vm)) == vm
    return sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm}'")


def await_running(vm: str) -> None:
    started = time.monotonic()
    dumped = False

    def running() -> bool:
        nonlocal dumped
        state = vm_state(vm)
        if (
            state != "running"
            and not dumped
            and (state == "failed" or time.monotonic() - started > 100)
        ):
            dumped = True
            dump_guest_diagnostics(provisioners)
            for machine in provisioners:
                print(
                    machine.succeed(
                        "for cg in /sys/fs/cgroup/lilly.slice/lilly-vm-*.service; do "
                        '[ -d "$cg" ] || continue; echo ===="$cg"; '
                        'cat "$cg/cgroup.procs" 2>/dev/null || true; '
                        "done"
                    )
                )
        if state == "failed":
            print(
                sql_json(
                    f"SELECT json_agg(json_build_object('vm_id',v.id,'host_id',p.host_id,'reason',v.failure_reason)) "
                    f"FROM compute_virtual_machines v JOIN compute_workload_placements p "
                    f"ON p.id=v.current_placement_id WHERE v.id='{vm}'"
                )
            )
            placement = sql(
                f"SELECT current_placement_id FROM compute_virtual_machines WHERE id='{vm}'"
            )
            if placement and placement != "":
                for machine in provisioners:
                    print(
                        machine.succeed(
                            "for pid in $(find /sys/fs/cgroup/lilly.slice -path '*lilly-vm-*' -name cgroup.procs -exec cat {} + 2>/dev/null); "
                            "do printf '%s ' \"$pid\"; cat /proc/$pid/comm 2>/dev/null || true; "
                            "readlink /proc/$pid/exe 2>/dev/null || true; done"
                        )
                    )
        assert state != "failed", "Real guest launch failed"
        return state == "running"

    # Initial/copy-time digest verification reads the actual image over the
    # framework's shared store; retain it and give real nested launches a bound.
    eventually(running, timeout=600)


def provision(
    profile: str,
    key: str | None = None,
    disk_bytes: int | None = None,
    memory_bytes: int | None = None,
) -> dict[str, object]:
    request: dict[str, object] = dict(
        action="provision",
        owner_id=users["owner_id"],
        image_id=users["image_id"],
        profile=profile,
        key=key or str(uuid.uuid4()),
    )
    if disk_bytes is not None:
        request["disk_bytes"] = disk_bytes
    if memory_bytes is not None:
        request["memory_bytes"] = memory_bytes
    return request


def provision_when_available(
    machine: MachineLike,
    profile: str,
    disk_bytes: int | None = None,
    memory_bytes: int | None = None,
) -> ProvisionedPlacement:
    # Boot completion can precede idle measured usage. Setup may retry only a
    # capacity refusal; admission races use synchronized() without these retries.
    request = provision(profile, disk_bytes=disk_bytes, memory_bytes=memory_bytes)
    accepted = []

    def attempt() -> bool:
        result = operator(machine, request)
        if result["accepted"]:
            accepted.append(result)
            return True
        assert result["reason"] == "insufficient_capacity", result
        return False

    eventually(attempt, timeout=180)
    return accepted_placement(accepted[0])


def accepted_placement(result: dict[str, object]) -> ProvisionedPlacement:
    assert result["accepted"]
    return ProvisionedPlacement(
        vm_id=str(uuid.UUID(str(result["vm_id"]))),
        host_id=str(uuid.UUID(str(result["host_id"]))),
        placement_id=str(uuid.UUID(str(result["placement_id"]))),
        accepted=True,
    )


def lifecycle(vm: str, kind: str) -> None:
    # @cc [owner:ghuntley,label:verification] fleet-restart-capacity-retry
    # Restart setup MUST retry only explicit capacity refusals with the same
    # request key and a bounded deadline; every other failure MUST fail the test.
    # Retained disks still need fresh full-shape compute headroom on restart.
    # A restart needs a host report inside the 5s capacity window; a transient
    # control-plane stall can age a live host's report past it, which Marshall
    # refuses as host_unavailable. The operator reports that only as
    # host_report_stale after proving the host is still enabled, normal-mode and
    # execution-ready, so it is retried like a capacity refusal.
    request = dict(
        action="lifecycle", owner_id=users["owner_id"], vm_id=vm, kind=kind, key=str(uuid.uuid4())
    )

    def attempt() -> bool:
        result = operator(m2, request)
        if result["requested"]:
            return True
        assert kind == "start" and result["reason"] in (
            "insufficient_capacity",
            "host_report_stale",
        ), result
        return False

    eventually(attempt, timeout=180)


def host_for(vm: HostRef) -> MachineLike:
    return next(
        machine for machine in provisioners if host_bindings[machine.name]["host"] == vm["host_id"]
    )


def process_snapshot(vm: PlacementRef) -> list[object]:
    snapshot: list[object] = json.loads(
        host_for(vm).succeed("fleet-processes " + shlex.quote(vm["placement_id"]))
    )
    return snapshot


def host_identity(machine: MachineLike) -> dict[str, object]:
    try:
        identity: dict[str, object] = json.loads(machine.succeed("fleet-host-identity"))
        return identity
    except Exception:
        # Storage metadata is public; no credential or console file is read.
        print(
            machine.succeed(
                "findmnt -J -T /var/lib/lilly/pool -o FSTYPE,SOURCE,TARGET,FSROOT,OPTIONS"
            )
        )
        print(machine.succeed("zfs get -Hp all zroot/lilly"))
        print(machine.succeed("zpool status -jLPp zroot"))
        raise
