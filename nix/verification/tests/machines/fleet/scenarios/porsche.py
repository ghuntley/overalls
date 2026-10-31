# @cc [owner:ghuntley,label:verification;security] fleet-porsche-real-command-path
# SSH mutations MUST traverse native OpenSSH, the packaged gateway, verified
# Marshall HTTPS and actual Ash/Oban/Lilly execution. Guest completion MUST be
# checked against native process/storage evidence, never injected outcomes.
# Browser login tokens and unknown-key approval URLs MUST remain private.
from typing import Literal, TypedDict, overload


class PorscheResult(TypedDict, total=False):
    id: str
    destination_vm_id: str
    host: str


class PorscheReceipt(TypedDict, total=False):
    status: str
    error: str
    operation_id: str
    result: PorscheResult


class NativeBootObservation(TypedDict):
    intent_readable: bool
    boot_readable: bool
    intent_present: bool
    boot_present: bool
    intent_running: bool
    placement_matches: bool
    epoch_matches: bool
    generation_matches: bool
    current_boot: bool


def native_boot_flag(value: object) -> bool:
    if not isinstance(value, bool):
        raise AssertionError("invalid native boot observation flag")
    return value


def native_boot_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid native boot observation object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid native boot observation key")
        result[key] = item
    return result


def native_boot_observations(value: object) -> list[NativeBootObservation]:
    """@cc [owner:ghuntley,label:verification;security] clone-boot-diagnostic-schema
    External observations MUST contain exactly thirty objects with the nine
    boolean fields below. Unknown fields or other types MUST fail before output;
    this diagnostic MUST NOT establish readiness or replace a native assertion.
    """
    if not isinstance(value, list) or len(value) != 30:
        raise AssertionError("invalid native boot observations")
    fields: set[str] = {
        "intent_readable",
        "boot_readable",
        "intent_present",
        "boot_present",
        "intent_running",
        "placement_matches",
        "epoch_matches",
        "generation_matches",
        "current_boot",
    }
    result: list[NativeBootObservation] = []
    for raw_observation in value:
        observation = native_boot_object(raw_observation)
        if set(observation) != fields:
            raise AssertionError("invalid native boot observation fields")
        result.append(
            NativeBootObservation(
                intent_readable=native_boot_flag(observation.get("intent_readable")),
                boot_readable=native_boot_flag(observation.get("boot_readable")),
                intent_present=native_boot_flag(observation.get("intent_present")),
                boot_present=native_boot_flag(observation.get("boot_present")),
                intent_running=native_boot_flag(observation.get("intent_running")),
                placement_matches=native_boot_flag(observation.get("placement_matches")),
                epoch_matches=native_boot_flag(observation.get("epoch_matches")),
                generation_matches=native_boot_flag(observation.get("generation_matches")),
                current_boot=native_boot_flag(observation.get("current_boot")),
            )
        )
    return result


