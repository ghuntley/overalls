"""Actual Marshall → Audi → Lilly → Firecracker browser editor acceptance."""

import base64
import re

editor_root = "/var/lib/fleet-vscode-web"


with subtest("actual gateway startup requires a canonical editor zone with its immutable package"):
    for gateway in provisioners:
        gateway.succeed("fleet-editor-zone", timeout=60)


def editor_native(operation: str) -> None:
    assert operation in {
        "prepare",
        "custody",
        "broker-restart",
        "worker-stop",
        "saved",
        "policy",
        "boot-capture",
        "boot-changed",
        "diagnose",
        "journal",
    }
    host, placement = current_placement(editor_vm)
    output = host.succeed(
        shlex.join(["fleet-editor-guest", operation, placement, guest_name, str(guest_uid)]),
        timeout=60 if operation in {"diagnose", "journal"} else 150,
    )
    if operation == "diagnose":
        publish_editor_diagnostics(output)
    if operation == "journal":
        publish_editor_journal(output)


def publish_editor_journal(output: str) -> None:
    """@cc [owner:ghuntley,label:verification;privacy] editor-broker-journal-publication
    Broker journal capture MUST be bounded and every line MUST match the closed
    timestamp, unit-kind and event-token grammar before any line is printed.
    Any other line refuses the whole capture without exposing its text.
    """
    assert len(output) <= 65_536
    lines = output.splitlines()
    assert lines and lines[-1] == "Editor native guest assertions passed"
    assert len(lines) >= 2
    summary = re.fullmatch(
        r"Editor broker journal summary lines=\d{1,4} kept=\d{1,3}",
        lines[-2],
    )
    assert summary is not None
    entries = lines[:-2]
    assert len(entries) <= 400
    pattern = (
        r"Editor broker journal \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}(?:Z|[+-]\d\d:?\d\d)? "
        r"(?:broker editor\.[a-z_]{1,32}(?: [a-z]{1,16})?"
        r"|(?:broker|worker) (?:started|starting|stopping|stopped|deactivated"
        r"|main_exited|failed|restart_scheduled|auto_shutdown))"
    )
    for line in entries:
        assert re.fullmatch(pattern, line) is not None
    for line in entries:
        print(line)
    print(lines[-2])


def editor_failure_evidence() -> None:
    """Best-effort native evidence after a failed editor acceptance step."""
    for operation in ("diagnose", "journal"):
        try:
            editor_native(operation)
        except Exception:
            print("Editor native " + operation + " unavailable")


def publish_editor_diagnostics(output: str) -> None:
    """@cc [owner:ghuntley,label:verification;privacy] editor-native-diagnostic-publication
    Native diagnostic output MUST be bounded and validated against the exact
    closed boolean catalog before any line is printed. Unknown, duplicate or
    incomplete output MUST refuse without exposing the captured source text.
    """
    keys = {
        "native_boot",
        "root_shell",
        "broker_active",
        "broker_root",
        "broker_exec_failed",
        "broker_package_failed",
        "worker_loaded",
        "worker_active",
        "worker_failed",
        "worker_uid",
        "worker_socket",
        "worker_exec_failed",
        "worker_version",
        "personal_launcher",
        "node_as_account",
        "guest_memory_observed",
        "guest_memory_low",
        "guest_oom_observed",
        "guest_oom",
        "broker_pids_observed",
        "broker_pids_limited",
        "worker_memory_observed",
        "worker_oom",
        "worker_oom_kill",
        "worker_pids_observed",
        "worker_pids_limited",
        "refusal_package",
        "refusal_account",
        "refusal_custody",
        "refusal_startup",
        "refusal_readiness",
        "refusal_transport",
    }
    assert len(output) <= 4096
    lines = output.splitlines()
    assert lines and lines[-1] == "Editor native guest assertions passed"
    values: dict[str, str] = {}
    for line in lines[:-1]:
        match = re.fullmatch(r"Editor native diagnostic ([a-z_]+)=(true|false)", line)
        assert match is not None
        key, value = match.groups()
        assert key in keys and key not in values
        values[key] = value
    assert values.keys() == keys
    assert values["native_boot"] == values["root_shell"] == "true"
    for key, value in values.items():
        print("Editor native diagnostic " + key + "=" + value)


