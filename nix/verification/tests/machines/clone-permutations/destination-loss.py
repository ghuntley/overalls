"""Real mid-receive destination loss for a cross-host public clone."""

from test_driver.errors import RequestedAssertionFailed

# @cc [owner:ghuntley,label:verification;recovery] clone-destination-loss-mid-receive
# The destination host MUST crash only after its receive-created dataset exists
# on real ZFS state. While it is absent, cancellation MUST retain the
# destination reservation, both transfer slots and completed cleanup evidence
# obligations as unfinished physical commitments, and the live source MUST be
# restored. Rejoining MUST let real revoke/discard/prune effects complete; only
# the copy or adopt command the cancellation abandoned may stay unreceipted.
# The destination dataset MUST be natively absent, leaving only its retired
# import tombstone. The request MUST then refuse retry, the archived copy MUST
# NOT reappear and no receipt may be fabricated.


def clone_placement_of(vm_id: str) -> dict[str, str]:
    assert str(uuid.UUID(vm_id)) == vm_id
    value: object = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert isinstance(value, dict)
    fields: dict[str, object] = {key: item for key, item in value.items() if isinstance(key, str)}
    placement_id = fields.get("placement_id")
    host_id = fields.get("host_id")
    assert isinstance(placement_id, str) and isinstance(host_id, str)
    assert str(uuid.UUID(placement_id)) == placement_id
    assert str(uuid.UUID(host_id)) == host_id
    return {"host_id": host_id, "placement_id": placement_id}


def clone_server_for(destination: dict[str, str]) -> MachineLike:
    return next(
        machine
        for machine in provisioners
        if host_bindings[machine.name]["host"] == destination["host_id"]
    )


def clone_row(request_id: str) -> dict[str, object]:
    assert str(uuid.UUID(request_id)) == request_id
    value: object = sql_json(
        "SELECT jsonb_build_object("
        "'phase', r.phase, 'failure', r.failure, 'active', r.active,"
        "'finished', r.finished_at IS NOT NULL, 'published', r.published_at IS NOT NULL,"
        "'cancelled', r.cancel_requested_at IS NOT NULL,"
        "'source_restored', r.source_restored_at IS NOT NULL,"
        "'slots_held', (SELECT count(*) FROM compute_transfer_slots s "
        "WHERE s.clone_request_id=r.id AND s.released_at IS NULL),"
        "'destination_held', (SELECT coalesce(bool_or(h.disk_held), false) "
        "FROM compute_reservations h WHERE h.vm_id=r.destination_vm_id),"
        "'temporary_matches_hold', (SELECT coalesce(sum(h.temporary_disk_bytes), 0) "
        "FROM compute_reservations h WHERE h.vm_id=r.source_vm_id) "
        "= (SELECT coalesce(max(d.disk_bytes), 0) FROM compute_reservations d "
        "WHERE d.vm_id=r.destination_vm_id),"
        "'effects_pending', (SELECT count(*) FROM compute_clone_effects e "
        "WHERE e.clone_request_id=r.id AND e.completed_at IS NULL),"
        "'cleanup_completed', (SELECT count(*) FROM compute_clone_effects e "
        "WHERE e.clone_request_id=r.id AND e.completed_at IS NOT NULL "
        "AND e.kind IN ('revoke','discard','prune')),"
        "'unfinished_kinds', (SELECT coalesce(jsonb_agg(DISTINCT e.kind), '[]'::jsonb) "
        "FROM compute_clone_effects e "
        "WHERE e.clone_request_id=r.id AND e.completed_at IS NULL)) "
        f"FROM compute_clone_requests r WHERE r.id='{request_id}'"
    )
    assert isinstance(value, dict)
    assert all(isinstance(key, str) for key in value)
    return {key: item for key, item in value.items() if isinstance(key, str)}


