with subtest("runtime fixture CA and independent production Brady services"):
    egress.succeed("fleet-brady-origin-prepare", "systemctl start fleet-brady-origin")
    egress.wait_until_succeeds("curl --silent --fail http://11.0.0.1/public >/dev/null", timeout=15)
    for machine in provisioners:
        transfer(egress, "/run/brady-fixture/ca.pem", machine, root + "/brady-ca.pem")
        transfer(egress, "/run/brady-fixture/ca.key", machine, root + "/brady-ca.key")
        machine.succeed(
            f"install -m 644 {root}/brady-ca.pem /etc/brady-upstream-ca.pem",
            f"chmod 644 {root}/brady-ca.pem",
            f"chmod 600 {root}/brady-ca.key",
            f"touch {root}/brady-ready",
        )
        machine.wait_for_unit("brady.service")
        machine.wait_until_succeeds("test -s /run/brady-pressure/pressure.json", timeout=45)
        machine.wait_until_succeeds(
            "jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json", timeout=45
        )

with subtest("real guest requests carry authoritative current VM and user attribution"):
    for peer in provisioners:
        operator(
            m1, dict(action="enable", host_id=host_bindings[peer.name]["host"], enabled=peer == l1)
        )
    brady_vm = provision_when_available(m1, "standard")
    await_running(brady_vm["vm_id"])
    brady_binding = sql_json(
        "SELECT json_build_object('placement_id',current_placement_id,'epoch',execution_epoch,'generation',generation) "
        f"FROM compute_virtual_machines WHERE id='{brady_vm['vm_id']}'"
    )
    brady_placement = brady_binding["placement_id"]
    brady_processes = l1.succeed("fleet-processes " + brady_placement)
    brady_cursor = (
        l1.succeed("journalctl -u brady.service -n 0 --show-cursor --no-pager")
        .strip()
        .split("-- cursor: ")[-1]
    )
    l1.succeed("fleet-brady-guest http " + brady_placement, timeout=160)
    l1.succeed("fleet-brady-guest tls " + brady_placement, timeout=160)

    def attributed_completions() -> int:
        """@cc [owner:ghuntley,label:verification] brady-fleet-authoritative-attribution
        Use real enrolled hosts, authenticated commands, Firecracker sockets and kernel
        labels. A matching log MUST name the authoritative VM/placement/owner; a host-
        side fixture request or synthetic actor response cannot satisfy this assertion.
        Count only SLO-admitted 200 completions, which brady-slo-admitted-outcomes
        settles into the request recorder.
        """
        count = 0
        records = l1.succeed(
            "journalctl -u brady.service -o cat --no-pager --after-cursor="
            + shlex.quote(brady_cursor)
        )
        for line in records.splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            # Canonical diagnostic lines carry their catalogued fields under
            # "metadata" (Overalls.Diagnostics formatter).
            fields = row.get("metadata") if isinstance(row, dict) else None
            if not isinstance(fields, dict):
                continue
            if (
                row.get("event") == "brady.request_completed"
                and fields.get("status") == 200
                and fields.get("attribution") == "resolved"
                and fields.get("vm_id") == brady_vm["vm_id"]
                and fields.get("placement_id") == brady_placement
                and fields.get("owner_id") == users["owner_id"]
                and fields.get("host_id") == host_bindings["l1"]["host"]
                and fields.get("execution_epoch") == brady_binding["epoch"]
                and fields.get("generation") == brady_binding["generation"]
                and fields.get("slo_admitted") == "yes"
            ):
                count += 1
        return count

    def attributed() -> bool:
        return attributed_completions() >= 1

    # Lilly attributes only while the actor's running observation is under two
    # seconds old (execution-view-exact-current-read, ADR-0140). Under nested-VM
    # load observations can stall past that, so a request landing in a stale
    # window is correctly frozen as unresolved and never rewritten. Send fresh
    # requests until one is attributed rather than requiring a single request to.
    def attributed_or_retried() -> bool:
        if attributed():
            return True
        l1.succeed("fleet-brady-guest http " + brady_placement, timeout=160)
        return attributed()

    eventually(attributed_or_retried, timeout=60)

    # Only resolved, admitted requests enter the SLO denominator
    # (brady-slo-admitted-outcomes). The guest requests above can be frozen as
    # unresolved, so log "slo_admitted": "yes" alone does not mean the recorder
    # counted them. Settle two attributed successes before reading the snapshot.
    def two_attributed() -> bool:
        if attributed_completions() >= 2:
            return True
        l1.succeed("fleet-brady-guest http " + brady_placement, timeout=160)
        return attributed_completions() >= 2

    eventually(two_attributed, timeout=120)
    l1.wait_until_succeeds(
        'jq -e \'.service == "brady" and .requests >= 2 and .successes >= 2 '
        "and .requests == (.successes + .failures) and .duration.count >= 2 and "
        "([.duration.bucket_counts[]] | add) == .duration.count' /run/overalls-request-brady-source/slo.json",
        timeout=45,
    )
    l1.wait_for_unit("overalls-request-brady-exporter.service")
    l1.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        'grep -E \'overalls_outer_brady_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="brady"[^}]*\\} [1-9][0-9]*\'',
        timeout=45,
    )

