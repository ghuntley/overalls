"""Verify real recorder/producer death, surviving producers and source custody."""
# generated production worker histories preserve durable recorder accounting
# whole VM hard stop preserves acknowledged admission and completed history
# dynamic application uses configured private marker and preserves clean coverage
# exporter can read snapshots but cannot access producer RPC or checkpoint
# authenticated recording gaps preserve history and survive restart

import json
import shlex

from hegel import TestCase, booleans, given, integers, lists


def control(op: str, identifier: int | None = None, role: str = "request-producer") -> str:
    arguments = ["request_fixture", "call", f"/run/{role}/control.sock", op]
    if identifier is not None:
        arguments.append(str(identifier))
    return shlex.join(arguments)


def admit(role: str = "request-producer") -> int:
    """Admit through a producer, failing with its whole bounded reply.

    The control reply carries only status, id and refusal reason, so printing
    it shows why an admission was refused without exposing request contents.
    """
    reply = machine.succeed(control("admit", role=role)).strip()
    parsed: object = json.loads(reply)
    match parsed:
        case {"status": "admitted", "id": int(identifier)} if (
            not isinstance(identifier, bool) and identifier > 0
        ):
            return identifier
        case _:
            raise AssertionError(f"{role} admit was not acknowledged: {reply}")


RECORDERS: dict[str, str] = {
    "request-producer": "primary",
    "deadline-producer": "deadline",
    "sdk-producer": "sdk",
    "dynamic-producer": "marshall-overalls",
}


def wait_recorder_ready(name: str) -> None:
    """Wait until a recorder serves its socket.

    The recorder is Type=exec and binds only after opening its checkpoint and
    recording its restart gap, so an active unit proves nothing. An
    unauthenticated root probe is refused for producer identity before any
    frame is read; that refusal proves the recorder is serving without
    changing accounting state. The probe exits non-zero on any refusal, so
    its reply, not its status, is judged under the driver's pipefail.
    """
    probe = shlex.join(
        ["request_fixture", "probe", f"/run/overalls-request-{name}/recorder.sock", "hello"]
    )
    machine.wait_until_succeeds(
        f"{{ {probe} || true; }}" + ' | jq -e \'.status == "refused" and .reason == "producer"\'',
        timeout=60,
    )


def wait_producer_ready(role: str = "request-producer") -> None:
    """Wait until a producer and its recorder are both ready.

    The native request_fixture producers forward hello to the recorder, but the
    BEAM fixture answers hello itself, and the production Elixir client only
    returns an unrecorded ticket while its recorder is unreachable. A
    preserved snapshot is not proof either: the recorder RuntimeDirectory and
    its previous slo.json survive stops.
    """
    wait_recorder_ready(RECORDERS[role])
    machine.wait_until_succeeds(
        control("hello", role=role) + " | jq -e '.status == \"ok\"'", timeout=60
    )


def late_refusal(identifier: int, outcome: str = "success", role: str = "request-producer") -> str:
    """A settled admission refuses for accounting, not an unreachable recorder."""
    return (
        control(outcome, identifier, role)
        + ' | jq -e \'.status == "refused" and .reason == "accounting"\''
    )


def state_assert(predicate: str, name: str = "primary") -> str:
    return f"jq -e {shlex.quote(predicate)} /var/lib/overalls-request-{name}/state.json"


def snapshot_assert(predicate: str, name: str = "primary") -> str:
    return f"jq -e {shlex.quote(predicate)} /run/overalls-request-{name}-source/slo.json"