# @cc [owner:ghuntley,label:verification;capacity] clone-destination-loss-cross-host-shape
# Clone placement is first-fit by host id and same-host copies are admissible,
# so a cross-host copy MUST follow from real admission arithmetic, not from
# incidental CPU noise. Fleet hosts enroll 6 cores with 1 overhead core; a
# running source's restart hold plus a same-host copy of three vCPUs needs 6 of
# the 5 schedulable cores, while one three-vCPU copy fits an otherwise idle peer.
CLONE_SOURCE_VCPU = 3


with subtest("destination host loss mid-receive retains commitments until rejoin"):
    origin_request = dict(
        action="provision",
        owner_id=users["owner_id"],
        image_id=users["image_id"],
        profile="standard",
        vcpu=CLONE_SOURCE_VCPU,
        key=str(uuid.uuid4()),
    )

    origin_placed: dict[str, object] = {}

    def provisioned() -> bool:
        result = operator(m1, origin_request)
        reason = result.get("reason")
        assert reason in (None, "insufficient_capacity"), result
        origin_placed.update(result)
        return bool(result.get("accepted"))

    eventually(provisioned, timeout=180)
    origin_vm = str(origin_placed["vm_id"])
    assert str(uuid.UUID(origin_vm)) == origin_vm
    await_running(origin_vm)
    origin = clone_placement_of(origin_vm)
    origin_server = clone_server_for(origin)
    origin_child = "zroot/lilly/vm-" + origin["placement_id"]
    origin_guid = origin_server.succeed(f"zfs get -Hp -o value guid {origin_child}").strip()
    # The marker enters the real guest and syncs to its disk before any copy.
    origin_server.succeed(
        "fleet-relocation-guest clone-write " + origin["placement_id"], timeout=180
    )

    # Activation admits against measured CPU/RAM headroom (restart-full-shape-
    # recheck), which counts the running source's own load. A burst such as the
    # marker sync can refuse one activation with insufficient_capacity, a durable
    # failure; a fresh request is retried exactly as provisioning above is.
    clone_admitted: dict[str, str] = {}

    def clone_activated() -> bool:
        admission: object = operator(
            m1,
            dict(
                action="clone", owner_id=users["owner_id"], vm_id=origin_vm, key=str(uuid.uuid4())
            ),
        )
        assert isinstance(admission, dict)
        request_id = str(admission["id"])
        destination_id = str(admission["destination_vm_id"])
        assert str(uuid.UUID(request_id)) == request_id
        assert str(uuid.UUID(destination_id)) == destination_id

        def activation_settled() -> bool:
            return sql(
                "SELECT phase <> 'queued' OR finished_at IS NOT NULL "
                f"FROM compute_clone_requests WHERE id='{request_id}'"
            ) in ("t", "true")

        eventually(activation_settled, timeout=300)
        failure = sql(
            "SELECT coalesce(failure, '') || ':' || (finished_at IS NOT NULL)::text "
            f"FROM compute_clone_requests WHERE id='{request_id}'"
        )
        if failure == "insufficient_capacity:true":
            time.sleep(5)
            return False
        assert failure.endswith(":false"), f"clone activation failed: {failure.split(':')[0]}"
        clone_admitted.update(clone_id=request_id, copy_id=destination_id)
        return True

    eventually(clone_activated, timeout=600)
    clone_id = clone_admitted["clone_id"]
    copy_id = clone_admitted["copy_id"]

    # Only the physical receive of a running admitted copy arms the crash.
    def receive_begun() -> bool:
        phase = sql(f"SELECT phase FROM compute_clone_requests WHERE id='{clone_id}'")
        if phase not in ("copying", "publishing"):
            return False
        destination = clone_placement_of(copy_id)
        status, _ = clone_server_for(destination).execute(
            "zfs list zroot/lilly/vm-" + destination["placement_id"]
        )
        return status == 0

    eventually(receive_begun, timeout=600)
    copy = clone_placement_of(copy_id)
    copy_server = clone_server_for(copy)
    copy_child = "zroot/lilly/vm-" + copy["placement_id"]
    assert copy["host_id"] != origin["host_id"]

    # Crash the destination provisioner mid-receive; no simulated teardown.
    copy_server.crash()

    closed = operator(
        m1,
        dict(action="cancel-clone", owner_id=users["owner_id"], request_id=clone_id),
    )
    assert isinstance(closed, dict)
    assert str(closed["id"]) == clone_id
    # Source restoration proceeds on its own live host while its destination
    # obligations wait for physical evidence from the crashed provisioner.
    restore_deadline = time.monotonic() + 600
    while not bool(clone_row(clone_id)["source_restored"]):
        assert time.monotonic() < restore_deadline, "running source never restored"
        time.sleep(2)
    await_running(origin_vm)
    assert vm_state(origin_vm) == "running"
    assert origin_server.succeed(f"zfs get -Hp -o value guid {origin_child}").strip() == origin_guid
    # Physical uncertainty MUST NOT finish the request or release commitments.
    time.sleep(20)
    held = clone_row(clone_id)
    assert held["phase"] == "cancelling"
    assert held["finished"] is False
    assert held["published"] is False
    assert held["slots_held"] == 2
    assert held["destination_held"] is True
    assert held["temporary_matches_hold"] is True
    assert isinstance(held["effects_pending"], int) and held["effects_pending"] > 0

    # Rejoin; only completed native effects finish the cancellation.
    copy_server.start()
    copy_server.wait_for_unit("multi-user.target")
    copy_server.wait_for_unit("fleet-storage.service")
    copy_server.wait_for_unit("lilly.service")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' "
                f"AND id='{copy['host_id']}' AND reported_at > "
                "(statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
            )
            == "1"
        ),
        timeout=300,
    )

    def cancelled() -> bool:
        return clone_row(clone_id)["phase"] == "cancelled"

    eventually(cancelled, timeout=600)
    settled = clone_row(clone_id)
    assert settled["active"] is False
    assert settled["cancelled"] is True
    assert settled["slots_held"] == 0
    assert settled["source_restored"] is True
    # Source and destination revoke, destination discard and source prune all
    # carry real receipts; the abandoned copy/adopt command is never receipted.
    assert settled["cleanup_completed"] == 4, settled
    unfinished = settled["unfinished_kinds"]
    assert isinstance(unfinished, list) and set(unfinished) <= {"copy", "adopt"}, settled
    assert (
        sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{copy_id}'")
        == "t"
    )
    # Every trace of the unfinished copy disappears natively from the rejoined
    # host. Its staging keeps only the permanent retired import tombstone
    # (import-retirement-is-permanent), bound to the destroyed dataset.
    copy_server.fail("zfs list " + copy_child)
    staging = "/var/lib/lilly/pool/.lilly-zfs/imports/" + copy["placement_id"]
    assert copy_server.succeed(f"ls -A {staging}").split() == ["import.json"]
    tombstone: object = json.loads(copy_server.succeed(f"cat {staging}/import.json"))
    assert isinstance(tombstone, dict)
    phases = [value for key, value in tombstone.items() if key == "phase"]
    assert phases == ["retired"]
    assert origin_server.succeed(f"zfs get -Hp -o value guid {origin_child}").strip() == origin_guid
    assert vm_state(origin_vm) == "running"

    # A cancelled request refuses later clone retry at the public domain edge:
    # the operator exits non-zero, which the driver raises as a failed command.
    refused = False
    try:
        retried = operator(
            m1,
            dict(action="retry-clone", owner_id=users["owner_id"], request_id=clone_id),
        )
    except RequestedAssertionFailed:
        refused = True
    else:
        raise AssertionError(f"cancelled clone request accepted retry: {retried}")
    assert refused
    assert sql(f"SELECT phase FROM compute_clone_requests WHERE id='{clone_id}'") == "cancelled"