brady_slo_faults(brady_placement)
assert l1.succeed("fleet-processes " + brady_placement) == brady_processes

with subtest("Brady and Lilly restarts preserve guest lifetime and refresh flow attribution"):
    brady_cursor = (
        l1.succeed("journalctl -u brady.service -n 0 --show-cursor --no-pager")
        .strip()
        .split("-- cursor: ")[-1]
    )
    l1.succeed("systemctl restart brady.service")
    l1.succeed("fleet-brady-guest http " + brady_placement, timeout=160)
    assert l1.succeed("fleet-processes " + brady_placement) == brady_processes
    eventually(attributed_or_retried, timeout=60)
    brady_cursor = (
        l1.succeed("journalctl -u brady.service -n 0 --show-cursor --no-pager")
        .strip()
        .split("-- cursor: ")[-1]
    )
    l1.succeed("systemctl restart lilly.service")
    eventually(fresh_hosts, timeout=120)
    l1.succeed("fleet-brady-guest tls " + brady_placement, timeout=160)
    assert l1.succeed("fleet-processes " + brady_placement) == brady_processes

    # The first request may arrive before Lilly restores fresh actor evidence.
    # Its frozen unresolved identity must not be retroactively rewritten; send
    # fresh requests until the recovered actor can prove the current binding.
    def restarted_guest_attributed() -> bool:
        l1.succeed("fleet-brady-guest tls " + brady_placement, timeout=160)
        return attributed()

    eventually(restarted_guest_attributed, timeout=30)
    l1.succeed("fleet-brady-guest secret " + brady_placement, timeout=160)
    brady_records = l1.succeed(
        "journalctl -u brady.service -o cat --no-pager --after-cursor=" + shlex.quote(brady_cursor)
    )
    for forbidden in [
        "brady-fleet-secret",
        "brady-fleet-signature",
        "origin.brady.test",
        "isolated-brady-origin",
    ]:
        assert forbidden not in brady_records

with subtest("real infrastructure exporter observes Brady without Marshall ingestion"):
    l1.wait_for_unit("overalls-fleet-exporter.service")
    l1.wait_until_succeeds(
        "curl --silent --fail http://127.0.0.1:9466/metrics | "
        'grep -E \'overalls_fleet_gauge\\{[^}]*kind="brady"[^}]*measure="cache_writable"[^}]*\\} 1\'',
        timeout=45,
    )

# @cc [owner:ghuntley,label:verification] brady-native-address-reuse
# Retain a real guest connection's kernel label across confirmed deletion and
# address reassignment. The old tuple MUST remain unresolved while a new tuple
# resolves to the new VM and owner; an expired conntrack entry cannot prove this.
with subtest("address reuse cannot attribute an old kernel flow to the new owner"):
    import hashlib
    import re

    brady_namespace = (
        "lilly-" + hashlib.sha256(host_bindings["l1"]["host"].encode()).hexdigest()[:12]
    )
    netns = "ip netns exec " + shlex.quote(brady_namespace) + " "
    l1.succeed("fleet-brady-guest retained " + brady_placement, timeout=160)

    def flow_source(port: int) -> str:
        table = l1.succeed(netns + f"conntrack -L -p tcp --dport 80 --sport {port} --dst 11.0.0.1")
        sources = re.findall(
            r"src=([0-9.]+) dst=11\.0\.0\.1 sport=" + str(port) + r" dport=80\b", table
        )
        assert len(sources) == 1
        return sources[0]

    old_source = flow_source(42001)
    l1.succeed(
        netns
        + f"conntrack -U -p tcp --src {old_source} --dst 11.0.0.1 --sport 42001 --dport 80 --timeout 3600"
    )
    old_tuple = old_source + " 42001 11.0.0.1 80"
    old_label = l1.succeed(netns + "fleet-brady-flow-label " + old_tuple).strip()
    assert re.fullmatch("[0-9a-f]{32}", old_label)

    def probe(tuple_args: str) -> dict[str, object]:
        attribution: dict[str, object] = json.loads(
            l1.succeed("fleet-brady-attribution " + tuple_args)
        )
        return attribution

    eventually(lambda: probe(old_tuple).get("owner_id") == users["owner_id"], timeout=30)
    lifecycle(brady_vm["vm_id"], "delete")
    eventually(
        lambda: (
            sql(
                f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{brady_vm['vm_id']}'"
            )
            == "t"
        )
    )
    new_request = provision("standard")
    new_request["owner_id"] = users["stranger_id"]
    new_guests = []

    def provision_new_owner() -> bool:
        result = operator(m1, new_request)
        if result["accepted"]:
            new_guests.append(result)
            return True
        assert result["reason"] == "insufficient_capacity"
        return False

    # Lilly restarted earlier in this journey; it advertises an image only after
    # background SHA-256 verification (ADR-0014), which can take minutes on the
    # nested fixture's storage. Admission is expected to wait for that.
    image_id: object = users["image_id"]
    l1_host: object = host_bindings["l1"]["host"]
    assert isinstance(image_id, str) and re.fullmatch("sha256:[0-9a-f]{64}", image_id)
    assert isinstance(l1_host, str) and re.fullmatch("[0-9a-f-]{36}", l1_host)
    image_advertised = (
        f"SELECT (inventory->'images') ? '{image_id}' FROM compute_hosts WHERE id='{l1_host}'"
    )
    eventually(lambda: sql(image_advertised) == "t", timeout=900)
    eventually(provision_new_owner, timeout=180)
    new_guest = new_guests[0]
    await_running(new_guest["vm_id"])
    l1.succeed("fleet-brady-guest reused " + new_guest["placement_id"], timeout=160)
    assert flow_source(42002) == old_source
    new_tuple = old_source + " 42002 11.0.0.1 80"

    def new_owner_resolves() -> bool:
        identity = probe(new_tuple)
        return (
            identity.get("vm_id") == new_guest["vm_id"]
            and identity.get("placement_id") == new_guest["placement_id"]
            and identity.get("owner_id") == users["stranger_id"]
        )

    eventually(new_owner_resolves, timeout=30)
    # Distinguish a vanished kernel entry from a failed label read.
    retained = l1.succeed(
        netns
        + "conntrack -L -p tcp --dport 80 --sport 42001 --dst 11.0.0.1 2>&1 | grep -c sport=42001 || true"
    ).strip()
    status, label = l1.execute(netns + "fleet-brady-flow-label " + old_tuple)
    assert status == 0 and label.strip() == old_label, (status, retained)
    assert probe(old_tuple) == {"attribution": "unresolved"}