def hard_stop_recovery() -> None:
    """@cc [owner:ghuntley,label:verification;durability] recorder-whole-vm-loss
    An acknowledged pending admission MUST survive an abrupt VM stop and settle
    once after a new kernel boot, before its deadline, without invented duration.
    Completed history, source identity and admission sequence MUST survive;
    late completion MUST refuse and a new authenticated admission MUST succeed.
    This fixture establishes virtual host recovery, not hardware power-loss or
    real application adapter acceptance.
    """
    checkpoint = "/var/lib/overalls-request-primary/state.json"
    history_query = (
        "jq -c '[.started_at_ns,.incarnation,.excluded,"
        "(.totals | del(.requests,.failures))]' " + checkpoint
    )
    machine.succeed(
        state_assert(
            ".totals.requests == 2 and .totals.successes == 1 and .totals.failures == 1 "
            "and .totals.duration_count == 1 and (.pending | length) == 0"
        )
    )
    history = machine.succeed(history_query).strip()
    boot = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    coverage = int(machine.succeed("jq -er .coverage_started_at_ns " + checkpoint))
    expected_id = int(machine.succeed("jq -er .next_id " + checkpoint))
    # The previous subtest restarts the recorder and producer; its preserved
    # snapshot is not proof that the new recorder is reachable.
    wait_producer_ready()
    lost = admit()
    assert lost == expected_id > 0
    machine.succeed(state_assert(f"(.pending | length) == 1 and .next_id == {lost + 1}"))
    deadline = int(machine.succeed(f"jq -er '.pending[\"{lost}\"].deadline_ns' {checkpoint}"))
    assert int(machine.succeed("date +%s%N")) < deadline
    machine.crash()
    machine.start()
    machine.wait_for_unit("overalls-request-primary.service")
    assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot
    assert int(machine.succeed("date +%s%N")) < deadline
    machine.wait_until_succeeds(
        state_assert(
            ".totals.requests == 3 and .totals.successes == 1 and .totals.failures == 2 "
            f"and (.pending | length) == 0 and .next_id == {lost + 1} "
            f"and .coverage_started_at_ns > {coverage}"
        )
    )
    assert machine.succeed(history_query).strip() == history
    machine.succeed("systemctl start request-producer.service")
    wait_producer_ready()
    machine.wait_until_succeeds(snapshot_assert(".requests == 3 and .failures == 2"))
    machine.succeed(late_refusal(lost))
    assert machine.succeed(history_query).strip() == history
    fresh = admit()
    assert fresh == lost + 1
    machine.succeed(control("success", fresh) + " | jq -e '.status == \"ok\"'")
    machine.wait_until_succeeds(
        snapshot_assert(".requests == 4 and .successes == 2 and .failures == 2")
    )
    machine.succeed(state_assert(".totals.duration_count == 2 and (.pending | length) == 0"))


start_all()
machine.wait_for_unit("overalls-request-primary.service")
machine.wait_for_unit("overalls-request-deadline.service")
machine.succeed("test ! -e /run/overalls-request-primary-source/slo.json")

with subtest("same UID in a different systemd unit and foreign UID cannot produce"):
    machine.fail("systemctl start request-wrong.service")
    machine.fail("request_fixture probe /run/overalls-request-primary/recorder.sock hello")
    machine.succeed(state_assert(".next_id == 1 and .totals.requests == 0"))

machine.succeed("systemctl start request-producer.service")
machine.wait_for_unit("request-producer.service")
wait_producer_ready()
machine.wait_until_succeeds(snapshot_assert(".requests == 0"))
lifetime = machine.succeed(
    "jq -c '[.started_at_ns,.incarnation]' /var/lib/overalls-request-primary/state.json"
).strip()

with subtest("exporter can read snapshots but cannot access producer RPC or checkpoint"):
    machine.succeed(
        "runuser -u request-reader -- cat /run/overalls-request-primary-source/slo.json >/dev/null"
    )
    machine.fail("runuser -u request-reader -- test -w /run/overalls-request-primary-source")
    machine.fail(
        "runuser -u request-reader -- test -w /run/overalls-request-primary-source/slo.json"
    )
    machine.fail(
        "runuser -u request-reader -- request_fixture probe /run/overalls-request-primary/recorder.sock hello"
    )
    machine.fail("runuser -u request-reader -- cat /var/lib/overalls-request-primary/state.json")
    machine.fail("runuser -u request-producer -- cat /run/overalls-request-primary-source/slo.json")

with subtest("authenticated recording gaps preserve history and survive restart"):
    before_gap = int(
        machine.succeed(
            "jq -r .coverage_started_at_ns /var/lib/overalls-request-primary/state.json"
        )
    )
    machine.succeed(control("gap") + " | jq -e '.status == \"ok\"'")
    explicit_gap = int(
        machine.succeed(
            "jq -r .coverage_started_at_ns /var/lib/overalls-request-primary/state.json"
        )
    )
    assert explicit_gap > before_gap
    machine.succeed(state_assert(".totals.requests == 0 and .next_id == 1"))
    machine.wait_until_succeeds(
        snapshot_assert(f".coverage_started_at_unix_nano == {explicit_gap}")
    )
    machine.succeed("systemctl restart overalls-request-primary.service")
    wait_producer_ready()
    machine.succeed(state_assert(f".coverage_started_at_ns > {explicit_gap}"))
    assert (
        machine.succeed(
            "jq -c '[.started_at_ns,.incarnation]' /var/lib/overalls-request-primary/state.json"
        ).strip()
        == lifetime
    )

