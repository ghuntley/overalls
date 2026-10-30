# @cc [owner:ghuntley,label:verification;security] galileo-full-fleet-acceptance
# Requests MUST originate inside real Firecracker guests and traverse packaged
# Audi private, Galileo, real Marshall and either the verified TLS origin or the
# destination's packaged public Audi gateway. Setup may use only closed operator
# actions. SQL is observation-only and synthetic control replies are forbidden.


def galileo_metrics(machine: MachineLike, gauge_name: str) -> int:
    value: object = json.loads(
        machine.succeed(
            "curl --fail --silent --unix-socket /run/galileo/proxy.sock http://galileo/metrics"
        )
    )
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        fields[key] = item
    gauges: object = fields.get("gauges")
    assert isinstance(gauges, dict)
    gauge_map: dict[str, object] = {}
    for key, item in gauges.items():
        assert isinstance(key, str)
        gauge_map[key] = item
    gauge = gauge_map.get(gauge_name)
    assert isinstance(gauge, int)
    return gauge


def origin_count() -> int:
    return int(egress.succeed("cat /run/galileo-origin/count").strip())


def galileo_audi_ready(machine: MachineLike, path: str, role: str) -> bool:
    """Return only exact, live readiness from an Audi status socket."""
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
    value: dict[str, object] = json.loads(output)
    assert set(value) == {"version", "role", "ready"}
    assert type(value["version"]) is int and value["version"] == 1
    assert value["role"] == role and type(value["ready"]) is bool
    return value["ready"]


with subtest("both Lilly hosts receive real Galileo credentials and private wildcard custody"):
    egress.wait_for_unit("fleet-galileo-origin.service")
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 "
        f"https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        binding = host_bindings[machine.name]
        token = f"{root}/galileo-{machine.name}.token"
        issued = operator(
            m1,
            dict(action="galileo-enroll", host_id=binding["host"], output=token),
        )
        assert issued["issued"] is True and issued["host_id"] == binding["host"]
        transfer(m1, token, machine, root + "/galileo.token")
        transfer(m1, root + "/audi-root.pem", machine, "/run/galileo-audi-root.pem")
        machine.succeed("chmod 0444 /run/galileo-audi-root.pem")
        machine.succeed("fleet-seal-galileo", "fleet-seal-audi-private")
        # Enrollment already started the secret bundle and Galileo with the
        # previous credential. Reload both before checking current authority.
        machine.succeed("systemctl restart overalls-secrets-galileo.service")
        machine.succeed("systemctl restart galileo.service")
        machine.wait_for_unit("galileo.service")
        machine.wait_for_unit("audi-private.service")
        try:
            machine.wait_until_succeeds(
                "curl --fail --silent --unix-socket /run/galileo/proxy.sock "
                "http://galileo/health/ready | jq -e '.ready == true and .role == \"galileo\"'",
                timeout=120,
            )
        except Exception:
            if otel_galileo_enabled:
                ready_code, ready_output = machine.execute(
                    "curl --silent --unix-socket /run/galileo/proxy.sock "
                    "http://galileo/health/ready"
                )
                slo_code, slo_output = machine.execute(
                    "curl --silent --output /dev/null --write-out '%{http_code}' "
                    "--unix-socket /run/galileo/proxy.sock http://localhost/slo"
                )
                print(
                    f"{machine.name} Galileo readiness: curl={ready_code} "
                    f"body={ready_output[:256]!r}; SLO curl={slo_code} status={slo_output.strip()!r}"
                )
            raise
        eventually(
            lambda machine=machine: galileo_audi_ready(
                machine, "/run/audi-private/status.sock", "private"
            ),
            timeout=60,
        )

with subtest("existing public Audi roles receive independent production credentials"):
    for machine in [m2, m3]:
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path)
        )
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
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
    for machine in [m2, m3]:
        eventually(
            lambda machine=machine: galileo_audi_ready(machine, "/run/audi-dns/status.sock", "dns"),
            timeout=60,
        )
    for machine in provisioners:
        eventually(
            lambda machine=machine: galileo_audi_ready(machine, "/run/audi/status.sock", "gateway"),
            timeout=60,
        )