def editor_execution_query(vm_id: str) -> str:
    """Select persisted fields, deriving the current host through its placement."""
    assert str(uuid.UUID(vm_id)) == vm_id
    return (
        "SELECT json_build_object('host',p.host_id,'placement',v.current_placement_id,"
        "'epoch',v.execution_epoch,'generation',v.generation) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        "ON p.id=v.current_placement_id AND p.vm_id=v.id WHERE v.id='" + vm_id + "'"
    )


def editor_readiness_query(vm_id: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] editor-current-physical-readiness
    Restart readiness MUST require the current physical outcome sequence and a
    JSON boolean guest_ready fact at the exact host/placement/epoch/generation,
    bound to its immutable start operation. Historical diagnostic events MUST NOT
    substitute for committed physical readiness.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    return (
        "SELECT count(*) FROM compute_virtual_machines v JOIN compute_workload_placements w "
        "ON w.id=v.current_placement_id AND w.vm_id=v.id WHERE v.id='"
        + vm_id
        + "' AND v.observed_state='running' AND EXISTS ("
        "SELECT 1 FROM compute_physical_outcomes p JOIN compute_operations o "
        "ON o.id=p.operation_id WHERE p.vm_id=v.id AND p.host_id=w.host_id "
        "AND p.placement_id=v.current_placement_id AND p.execution_epoch=v.execution_epoch "
        "AND p.generation=v.generation AND p.sequence=v.outcome_sequence "
        "AND p.observation->>'state'='running' AND p.observation->'guest_ready'='true'::jsonb "
        "AND p.observation->>'id'=p.id::text AND p.observation->>'operation_id'=o.id::text "
        "AND p.observation->>'vm_id'=v.id::text "
        "AND p.observation->>'placement_id'=v.current_placement_id::text "
        "AND p.observation->>'execution_epoch'=v.execution_epoch::text "
        "AND p.observation->>'generation'=v.generation::text "
        "AND o.kind='start' AND o.vm_id=v.id AND o.placement_id=v.current_placement_id "
        "AND o.execution_epoch=v.execution_epoch AND o.generation=v.generation "
        "AND o.command_snapshot->>'host_id'=w.host_id::text)"
    )


with subtest("editor lifecycle queries match the actual migrated relational schema"):
    # @cc [owner:ghuntley,label:verification] editor-native-query-schema-preflight
    # The exact runtime queries MUST be planned read-only against the actual
    # migrated fleet database before costly guest provisioning. Ash calculations
    # MUST NOT be treated as persisted SQL columns. Planning is schema evidence,
    # never a substitute for the matching after-restart rows required below.
    unused_vm = str(uuid.UUID(int=0))
    for query in (editor_execution_query(unused_vm), editor_readiness_query(unused_vm)):
        sql("EXPLAIN " + query)


def editor_execution() -> tuple[str, str, int, int]:
    """Read and validate the current durable host/placement/epoch/generation."""
    value: object = json.loads(sql(editor_execution_query(editor_vm)))
    fields = object_fields(value)
    host, placement = fields["host"], fields["placement"]
    epoch, generation = fields["epoch"], fields["generation"]
    assert isinstance(host, str) and str(uuid.UUID(host)) == host
    assert isinstance(placement, str) and str(uuid.UUID(placement)) == placement
    assert isinstance(epoch, int) and not isinstance(epoch, bool) and epoch > 0
    assert isinstance(generation, int) and not isinstance(generation, bool) and generation > 0
    return host, placement, epoch, generation


def editor_journey() -> None:
    # Tokens and browser URLs stay in the client; only finite stage results may
    # leave the actual shared browser helper.
    # @cc [owner:ghuntley,label:verification;security] editor-live-failure-diagnosis
    # Failure MUST retain the original browser exception and unchanged deadline.
    # Before teardown, bounded native diagnostics MAY observe only the current
    # authenticated boot, fixed worker health booleans and the closed-grammar
    # broker journal; diagnostic refusal MUST NOT replace failed acceptance or
    # expose private terminal state.
    try:
        client.succeed(
            "sudo -u tester env HOME=/home/tester "
            + shlex.join(
                [
                    editor_python,
                    editor_browser_artifact + "/browser_journey.py",
                    editor_root + "/journey.json",
                    "--chromium",
                    "/run/current-system/sw/bin/chromium",
                ]
            ),
            timeout=240,
        )
    except Exception:
        editor_failure_evidence()
        raise


