"""Native launch fencing and authenticated settlement driven by Hegel.

The registered property preserves the imperative evidence label ``real launch
submission and authenticated outcome survive whole daemon loss``.
# real launch submission and authenticated outcome survive whole daemon loss
"""

from hegel import TestCase, given, sampled_from


@given(host_index=sampled_from([0, 1]), reopens=sampled_from([1, 2]))
def submission_daemon_recovery(tc: TestCase, host_index: int, reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-submission-daemon-recovery
    Each history MUST observe a real before/after submission checkpoint and old
    daemon death. Before submission MUST refuse the fenced generation; after
    submission MUST adopt the exact VMM. Authenticated settlement and subsequent
    daemon reopens MUST preserve outcome identity and unrelated native processes.
    """
    # Every generated history owns its daemon fault and returns the shared fleet
    # to a usable baseline, so Hegel can shrink and replay one draw sequence.
    machine = provisioners[host_index]
    for provisioner in provisioners:
        provisioner.succeed("systemctl start lilly.service")
    eventually(fresh_hosts)
    victim = next(vm for vm in vms if host_for(vm) is machine and vm["profile"] == "standard")
    vm_id = victim["vm_id"]
    placement = victim["placement_id"]
    barrier = "/run/fleet-submission-barrier"
    unit = f"lilly-vm-{placement}.service"
    marker = f"/var/lib/lilly/vms/{placement}/launch-attempt.bin"
    survivors = {vm["vm_id"]: process_snapshot(vm) for vm in vms if vm != victim}

    try:
        for phase in ("before", "after"):
            lifecycle(vm_id, "stop")
            eventually(lambda: vm_state(vm_id) == "stopped")
            machine.fail(f"systemctl is-active {unit}")
            machine.succeed(f"rm -rf {barrier}; install -d -m 0700 {barrier}")
            selector = placement + "\n" + phase + "\n"
            machine.succeed("printf %s " + shlex.quote(selector) + f" > {barrier}/armed")
            old_pid = int(machine.succeed("systemctl show -p MainPID --value lilly.service"))
            assert old_pid > 0
            try:
                lifecycle(vm_id, "start")
                machine.wait_until_succeeds(
                    f"test -f {barrier}/reached && "
                    "systemctl kill --kill-whom=all --signal=STOP lilly.service",
                    timeout=30,
                )
                assert machine.succeed(f"cat {barrier}/reached").strip() == phase
                worker_pid, worker_start = (
                    int(value)
                    for value in machine.succeed(f"cat {barrier}/worker").strip().split(":")
                )
                assert worker_pid > 0 and worker_start > 0
                # lilly-hostd, not the BEAM, runs the submission (vm_launch.rs).
                # ADR-0176 decision 3: each hostd command runs in its own run-<n>
                # child of hostd's delegated cgroup (never hostd's daemon leaf),
                # so the paused worker is not suspended with lilly.service; hostd
                # kills and reaps it when the BEAM session closes
                # (session-close-custody) or at its own 10 s launch timeout.
                # Not asserted here: that the worker is reaped before a restarted
                # Lilly's next submission is granted the lease
                # (lease-release-after-commands-reaped). The fenced generation is
                # never resubmitted, so the first later submission follows the
                # explicit wait below; observing the grant needs barrier plumbing
                # that records lease acquisition. The worker's inherited flock
                # keeps the lease held in the kernel while it lives regardless.
                worker_stat = (
                    machine.succeed(f"cat /proc/{worker_pid}/stat").rsplit(") ", 1)[1].split()
                )
                assert int(worker_stat[19]) == worker_start
                worker_cgroup = machine.succeed(f"cat /proc/{worker_pid}/cgroup").strip()
                assert worker_cgroup.startswith("0::/"), worker_cgroup
                service, _, command_cgroup = worker_cgroup.removeprefix("0::").rpartition("/")
                assert service.endswith("/lilly-hostd.service"), worker_cgroup
                assert command_cgroup.startswith("run-"), worker_cgroup
                assert command_cgroup.removeprefix("run-").isdigit(), worker_cgroup
                daemon_stat = (
                    machine.succeed(f"cat /proc/{old_pid}/stat").rsplit(") ", 1)[1].split()
                )
                assert daemon_stat[0] == "T", "the original daemon must actually be suspended"
                assert (
                    int(machine.succeed("systemctl show -p MainPID --value lilly.service"))
                    == old_pid
                )
                authority = sql(
                    "SELECT execution_epoch::text || ':' || generation::text "
                    f"FROM compute_operations WHERE vm_id='{vm_id}' AND kind='start' "
                    "ORDER BY generation DESC LIMIT 1"
                )
                epoch, generation = (int(value) for value in authority.split(":"))
                assert epoch > 0 and generation > 0
                outcome_filter = (
                    f"placement_id='{placement}' AND execution_epoch={epoch} "
                    f"AND generation={generation}"
                )
                assert (
                    sql(f"SELECT count(*) FROM compute_physical_outcomes WHERE {outcome_filter}")
                    == "0"
                )
                original_marker = machine.succeed(f"sha256sum {marker}")
                launched: list[object] | None = None
                if phase == "before":
                    machine.fail(f"systemctl is-active {unit}")
                else:
                    machine.wait_for_unit(unit, timeout=30)
                    machine.wait_until_succeeds(f"fleet-processes {placement}", timeout=30)
                    launched = process_snapshot(victim)
                    assert launched
                machine.succeed(f"rm {barrier}/armed")
                machine.succeed("systemctl kill --kill-whom=all --signal=KILL lilly.service")
                machine.wait_until_succeeds(f"test ! -e /proc/{old_pid}", timeout=30)
                machine.wait_until_succeeds(f"test ! -e /proc/{worker_pid}", timeout=30)
                machine.wait_until_succeeds(
                    "test $(systemctl show -p MainPID --value lilly.service) -gt 0 && "
                    f"test $(systemctl show -p MainPID --value lilly.service) != {old_pid}",
                    timeout=60,
                )
                target = "failed" if phase == "before" else "running"
                eventually(lambda expected=target: vm_state(vm_id) == expected, timeout=180)
                assert machine.succeed(f"sha256sum {marker}") == original_marker
                expected_reason = "execution_failed" if phase == "before" else "none"
                assert (
                    sql(
                        "SELECT count(*) FROM compute_physical_outcomes "
                        f"WHERE {outcome_filter} AND observation->>'state'='{target}' "
                        f"AND observation->>'reason'='{expected_reason}'"
                    )
                    == "1"
                )
                assert (
                    sql(
                        "SELECT status FROM compute_operations "
                        f"WHERE placement_id='{placement}' AND execution_epoch={epoch} "
                        f"AND generation={generation}"
                    )
                    == "completed"
                )
                settled = sql(
                    "SELECT id::text || ':' || sequence::text FROM compute_physical_outcomes "
                    f"WHERE {outcome_filter} ORDER BY sequence"
                )
                assert settled
                for _ in range(reopens):
                    machine.succeed("systemctl restart lilly.service")
                    machine.wait_until_succeeds("fleet-readiness true", timeout=120)
                    assert vm_state(vm_id) == target
                    assert (
                        sql(
                            "SELECT id::text || ':' || sequence::text FROM compute_physical_outcomes "
                            f"WHERE {outcome_filter} ORDER BY sequence"
                        )
                        == settled
                    )
                    assert machine.succeed(f"sha256sum {marker}") == original_marker
                    if launched is not None:
                        assert process_snapshot(victim) == launched
                    else:
                        machine.fail(f"systemctl is-active {unit}")
                    for vm in vms:
                        if vm != victim:
                            assert process_snapshot(vm) == survivors[vm["vm_id"]]
                if phase == "before":
                    lifecycle(vm_id, "start")
                    next_generation = int(
                        sql(f"SELECT generation FROM compute_virtual_machines WHERE id='{vm_id}'")
                    )

                    def restored_generation_running(
                        expected_epoch: int = epoch, expected_generation: int = next_generation
                    ) -> bool:
                        current = (
                            f"placement_id='{placement}' AND execution_epoch={expected_epoch} "
                            f"AND generation={expected_generation}"
                        )
                        assert (
                            sql(
                                "SELECT count(*) FROM compute_physical_outcomes "
                                f"WHERE {current} AND observation->>'state'='failed'"
                            )
                            == "0"
                        )
                        return (
                            sql(
                                "SELECT count(*) FROM compute_operations o "
                                "JOIN compute_physical_outcomes p ON p.id=o.completion_outcome_id "
                                f"WHERE o.placement_id='{placement}' AND o.execution_epoch={expected_epoch} "
                                f"AND o.generation={expected_generation} AND o.status='completed' "
                                "AND p.observation->>'state'='running'"
                            )
                            == "1"
                        )

                    eventually(restored_generation_running, timeout=600)
                    assert vm_state(vm_id) == "running"
            finally:
                machine.execute(f"rm -f {barrier}/armed; touch {barrier}/release")
                machine.execute("systemctl kill --kill-whom=all --signal=CONT lilly.service")
    finally:
        machine.execute(f"rm -f {barrier}/armed; touch {barrier}/release")
        machine.execute("systemctl kill --kill-whom=all --signal=CONT lilly.service")
        machine.execute("systemctl start lilly.service")
        # A failure before the post-settlement branch may leave the selected
        # guest stopped or fenced. Request a fresh public start so the next
        # generated case and any replay see the same running baseline.
        if vm_state(vm_id) != "running":
            lifecycle(vm_id, "start")
            eventually(lambda: vm_state(vm_id) == "running", timeout=600)