with subtest("source and peer target are real guests on different enrolled hosts"):
    operator(m1, dict(action="enable", host_id=host_bindings["l1"]["host"], enabled=False))
    try:
        target = provision_when_available(m1, "standard")
    finally:
        operator(m1, dict(action="enable", host_id=host_bindings["l1"]["host"], enabled=True))
    await_running(target["vm_id"])
    assert target["host_id"] == host_bindings["l2"]["host"]

    operator(m1, dict(action="enable", host_id=host_bindings["l2"]["host"], enabled=False))
    try:
        galileo_source = provision_when_available(m1, "standard")
    finally:
        operator(m1, dict(action="enable", host_id=host_bindings["l2"]["host"], enabled=True))
    await_running(galileo_source["vm_id"])
    assert galileo_source["host_id"] == host_bindings["l1"]["host"]
    assert galileo_source["host_id"] != target["host_id"]

    host_for(target).succeed(
        "fleet-galileo-guest serve-peer "
        + shlex.quote(target["placement_id"])
        + " "
        + shlex.quote(galileo_source["vm_id"]),
        timeout=180,
    )
    target_policy = operator(
        m1,
        dict(
            action="audi-policy",
            owner_id=users["owner_id"],
            vm_id=target["vm_id"],
            visibility="public",
        ),
    )
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM ingress_routes WHERE vm_id='{target['vm_id']}' "
                "AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    assert target_policy["label"]
    target_hostname = str(target_policy["label"]) + ".apps.example.test"

with subtest("Peach projects the running guest through Audi private and real Marshall"):
    for machine in provisioners:
        binding = host_bindings[machine.name]
        token = f"{root}/peach-{machine.name}.token"
        issued = operator(
            m1,
            dict(action="peach-enroll", host_id=binding["host"], output=token),
        )
        assert issued["issued"] is True and issued["host_id"] == binding["host"]
        transfer(m1, token, machine, root + "/peach.token")
        machine.succeed("fleet-seal-peach")
        machine.succeed("systemctl start peach.service")
        machine.wait_for_unit("peach.service")
        machine.succeed("test -S /run/peach/reflection.sock")
        machine.succeed('test "$(stat -c %G:%a /run/peach/reflection.sock)" = peach-proxy:660')
        machine.succeed('test "$(stat -c %a /run/peach/credentials)" = 700')
    host_for(galileo_source).succeed(
        "fleet-galileo-guest reflection-ok "
        + shlex.quote(galileo_source["placement_id"])
        + " "
        + shlex.quote(galileo_source["vm_id"]),
        timeout=120,
    )

with subtest("attachment denial, grant and detach traverse the complete private path"):
    operator(m1, dict(action="galileo-configure-direct", owner_id=users["stranger_id"]))
    operator(
        m1,
        dict(
            action="galileo-configure-peer",
            owner_id=users["owner_id"],
            target_vm_id=target["vm_id"],
        ),
    )
    operator(
        m1,
        dict(
            action="galileo-attach-peer",
            owner_id=users["owner_id"],
            vm_id=galileo_source["vm_id"],
        ),
    )
    before = origin_count()
    host_for(galileo_source).succeed(
        "fleet-galileo-guest direct-denied " + shlex.quote(galileo_source["placement_id"]),
        timeout=60,
    )
    assert origin_count() == before
    attached = operator(
        m1,
        dict(
            action="galileo-attach-direct",
            owner_id=users["stranger_id"],
            vm_id=galileo_source["vm_id"],
        ),
    )
    assert attached["attached"] is True
    host_for(galileo_source).succeed(
        "fleet-galileo-guest direct-success " + shlex.quote(galileo_source["placement_id"]),
        timeout=60,
    )
    operator(
        m1,
        dict(
            action="galileo-detach-direct",
            owner_id=users["stranger_id"],
            vm_id=galileo_source["vm_id"],
        ),
    )
    before = origin_count()
    host_for(galileo_source).succeed(
        "fleet-galileo-guest direct-denied " + shlex.quote(galileo_source["placement_id"]),
        timeout=60,
    )
    assert origin_count() == before
    operator(
        m1,
        dict(
            action="galileo-attach-direct",
            owner_id=users["stranger_id"],
            vm_id=galileo_source["vm_id"],
        ),
    )