with subtest("dynamic application uses configured private marker and preserves clean coverage"):
    machine.succeed("systemctl start dynamic-producer.service")
    wait_producer_ready("dynamic-producer")
    dynamic_id = admit("dynamic-producer")
    machine.succeed(
        control("success", dynamic_id, "dynamic-producer") + " | jq -e '.status == \"ok\"'"
    )
    machine.wait_until_succeeds(
        snapshot_assert(".requests == 1 and .successes == 1", "marshall-overalls")
    )
    dynamic_history = machine.succeed(
        "jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' /var/lib/overalls-request-marshall-overalls/state.json"
    ).strip()
    machine.succeed("systemctl stop dynamic-producer.service")
    machine.succeed(
        "grep -qx 'v1:clean' /var/lib/overalls-request-marshall-overalls-producer/marker/quality"
    )
    machine.succeed("systemctl start dynamic-producer.service")
    wait_producer_ready("dynamic-producer")
    assert (
        machine.succeed(
            "jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' /var/lib/overalls-request-marshall-overalls/state.json"
        ).strip()
        == dynamic_history
    )

with subtest("production BEAM client measures completion and worker death"):
    machine.succeed("systemctl start sdk-producer.service")
    machine.wait_for_unit("sdk-producer.service")
    machine.wait_until_succeeds(snapshot_assert(".requests == 0", "sdk"))
    wait_producer_ready("sdk-producer")
    sdk_first = admit("sdk-producer")
    machine.succeed(control("success", sdk_first, "sdk-producer") + " | jq -e '.status == \"ok\"'")
    sdk_worker = admit("sdk-producer")
    machine.succeed(control("exclude", sdk_worker, "sdk-producer") + " | jq -e '.status == \"ok\"'")
    machine.wait_until_succeeds(
        state_assert(
            ".totals.requests == 2 and .totals.successes == 1 and .totals.failures == 1 "
            "and .totals.duration_count == 2 and (.pending | length) == 0",
            "sdk",
        )
    )

with subtest("clean application deployment preserves complete recording coverage"):
    sdk_sample = int(
        machine.succeed("jq -r .sampled_at_unix_nano /run/overalls-request-sdk-source/slo.json")
    )
    sdk_history = machine.succeed(
        "jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' "
        "/var/lib/overalls-request-sdk/state.json"
    ).strip()
    machine.succeed("systemctl stop sdk-producer.service")
    machine.succeed("test $(cat /var/lib/request-sdk-marker/quality) = v1:clean")
    machine.succeed("systemctl start sdk-producer.service")
    wait_producer_ready("sdk-producer")
    sdk_restart_clock = int(machine.succeed("date +%s%N"))
    machine.wait_until_succeeds(
        snapshot_assert(
            f".requests == 2 and .sampled_at_unix_nano > {max(sdk_sample, sdk_restart_clock)}",
            "sdk",
        )
    )
    assert (
        machine.succeed(
            "jq -c '[.started_at_ns,.incarnation,.coverage_started_at_ns,.totals]' "
            "/var/lib/overalls-request-sdk/state.json"
        ).strip()
        == sdk_history
    )

with subtest("unclean BEAM restart reports a gap and counts unresolved work once"):
    sdk_clock = int(
        machine.succeed("jq -r .coverage_started_at_ns /var/lib/overalls-request-sdk/state.json")
    )
    admit("sdk-producer")
    machine.succeed("systemctl kill --signal=SIGKILL sdk-producer.service")
    machine.wait_until_succeeds(
        state_assert(
            ".totals.requests == 3 and .totals.failures == 2 and .totals.duration_count == 2", "sdk"
        )
    )
    machine.succeed(
        "systemctl reset-failed sdk-producer.service; systemctl start sdk-producer.service"
    )
    wait_producer_ready("sdk-producer")
    machine.wait_until_succeeds(state_assert(f".coverage_started_at_ns > {sdk_clock}", "sdk"))
    machine.wait_until_succeeds(snapshot_assert(".requests == 3", "sdk"))