with subtest("ordinary browser provisions the selected editor image with its default shape"):
    client.succeed(
        "install -d -m 700 -o tester -g users " + editor_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    for source, name in ((root + "/ca.crt", "control"), (root + "/audi-root.pem", "editor")):
        if name == "editor":
            transfer(m1, source, client, editor_root + "/" + name + ".pem")
        else:
            client.succeed("install -m 644 " + source + " " + editor_root + "/" + name + ".pem")
        client.succeed(
            "sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n "
            + name
            + " -t 'C,,' -i "
            + editor_root
            + "/"
            + name
            + ".pem"
        )
    transfer(m1, root + "/users.json", client, editor_root + "/users.json")
    client.succeed(
        "cat "
        + editor_root
        + "/control.pem "
        + editor_root
        + "/editor.pem > "
        + editor_root
        + "/browser-roots.pem"
    )
    client.succeed(
        "chown tester:users "
        + editor_root
        + "/users.json; chmod 600 "
        + editor_root
        + "/users.json"
    )
    selected_value = users["image_id"]
    assert isinstance(selected_value, str)
    selected: str = selected_value
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE (inventory->'images') ? '"
                + selected
                + "'"
            )
            != "0"
        ),
        timeout=900,
    )
    eventually(
        lambda: sql("SELECT count(*) FROM ingress_fleet_certificates WHERE status='active'") == "1",
        timeout=360,
    )
    eventually(
        lambda: (
            sql(
                "SELECT count(DISTINCT host_id) FROM ingress_fleet_certificate_installations WHERE generation=1"
            )
            == "2"
        ),
        timeout=90,
    )
    # Require actual fresh authenticated observations of the larger fixture
    # cgroup and enough measured memory for the unchanged default guest, host
    # reserve and VMM allowance. Configuration alone cannot establish capacity.
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE enabled AND maintenance_mode='normal' "
                "AND inventory->>'execution_ready'='true' AND reported_at > "
                "(statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds' "
                "AND effective_memory_bytes="
                + str(editor_guest_memory_bytes)
                + " AND overhead_memory_bytes=1073741824 AND capacity->>'version'='1' "
                "AND (capacity->>'memory_headroom_bytes')::bigint >= "
                "overhead_memory_bytes + 2147483648 + 67108864"
            )
            == "2"
        ),
        timeout=180,
    )
    client.succeed(
        "sudo -u tester env HOME=/home/tester "
        + shlex.join(
            [
                editor_python,
                editor_browser_artifact + "/prepare.py",
                editor_root + "/users.json",
                editor_root,
            ]
        ),
        timeout=180,
    )
    ordinary_accounts()
    editor_vm = client.succeed("cat " + editor_root + "/vm-id").strip()
    assert str(uuid.UUID(editor_vm)) == editor_vm
    running(editor_vm)
    shape_value: object = json.loads(
        sql(
            "SELECT json_build_object('vcpu',v.vcpu,'memory',v.memory_bytes,'disk',v.disk_bytes,'manifest',i.manifest) FROM compute_virtual_machines v JOIN compute_images i ON i.id=v.image_id WHERE v.id='"
            + editor_vm
            + "'"
        )
    )
    shape = object_fields(shape_value)
    assert shape["vcpu"] == 1 and shape["memory"] == 2147483648
    disk = shape["disk"]
    assert isinstance(disk, int) and disk <= 8589934592
    manifest = object_fields(shape["manifest"])
    assert manifest["version"] == 4
    descriptor = object_fields(manifest["editor"])
    assert descriptor == {"protocol": 1, "commit": editor_source_commit, "release": editor_release}
    rootfs = object_fields(manifest["rootfs"])
    rootfs_bytes = rootfs["bytes"]
    minimum_disk = manifest["minimum_disk_bytes"]
    assert isinstance(rootfs_bytes, int) and isinstance(minimum_disk, int)
    assert disk == minimum_disk and disk - rootfs_bytes >= 2147483648
    owner = users["owner_id"]
    assert isinstance(owner, str) and str(uuid.UUID(owner)) == owner
    account_value: object = json.loads(
        sql(
            "SELECT json_build_object('id',id,'username',username,'uid',uid) FROM account_guest_accounts WHERE user_id='"
            + owner
            + "' AND retired_at IS NULL"
        )
    )
    account = object_fields(account_value)
    name_value, uid_value, account_id_value = account["username"], account["uid"], account["id"]
    assert isinstance(name_value, str) and re.fullmatch(
        r"[a-z_][a-z0-9_.-]{0,30}[a-z0-9_]|[a-z_]", name_value
    )
    assert isinstance(uid_value, int) and 200000 <= uid_value <= 999999
    assert name_value == "u" + str(uid_value)
    assert (
        isinstance(account_id_value, str) and str(uuid.UUID(account_id_value)) == account_id_value
    )
    guest_name: str = name_value
    guest_uid: int = uid_value
    account_id: str = account_id_value
    editor_native("prepare")
    vm_label = base64.b32encode(uuid.UUID(editor_vm).bytes).decode().lower().rstrip("=")
    account_label = base64.b32encode(uuid.UUID(account_id).bytes).decode().lower().rstrip("=")
    journey: dict[str, object] = {
        "marshall_origin": "https://control.example.test",
        "machine_id": editor_vm,
        "expected_editor_origin": "https://e-"
        + vm_label
        + "-"
        + account_label
        + ".apps.example.test",
        "expected_guest": editor_guest_family,
        "workspace_file": "/home/" + guest_name + "/workspace/browser-fixture.md",
        "expected_uid": guest_uid,
        "expected_username": guest_name,
        "storage_state_path": editor_root + "/storage-state.json",
    }
    with TemporaryDirectory(prefix="editor-journey-private-") as directory:
        path = Path(directory) / "journey.json"
        path.write_text(json.dumps(journey))
        os.chmod(path, 0o600)
        client.copy_from_host(str(path), editor_root + "/journey.json")
    client.succeed(
        "chown tester:users "
        + editor_root
        + "/journey.json; chmod 600 "
        + editor_root
        + "/journey.json"
    )