with subtest("Porsche browser keys and native SSH execute real guest lifecycle"):
    porsche_root = "/var/lib/fleet-porsche"
    m1.succeed(f"fleet-op gateway-prepare {root}/porsche.token")
    m1.succeed(f"fleet-op gateway-configure fleet {root}/porsche.token")
    m1.succeed("systemctl start porsche.service")
    m1.wait_for_open_port(22)
    client.succeed(f"install -d -m 700 -o tester -g users {porsche_root} /home/tester/.pki/nssdb")
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {porsche_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n fleet-root -t 'C,,' -i {porsche_root}/ca.crt"
    )
    for role in ("owner", "member", "stranger"):
        client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {porsche_root}/{role}")
    host_key = m1.succeed("cat /var/lib/porsche/keys/ssh_host_ed25519_key.pub").strip()
    host_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    assert host_key.split()[:2] != host_ca.split()[:2]
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority control.example.test " + host_ca)
        + f" >{porsche_root}/known_hosts"
    )

    def porsche_browser(mode: str) -> None:
        operator(
            m1,
            dict(
                action="refresh-browser-tokens",
                source=root + "/users.json",
                output=root + "/porsche-users-" + mode + ".json",
            ),
        )
        transfer(
            m1, root + "/porsche-users-" + mode + ".json", client, porsche_root + "/users.json"
        )
        client.succeed(
            f"chown tester:users {porsche_root}/users.json && chmod 600 {porsche_root}/users.json"
        )
        client.succeed(
            "sudo -u tester env HOME=/home/tester fleet-porsche-browser " + mode, timeout=120
        )

    porsche_browser("add")

    def porsche_arguments(command: str, role: str = "owner") -> list[str]:
        control = ["-S", porsche_root + "/control"] if role == "stranger" else []
        # Transient systemd units do not inherit the interactive user's PATH.
        return [
            "/run/current-system/sw/bin/ssh",
            *control,
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
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UserKnownHostsFile=" + porsche_root + "/known_hosts",
            "-o",
            "HostKeyAlias=control.example.test",
            "-i",
            porsche_root + "/" + role,
            "fixture@m1",
            command + " --json",
        ]

    @overload
    def porsche_command(
        command: str,
        role: str = ...,
        accepted: Literal[True] = ...,
        allow_clone_capacity: bool = ...,
    ) -> PorscheReceipt: ...

    @overload
    def porsche_command(
        command: str,
        role: str = ...,
        accepted: Literal[False] = ...,
        allow_clone_capacity: bool = ...,
    ) -> None: ...

    def porsche_command(
        command: str,
        role: str = "owner",
        accepted: bool = True,
        allow_clone_capacity: bool = False,
    ) -> PorscheReceipt | None:
        """@cc [owner:ghuntley,label:verification] porsche-restart-fresh-observations
        Lifecycle setup MUST observe fresh native host readiness before start.
        It MUST retain one request ID and retry only explicit pre-admission
        capacity or unavailable-host refusal within a bounded deadline;
        unexpected failures expose bounded state diagnostics and still fail.
        Share mutations also retain one request ID and retry only a transient
        Porsche-to-Marshall transport or availability failure within the same
        deadline, so a replay is deduplicated by that ID.
        """
        # Capture rejected exec output inside the VM: an unknown key can receive
        # a private browser approval URL, which must never enter driver output.
        # Native restarts recheck measured headroom. Retry only a pre-admission
        # capacity/host refusal, with one retained public request ID and a deadline.
        restarting = command.startswith("start ")
        # A share mutation replayed with its retained request ID is idempotent.
        replayable = accepted and command.startswith(("share add ", "share remove "))
        if (restarting or replayable) and "--request-id" not in command:
            command += " --request-id " + str(uuid.uuid4())
        if restarting:
            eventually(fresh_hosts)
        arguments = porsche_arguments(command, role)
        program = (
            "import subprocess,json,sys; r=subprocess.run("
            + repr(arguments)
            + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=660); "
            + (
                "v=json.loads(r.stdout); detail=v.get('result',{}); "
                "e=v.get('error'); failure=detail.get('failure') if isinstance(detail,dict) else None; "
                "capacity_clone=" + repr(allow_clone_capacity) + " and v.get('status')=='failed' "
                "and detail.get('phase')=='failed' and failure=='insufficient_capacity' "
                "and detail.get('active') is False and detail.get('published_at') is None; "
                "reason=e or failure; reason=reason if reason in ("
                "'insufficient_capacity','host_unavailable',"
                "'host_not_ready','invalid_state','unauthorized','request_conflict','operation_failed',"
                "'timeout','unavailable','not_found','request_failed','invalid_request','forbidden',"
                "'conflict','clone_not_supported','clone_already_published','clone_not_retryable',"
                "'clone_in_progress','idempotency_conflict','rate_limited','unsupported_version',"
                "'workload_not_stable','source_unavailable','transfer_busy','resize_in_progress',"
                "'relocation_in_progress','relocation_committed','relocation_finished',"
                "'relocation_retry_unavailable','placement_changed',"
                "'temporarily_unavailable','http_error','transport_error','invalid_response',"
                "'message_too_large') else 'redacted'; "
                "assert (r.returncode == 0 and v.get('status')=='succeeded') or "
                "e in ('insufficient_capacity','host_unavailable') or capacity_clone "
                "or (" + repr(replayable) + " and e in ('transport_error','unavailable',"
                "'temporarily_unavailable')), "
                "'SSH command failed: '+reason; "
                "print(json.dumps(v))"
                if accepted
                else "assert r.returncode != 0, 'Unauthorized command succeeded'"
            )
        )
        results = []

        def attempt() -> bool:
            if restarting and not fresh_hosts():
                return False
            try:
                output = client.succeed(
                    "sudo -u tester python3 -c " + shlex.quote(program), timeout=680
                )
            except Exception:
                print("Porsche failure capacity:", capacity_snapshot())
                print(
                    "Porsche failure lifecycle state:",
                    sql_json(
                        "SELECT json_agg(json_build_object('vm_id',v.id,"
                        "'generation',v.generation,'desired',v.desired_state,"
                        "'observed',v.observed_state,'archived',v.archived_at IS NOT NULL,"
                        "'placement_id',v.current_placement_id,'disk_held',r.disk_held,"
                        "'compute_held',r.compute_held)) FROM compute_virtual_machines v "
                        "LEFT JOIN compute_reservations r ON r.placement_id=v.current_placement_id"
                    ),
                )
                raise
            value = json.loads(output) if accepted else None
            if value and value.get("error") in ("insufficient_capacity", "host_unavailable"):
                assert restarting, "Unexpected admission refusal"
                return False
            if (
                value
                and replayable
                and value.get("error")
                in (
                    "transport_error",
                    "unavailable",
                    "temporarily_unavailable",
                )
            ):
                return False
            assert not accepted or (
                value is not None
                and (
                    value.get("status") == "succeeded"
                    or (allow_clone_capacity and value.get("status") == "failed")
                )
            ), "SSH did not complete"
            results.append(value)
            return True

        eventually(attempt, timeout=180)
        return results[0]

    def porsche_placement(vm: str) -> PlacementRef:
        value = sql_json(
            "SELECT json_build_object('placement_id',p.id,'host_id',p.host_id) "
            "FROM compute_virtual_machines v JOIN compute_workload_placements p "
            f"ON p.id=v.current_placement_id WHERE v.id='{vm}'"
        )
        assert isinstance(value, dict)
        return PlacementRef(
            placement_id=str(uuid.UUID(str(value["placement_id"]))),
            host_id=str(uuid.UUID(str(value["host_id"]))),
        )

    # @cc [owner:ghuntley,label:verification;capacity] porsche-source-preflight-is-observational
    # Waiting MUST observe real source readiness/hold predicates without changing
    # authority. Timeouts MUST expose only the fixed boolean schema; passing
    # preflight cannot substitute for actual public admission or its guards.
    def await_porsche_source(vm: str) -> None:
        # Read current source predicates before the single public admission.
        # This cannot supply authority or retry a refused relocation receipt.
        source_flags = (
            "stable_power",
            "operations_settled",
            "host_enabled",
            "host_normal",
            "endpoint_valid",
            "architecture_matches",
            "execution_ready",
            "host_fresh",
            "pool_fresh",
            "reports_recent",
            "pool_zfs",
            "pool_space_known",
            "disk_held",
            "temporary_disk_settled",
            "compute_hold_matches",
        )
        observed_source: dict[str, bool] = {}

        def source_ready() -> bool:
            observed = operator(m1, dict(action="relocation-source-observations", vm_id=vm))
            assert set(observed) == set(source_flags)
            observed_source.update(
                {flag: native_boot_flag(observed.get(flag)) for flag in source_flags}
            )
            return all(observed_source.values())

        try:
            eventually(source_ready, timeout=180)
        except Exception:
            print("Porsche source predicate observations:", observed_source)
            raise

    # @cc [owner:ghuntley,label:verification;recovery] porsche-clone-relocation-replay
    # Each clone move MUST use the public Porsche relocation command without a
    # destination, replay its exact request ID to the same operation, observe a
    # different current host and placement, boot and verify the real guest, and
    # confirm that the former host no longer retains the source ZFS dataset.
    def relocate_porsche_clone(name: str, vm: str, current: PlacementRef) -> PlacementRef:
        source_machine = host_for(current)
        source_child = "zroot/lilly/vm-" + current["placement_id"]
        source_host_name = porsche_command("show " + name)["result"]["host"]
        await_porsche_source(vm)
        request_id = str(uuid.uuid4())
        command = f"relocate {name} --request-id {request_id} --timeout 600"
        receipt = porsche_command(command)
        operation_id = str(uuid.UUID(receipt["operation_id"]))
        assert (
            sql(
                "SELECT count(*) FROM ssh_requests "
                f"WHERE request_id='{request_id}' AND relocation_id='{operation_id}'"
            )
            == "1"
        )
        assert porsche_command(command)["operation_id"] == operation_id
        destination = porsche_placement(vm)
        assert destination["host_id"] != current["host_id"]
        assert destination["placement_id"] != current["placement_id"]
        await_running(vm)
        destination_host_name = porsche_command("show " + name)["result"]["host"]
        assert destination_host_name and destination_host_name != source_host_name
        host_for(destination).wait_until_succeeds(
            "fleet-relocation-guest verify " + destination["placement_id"], timeout=240
        )
        source_machine.fail("zfs list " + source_child)
        return destination

    master = [*porsche_arguments("whoami", "stranger")[:-2], "-M", "-N", "-f", "fixture@m1"]
    # A background control master must not retain the test driver's stdout pipe.
    client.succeed("sudo -u tester " + shlex.join(master) + " >/dev/null 2>&1", timeout=30)
    pending_program = (
        "import subprocess,json,os; r=subprocess.run("
        + repr(porsche_arguments("new --name must-not-exist --no-wait", "stranger"))
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30); "
        "assert r.returncode != 0; v=json.loads(r.stdout); "
        "assert v.get('status') == 'approval_required'; "
        "f=os.open('/var/lib/fleet-porsche/pending.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); "
        "os.write(f,json.dumps(v).encode()); os.close(f)"
    )
    client.succeed("sudo -u tester python3 -c " + shlex.quote(pending_program))
    assert sql("SELECT count(*) FROM compute_virtual_machines WHERE name='must-not-exist'") == "0"
    porsche_browser("approve")
    approved_user = client.succeed(
        "sudo -u tester python3 -c "
        + shlex.quote(
            "import json; print(json.load(open('/var/lib/fleet-porsche/users.json'))['stranger_id'])"
        )
    ).strip()
    assert porsche_command("whoami", role="stranger")["result"]["id"] == approved_user
    client.succeed(
        "sudo -u tester "
        + shlex.join([*porsche_arguments("whoami", "stranger")[:-2], "-O", "exit", "fixture@m1"])
    )

    assert porsche_command("whoami")["status"] == "succeeded"
    # @cc [owner:ghuntley,label:verification] porsche-native-source-after-authorized-dispatch
    # The focused native SLO check stops here after real key approval and SSH
    # dispatch. The following physical VM workflows retain their separate scope.
    client.succeed(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/docs.md >/dev/null"
    )
    client.succeed(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/llms.txt >/dev/null"
    )
    request = str(uuid.uuid4())
    creation = f"new --profile standard --name porsche-fleet --cpu 2 --image {users['image_id']} --timeout 600 --request-id {request}"
    # The first native client waits for physical completion. Kill the gateway
    # only after PostgreSQL proves durable admission, and require that this
    # client received no final command result. Recovery retries the same ID.
    interrupted = (
        "import subprocess; r=subprocess.run("
        + repr(porsche_arguments(creation))
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=660); "
        "assert r.returncode != 0 and not r.stdout, 'Expected lost SSH result'"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=fleet-porsche-interrupted "
        "--property=User=tester --property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null "
        "/run/current-system/sw/bin/python3 -c " + shlex.quote(interrupted)
    )
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM ssh_requests WHERE request_id='{request}' AND status='accepted'"
            )
            == "1"
        )
    )
    recorded = sql_json(
        f"SELECT json_build_object('vm_id',vm_id,'operation_id',operation_id) "
        f"FROM ssh_requests WHERE request_id='{request}'"
    )
    assert isinstance(recorded, dict)
    admitted = {
        "vm_id": str(recorded["vm_id"]),
        "operation_id": str(recorded["operation_id"]),
    }
    m1.succeed("systemctl kill --signal=SIGKILL --kill-whom=main porsche.service")
    client.wait_for_unit("fleet-porsche-interrupted.service", timeout=30)
    m1.succeed("systemctl restart marshall-m1.service")
    m1.wait_for_unit("porsche.service")
    m1.wait_for_open_port(22)
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
        timeout=60,
    )
    assert m1.succeed("cat /var/lib/porsche/keys/ssh_host_ed25519_key.pub").strip() == host_key
    created = porsche_command(creation)
    vm_id = created["result"]["id"]
    assert isinstance(vm_id, str)
    porsche_vm_id = vm_id
    assert vm_id == admitted["vm_id"] and created["operation_id"] == admitted["operation_id"]
    assert str(uuid.UUID(vm_id)) == vm_id
    assert porsche_command(creation)["result"]["id"] == vm_id
    assert (
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{vm_id}' AND kind='provision'")
        == "1"
    )
    await_running(vm_id)
    placement = sql_json(
        f"SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        f"FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    machine = host_for(placement)
    if ubuntu_enabled:
        machine.succeed(
            "fleet-relocation-guest ubuntu-check " + placement["placement_id"], timeout=180
        )
    process_snapshot(placement)
    child = "zroot/lilly/vm-" + placement["placement_id"]
    disk_identity = machine.succeed(f"zfs get -Hp -o value guid {child}").strip()
    source_host_name = porsche_command("show porsche-fleet")["result"]["host"]
    assert source_host_name
    porsche_command("share add porsche-fleet " + str(users["member_email"]) + " viewer")
    assert (
        porsche_command("show porsche-fleet", role="member")["result"]["host"] == source_host_name
    )
    porsche_command("stop porsche-fleet", role="member", accepted=False)
    porsche_command("share remove porsche-fleet " + str(users["member_email"]))
    porsche_command("show porsche-fleet", role="member", accepted=False)
    porsche_command("stop porsche-fleet --timeout 600")
    assert vm_state(vm_id) == "stopped"
    machine.fail("systemctl is-active lilly-vm-" + placement["placement_id"] + ".service")
    assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == disk_identity
    porsche_command("start porsche-fleet --timeout 600")
    await_running(vm_id)
    process_snapshot(placement)
    # Porsche exposes relocation without placement input. Marshall must choose a
    # different host, retain the request identity and preserve guest data.
    # @cc [owner:ghuntley,label:verification] porsche-relocation-guest-readiness
    # A running control-plane observation MAY precede guest SSH readiness.
    # Physical relocation assertions MUST retry the real guest probe within a
    # fixed bound; they MUST NOT inject readiness or bypass guest execution.
    machine.wait_until_succeeds(
        "fleet-relocation-guest prepare " + placement["placement_id"], timeout=240
    )
    machine.wait_until_succeeds(
        "fleet-relocation-guest before-stop " + placement["placement_id"], timeout=240
    )
    source_machine = machine
    source_child = child
    relocation_key = str(uuid.uuid4())
    relocation_command = f"relocate porsche-fleet --request-id {relocation_key} --timeout 600"
    await_porsche_source(vm_id)
    moved = porsche_command(relocation_command)
    relocation_id = str(uuid.UUID(moved["operation_id"]))
    assert (
        sql(
            "SELECT count(*) FROM ssh_requests "
            f"WHERE request_id='{relocation_key}' AND relocation_id='{relocation_id}'"
        )
        == "1"
    )
    assert porsche_command(relocation_command)["operation_id"] == relocation_id
    relocated = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert relocated["host_id"] != placement["host_id"]
    await_running(vm_id)
    destination_host_name = porsche_command("show porsche-fleet")["result"]["host"]
    assert destination_host_name and destination_host_name != source_host_name
    host_for(relocated).wait_until_succeeds(
        "fleet-relocation-guest verify " + relocated["placement_id"], timeout=240
    )
    source_machine.fail("zfs list " + source_child)
    placement = relocated
    machine = host_for(placement)
    child = "zroot/lilly/vm-" + placement["placement_id"]
    disk_identity = machine.succeed(f"zfs get -Hp -o value guid {child}").strip()
    process_snapshot(placement)
    # Independent cross-host copy through the actual public SSH/Ash/Oban path.
    # The two-vCPU source restart hold forces the clone onto the other provisioner.
    # @cc [owner:ghuntley,label:verification] porsche-clone-preflight-requested-shape
    # The CPU preflight MUST derive its threshold from the source VM's requested
    # vCPUs. It MUST NOT substitute for production admission or fabricate capacity.
    # Match the requested whole-core shape, not an unrelated idle-host target.
    # These hosts have zero configured overhead; real admission still checks
    # memory, disk, freshness and holds before allocating either copy.
    required_millicores = (
        int(sql(f"SELECT vcpu FROM compute_virtual_machines WHERE id='{vm_id}'")) * 1000
    )
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE enabled AND "
                "reported_at > now() - interval '10 seconds' AND "
                f"(capacity->>'cpu_headroom_millicores')::bigint >= {required_millicores}"
            )
            == "2"
        ),
        timeout=180,
    )
    clone_key = str(uuid.uuid4())
    clone_command = (
        f"clone porsche-fleet --name porsche-ssh-copy --request-id {clone_key} --timeout 600"
    )
    # @cc [owner:ghuntley,label:verification;recovery] clone-capacity-retry-before-physical-work
    # Only a failed, inactive insufficient_capacity clone with no source operation,
    # snapshot, destination or transfer slots may be retried. Use the public retry
    # command for the same clone identity with bounded admission attempts. Never
    # retry physical failures, fabricate headroom or submit another clone.
    clone_attempt: dict[str, object] = {
        "command": clone_command,
        "id": None,
        "destination": None,
        "receipt": None,
    }
    clone_source_processes = process_snapshot(placement)

    def porsche_receipt(command: str) -> dict[str, object]:
        arguments = porsche_arguments(command)
        program = (
            "import subprocess,json; r=subprocess.run("
            + repr(arguments)
            + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=40); "
            "v=json.loads(r.stdout); assert isinstance(v,dict); print(json.dumps(v))"
        )
        raw: object = json.loads(
            client.succeed("sudo -u tester python3 -c " + shlex.quote(program), timeout=50)
        )
        assert isinstance(raw, dict) and all(isinstance(key, str) for key in raw)
        return {str(key): value for key, value in raw.items()}

    # @cc [owner:ghuntley,label:verification;recovery] published-clone-native-recovery
    # A real failed source launch MUST leave a published independent destination
    # and occupied slots. Transfers from that other VM must remain blocked until
    # public retry restores the source and completes physical cleanup. Never
    # synthesize outcomes, clear slots or replace the original clone identity.
    published_source: str = vm_id

    def recover_published_clone() -> None:
        await_porsche_source(published_source)
        machine.succeed(
            "printf %s " + shlex.quote(placement["placement_id"]) + " > /run/clone-restart-fault"
        )
        command = f"clone porsche-fleet --name porsche-ssh-copy --request-id {clone_key} --no-wait"
        receipt = porsche_receipt(command)
        assert receipt["status"] in ("accepted", "running", "succeeded")

        def published_restart_failure() -> bool:
            phase = sql("SELECT phase FROM compute_clone_requests WHERE name='porsche-ssh-copy'")
            if phase == "failed":
                reason = sql(
                    "SELECT failure FROM compute_clone_requests WHERE name='porsche-ssh-copy'"
                )
                label = (
                    reason
                    if reason
                    in (
                        "insufficient_capacity",
                        "source_unavailable",
                        "workload_not_stable",
                        "transfer_busy",
                        "invalid_state",
                        "clone_not_supported",
                    )
                    else "redacted"
                )
                raise AssertionError("Published clone admission failed: " + label)
            return (
                sql(
                    "SELECT count(*) FROM compute_clone_requests WHERE "
                    "name='porsche-ssh-copy' AND active AND phase='cleaning' "
                    "AND published_at IS NOT NULL AND source_restored_at IS NULL "
                    "AND failure='source_restart_failed'"
                )
                == "1"
            )

        eventually(published_restart_failure, timeout=600)
        identity = sql("SELECT id FROM compute_clone_requests WHERE name='porsche-ssh-copy'")
        destination = sql(
            f"SELECT destination_vm_id FROM compute_clone_requests WHERE id='{identity}'"
        )
        await_running(destination)
        copy = porsche_placement(destination)
        host_for(copy).wait_until_succeeds(
            "fleet-relocation-guest verify " + copy["placement_id"], timeout=240
        )
        copy_processes = process_snapshot(copy)
        machine.succeed("test -f /run/clone-restart-fault-fired")
        machine.fail("systemctl is-active lilly-vm-" + placement["placement_id"] + ".service")
        assert (
            sql(
                f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{identity}' "
                "AND released_at IS NULL"
            )
            == "2"
        )
        refusal = porsche_receipt(
            f"relocate porsche-ssh-copy --request-id {uuid.uuid4()} --no-wait"
        )
        # Only finite refusal labels may enter diagnostics; preserve the exact
        # expected refusal instead of accepting a neighboring admission failure.
        refusal_error = refusal.get("error")
        refusal_reason = (
            refusal_error
            if refusal_error
            in (
                "transfer_busy",
                "source_unavailable",
                "workload_not_stable",
                "host_unavailable",
                "insufficient_capacity",
                "transport_error",
                "unavailable",
                "unauthorized",
                "forbidden",
                "request_conflict",
                "operation_failed",
            )
            else "redacted"
        )
        assert refusal_error == "transfer_busy", "Published clone relocation refusal: " + str(
            refusal_reason
        )
        blocked_key = str(uuid.uuid4())
        porsche_receipt(
            f"clone porsche-ssh-copy --name blocked-by-restoration --request-id {blocked_key} --no-wait"
        )
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_clone_requests "
                    "WHERE name='blocked-by-restoration' AND phase='failed' "
                    "AND failure='source_unavailable'"
                )
                == "1"
            )
        )
        assert process_snapshot(copy) == copy_processes
        machine.succeed("rm /run/clone-restart-fault")
        retry_key = str(uuid.uuid4())
        retry_command = f"request retry {clone_key} --request-id {retry_key} --timeout 600"
        retry = porsche_command(retry_command)
        assert retry["result"]["id"] == identity
        assert retry["result"]["destination_vm_id"] == destination
        with subtest("native retry measurement survives exact receipt replay"):
            retry_measurement = workflow_measurement(retry_key, "porsche_retry", identity)
            assert porsche_command(retry_command)["result"]["id"] == identity
            assert workflow_measurement(retry_key, "porsche_retry", identity) == retry_measurement
        await_running(porsche_vm_id)
        machine.wait_until_succeeds(
            "fleet-relocation-guest verify " + placement["placement_id"], timeout=240
        )
        assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == disk_identity
        assert (
            sql(
                f"SELECT count(*) FROM compute_clone_requests WHERE id='{identity}' "
                "AND phase='complete' AND source_restored_at IS NOT NULL AND NOT active"
            )
            == "1"
        )
        assert (
            sql(
                f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{identity}' "
                "AND released_at IS NULL"
            )
            == "0"
        )
        machine.fail("zfs list " + child + "@lilly-b")
        assert process_snapshot(copy) == copy_processes

    def workflow_measurement(
        request_id: str, service: Literal["porsche_retry", "porsche_cancel"], workflow_id: str
    ) -> str:
        """@cc [owner:ghuntley,label:verification;accounting] native-workflow-receipt-accounting
        A native retry/cancel MUST have exactly one successful terminal measurement
        bound to its public request ID and clone identity within its original deadline.
        The production reconciler MUST supply outcomes without fixture mutation.
        Replaying the same command MUST preserve the measurement and source totals.
        """
        assert str(uuid.UUID(request_id)) == request_id
        assert str(uuid.UUID(workflow_id)) == workflow_id
        operator(m1, dict(action="service-levels", vm_id=vm_id))
        predicate = (
            "FROM compute_workflow_service_level_attempts a "
            "JOIN ssh_requests r ON r.id=a.request_id "
            f"WHERE r.request_id='{request_id}' AND a.service='{service}' "
            f"AND a.workflow_type='clone' AND a.workflow_id='{workflow_id}' "
            "AND a.status='finished' AND a.success AND a.excluded_outcome IS NULL "
            "AND a.completed_at >= a.admitted_at AND a.completed_at <= a.deadline "
            "AND a.duration_us >= 0"
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_workflow_service_level_attempts a "
                "JOIN ssh_requests r ON r.id=a.request_id "
                f"WHERE r.request_id='{request_id}'"
            )
            == "1"
        )
        assert sql("SELECT count(*) " + predicate) == "1"
        assert (
            sql(
                "SELECT count(*) FROM compute_service_level_totals "
                f"WHERE service='{service}' AND requests > 0 "
                "AND requests=successes+failures "
                "AND requests=(SELECT sum(value) FROM unnest(bucket_counts) value) "
                "AND successes=(SELECT count(*) FROM compute_workflow_service_level_attempts a "
                f"WHERE a.service='{service}' AND a.status='finished' AND a.success)"
            )
            == "1"
        )
        return (
            sql("SELECT md5(to_jsonb(a)::text) " + predicate)
            + ":"
            + sql(
                "SELECT md5(to_jsonb(t)::text) FROM compute_service_level_totals t "
                f"WHERE service='{service}'"
            )
        )

    if cloning_enabled:
        recover_published_clone()

    def complete_clone() -> bool:
        value = porsche_command(str(clone_attempt["command"]), allow_clone_capacity=True)
        result = value["result"]
        assert isinstance(result, dict)
        identity = str(uuid.UUID(result["id"]))
        destination = str(uuid.UUID(result["destination_vm_id"]))
        if clone_attempt["id"] is not None:
            assert (identity, destination) == (
                clone_attempt["id"],
                clone_attempt["destination"],
            )
        clone_attempt.update(id=identity, destination=destination)
        if value["status"] == "failed":
            assert (
                sql(
                    "SELECT count(*) FROM compute_clone_requests WHERE "
                    f"id='{identity}' AND phase='failed' AND failure='insufficient_capacity' "
                    "AND NOT active AND source_operation_id IS NULL AND snapshot IS NULL "
                    "AND published_at IS NULL"
                )
                == "1"
            )
            assert (
                sql(f"SELECT count(*) FROM compute_virtual_machines WHERE id='{destination}'")
                == "0"
            )
            assert (
                sql(
                    f"SELECT count(*) FROM compute_transfer_slots WHERE clone_request_id='{identity}'"
                )
                == "0"
            )
            assert process_snapshot(placement) == clone_source_processes
            machine.fail("zfs list " + child + "@lilly-b")
            clone_attempt["command"] = (
                f"request retry {clone_key} --request-id {uuid.uuid4()} --timeout 600"
            )
            return False
        clone_attempt["receipt"] = value
        return True

    eventually(complete_clone, timeout=180)
    copied = clone_attempt["receipt"]
    assert isinstance(copied, dict), "successful clone must retain its receipt"
    result = copied["result"]
    assert isinstance(result, dict)
    copy_id = result["destination_vm_id"]
    assert porsche_command(str(clone_attempt["command"]))["result"]["destination_vm_id"] == copy_id
    original_receipt = porsche_command(clone_command, allow_clone_capacity=True)
    assert original_receipt is not None
    prior = original_receipt["result"]
    assert isinstance(prior, dict)
    assert prior["id"] == result["id"]
    assert prior["destination_vm_id"] == copy_id
    copy_placement = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{copy_id}'"
    )
    assert copy_placement["host_id"] != placement["host_id"]
    await_running(copy_id)
    host_for(copy_placement).wait_until_succeeds(
        "fleet-relocation-guest verify " + copy_placement["placement_id"], timeout=240
    )
    original_copy_placement = copy_placement
    copy_machine = host_for(copy_placement)
    copy_child = "zroot/lilly/vm-" + copy_placement["placement_id"]
    # @cc [owner:ghuntley,label:verification] clone-retained-shape-oracle
    # The destination row MUST equal the source's captured architecture, image,
    # profile and requested sizes; catalog state and defaults MUST NOT
    # re-derive any of them for either side.
    shape_columns = (
        "'architecture',architecture,'image_id',image_id,'profile',profile,"
        "'vcpu',vcpu,'memory_bytes',memory_bytes,'disk_bytes',disk_bytes"
    )
    assert sql_json(
        f"SELECT jsonb_build_object({shape_columns}) "
        f"FROM compute_virtual_machines WHERE id='{vm_id}'"
    ) == sql_json(
        f"SELECT jsonb_build_object({shape_columns}) "
        f"FROM compute_virtual_machines WHERE id='{copy_id}'"
    )
    # @cc [owner:ghuntley,label:verification;storage] clone-native-storage-independence
    # An adopted destination MUST be a full copy: empty ZFS origin on both
    # sides, distinct dataset GUIDs, and no sibling dataset visibility from the
    # other host.
    assert machine.succeed(f"zfs get -Hp -o value origin {child}").strip() == "-"
    assert copy_machine.succeed(f"zfs get -Hp -o value origin {copy_child}").strip() == "-"
    assert (
        machine.succeed(f"zfs get -Hp -o value guid {child}").strip()
        != copy_machine.succeed(f"zfs get -Hp -o value guid {copy_child}").strip()
    )
    # @cc [owner:ghuntley,label:verification] clone-divergent-write-invisible
    # Divergent post-copy guest writes MUST be read through each guest's own
    # console (never fixture-written state) and stay invisible to the peer
    # copy's console.
    machine.succeed(
        "fleet-relocation-guest clone-write-post " + placement["placement_id"], timeout=120
    )
    copy_machine.succeed(
        "fleet-relocation-guest clone-write-post " + copy_placement["placement_id"], timeout=120
    )
    machine.succeed(
        "fleet-relocation-guest clone-check "
        + placement["placement_id"]
        + " "
        + copy_placement["placement_id"],
        timeout=120,
    )
    copy_machine.succeed(
        "fleet-relocation-guest clone-check "
        + copy_placement["placement_id"]
        + " "
        + placement["placement_id"],
        timeout=120,
    )
    copy_machine.fail("zfs list " + child)
    machine.fail("zfs list " + copy_child)
    # @cc [owner:ghuntley,label:verification;product] clone-published-cancel-refusal
    # A published clone is ordinary lifecycle authority: the public
    # `request cancel` CLI edge MUST refuse with clone_already_published and
    # leave the running copy untouched.
    published_cancel = porsche_receipt(
        f"request cancel {clone_key} --request-id {uuid.uuid4()} --no-wait"
    )
    assert published_cancel.get("error") == "clone_already_published"
    assert vm_state(copy_id) == "running"
    assert vm_state(vm_id) == "running"
    if cloning_enabled:
        # @cc [owner:ghuntley,label:verification;product] clone-oss-profile-native
        # The OSS profile MUST clone through the public path to the other host.
        # Its requested CPU shape MUST exceed half the uniformly observed native
        # core count, so its retained restart hold prevents same-host admission.
        # A catalog-disabled image MUST still clone the existing workload, and
        # the copy MUST keep the captured OSS shape.
        oss_origin_name = "porsche-oss-src"
        oss_copy_name = "porsche-oss-copy"
        native_cores = int(sql("SELECT min(effective_cores) FROM compute_hosts WHERE enabled"))
        assert 1 < native_cores <= 32
        assert sql("SELECT count(DISTINCT effective_cores) FROM compute_hosts WHERE enabled") == "1"
        oss_vcpus = native_cores // 2 + 1
        assert 2 * oss_vcpus > native_cores
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_hosts WHERE enabled "
                    "AND reported_at > now() - interval '10 seconds' "
                    f"AND (capacity->>'cpu_headroom_millicores')::bigint >= {oss_vcpus * 1000}"
                )
                == "2"
            ),
            timeout=180,
        )
        oss_creation = (
            f"new --profile oss --name {oss_origin_name} --cpu {oss_vcpus} "
            f"--image {users['image_id']} --timeout 600 --request-id {uuid.uuid4()}"
        )
        oss_created = porsche_command(oss_creation)
        assert oss_created is not None
        oss_result = oss_created["result"]
        assert isinstance(oss_result, dict)
        oss_vm = str(oss_result["id"])
        assert str(uuid.UUID(oss_vm)) == oss_vm
        await_running(oss_vm)
        assert sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{oss_vm}'") == "oss"
        oss_placement = porsche_placement(oss_vm)
        oss_machine = host_for(oss_placement)
        oss_child = "zroot/lilly/vm-" + oss_placement["placement_id"]
        oss_guid = oss_machine.succeed(f"zfs get -Hp -o value guid {oss_child}").strip()
        oss_machine.succeed(
            "fleet-relocation-guest clone-write " + oss_placement["placement_id"], timeout=120
        )
        operator(
            m1,
            dict(action="image-configure", image_id=users["image_id"], enabled=False),
        )
        porsche_command(
            "new --profile oss --name porsche-image-refused "
            f"--image {users['image_id']} --timeout 30",
            accepted=False,
        )
        assert (
            sql("SELECT count(*) FROM compute_virtual_machines WHERE name='porsche-image-refused'")
            == "0"
        )
        oss_clone_key = str(uuid.uuid4())
        oss_clone = porsche_command(
            f"clone {oss_origin_name} --name {oss_copy_name} "
            f"--request-id {oss_clone_key} --timeout 600"
        )
        assert oss_clone is not None
        oss_clone_result = oss_clone["result"]
        assert isinstance(oss_clone_result, dict)
        oss_copy = str(oss_clone_result["destination_vm_id"])
        assert str(uuid.UUID(oss_copy)) == oss_copy
        # The disabled catalog never substituted or dropped the captured shape.
        assert sql_json(
            f"SELECT jsonb_build_object({shape_columns}) "
            f"FROM compute_virtual_machines WHERE id='{oss_vm}'"
        ) == sql_json(
            f"SELECT jsonb_build_object({shape_columns}) "
            f"FROM compute_virtual_machines WHERE id='{oss_copy}'"
        )
        oss_copy_placement = porsche_placement(oss_copy)
        assert oss_copy_placement["host_id"] != oss_placement["host_id"]
        oss_copy_machine = host_for(oss_copy_placement)
        oss_copy_child = "zroot/lilly/vm-" + oss_copy_placement["placement_id"]
        assert (
            oss_copy_machine.succeed(f"zfs get -Hp -o value origin {oss_copy_child}").strip() == "-"
        )
        assert (
            oss_machine.succeed(f"zfs get -Hp -o value guid {oss_child}").strip()
            != oss_copy_machine.succeed(f"zfs get -Hp -o value guid {oss_copy_child}").strip()
        )
        # The source restarted while its immutable snapshot streamed; its guest
        # remains live and its disk identity is unchanged.
        assert vm_state(oss_vm) == "running"
        assert oss_machine.succeed(f"zfs get -Hp -o value guid {oss_child}").strip() == oss_guid
        # The captured pre-clone marker boots with the independent copy.
        # @cc [owner:ghuntley,label:verification;recovery] clone-running-start-continuity
        # Starting an already-running OSS copy MUST retain its native processes
        # while completing current-generation readiness. It cannot bypass start
        # or restart the VMM to repair logical generation bookkeeping.
        assert vm_state(oss_copy) == "running"
        oss_copy_processes = process_snapshot(oss_copy_placement)
        assert oss_copy_processes
        oss_copy_machine.succeed(
            "systemd-run --no-block --unit=clone-native-boot-observations "
            "--property=Type=oneshot --property=TimeoutStartSec=90 "
            "--property=StandardOutput=null --property=StandardError=null "
            "/run/current-system/sw/bin/fleet-relocation-guest boot-observations "
            + oss_copy_placement["placement_id"]
        )
        try:
            porsche_command(f"start {oss_copy_name} --timeout 600")
        except Exception:
            observer_status, observer_output = oss_copy_machine.execute(
                "cat /run/clone-native-boot-observations.json"
            )
            if observer_status == 0:
                raw_observations: object = json.loads(observer_output)
                print(
                    "OSS copy early boot observations:", native_boot_observations(raw_observations)
                )
            else:
                print("OSS copy early boot observations unavailable")
            oss_copy_machine.execute(
                "fleet-relocation-guest readiness-diagnostics "
                + oss_copy_placement["placement_id"],
                timeout=210,
            )
            raise
        await_running(oss_copy)
        assert process_snapshot(oss_copy_placement) == oss_copy_processes
        oss_copy_machine.wait_until_succeeds(
            "fleet-relocation-guest clone-inherit "
            + oss_copy_placement["placement_id"]
            + " "
            + oss_placement["placement_id"],
            timeout=240,
        )
        # Both sides now diverge; reads come from each guest's own console only.
        oss_machine.succeed(
            "fleet-relocation-guest clone-write-post " + oss_placement["placement_id"],
            timeout=120,
        )
        oss_copy_machine.succeed(
            "fleet-relocation-guest clone-write-post " + oss_copy_placement["placement_id"],
            timeout=120,
        )
        oss_machine.succeed(
            "fleet-relocation-guest clone-check "
            + oss_placement["placement_id"]
            + " "
            + oss_copy_placement["placement_id"],
            timeout=120,
        )
        oss_copy_machine.succeed(
            "fleet-relocation-guest clone-check "
            + oss_copy_placement["placement_id"]
            + " "
            + oss_placement["placement_id"],
            timeout=120,
        )
        oss_copy_machine.fail("zfs list " + oss_child)
        oss_machine.fail("zfs list " + oss_copy_child)
        porsche_command(f"stop {oss_copy_name} --timeout 600")
        porsche_command(f"stop {oss_origin_name} --timeout 600")
        porsche_command(f"rm {oss_copy_name} --timeout 600")
        porsche_command(f"rm {oss_origin_name} --timeout 600")
        operator(
            m1,
            dict(action="image-configure", image_id=users["image_id"], enabled=True),
        )
        # @cc [owner:ghuntley,label:verification;recovery] clone-mid-copy-cancel-native
        # A public `request cancel` issued while the copy is physically in
        # flight MUST fence publication, restore the running source with its
        # exact disk identity, reclaim every destination row, dataset and
        # transfer slot, and never re-offer later work for that request.
        cancelled_name = "porsche-cancelled-copy"
        cancelled_key = str(uuid.uuid4())
        machine.succeed(
            "fleet-relocation-guest clone-cancel-seed " + placement["placement_id"], timeout=180
        )
        cancel_submission = porsche_receipt(
            f"clone porsche-fleet --name {cancelled_name} --request-id {cancelled_key} --no-wait"
        )
        assert cancel_submission["status"] in ("accepted", "running", "succeeded")
        cancel_result: object = cancel_submission.get("result")
        assert isinstance(cancel_result, dict) and all(
            isinstance(key, str) for key in cancel_result
        )
        validated_cancel_result: dict[str, object] = {
            str(key): value for key, value in cancel_result.items()
        }
        cancelled_value: object = validated_cancel_result.get("id")
        assert isinstance(cancelled_value, str)
        cancelled_identity = str(uuid.UUID(cancelled_value))
        cancelled_deadline = time.monotonic() + 600
        while (
            sql(f"SELECT phase FROM compute_clone_requests WHERE id='{cancelled_identity}'")
            != "copying"
        ):
            assert time.monotonic() < cancelled_deadline, "copy never began"
            time.sleep(0.2)
        cancelled_destination = sql(
            f"SELECT destination_vm_id FROM compute_clone_requests WHERE id='{cancelled_identity}'"
        )
        cancelled_placement = porsche_placement(cancelled_destination)
        cancelled_machine = host_for(cancelled_placement)
        # Native transfer custody must be occupied, independently of durable
        # phase polling. Missing files and other command errors cannot pass.
        cancel_stream_lock = (
            "/var/lib/lilly/transfers/transfers/" + cancelled_identity + "/stream/owner.lock"
        )
        eventually(
            lambda: (
                cancelled_machine.execute(
                    "test -f "
                    + cancel_stream_lock
                    + " && flock -n -E 75 "
                    + cancel_stream_lock
                    + " true"
                )[0]
                == 75
            ),
            timeout=30,
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_clone_effects "
                f"WHERE clone_request_id='{cancelled_identity}' AND kind='copy' "
                "AND status='offered' AND completed_at IS NULL"
            )
            == "1"
        )
        # Allocation has no physical stopped receipt: its observed state is
        # pending until an execution command completes. Require both retained
        # publication authority and independent absence of a running VMM.
        assert vm_state(cancelled_destination) == "pending"
        assert (
            sql(
                "SELECT published_at IS NULL AND destination_operation_id IS NULL "
                f"AND phase='copying' FROM compute_clone_requests WHERE id='{cancelled_identity}'"
            )
            == "t"
        )
        cancelled_machine.fail(
            "systemctl is-active lilly-vm-" + cancelled_placement["placement_id"] + ".service"
        )
        cancel_key = str(uuid.uuid4())
        cancel_command = f"request cancel {cancelled_key} --request-id {cancel_key} --timeout 600"
        cancelled = porsche_command(cancel_command)
        assert cancelled is not None
        with subtest("native cancellation measurement survives exact receipt replay"):
            cancel_measurement = workflow_measurement(
                cancel_key, "porsche_cancel", cancelled_identity
            )
            assert porsche_command(cancel_command)["result"]["id"] == cancelled_identity
            assert (
                workflow_measurement(cancel_key, "porsche_cancel", cancelled_identity)
                == cancel_measurement
            )
        assert (
            sql(f"SELECT phase FROM compute_clone_requests WHERE id='{cancelled_identity}'")
            == "cancelled"
        )
        await_running(vm_id)
        assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == disk_identity
        assert (
            sql(
                "SELECT archived_at IS NOT NULL FROM compute_virtual_machines "
                f"WHERE id='{cancelled_destination}'"
            )
            == "t"
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_transfer_slots "
                f"WHERE clone_request_id='{cancelled_identity}' AND released_at IS NULL"
            )
            == "0"
        )
        cancelled_machine.fail("zfs list zroot/lilly/vm-" + cancelled_placement["placement_id"])
        machine.wait_until_succeeds(
            "fleet-relocation-guest verify " + placement["placement_id"], timeout=240
        )
    porsche_command("stop porsche-ssh-copy --timeout 600")
    porsche_command("stop porsche-fleet --timeout 600")
    client.succeed("printf %s " + shlex.quote(vm_id) + f" >{porsche_root}/clone-source")
    porsche_browser("clone")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_clone_requests WHERE name='porsche-browser-copy' AND phase='complete'"
            )
            == "1"
        ),
        timeout=600,
    )
    browser_id = sql("SELECT id FROM compute_virtual_machines WHERE name='porsche-browser-copy'")
    assert browser_id != copy_id
    assert vm_state(browser_id) == "stopped"
    # @cc [owner:ghuntley,label:verification;recovery] clone-stopped-source-native-invariant
    # An originally stopped source MUST remain stopped through its browser
    # clone: native power observation, no restart evidence on its host console
    # and an unchanged dataset GUID, never merely a unit-level expectation.
    assert vm_state(vm_id) == "stopped"
    machine.fail("systemctl is-active lilly-vm-" + placement["placement_id"] + ".service")
    assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == disk_identity
    assert (
        sql(f"SELECT count(*) FROM access_grants WHERE vm_id IN ('{copy_id}', '{browser_id}')")
        == "0"
    )
    # The SSH and browser copies always queue; the cloning variant's mid-copy
    # cancellation retains its cancelled request row as well.
    expected_source_requests = "3" if cloning_enabled else "2"
    assert (
        sql(f"SELECT count(*) FROM compute_clone_requests WHERE source_vm_id='{vm_id}'")
        == expected_source_requests
    )
    porsche_command("start porsche-ssh-copy --timeout 600")
    copy_placement = relocate_porsche_clone("porsche-ssh-copy", copy_id, copy_placement)
    assert copy_placement["host_id"] == placement["host_id"]
    copy_placement = relocate_porsche_clone("porsche-ssh-copy", copy_id, copy_placement)
    assert copy_placement["host_id"] == original_copy_placement["host_id"]
    assert copy_placement["placement_id"] != original_copy_placement["placement_id"]
    porsche_command("stop porsche-ssh-copy --timeout 600")
    porsche_command("rm porsche-fleet --timeout 600")
    assert (
        sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm_id}'")
        == "t"
    )
    machine.fail("zfs list " + child)
    # Source deletion must not invalidate either independent received dataset.
    porsche_command("start porsche-ssh-copy --timeout 600")
    host_for(copy_placement).wait_until_succeeds(
        "fleet-relocation-guest verify " + copy_placement["placement_id"], timeout=240
    )
    porsche_command("rm porsche-ssh-copy --timeout 600")
    browser_placement = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{browser_id}'"
    )
    porsche_command("start porsche-browser-copy --timeout 600")
    host_for(browser_placement).wait_until_succeeds(
        "fleet-relocation-guest verify " + browser_placement["placement_id"], timeout=240
    )
    porsche_command("rm porsche-browser-copy --timeout 600")
    if ubuntu_enabled:
        porsche_browser("provision")
        browser_vm = client.succeed(f"cat {porsche_root}/provisioned-vm").strip()
        assert (
            sql(f"SELECT image_id FROM compute_virtual_machines WHERE id='{browser_vm}'")
            == users["image_id"]
        )
        await_running(browser_vm)
        selected = sql_json(
            "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
            "FROM compute_virtual_machines v JOIN compute_workload_placements p "
            f"ON p.id=v.current_placement_id WHERE v.id='{browser_vm}'"
        )
        host_for(selected).succeed(
            "fleet-relocation-guest ubuntu-check " + selected["placement_id"], timeout=180
        )
        porsche_command(f"rm {browser_vm} --timeout 600")
    porsche_browser("remove")
    porsche_command("whoami", accepted=False)