if otel_galileo_enabled:
    with subtest("real Galileo guest outcome reaches isolated Rust OTLP collector intake"):
        source_host = host_for(galileo_source)
        source_host.wait_until_succeeds(
            'jq -e \'.service == "galileo" and .requests >= 1 and .successes >= 1 '
            "and .requests == (.successes + .failures) and "
            "([.duration.bucket_counts[]] | add) == .duration.count' /run/overalls-request-galileo-source/slo.json",
            timeout=45,
        )
        source_host.wait_for_unit("overalls-request-galileo-exporter.service")
        source_host.wait_until_succeeds(
            "curl -fsS http://127.0.0.1:9464/metrics | "
            'grep -E \'overalls_outer_galileo_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="galileo"[^}]*\\} [1-9][0-9]*\'',
            timeout=45,
        )
        source_host.wait_until_succeeds(
            'jq -e \'.service == "audi_private" and .requests >= 1 '
            "and .successes >= 1 and .requests == (.successes + .failures)' "
            "/run/overalls-request-audi-private-source/slo.json",
            timeout=45,
        )
        source_host.wait_for_unit("overalls-request-audi-private-exporter.service")
        source_host.wait_until_succeeds(
            "curl -fsS http://127.0.0.1:9464/metrics | "
            'grep -E \'overalls_outer_audi_private_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="audi_private"[^}]*\\} [1-9][0-9]*\'',
            timeout=45,
        )
        source_host.succeed(
            "code=$(runuser -u audi -- curl --silent --output /dev/null "
            "--write-out '%{http_code}' --unix-socket "
            "/run/overalls-otel-audi-private/collector.sock http://localhost/v1/metrics || true); "
            'test "$code" = 000'
        )
        source_host.succeed(
            "code=$(runuser -u galileo -- curl --silent --output /dev/null "
            "--write-out '%{http_code}' --unix-socket "
            "/run/overalls-otel-galileo/collector.sock http://localhost/v1/metrics || true); "
            'test "$code" = 000'
        )
        before_slo = int(
            source_host.succeed(
                "curl -fsS --unix-socket /run/galileo/proxy.sock "
                "http://localhost/slo | jq -r '.requests'"
            )
        )
        operator(
            m1,
            dict(
                action="galileo-detach-direct",
                owner_id=users["stranger_id"],
                vm_id=galileo_source["vm_id"],
            ),
        )
        source_host.succeed(
            "fleet-galileo-guest direct-denied " + shlex.quote(galileo_source["placement_id"]),
            timeout=60,
        )
        after_slo = int(
            source_host.succeed(
                "curl -fsS --unix-socket /run/galileo/proxy.sock "
                "http://localhost/slo | jq -r '.requests'"
            )
        )
        assert after_slo == before_slo
        operator(
            m1,
            dict(
                action="galileo-attach-direct",
                owner_id=users["stranger_id"],
                vm_id=galileo_source["vm_id"],
            ),
        )

    def galileo_slo_ready() -> None:
        source_host.wait_until_succeeds(
            "curl -fsS --unix-socket /run/galileo/proxy.sock "
            "http://localhost/health/ready | jq -e '.ready == true and .role == \"galileo\"'"
        )
        source_host.wait_for_unit("audi-private.service")
        audi_private_slo_ready()

    def audi_private_slo_ready() -> None:
        eventually(
            lambda: galileo_audi_ready(source_host, "/run/audi-private/status.sock", "private"),
            timeout=60,
        )

    def galileo_slo_probe() -> None:
        source_host.succeed(
            "fleet-galileo-guest direct-success " + shlex.quote(galileo_source["placement_id"]),
            timeout=60,
        )

    galileo_slo_guest_before = process_snapshot(galileo_source)
    for accounting_guest in (galileo_source, target):
        host_for(accounting_guest).succeed(
            "fleet-galileo-guest pause-authority-refresh "
            + shlex.quote(accounting_guest["placement_id"]),
            timeout=60,
        )
    try:
        transport_restart_faults(source_host, "galileo", galileo_slo_ready, galileo_slo_probe)
        transport_restart_faults(
            source_host, "audi_private", audi_private_slo_ready, galileo_slo_probe
        )
    finally:
        for accounting_guest in (galileo_source, target):
            host_for(accounting_guest).succeed(
                "fleet-galileo-guest resume-authority-refresh "
                + shlex.quote(accounting_guest["placement_id"]),
                timeout=60,
            )
    assert process_snapshot(galileo_source) == galileo_slo_guest_before