with subtest("native editor opens from Marshall with personal terminal and isolated webview"):
    editor_journey()
    editor_native("custody")

with subtest("the real guest preserves editor policy, personal defaults and direnv approval"):
    try:
        client.succeed(
            "sudo -u tester env HOME=/home/tester "
            + shlex.join(
                [
                    editor_python,
                    editor_browser_artifact + "/fleet_policy.py",
                    editor_root + "/journey.json",
                    "--chromium",
                    "/run/current-system/sw/bin/chromium",
                ]
            ),
            timeout=300,
        )
    except Exception:
        editor_failure_evidence()
        raise
    editor_native("policy")

with subtest("live editor WebSockets survive lilly-hostd and Lilly restarts in detached bridges"):
    # @cc [owner:ghuntley,label:verification;recovery] journey-editor-restart-keeps-bridges
    # ADR-0192: editor connections run in detached lilly-ingress-bridge
    # processes in lilly_ingress.slice like guest SSH (ADR-0187). With a live
    # browser editor, restarting lilly-hostd (which restarts Lilly through
    # BindsTo) and then Lilly alone, each past the 30 s adoption grace, MUST
    # keep the bridge processes holding the guest's port 4444 and every editor
    # WebSocket open, with frames still arriving on them afterwards.
    restart_host, _ = current_placement(editor_vm)
    live = editor_root + "/restart"
    editor_bridges = (
        "for ns in $(ip netns list | cut -d' ' -f1); do "
        "ip netns exec \"$ns\" ss -Htnp state established '( dport = :4444 )'; done "
        "| grep -o '\"lilly-ingress-b\",pid=[0-9]*' | cut -d= -f2 | sort -u"
    )
    client.succeed(f"rm -rf {live} && install -d -o tester -m 0700 {live}")
    # The browser helper runs detached from the driver's pipes; the driver and
    # the helper coordinate only through the ready and go files.
    # Playwright's request client runs in Node, which trusts only its own roots
    # plus NODE_EXTRA_CA_CERTS, not Chromium's; the final /version check needs it.
    client.succeed(
        "sudo -u tester env HOME=/home/tester NODE_EXTRA_CA_CERTS="
        + editor_root
        + "/browser-roots.pem "
        + shlex.join(
            [
                editor_python,
                editor_browser_artifact + "/restart.py",
                editor_root + "/journey.json",
                "--chromium",
                "/run/current-system/sw/bin/chromium",
                "--ready",
                live + "/ready",
                "--go",
                live + "/go",
            ]
        )
        + f" </dev/null >{live}/out 2>&1 & echo $! >{live}/pid"
    )
    client.wait_until_succeeds(f"test -s {live}/ready", timeout=180)
    restart_host.wait_until_succeeds(f'test -n "$({editor_bridges})"', timeout=30)
    # Short HTTP requests also cross 4444; two snapshots keep the long-lived
    # (WebSocket) bridges, and the browser asserts each WebSocket itself.
    first = set(restart_host.succeed(editor_bridges).split())
    client.succeed("sleep 10")
    bridge_pids = sorted(first & set(restart_host.succeed(editor_bridges).split()))
    assert bridge_pids, "no long-lived editor bridge"
    for pid in bridge_pids:
        cgroup = restart_host.succeed(f"cat /proc/{pid}/cgroup").strip()
        assert re.fullmatch(
            r"0::/lilly_ingress\.slice/lilly-ingress-[0-9a-f]{32}\.scope", cgroup
        ), cgroup

    hostd_before = restart_host.succeed("systemctl show -P MainPID lilly-hostd.service").strip()
    restart_host.succeed("systemctl restart lilly-hostd.service")
    restart_host.wait_until_succeeds(
        "systemctl is-active lilly-hostd.service && systemctl is-active lilly.service", timeout=120
    )
    assert (
        restart_host.succeed("systemctl show -P MainPID lilly-hostd.service").strip()
        != hostd_before
    )
    client.succeed("sleep 35")
    restart_host.succeed("systemctl restart lilly.service")
    restart_host.wait_until_succeeds("systemctl is-active lilly.service", timeout=120)
    client.succeed("sleep 35")
    survivors = set(bridge_pids) & set(restart_host.succeed(editor_bridges).split())
    assert survivors, "no editor bridge survived the restarts"

    client.succeed(f"touch {live}/go")
    client.wait_until_succeeds(f'! kill -0 "$(cat {live}/pid)"', timeout=180)
    # The helper prints only fixed stage and assertion messages, never browser data.
    print(client.succeed(f"cat {live}/out"))
    try:
        client.succeed(f"grep -qx 'Editor restart survival assertions passed' {live}/out")
    except Exception:
        editor_failure_evidence()
        raise

