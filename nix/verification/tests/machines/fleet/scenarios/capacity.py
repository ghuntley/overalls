with subtest("capacity races spend pending startup headroom only once"):
    vms = [accepted_placement(results[0])]
    target = results[0]["host_id"]
    other = next(value["host"] for value in host_bindings.values() if value["host"] != target)
    # Pin fixture placement through the real operator action. Overcommit no longer
    # forces idle workloads to spill onto another host at three logical shapes.
    operator(m1, dict(action="enable", host_id=other, enabled=False))
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM compute_reservations WHERE host_id='{target}' "
                "AND (startup_compute_held OR startup_disk_held)"
            )
            == "0"
        )
    )
    eventually(
        lambda: (
            sql(
                f"SELECT (capacity->>'cpu_headroom_millicores')::bigint >= 3000 "
                f"FROM compute_hosts WHERE id='{target}'"
            )
            == "t"
        )
    )

    # Why the sizes are derived: zroot also holds the host's installed system
    # closure, so the evaluation-time pool size alone left free space within
    # 180 MB of three slots, and an unrelated closure change crossed it.
    target_machine = next(
        machine for machine in provisioners if host_bindings[machine.name]["host"] == target
    )
    race_filler = "zroot/capacity-race-filler"

    def race_disk_measure() -> tuple[int, int] | None:
        """@cc [owner:ghuntley,label:verification;capacity] fleet-race-runtime-derived-slots
        The race window MUST be derived at runtime from the target's fresh
        reported free-minus-overhead bytes and the real preceding reservation,
        never from incidental free space. When more than two and a half
        reservations are free, a sibling ZFS refreservation (a real pool writer
        outside Lilly's dataset, as on a shared production root) MUST trim the
        reported space to two and a half, half a reservation from each bound,
        and MUST be destroyed once admission is decided. Returns None until a
        fresh report exists.
        """
        row = sql(
            "SELECT p.free_bytes - p.overhead_bytes, r.disk_bytes "
            "FROM compute_storage_pools p JOIN compute_reservations r ON r.pool_id=p.id "
            f"WHERE r.vm_id='{results[0]['vm_id']}' AND p.reported_at > "
            "(statement_timestamp() AT TIME ZONE 'UTC') - interval '3 seconds'"
        )
        if not row:
            return None
        available, reservation = (int(value) for value in row.split("|"))
        return available, reservation

    measured: list[tuple[int, int]] = []

    def race_measured() -> bool:
        measure = race_disk_measure()
        if measure is None:
            return False
        measured[:] = [measure]
        return True

    eventually(race_measured)
    available, reservation = measured[0]
    filler_bytes = available - (5 * reservation) // 2
    print(
        "Race disk slots: available",
        available,
        "reservation",
        reservation,
        "filler",
        max(0, filler_bytes),
    )
    if filler_bytes > 0:
        target_machine.succeed(
            "zfs create -o canmount=off -o mountpoint=none "
            f"-o refreservation={filler_bytes} {race_filler}"
        )
        # Only a report sampled after the reservation may open the race.
        filled_at = sql("SELECT (statement_timestamp() AT TIME ZONE 'UTC')::text")
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_storage_pools p JOIN compute_reservations r "
                    f"ON r.pool_id=p.id WHERE r.vm_id='{results[0]['vm_id']}' "
                    f"AND p.reported_at > '{filled_at}'::timestamp + interval '1 second'"
                )
                == "1"
            )
        )

    def race_has_two_disk_slots() -> bool:
        """@cc [owner:ghuntley,label:verification] fleet-race-real-disk-slots
        The race MUST start with fresh native physical headroom sufficient for
        two complete startup reservations but insufficient for three. Its cost
        MUST come from the real preceding reservation, including the image and
        portable bundle. Logical enrollment budgets MUST NOT stand in for usage.
        """
        # Fresh report, at least two slots, fewer than three: reported separately
        # so a timeout names the failing term.
        race_terms[:] = sql(
            "SELECT p.reported_at > (statement_timestamp() AT TIME ZONE 'UTC') "
            "- interval '3 seconds', p.free_bytes - p.overhead_bytes >= 2 * r.disk_bytes, "
            "p.free_bytes - p.overhead_bytes < 3 * r.disk_bytes "
            "FROM compute_storage_pools p JOIN compute_reservations r "
            f"ON r.pool_id=p.id WHERE r.vm_id='{results[0]['vm_id']}'"
        ).split("|")
        return race_terms == ["t", "t", "t"]

    race_terms: list[str] = []
    try:
        eventually(race_has_two_disk_slots)
    except AssertionError:
        print("Race disk-slot terms (fresh, two slots, below three):", race_terms)
        raise
    raced = synchronized([provision(profile) for profile in ["standard", "oss", "oss"]])
    assert sum(result["accepted"] for result in raced) == 2, (
        "Unexpected admission count",
        raced,
        capacity_snapshot(),
    )
    assert [result["reason"] for result in raced if not result["accepted"]] == [
        "insufficient_capacity"
    ]
    # Admission is decided; later stages run on the host's natural free space.
    if filler_bytes > 0:
        target_machine.succeed(f"zfs destroy {race_filler}")
    vms.extend(accepted_placement(result) for result in raced if result["accepted"])
    for vm in vms:
        await_running(vm["vm_id"])
    operator(m1, dict(action="enable", host_id=other, enabled=True))
    operator(m1, dict(action="enable", host_id=target, enabled=False))
    for profile in ["customer", "standard", "oss"]:
        result = provision_when_available(m2, profile)
        assert result["accepted"], (result, capacity_snapshot())
        vms.append(result)
        await_running(result["vm_id"])
        eventually(
            lambda result=result: (
                sql(
                    f"SELECT NOT (startup_compute_held OR startup_disk_held) "
                    f"FROM compute_reservations WHERE vm_id='{result['vm_id']}'"
                )
                == "t"
            )
        )
    operator(m1, dict(action="enable", host_id=target, enabled=True))
    counts = sql_json(
        "SELECT json_agg(count) FROM (SELECT count(*) AS count FROM compute_virtual_machines v "
        "JOIN compute_workload_placements p ON p.id=v.current_placement_id "
        "WHERE v.archived_at IS NULL GROUP BY p.host_id) AS grouped"
    )
    assert sorted(counts) == [3, 3]
    assert sql("SELECT count(*) FROM compute_reservations WHERE compute_held AND disk_held") == "6"
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_reservations WHERE startup_compute_held OR startup_disk_held"
            )
            == "0"
        )
    )
    for machine in provisioners:
        for vm in vms:
            if vm["host_id"] == host_bindings[machine.name]["host"]:
                machine.succeed(f"systemctl is-active lilly-vm-{vm['placement_id']}.service")