with subtest("bounded upload and sustained guest load preserve complete bodies"):
    source_host = host_for(galileo_source)
    source_host.succeed(
        "fleet-galileo-guest upload " + shlex.quote(galileo_source["placement_id"]), timeout=90
    )
    before = origin_count()
    source_host.succeed(
        "fleet-galileo-guest load " + shlex.quote(galileo_source["placement_id"]), timeout=180
    )
    assert origin_count() == before + 32
    metrics = galileo_metrics(source_host, "galileo_active_requests")
    assert metrics == 0

with subtest("execution stop fences a stalled request and restart obtains fresh authority"):
    source_host.succeed(
        "fleet-galileo-guest start-stall " + shlex.quote(galileo_source["placement_id"]), timeout=60
    )
    eventually(
        lambda: galileo_metrics(source_host, "galileo_active_requests") == 1,
        timeout=20,
    )
    lifecycle(galileo_source["vm_id"], "stop")
    eventually(lambda: vm_state(galileo_source["vm_id"]) == "stopped", timeout=180)
    eventually(
        lambda: galileo_metrics(source_host, "galileo_active_requests") == 0,
        timeout=20,
    )
    eventually(fresh_hosts, timeout=120)
    lifecycle(galileo_source["vm_id"], "start")
    await_running(galileo_source["vm_id"])
    galileo_source = current_copy(galileo_source["vm_id"])
    host_for(galileo_source).succeed(
        "fleet-galileo-guest direct-success " + shlex.quote(galileo_source["placement_id"]),
        timeout=60,
    )

with subtest("cross-host peer ingress replaces provenance and consumes the peer token"):
    source_host = host_for(galileo_source)
    source_host.wait_until_succeeds(
        "test \"$(curl --silent --output /dev/null --write-out '%{http_code}' "
        f'--cacert {root}/audi-root.pem https://{target_hostname}/)" = 403',
        timeout=120,
    )
    source_host.succeed(
        "fleet-galileo-guest peer-success "
        + shlex.quote(galileo_source["placement_id"])
        + " "
        + shlex.quote(galileo_source["vm_id"]),
        timeout=90,
    )

with subtest("source relocation resolves new private routing and retires the stale source"):
    old = current_copy(galileo_source["vm_id"])
    old_host = host_for(old)
    move = relocate(galileo_source["vm_id"])
    moved = await_relocation(move, abort_on_readiness_failure=True)
    await_running(moved["vm_id"])
    assert moved["host_id"] != old["host_id"]
    assert host_for(moved) != old_host
    old_host.fail(
        "systemctl is-active lilly-vm-" + shlex.quote(old["placement_id"]) + ".service",
        "zfs list zroot/lilly/vm-" + shlex.quote(old["placement_id"]),
    )
    # The restored guest keeps its pre-relocation gateway neighbour; it must
    # already name the destination TAP before any guest traffic re-resolves it.
    host_for(moved).succeed(
        "fleet-galileo-guest gateway-neighbour " + shlex.quote(moved["placement_id"]), timeout=90
    )
    host_for(moved).succeed(
        "fleet-galileo-guest direct-success " + shlex.quote(moved["placement_id"]), timeout=90
    )
    host_for(moved).succeed(
        "fleet-galileo-guest peer-success "
        + shlex.quote(moved["placement_id"])
        + " "
        + shlex.quote(moved["vm_id"]),
        timeout=90,
    )
    galileo_source = moved

with subtest("all-Marshall outage fails closed before origin and recovers"):
    before = origin_count()
    try:
        for machine in marshalls:
            machine.succeed(
                f"systemctl kill --signal=STOP --kill-whom=main marshall-{machine.name}.service"
            )
        host_for(galileo_source).succeed(
            "fleet-galileo-guest direct-unavailable " + shlex.quote(galileo_source["placement_id"]),
            timeout=60,
        )
        assert origin_count() == before
    finally:
        for machine in marshalls:
            machine.succeed(
                f"systemctl kill --signal=CONT --kill-whom=main marshall-{machine.name}.service"
            )
    eventually(fresh_hosts, timeout=120)
    host_for(galileo_source).succeed(
        "fleet-galileo-guest direct-success " + shlex.quote(galileo_source["placement_id"]),
        timeout=90,
    )