def brady_watcher_diagnostics(placement: str, cursor: str) -> dict[str, int | bool]:
    """Validate the closed count-only snapshot before printing fault diagnostics."""
    raw = brady_slo_object(json.loads(l1.succeed("fleet-brady-watcher " + placement)))
    assert set(raw) == {"vmm_processes", "target_watchers", "target_pidfds"}
    return {
        "vmm_processes": brady_slo_integer(raw["vmm_processes"]),
        "target_watchers": brady_slo_integer(raw["target_watchers"]),
        "target_pidfds": brady_slo_integer(raw["target_pidfds"]),
        "cursor_valid": re.fullmatch(
            "s=[0-9a-f]+;i=[0-9a-f]+;b=[0-9a-f]+;m=[0-9a-f]+;t=[0-9a-f]+;x=[0-9a-f]+",
            cursor,
        )
        is not None,
    }


def brady_vmm_death_revocation() -> None:
    """@cc [owner:ghuntley,label:verification;security] brady-vmm-death-revokes-via-watcher
    Killing the running guest's Firecracker process MUST revoke its execution
    proof through lilly-vm-watch (vm.watch_ended reason=exited) well inside the
    two-second observation backstop, and attribution for its flow MUST then be
    refused rather than served from the stale proof (ADR-0140 phase 2).
    """
    placement = new_guest["placement_id"]
    assert re.fullmatch("[0-9a-f-]{36}", placement)
    cgroup = f"/sys/fs/cgroup/lilly.slice/lilly-vm-{placement}.service"
    # The prior kernel/socket checks can cross ADR-0140's two-second live-proof
    # window. Re-establish the same exact native identity before the fault,
    # using its existing setup bound; stale proof remains an expected refusal.
    eventually(new_owner_resolves, timeout=30)
    cursor = (
        l1.succeed("journalctl -u lilly.service -n 0 --show-cursor --no-pager")
        .strip()
        .split("-- cursor: ")[-1]
    )
    print("Native watcher pre-kill diagnostics:", brady_watcher_diagnostics(placement, cursor))
    # Kill and wait for the revocation in one host-side command, so the measured
    # delay excludes test-driver round trips.
    elapsed_ms = int(
        l1.succeed(
            "set -eu; "
            f"pid=$(for p in $(cat {cgroup}/cgroup.procs); do "
            'if [ "$(cat /proc/$p/comm)" = firecracker ]; then echo $p; fi; done); '
            'test -n "$pid"; start=$(date +%s%N); kill -9 $pid; '
            # A bounded loop in this shell: the cursor contains ';', so it must
            # not be nested inside another quoted sh -c argument.
            "n=0; until journalctl -u lilly.service -o cat --no-pager "
            f'--after-cursor={shlex.quote(cursor)} | grep -q "vm.watch_ended"; do '
            'n=$((n + 1)); [ "$n" -lt 250 ]; sleep 0.02; done; '
            "echo $(( ($(date +%s%N) - start) / 1000000 ))"
        ).strip()
    )
    print(f"VMM death revoked through the watcher in {elapsed_ms} ms")
    assert elapsed_ms < 1000, elapsed_ms
    ended = l1.succeed(
        "journalctl -u lilly.service -o cat --no-pager --after-cursor="
        + shlex.quote(cursor)
        + " | grep vm.watch_ended"
    )
    assert '"reason":"exited"' in ended and placement in ended
    assert probe(new_tuple) == {"attribution": "unresolved"}


with subtest("VMM death revokes attribution through the native watcher"):
    brady_vmm_death_revocation()