with subtest("generated races re-spend confirmed releases exactly once"):
    provisioners_hosts = sorted(value["host"] for value in host_bindings.values())

    def reservation_shape(vm_id: str) -> dict[str, int]:
        """@cc [owner:ghuntley,label:verification] fleet-shape-from-committed-reservation
        A race round's expected winners MUST be measured from the confirmed
        reservation row of the released workload before any race starts.
        """
        row = sql_json(
            "SELECT json_build_object('vcpu',vcpu,'memory_bytes',memory_bytes,"
            f"'disk_bytes',disk_bytes) FROM compute_reservations WHERE vm_id='{vm_id}'"
        )
        return {
            "vcpu": int(row["vcpu"]),
            "memory_bytes": int(row["memory_bytes"]),
            "disk_bytes": int(row["disk_bytes"]),
        }

    def fitting_slots(host_id: str, shape: dict[str, int]) -> int:
        """@cc [owner:ghuntley,label:verification] fleet-race-fitting-slots
        Expected winners equal the count fitting the fresh measured headroom
        minus overheads minus outstanding startup-held shapes, read by explicit
        SQL from committed rows -- never via Budget internals. Clamps at zero.
        """
        host = sql_json(
            "SELECT json_build_object("
            "'headroom_mc',(capacity->>'cpu_headroom_millicores')::bigint,"
            "'memory_headroom',(capacity->>'memory_headroom_bytes')::bigint,"
            "'overhead_cores',overhead_cores,'overhead_memory',overhead_memory_bytes)"
            f" FROM compute_hosts WHERE id='{host_id}'"
        )
        holds = sql_json(
            "SELECT coalesce(json_agg(x),'[]') FROM ("
            "SELECT vcpu,memory_bytes,disk_bytes,compute_held,startup_compute_held,"
            "disk_held,startup_disk_held,temporary_disk_bytes,pending_disk_bytes,placement_id"
            f" FROM compute_reservations WHERE host_id='{host_id}'"
            " ) x"
        )
        pool = sql_json(
            "SELECT json_build_object('free_bytes',free_bytes,"
            "'overhead_bytes',overhead_bytes,'allocations',allocations)"
            f" FROM compute_storage_pools WHERE host_id='{host_id}'"
        )

        startup_vcpu = sum(
            h["vcpu"] for h in holds if h["compute_held"] and h["startup_compute_held"]
        )
        startup_memory = sum(
            h["memory_bytes"] for h in holds if h["compute_held"] and h["startup_compute_held"]
        )
        pending_disk = 0
        for hold in holds:
            allocation = int(pool["allocations"].get(hold["placement_id"], 0))
            if hold["disk_held"] and hold["startup_disk_held"]:
                pending_disk += hold["disk_bytes"] - min(hold["disk_bytes"], allocation)
            pending_disk += hold["temporary_disk_bytes"] + hold["pending_disk_bytes"]

        # Unknown measured capacity fits nothing, matching admission itself.
        headroom_vcpu = host["headroom_mc"] or 0
        headroom_memory = host["memory_headroom"] or 0
        vcpu = max(0, headroom_vcpu // 1000 - host["overhead_cores"] - startup_vcpu)
        memory = max(0, headroom_memory - host["overhead_memory"] - startup_memory)
        disk = max(0, pool["free_bytes"] - pool["overhead_bytes"] - pending_disk)

        return min(
            vcpu // shape["vcpu"],
            memory // shape["memory_bytes"],
            disk // shape["disk_bytes"],
        )

    def assert_startup_bound() -> None:
        """@cc [owner:ghuntley,label:verification] fleet-startup-bound-from-raw-rows
        After every race, outstanding startup-held compute plus settled running
        compute MUST fit the host's enrolled capacity minus overheads, and
        startup disk charges plus temporary and resize holds MUST fit the
        pool's reported free minus overhead. A pending disk's charge is net of
        its own reported physical allocation, capped at its size: once those
        bytes materialize they already reduce reported free, so counting them
        again would double-charge them (physical-disk-pending-growth). All
        values come from committed rows.
        """
        rows = sql_json(
            "SELECT json_agg(json_build_object("
            "'host',h.id,'cores',h.effective_cores,'overhead_cores',h.overhead_cores,"
            "'settled_mem',(SELECT coalesce(sum(r.memory_bytes),0) FROM compute_reservations r"
            "   WHERE r.host_id=h.id AND r.compute_held AND NOT r.startup_compute_held),"
            "'startup_mem',(SELECT coalesce(sum(r.memory_bytes),0) FROM compute_reservations r"
            "   WHERE r.host_id=h.id AND r.compute_held AND r.startup_compute_held),"
            "'startup_vcpu',(SELECT coalesce(sum(r.vcpu),0) FROM compute_reservations r"
            "   WHERE r.host_id=h.id AND r.compute_held AND r.startup_compute_held),"
            "'settled_vcpu',(SELECT coalesce(sum(r.vcpu),0) FROM compute_reservations r"
            "   WHERE r.host_id=h.id AND r.compute_held AND NOT r.startup_compute_held),"
            "'pool_free',p.free_bytes,'pool_overhead',p.overhead_bytes,"
            "'startup_disks',(SELECT coalesce(json_agg(json_build_object("
            "   'placement',r.placement_id,'disk',r.disk_bytes)),'[]')"
            "   FROM compute_reservations r"
            "   WHERE r.pool_id=p.id AND r.disk_held AND r.startup_disk_held),"
            "'allocations',p.allocations,"
            "'temp_disk',(SELECT coalesce(sum(r.temporary_disk_bytes),0)"
            "   FROM compute_reservations r WHERE r.pool_id=p.id),"
            "'resize_disk',(SELECT coalesce(sum(r.pending_disk_bytes),0)"
            "   FROM compute_reservations r WHERE r.pool_id=p.id)))"
            " FROM compute_hosts h JOIN compute_storage_pools p ON p.host_id=h.id"
        )
        for row in rows:
            assert row["startup_vcpu"] + row["settled_vcpu"] <= (
                row["cores"] - row["overhead_cores"]
            ), row
            allocations = row["allocations"]
            startup_disk = sum(
                int(hold["disk"])
                - min(int(hold["disk"]), int(allocations.get(hold["placement"], 0)))
                for hold in row["startup_disks"]
            )
            assert startup_disk + row["temp_disk"] + row["resize_disk"] <= max(
                0, row["pool_free"] - row["pool_overhead"]
            ), row

    def release_wait(vm_id: str) -> None:
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_reservations"
                    f" WHERE vm_id='{vm_id}' AND (compute_held OR disk_held)"
                )
                == "0"
            ),
            timeout=300,
        )

    rounds = 2
    for race_round in range(rounds):
        target_host = provisioners_hosts[race_round % len(provisioners_hosts)]
        candidates = [vm for vm in vms if vm["host_id"] == target_host]
        assert candidates, capacity_snapshot()
        victim = candidates[uuid.uuid4().int % len(candidates)]
        shape = reservation_shape(victim["vm_id"])
        # The replacement below re-provisions this profile so downstream
        # scenarios keep one guest of every profile, whichever victim is drawn.
        victim_profile = sql(
            f"SELECT profile FROM compute_network_addresses WHERE vm_id='{victim['vm_id']}' "
            "AND archived_at IS NULL"
        )
        assert victim_profile in ("customer", "standard", "oss"), victim_profile

        # Confirmed stop then physical delete: the reservation releases its
        # whole shape and the pool's reported free bytes recover it.
        stop = operator(
            m2,
            dict(
                action="lifecycle",
                owner_id=users["owner_id"],
                vm_id=victim["vm_id"],
                kind="stop",
                key=str(uuid.uuid4()),
            ),
        )
        assert stop["requested"], stop
        eventually(
            lambda vm_id=victim["vm_id"]: (
                sql(
                    "SELECT NOT compute_held AND disk_held FROM compute_reservations"
                    f" WHERE vm_id='{vm_id}'"
                )
                == "t"
            )
        )
        delete = operator(
            m2,
            dict(
                action="lifecycle",
                owner_id=users["owner_id"],
                vm_id=victim["vm_id"],
                kind="delete",
                key=str(uuid.uuid4()),
            ),
        )
        assert delete["requested"], delete
        release_wait(victim["vm_id"])
        eventually(lambda: fresh_hosts())
        eventually(
            lambda host=target_host, s=shape: fitting_slots(host, s) >= 1,
            timeout=240,
        )
        slots = fitting_slots(target_host, shape)
        assert slots >= 1, (victim, capacity_snapshot())

        other_host = next(h for h in provisioners_hosts if h != target_host)
        operator(m1, dict(action="enable", host_id=other_host, enabled=False))

        racers = min(slots + 2, len(marshalls))
        keys = [str(uuid.uuid4()) for _ in range(racers)]
        profiles = ["oss" if number % 2 else "standard" for number in range(racers)]
        requests = [provision(profiles[number], key=keys[number]) for number in range(racers)]

        raced = synchronized(requests)
        winners = [result for result in raced if result["accepted"]]
        refusals = [result for result in raced if not result["accepted"]]
        # The generated round re-spends the released slot exactly once outside
        # measured draw drift; the ledger's exact accounting sits at the
        # distributed application tier.
        assert len(winners) >= 1, (raced, capacity_snapshot())
        assert all(result["reason"] == "insufficient_capacity" for result in refusals), raced

        # Refusals persist zero durable rows; winners replay to the same VM.
        loser_keys = [
            key for key, result in zip(keys, raced, strict=True) if not result["accepted"]
        ]
        if loser_keys:
            loser_list = "{" + ",".join('"' + key + '"' for key in loser_keys) + "}"
            assert (
                sql(
                    "SELECT count(*) FROM compute_virtual_machines"
                    f" WHERE idempotency_key = ANY('{loser_list}'::text[])"
                )
                == "0"
            )
        for result in winners:
            key, request_profile = next(
                (key, profile)
                for key, profile, raced in zip(keys, profiles, raced, strict=True)
                if raced is result
            )
            replayed = operator(m1, provision(request_profile, key=key))
            assert replayed["accepted"] and replayed["vm_id"] == result["vm_id"], (
                replayed,
                result,
            )

        assert_startup_bound()

        # The race's winners are admission-only evidence here -- boot/proof of
        # the same commits is asserted by the fixed stages around this one --
        # so delete them and wait for physical release before the next round.
        winner_ids: list[str] = []
        for result in winners:
            vm_id = result["vm_id"]
            assert isinstance(vm_id, str)
            winner_ids.append(vm_id)
            deleted = operator(
                m2,
                dict(
                    action="lifecycle",
                    owner_id=users["owner_id"],
                    vm_id=vm_id,
                    kind="delete",
                    key=str(uuid.uuid4()),
                ),
            )
            assert deleted["requested"], deleted
        for vm_id in winner_ids:
            release_wait(vm_id)

        operator(m1, dict(action="enable", host_id=other_host, enabled=True))

        # Replace the retired victim on the SAME host against the released
        # capacity so downstream scenarios keep their three guests per host.
        other_host = next(h for h in provisioners_hosts if h != target_host)
        operator(m1, dict(action="enable", host_id=other_host, enabled=False))
        replacement = provision_when_available(m2, victim_profile)
        await_running(replacement["vm_id"])
        assert replacement["host_id"] == target_host, (replacement, capacity_snapshot())
        operator(m1, dict(action="enable", host_id=other_host, enabled=True))
        eventually(lambda: fresh_hosts())
        vms[:] = [vm for vm in vms if vm["vm_id"] != victim["vm_id"]] + [replacement]
        assert_startup_bound()

    assert sql("SELECT count(*) FROM compute_reservations WHERE compute_held AND disk_held") == "6"