with subtest("producer communication gaps persist across restart until durable acknowledgment"):
    machine.succeed("mkdir -p /run/systemd/system/overalls-request-sdk.service.d")
    machine.succeed(
        "printf '[Unit]\\nConditionPathExists=/run/request-sdk-recorder-enabled\\n' > "
        "/run/systemd/system/overalls-request-sdk.service.d/unavailable.conf"
    )
    machine.succeed("systemctl daemon-reload")
    machine.succeed("systemctl stop overalls-request-sdk.service")
    machine.succeed(control("admit", role="sdk-producer") + " | jq -e '.status == \"refused\"'")
    machine.succeed("test $(cat /var/lib/request-sdk-marker/quality) = v1:gap")
    machine.succeed("systemctl restart sdk-producer.service")
    machine.wait_for_unit("sdk-producer.service")
    machine.wait_until_succeeds(
        control("hello", role="sdk-producer") + " | jq -e '.status == \"ok\"'"
    )
    machine.succeed("test $(cat /var/lib/request-sdk-marker/quality) = v1:gap")
    machine.fail("systemctl is-active overalls-request-sdk.service")
    machine.succeed(
        "rm /run/systemd/system/overalls-request-sdk.service.d/unavailable.conf; "
        "systemctl daemon-reload; systemctl start overalls-request-sdk.service"
    )
    machine.wait_until_succeeds("test $(cat /var/lib/request-sdk-marker/quality) = v1:running")
    machine.wait_until_succeeds(snapshot_assert(".requests == 3", "sdk"))