def assert_clone_audit(source: str, copies: tuple[str, str]) -> None:
    """@cc [owner:ghuntley,label:verification;observability] clone-independent-diagnostics
    Both completed public clones MUST retain human enqueue and successful system
    completion audits bound to their exact request/workflow and source identity
    after source and copy deletion. Fresh source/copy VMs MUST NOT ingest
    provisioner diagnostics. Native independent-disk and guest-data checks remain
    required before this audit check.
    """
    for vm in (source, *copies):
        assert str(uuid.UUID(vm)) == vm
        assert (
            sql(
                "SELECT count(*) FROM compute_lifecycle_events "
                f"WHERE vm_id='{vm}' AND actor_kind='provisioner'"
            )
            == "0"
        )
    assert (
        sql(
            "SELECT count(DISTINCT resource_id) FROM compute_lifecycle_events "
            f"WHERE resource_type='CloneRequest' AND vm_id='{source}' AND next_state='complete'"
        )
        == "2"
    )
    assert (
        sql(
            "SELECT count(DISTINCT r.id) FROM compute_clone_requests r "
            f"WHERE r.source_vm_id='{source}' AND r.phase='complete' "
            f"AND r.destination_vm_id IN ('{copies[0]}','{copies[1]}') "
            "AND EXISTS(SELECT 1 FROM compute_lifecycle_events e "
            "WHERE e.resource_type='CloneRequest' AND e.resource_id=r.id "
            "AND e.workflow_id=r.id AND e.vm_id=r.source_vm_id "
            "AND e.actor_kind='user' AND e.actor_id=r.requested_by_id "
            "AND e.action='enqueue' AND e.next_state='queued') "
            "AND EXISTS(SELECT 1 FROM compute_lifecycle_events e "
            "WHERE e.resource_type='CloneRequest' AND e.resource_id=r.id "
            "AND e.workflow_id=r.id AND e.vm_id=r.source_vm_id "
            "AND e.actor_kind='system' AND e.action='complete' "
            "AND e.next_state='complete' AND e.measurement_outcome='succeeded')"
        )
        == "2"
    )


with subtest("clone audit survives source deletion with independent diagnostics"):
    assert_clone_audit(vm_id, (copy_id, browser_id))