with subtest("broker restart preserves the independent editor process and user workspace"):
    editor_native("broker-restart")
    editor_journey()
    editor_native("saved")

with subtest("editor worker loss recovers through a fresh authorized browser open"):
    editor_native("worker-stop")
    editor_journey()
    editor_native("custody")
    editor_native("saved")

with subtest("VM stop/start keeps saved files and opens only the new physical execution"):
    # @cc [owner:ghuntley,label:verification;recovery] editor-same-placement-new-boot
    # Ordinary stop/start MUST preserve placement and execution epoch while
    # advancing logical generation. Success additionally requires a fresh native
    # boot challenge/guest boot UUID and exact current-generation committed
    # current physical guest readiness, never an epoch-only proxy.
    before = editor_execution()
    editor_native("boot-capture")
    operator(
        dict(
            action="lifecycle", owner_id=owner, vm_id=editor_vm, kind="stop", key=str(uuid.uuid4())
        )
    )
    eventually(lambda: observed_state(editor_vm) == "stopped", timeout=180)
    operator(
        dict(
            action="lifecycle", owner_id=owner, vm_id=editor_vm, kind="start", key=str(uuid.uuid4())
        )
    )
    running(editor_vm)
    after = editor_execution()
    assert after[:3] == before[:3] and after[3] > before[3]
    eventually(
        lambda: sql(editor_readiness_query(editor_vm)) == "1",
        timeout=120,
    )
    assert editor_execution() == after
    editor_native("boot-changed")
    editor_journey()
    editor_native("custody")
    editor_native("saved")
    ordinary_accounts()

with subtest(
    "actual Audi refuses foreign Origins and closes current editor authority after sign-out"
):
    client.succeed(
        "sudo -u tester env HOME=/home/tester NODE_EXTRA_CA_CERTS="
        + editor_root
        + "/browser-roots.pem "
        + shlex.join(
            [
                editor_python,
                editor_browser_artifact + "/authorization.py",
                editor_root + "/journey.json",
                "--chromium",
                "/run/current-system/sw/bin/chromium",
            ]
        ),
        timeout=180,
    )