def _producer_recorder_history(successes: list[bool], reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;durability] native-producer-recorder-conservation
    Recorder reopens MUST preserve every acknowledged live-worker admission and
    its deadline. Authorized success and actual worker death MUST each settle
    once with a duration; repeated completion MUST preserve exact totals.
    Completed totals and permanent identity MUST survive subsequent reopens.
    """
    checkpoint = "/var/lib/overalls-request-sdk/state.json"
    # Each Hegel case starts from a recorder boundary. The preceding fixed
    # checks may deliberately leave a gap/corrupt marker; a real restart
    # performs the production recovery handshake before generation begins.
    # A failed unit is always loaded; an inactive one systemd has already
    # garbage-collected reports "not loaded", leaving nothing to reset.
    machine.succeed(
        "systemctl reset-failed sdk-producer.service 2>/dev/null"
        " || ! systemctl is-failed --quiet sdk-producer.service"
    )
    machine.succeed("rm -f /var/lib/request-sdk-marker/quality")
    machine.succeed("systemctl restart sdk-producer.service")
    wait_producer_ready("sdk-producer")
    machine.wait_until_succeeds(state_assert("(.pending | length) == 0", "sdk"))
    machine.wait_until_succeeds("grep -qx v1:running /var/lib/request-sdk-marker/quality")
    identity_query = "jq -c '[.started_at_ns,.incarnation]' " + checkpoint
    identity = machine.succeed(identity_query).strip()
    previous = {
        field: int(machine.succeed(f"jq -er .totals.{field} {checkpoint}"))
        for field in ("requests", "successes", "failures", "duration_count")
    }
    first_sequence = int(machine.succeed(f"jq -er .next_id {checkpoint}"))
    workers = [admit("sdk-producer") for _ in successes]
    count = len(workers)
    machine.succeed(
        state_assert(
            f"(.pending | length) == {count} and .next_id == {first_sequence + count} "
            f"and ([.pending | keys[] | tonumber] | sort) == "
            f"[{','.join(str(first_sequence + index) for index in range(count))}]",
            "sdk",
        )
    )
    pending_query = (
        "jq -c '[.totals,.next_id,"
        "(.pending | to_entries | sort_by(.key) | "
        "map([.key,.value.producer,.value.admitted_at_ns,.value.deadline_ns]))]' " + checkpoint
    )
    pending = machine.succeed(pending_query).strip()
    producer_pid = int(machine.succeed("systemctl show -p MainPID --value sdk-producer.service"))
    assert producer_pid > 0
    for _ in range(reopens):
        machine.succeed("systemctl is-active overalls-request-sdk.service")
        # These are deliberate operator reopens of a healthy recorder. Reset
        # its start counter before each, keeping production limits unchanged.
        machine.succeed("systemctl reset-failed overalls-request-sdk.service")
        machine.succeed("systemctl restart overalls-request-sdk.service")
        wait_producer_ready("sdk-producer")
        assert machine.succeed(pending_query).strip() == pending
        assert machine.succeed(identity_query).strip() == identity
        assert (
            int(machine.succeed("systemctl show -p MainPID --value sdk-producer.service"))
            == producer_pid
        )
    for worker, success in zip(workers, successes, strict=True):
        machine.succeed(
            control("success" if success else "exclude", worker, "sdk-producer")
            + " | jq -e '.status == \"ok\"'"
        )
    expected = {
        "requests": previous["requests"] + count,
        "successes": previous["successes"] + sum(successes),
        "failures": previous["failures"] + count - sum(successes),
        "duration_count": previous["duration_count"] + count,
    }
    machine.wait_until_succeeds(
        state_assert(
            " and ".join(f".totals.{field} == {value}" for field, value in expected.items())
            + " and (.pending | length) == 0",
            "sdk",
        )
    )
    completed_query = "jq -c '[.totals,.next_id,.excluded]' " + checkpoint
    completed = machine.succeed(completed_query).strip()
    for worker in reversed(workers):
        machine.succeed(
            control("success", worker, "sdk-producer") + " | jq -e '.status == \"refused\"'"
        )
        assert machine.succeed(completed_query).strip() == completed
    for _ in range(reopens):
        machine.succeed("systemctl is-active overalls-request-sdk.service")
        machine.succeed("systemctl reset-failed overalls-request-sdk.service")
        machine.succeed("systemctl restart overalls-request-sdk.service")
        wait_producer_ready("sdk-producer")
        assert machine.succeed(completed_query).strip() == completed
        assert machine.succeed(identity_query).strip() == identity


@given(successes=lists(booleans(), min_size=1, max_size=4), reopens=integers(1, 2))
def producer_recorder_history(tc: TestCase, successes: list[bool], reopens: int) -> None:
    _producer_recorder_history(successes, reopens)


with subtest("fixed production worker histories preserve durable recorder accounting"):
    _producer_recorder_history([True, False, True, False], 2)
    _producer_recorder_history([False], 1)


with subtest("corrupt producer storage cannot confer complete coverage through old completions"):
    requests_before_corruption = int(
        machine.succeed("jq -er .totals.requests /var/lib/overalls-request-sdk/state.json")
    )
    successes_before_corruption = int(
        machine.succeed("jq -er .totals.successes /var/lib/overalls-request-sdk/state.json")
    )
    sdk_storage = admit("sdk-producer")
    before_storage_gap = int(
        machine.succeed("jq -r .coverage_started_at_ns /var/lib/overalls-request-sdk/state.json")
    )
    machine.succeed("printf corrupt > /var/lib/request-sdk-marker/quality")
    machine.succeed(
        control("success", sdk_storage, "sdk-producer") + " | jq -e '.status == \"ok\"'"
    )
    machine.wait_until_succeeds(
        state_assert(
            f".coverage_started_at_ns > {before_storage_gap} "
            f"and .totals.requests == {requests_before_corruption + 1} "
            f"and .totals.successes == {successes_before_corruption + 1}",
            "sdk",
        )
    )
    machine.succeed("systemctl stop sdk-producer.service")
    stored_gap = int(
        machine.succeed("jq -r .coverage_started_at_ns /var/lib/overalls-request-sdk/state.json")
    )
    machine.succeed("systemctl start sdk-producer.service")
    machine.wait_for_unit("sdk-producer.service")
    wait_producer_ready("sdk-producer")
    machine.wait_until_succeeds(state_assert(f".coverage_started_at_ns > {stored_gap}", "sdk"))
    machine.succeed("test $(cat /var/lib/request-sdk-marker/quality) = corrupt")

with subtest("admission acknowledgment survives recorder SIGKILL with producer alive"):
    first = admit()
    machine.succeed(state_assert("(.pending | length) == 1 and .totals.requests == 0"))
    machine.succeed("systemctl kill --signal=SIGKILL overalls-request-primary.service")
    machine.wait_until_succeeds("systemctl is-active overalls-request-primary.service")
    wait_producer_ready()
    machine.succeed(state_assert("(.pending | length) == 1 and .totals.failures == 0"))
    machine.succeed(control("success", first) + " | jq -e '.status == \"ok\"'")
    machine.wait_until_succeeds(snapshot_assert(".requests == 1 and .successes == 1"))
    machine.succeed(late_refusal(first, "failure"))
    machine.succeed(state_assert(".totals.requests == 1 and .totals.successes == 1"))

with subtest("invisible proc state cannot prove death of a surviving producer"):
    hidden = admit()
    machine.succeed("mkdir -p /run/systemd/system/overalls-request-primary.service.d")
    machine.succeed(
        "printf '[Service]\\nProtectProc=invisible\\n' > "
        "/run/systemd/system/overalls-request-primary.service.d/visibility.conf"
    )
    machine.succeed("systemctl daemon-reload; systemctl restart overalls-request-primary.service")
    machine.wait_for_unit("overalls-request-primary.service")
    machine.wait_until_succeeds(control("hello") + " | jq -e '.reason == \"producer\"'")
    machine.succeed("sleep 2")
    machine.succeed(state_assert("(.pending | length) == 1 and .totals.failures == 0"))
    machine.succeed("rm /run/systemd/system/overalls-request-primary.service.d/visibility.conf")
    machine.succeed("systemctl daemon-reload; systemctl restart overalls-request-primary.service")
    wait_producer_ready()
    machine.succeed(control("exclude", hidden) + " | jq -e '.status == \"ok\"'")
    machine.succeed(state_assert(".excluded == 1 and .totals.requests == 1"))

with subtest("producer SIGKILL counts unresolved admission once without duration"):
    second = admit()
    machine.succeed("systemctl kill --signal=SIGKILL request-producer.service")
    machine.wait_until_succeeds(state_assert("(.pending | length) == 0 and .totals.failures == 1"))
    sampled = machine.succeed(
        "jq -r .sampled_at_unix_nano /run/overalls-request-primary-source/slo.json"
    ).strip()
    machine.succeed("sleep 2")
    assert (
        machine.succeed(
            "jq -r .sampled_at_unix_nano /run/overalls-request-primary-source/slo.json"
        ).strip()
        == sampled
    )
    machine.succeed(state_assert(".totals.requests == 2 and .totals.duration_count == 1"))
    machine.succeed("systemctl start request-producer.service")
    machine.wait_for_unit("request-producer.service")
    wait_producer_ready()
    machine.wait_until_succeeds(snapshot_assert(".requests == 2 and .failures == 1"))
    machine.succeed(late_refusal(second))
    assert (
        machine.succeed(
            "jq -c '[.started_at_ns,.incarnation]' /var/lib/overalls-request-primary/state.json"
        ).strip()
        == lifetime
    )

with subtest("independent immutable deadline settles a live producer"):
    machine.succeed("systemctl start deadline-producer.service")
    machine.wait_for_unit("deadline-producer.service")
    wait_producer_ready("deadline-producer")
    expired = admit("deadline-producer")
    machine.succeed(control("gap", role="deadline-producer") + " | jq -e '.status == \"ok\"'")
    deadline_gap = int(
        machine.succeed(
            "jq -r .coverage_started_at_ns /var/lib/overalls-request-deadline/state.json"
        )
    )
    machine.wait_until_succeeds(
        state_assert(
            f".totals.failures == 1 and .totals.duration_count == 0 "
            f"and .coverage_started_at_ns > {deadline_gap}",
            "deadline",
        )
    )
    machine.succeed("systemctl is-active deadline-producer.service")
    machine.succeed(late_refusal(expired, role="deadline-producer"))

with subtest("initialized checkpoint loss refuses a new lifetime"):
    machine.succeed("systemctl stop request-producer.service overalls-request-primary.service")
    machine.succeed("cp -p /var/lib/overalls-request-primary/state.json /root/request-state.json")
    machine.succeed("rm /var/lib/overalls-request-primary/state.json")
    machine.succeed("systemctl start overalls-request-primary.service")
    machine.wait_until_succeeds(
        "test $(systemctl show -p NRestarts --value overalls-request-primary.service) -gt 1"
    )
    machine.succeed("test ! -e /var/lib/overalls-request-primary/state.json")
    machine.succeed("systemctl stop overalls-request-primary.service")
    machine.succeed(
        "cp --preserve=mode,ownership "
        "/root/request-state.json /var/lib/overalls-request-primary/state.json"
    )
    machine.succeed("systemctl reset-failed overalls-request-primary.service")
    machine.succeed("systemctl start request-producer.service")
    machine.wait_for_unit("overalls-request-primary.service")
    wait_producer_ready()
    machine.wait_until_succeeds(snapshot_assert(".requests == 2 and .failures == 1"))
    assert (
        machine.succeed(
            "jq -c '[.started_at_ns,.incarnation]' /var/lib/overalls-request-primary/state.json"
        ).strip()
        == lifetime
    )

with subtest("whole VM hard stop preserves acknowledged admission and completed history"):
    hard_stop_recovery()
