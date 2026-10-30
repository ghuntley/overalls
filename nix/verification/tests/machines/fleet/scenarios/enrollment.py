with subtest("disabled host fixtures become usable only after real authenticated observations"):
    enrolling = enrolled_provisioners()
    for machine in enrolling:
        machine.wait_for_unit("fleet-storage.service")
        machine.succeed("test -c /dev/kvm")
        observed = host_identity(machine)
        binding = host_bindings[machine.name]
        request = dict(
            version=3,
            name=machine.name,
            architecture="x86_64",
            machine_id=observed["machine_id"],
            overhead_cores=1,
            overhead_memory_bytes=1073741824,
            credential_ttl_seconds=14400 if relocation_enabled else 3600,
            pools=[
                dict(
                    name="guests",
                    storage=observed["storage"],
                    overhead_bytes=536870912,
                )
            ],
        )
        if relocation_enabled or porsche_enabled:
            machine.wait_for_unit("lilly-transfer-sshd.service")
            public = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").split()
            request["transfer_endpoint"] = dict(
                address=binding["ip"],
                port=2223 if audi_enabled else 2222,
                host_key=" ".join(public[:2]),
            )
        envelope = f"{root}/{machine.name}-credential.json"
        operator(
            m1,
            dict(
                action="enroll",
                host_id=binding["host"],
                pool_id=binding["pool"],
                request=request,
                output=envelope,
            ),
        )
        transfer(m1, envelope, machine, root + "/credential.json")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
        machine.succeed("fleet-seal-lilly")
        machine.succeed(f"touch {root}/ready")
        machine.wait_for_unit("lilly.service")

    def authenticated_enrollment_ready() -> bool:
        """@cc [owner:ghuntley,label:verification;protocol] enrollment-current-terminal-authority
        Setup MUST observe a fresh v4 execution-ready report advertising the
        established terminal protocol for every enrolled host. The initial
        execution-only report MUST NOT establish terminal authority; polling
        MUST remain read-only and bounded by the setup deadline.
        """
        return sql(
            "SELECT count(*) FROM compute_hosts "
            "WHERE inventory->>'execution_ready'='true' "
            "AND inventory->>'terminal_protocol'='2' "
            "AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') "
            "- interval '5 seconds'"
        ) == str(len(enrolling))

    eventually(authenticated_enrollment_ready, timeout=300)
    assert sql("SELECT count(*) FROM compute_hosts WHERE enabled") == "0"
    inventories = sql_json(
        "SELECT json_agg(json_build_object('cores',effective_cores,'memory',effective_memory_bytes,"
        "'inventory',inventory)) FROM compute_hosts"
    )
    assert isinstance(inventories, list)
    assert len(inventories) == len(enrolling)
    for row in inventories:
        assert isinstance(row, dict)
        inventory = row["inventory"]
        assert isinstance(inventory, dict)
        assert row["cores"] == 6 and row["memory"] == fixture_guest_memory_bytes
        assert inventory["architecture"] == "x86_64"
        assert set(inventory) == {
            "architecture",
            "images",
            "execution_ready",
            "terminal_protocol",
            "inception_image_id",
            "checkpoint_image_ids",
            "checkpoint_compatibility",
        }
        assert inventory["execution_ready"] is True
        assert inventory["terminal_protocol"] == 2
    pools = []

    def measured_pools() -> bool:
        """@cc [owner:ghuntley,label:verification] fleet-enrollment-measured-pools
        Setup MUST obtain fresh, positive, internally consistent native pool
        observations before proceeding. Host freshness alone is insufficient.
        Retries MUST remain bounded and MUST NOT fabricate or mutate capacity.
        Later assertions MUST inspect the same successful observation.
        """
        pools[:] = (
            sql_json(
                "SELECT json_agg(json_build_object('backend',backend,"
                "'free',free_bytes,'total',total_bytes,'fresh',"
                "reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds')) "
                "FROM compute_storage_pools"
            )
            or []
        )
        return len(pools) == len(enrolling) and all(
            pool["fresh"] is True and 0 < pool["free"] <= pool["total"] for pool in pools
        )

    try:
        eventually(measured_pools, timeout=300)
    except AssertionError:
        print(
            "Enrollment pool observations: "
            + json.dumps(
                [{key: pool[key] for key in ["free", "total", "fresh"]} for pool in pools[:2]]
            ),
            flush=True,
        )
        raise
    assert len(pools) == len(enrolling)
    for pool in pools:
        assert pool["backend"] == "zfs"
        assert 0 < pool["free"] <= pool["total"]
    # Measure steady-state cadence after both initial connection/report cycles;
    # start with enough freshness for the following database observations.
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE report_sequence >= 3 "
                "AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '3 seconds'"
            )
            == str(len(enrolling))
        )
    )
    samples = []
    for _ in range(6):
        samples.append(
            sql_json(
                "SELECT json_agg(row ORDER BY id) FROM (SELECT id,report_sequence,"
                "extract(epoch FROM clock_timestamp() - reported_at) AS age "
                "FROM compute_hosts) row"
            )
        )
        time.sleep(2)
    print("Public capacity cadence:", samples)
    if not agent_enabled:
        assert all(0 <= row["age"] < 5 for sample in samples for row in sample), (
            "Idle capacity expires between reports"
        )
    # The nested guest and model fixture contend for CPU in the agent variant.
    # Admission below still requires an actual fresh host report; transient
    # sample staleness is not an agent-path failure.
    assert all(
        samples[-1][i]["report_sequence"] > samples[0][i]["report_sequence"]
        for i in range(len(enrolling))
    )
    for machine in enrolling:
        candidate = host_bindings[machine.name]
        operator(m1, dict(action="enable", host_id=candidate["host"], enabled=True))
    if galileo_enabled or ssh_private_enabled:
        # Galileo's private trust file and Audi private bundle are startup
        # prerequisites, so prepare them before waiting for Galileo's unit.
        m1.succeed("systemctl start fleet-audi-ca.service")
        m1.wait_for_open_port(14000)
        m1.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 "
            f"https://m1:15000/roots/0 >{root}/audi-root.pem"
        )
    for machine in enrolling:
        binding = host_bindings[machine.name]
        token = f"{root}/{machine.name}-ziggy.token"
        m1.succeed(f"fleet-op ziggy-rotate {binding['host']} 14400 {token}", timeout=180)
        transfer(m1, token, machine, root + "/ziggy.token")
        machine.succeed("fleet-seal-ziggy")
        token = f"{root}/{machine.name}-galileo.token"
        m1.succeed(f"fleet-op galileo-rotate {binding['host']} 14400 {token}", timeout=180)
        transfer(m1, token, machine, root + "/galileo.token")
        machine.succeed("fleet-seal-galileo")
        # @cc [owner:ghuntley,label:verification;recovery] fleet-peach-bundle-sealed-dormant
        # Every fleet host declares the Peach SOPS bundle, and the real updater
        # stages every declared bundle before activation. Seal a credential
        # issued by the real Marshall domain at enrollment so the bundle
        # resolves like a deployed host; Peach itself stays stopped until a
        # scenario starts it (peach-fleet-explicit-start).
        token = f"{root}/peach-{machine.name}.token"
        operator(m1, dict(action="peach-enroll", host_id=binding["host"], output=token))
        transfer(m1, token, machine, root + "/peach.token")
        machine.succeed("fleet-seal-peach")
        if galileo_enabled or ssh_private_enabled:
            transfer(m1, root + "/audi-root.pem", machine, "/run/galileo-audi-root.pem")
            machine.succeed("chmod 0444 /run/galileo-audi-root.pem")
            machine.succeed("fleet-seal-audi-private")
        machine.wait_for_unit("ziggy.service")
        machine.wait_for_unit("galileo.service")
        machine.wait_until_succeeds(
            "curl --fail --silent --unix-socket /run/ziggy/proxy.sock http://localhost/health/ready "
            "| jq -e --arg host "
            + shlex.quote(binding["host"])
            + " '(.version == 1) and (.ready == true) and (.role == \"ziggy\") and (.host_id == $host)'",
            timeout=120,
        )
        if galileo_enabled or ssh_private_enabled:
            # @cc [owner:ghuntley,label:verification;recovery] fleet-private-front-after-provider-ready
            # The fixture MUST start the real private frontend after native
            # provider readiness. An initial dependency failure does not cause
            # systemd to start its dependent after that provider recovers.
            machine.succeed("systemctl start audi-private.service")
    users = operator(m1, dict(action="users", output=root + "/users.json"))
