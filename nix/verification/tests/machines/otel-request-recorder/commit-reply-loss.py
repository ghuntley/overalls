"""Generated real commit-before-reply losses, without a producer-identity proxy."""

from hegel import TestCase, booleans, given, sampled_from


def start_sdk_producer() -> None:
    """@cc [owner:ghuntley,label:verification] producer-control-incarnation-ready
    Startup MUST observe the actual control server before issuing work; a retained
    marker or socket pathname MUST NOT establish a new producer is ready.
    """
    # Hegel invokes each generated case after the fixed native witnesses and
    # after earlier cases. Restarting at this boundary lets the real producer
    # recovery protocol restore a usable marker without fabricating state.
    machine.succeed("systemctl reset-failed sdk-producer.service")
    machine.succeed("rm -f /var/lib/request-sdk-marker/quality")
    machine.succeed("systemctl restart sdk-producer.service")
    wait_producer_ready("sdk-producer")
    machine.wait_until_succeeds("grep -qx v1:running /var/lib/request-sdk-marker/quality")


def sdk_admit() -> int:
    """Validate the closed control reply before treating its ID as an admission."""
    return int(
        machine.succeed(
            control("admit", role="sdk-producer")
            + ' | jq -er \'if .status == "admitted" and (.id | type) == "number" '
            "then .id else error(tostring) end'"
        )
    )


def recorder_reopen() -> None:
    """Require a healthy recorder before an intentional bounded reopen."""
    machine.succeed("systemctl is-active overalls-request-sdk.service")
    machine.succeed("systemctl reset-failed overalls-request-sdk.service")
    machine.succeed("systemctl restart overalls-request-sdk.service")
    machine.wait_until_succeeds("systemctl is-active overalls-request-sdk.service")
    wait_recorder_ready("sdk")


def commit_reply_cut(operation: str, command: str, fault: str) -> str:
    """@cc [owner:ghuntley,label:verification;durability] commit-reply-exact-cut
    The fixture MUST observe the exact recorder stopped after accepted commit,
    then actual producer timeout/gap before killing or resuming that recorder. No reply or
    checkpoint data may be fabricated; the real producer MUST remain alive.
    """
    assert operation in ("admit", "finish", "gap")
    assert fault in ("kill", "delay")
    arm = "/run/overalls-request-sdk/recorder.commit-reply-arm"
    reached = "/run/overalls-request-sdk/recorder.commit-reply-reached"
    result = "/run/commit-reply-result.json"
    recorder_pid = int(
        machine.succeed("systemctl show -p MainPID --value overalls-request-sdk.service")
    )
    producer_pid = int(machine.succeed("systemctl show -p MainPID --value sdk-producer.service"))
    assert recorder_pid > 0 and producer_pid > 0
    machine.succeed(f"rm -f {reached} {result}")
    machine.succeed(
        "printf %s " + shlex.quote(operation) + f" > {arm}; "
        f"chown $(systemctl show -p User --value overalls-request-sdk.service) {arm}; chmod 0600 {arm}"
    )
    machine.succeed(f"({command} > {result}) &")
    machine.wait_until_succeeds(f"grep -qx {operation} {reached}", timeout=15)
    machine.wait_until_succeeds(f"grep -q '^State:.*T' /proc/{recorder_pid}/status", timeout=15)
    machine.wait_until_succeeds(f"jq -e '.status' {result}", timeout=15)
    machine.succeed("grep -qx v1:gap /var/lib/request-sdk-marker/quality")
    assert (
        int(machine.succeed("systemctl show -p MainPID --value sdk-producer.service"))
        == producer_pid
    )
    if fault == "kill":
        # SIGKILL while stopped guarantees the accepted command gets no reply.
        machine.succeed("systemctl kill --kill-whom=all --signal=KILL overalls-request-sdk.service")
        machine.wait_until_succeeds(f"test ! -e /proc/{recorder_pid}", timeout=15)
        machine.wait_until_succeeds("systemctl is-active overalls-request-sdk.service", timeout=15)
    else:
        # The client already timed out and closed this stream. Let production
        # write its actual late reply; it cannot acknowledge a different RPC.
        machine.succeed("systemctl kill --kill-whom=all --signal=CONT overalls-request-sdk.service")
        machine.wait_until_succeeds(
            f"! grep -q '^State:.*T' /proc/{recorder_pid}/status", timeout=15
        )
        assert (
            int(machine.succeed("systemctl show -p MainPID --value overalls-request-sdk.service"))
            == recorder_pid
        )
    return result


def _durable_commit_reply_loss(operation: str, success: bool, reopens: int, fault: str) -> None:
    """@cc [owner:ghuntley,label:verification;durability] native-uncertain-commit-conservation
    Lost admit replies MUST leave a real durable admission despite client refusal;
    observed producer death MUST settle it once without duration. Lost finish
    replies MUST retain the committed outcome and duration once across reopens.
    Permanent identity MUST survive, and fresh client work MUST recover.
    """
    state = "/var/lib/overalls-request-sdk/state.json"
    start_sdk_producer()
    machine.wait_until_succeeds(state_assert("(.pending | length) == 0", "sdk"))
    identity_command = "jq -c '[.started_at_ns,.incarnation]' " + state
    identity = machine.succeed(identity_command).strip()
    totals = {
        name: int(machine.succeed(f"jq -er .totals.{name} {state}"))
        for name in ("requests", "successes", "failures", "duration_count", "duration_sum_us")
    }
    buckets = [
        int(machine.succeed(f"jq -er '.totals.bucket_counts[{index}]' {state}"))
        for index in range(8)
    ]
    next_id = int(machine.succeed(f"jq -er .next_id {state}"))
    if operation == "admit":
        result = commit_reply_cut("admit", control("admit", role="sdk-producer"), fault)
        machine.succeed(f"jq -e '.status == \"refused\"' {result}")
        machine.succeed(
            state_assert(f'(.pending | keys) == ["{next_id}"] and .next_id == {next_id + 1}', "sdk")
        )
        pending_command = (
            "jq -c '[.totals,.next_id,(.pending | to_entries | sort_by(.key) | "
            "map([.key,.value.producer,.value.admitted_at_ns,.value.deadline_ns]))]' " + state
        )
        pending = machine.succeed(pending_command).strip()
        for _ in range(reopens):
            recorder_reopen()
            # Coverage uncertainty may grow; durable identity and admission do not.
            assert machine.succeed(pending_command).strip() == pending
            assert machine.succeed(identity_command).strip() == identity
        producer_pid = int(
            machine.succeed("systemctl show -p MainPID --value sdk-producer.service")
        )
        machine.succeed("systemctl kill --kill-whom=all --signal=KILL sdk-producer.service")
        machine.wait_until_succeeds(f"test ! -e /proc/{producer_pid}", timeout=15)
        expected = {
            **totals,
            "requests": totals["requests"] + 1,
            "failures": totals["failures"] + 1,
        }
    else:
        worker = sdk_admit()
        result = commit_reply_cut(
            "finish", control("success" if success else "failure", worker, "sdk-producer"), fault
        )
        machine.succeed(f"jq -e '.status == \"ok\"' {result}")
        expected = {
            "requests": totals["requests"] + 1,
            "successes": totals["successes"] + int(success),
            "failures": totals["failures"] + int(not success),
            "duration_count": totals["duration_count"] + 1,
            "duration_sum_us": totals["duration_sum_us"] + 100,
        }
        machine.succeed(
            control("success", worker, "sdk-producer") + " | jq -e '.status == \"refused\"'"
        )
    machine.wait_until_succeeds(
        state_assert(
            " and ".join(f".totals.{name} == {value}" for name, value in expected.items())
            + f" and .next_id == {next_id + 1} and (.pending | length) == 0",
            "sdk",
        ),
        timeout=30,
    )
    terminal_command = "jq -c '[.totals,.next_id,.excluded]' " + state
    expected_buckets = [
        value + int(operation == "finish" and index == 0) for index, value in enumerate(buckets)
    ]
    machine.succeed(state_assert(f".totals.bucket_counts == {expected_buckets}", "sdk"))
    terminal = machine.succeed(terminal_command).strip()
    for _ in range(reopens):
        recorder_reopen()
        assert machine.succeed(terminal_command).strip() == terminal
        assert machine.succeed(identity_command).strip() == identity
    start_sdk_producer()
    worker = sdk_admit()
    machine.succeed(control("success", worker, "sdk-producer") + " | jq -e '.status == \"ok\"'")
    recovered = {
        **expected,
        "requests": expected["requests"] + 1,
        "successes": expected["successes"] + 1,
        "duration_count": expected["duration_count"] + 1,
        "duration_sum_us": expected["duration_sum_us"] + 100,
    }
    recovered_buckets = [value + int(index == 0) for index, value in enumerate(expected_buckets)]
    machine.wait_until_succeeds(
        state_assert(
            " and ".join(f".totals.{name} == {value}" for name, value in recovered.items())
            + f" and .totals.bucket_counts == {recovered_buckets} and (.pending | length) == 0",
            "sdk",
        )
    )


@given(
    operation=sampled_from(["admit", "finish"]),
    success=booleans(),
    reopens=sampled_from([1, 2]),
    fault=sampled_from(["kill", "delay"]),
)
def durable_commit_reply_loss(
    tc: TestCase, operation: str, success: bool, reopens: int, fault: str
) -> None:
    _durable_commit_reply_loss(operation, success, reopens, fault)


def _durable_gap_ack_loss(fault: str, reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;durability] native-gap-handshake-before-admission
    A committed gap with unknown acknowledgment MUST NOT permit new admission.
    While its reply is withheld, real Client admission MUST refuse with unchanged
    sequence and totals. Only an acknowledged recovery handshake may admit fresh
    work. Delay/death and repeated reopens MUST preserve permanent identity.
    """
    state = "/var/lib/overalls-request-sdk/state.json"
    arm = "/run/overalls-request-sdk/recorder.commit-reply-arm"
    reached = "/run/overalls-request-sdk/recorder.commit-reply-reached"
    machine.wait_until_succeeds("grep -qx v1:running /var/lib/request-sdk-marker/quality")
    machine.wait_until_succeeds(state_assert("(.pending | length) == 0", "sdk"))
    stable_command = "jq -c '[.started_at_ns,.incarnation,.next_id,.totals,.excluded]' " + state
    stable = machine.succeed(stable_command).strip()
    coverage = int(machine.succeed("jq -er .coverage_started_at_ns " + state))
    next_id = int(machine.succeed("jq -er .next_id " + state))
    requests = int(machine.succeed("jq -er .totals.requests " + state))
    machine.succeed("systemctl stop overalls-request-sdk.service")
    machine.succeed(control("admit", role="sdk-producer") + " | jq -e '.status == \"refused\"'")
    machine.succeed("grep -qx v1:gap /var/lib/request-sdk-marker/quality")
    assert machine.succeed(stable_command).strip() == stable
    machine.succeed(
        f"rm -f {reached}; printf %s gap > {arm}; "
        f"chown $(systemctl show -p User --value overalls-request-sdk.service) {arm}; chmod 0600 {arm}"
    )
    machine.succeed("systemctl start overalls-request-sdk.service")
    pid = int(machine.succeed("systemctl show -p MainPID --value overalls-request-sdk.service"))
    assert pid > 0
    # The actual client heartbeat attempts the recovery handshake. No fixture
    # proxy or direct root RPC can satisfy this authenticated gap cut.
    machine.wait_until_succeeds(f"grep -qx gap {reached}", timeout=15)
    machine.succeed(f"grep -q '^State:.*T' /proc/{pid}/status")
    assert int(machine.succeed("jq -er .coverage_started_at_ns " + state)) > coverage
    machine.succeed(control("admit", role="sdk-producer") + " | jq -e '.status == \"refused\"'")
    machine.succeed("grep -qx v1:gap /var/lib/request-sdk-marker/quality")
    assert machine.succeed(stable_command).strip() == stable
    if fault == "kill":
        machine.succeed("systemctl kill --kill-whom=all --signal=KILL overalls-request-sdk.service")
        machine.wait_until_succeeds(f"test ! -e /proc/{pid}", timeout=15)
        machine.wait_until_succeeds("systemctl is-active overalls-request-sdk.service", timeout=15)
    else:
        machine.succeed("systemctl kill --kill-whom=all --signal=CONT overalls-request-sdk.service")
        machine.wait_until_succeeds(f"! grep -q '^State:.*T' /proc/{pid}/status", timeout=15)
        assert (
            int(machine.succeed("systemctl show -p MainPID --value overalls-request-sdk.service"))
            == pid
        )
    machine.wait_until_succeeds("grep -qx v1:running /var/lib/request-sdk-marker/quality")
    assert machine.succeed(stable_command).strip() == stable
    for _ in range(reopens):
        recorder_reopen()
        machine.wait_until_succeeds("grep -qx v1:running /var/lib/request-sdk-marker/quality")
        assert machine.succeed(stable_command).strip() == stable
    worker = sdk_admit()
    machine.succeed(
        state_assert(f'(.pending | keys) == ["{next_id}"] and .next_id == {next_id + 1}', "sdk")
    )
    machine.succeed(control("success", worker, "sdk-producer") + " | jq -e '.status == \"ok\"'")
    machine.wait_until_succeeds(
        state_assert(f".totals.requests == {requests + 1} and (.pending | length) == 0", "sdk")
    )


@given(fault=sampled_from(["kill", "delay"]), reopens=sampled_from([1, 2]))
def durable_gap_ack_loss(tc: TestCase, fault: str, reopens: int) -> None:
    _durable_gap_ack_loss(fault, reopens)


with subtest("fixed durable commit-reply losses preserve real recorder boundaries"):
    _durable_commit_reply_loss("admit", True, 1, "kill")
    _durable_commit_reply_loss("finish", True, 2, "kill")
    _durable_commit_reply_loss("finish", False, 1, "kill")
    _durable_commit_reply_loss("admit", True, 2, "delay")
    _durable_commit_reply_loss("finish", False, 1, "delay")


with subtest("fixed committed gaps require an acknowledged recovery handshake"):
    _durable_gap_ack_loss("kill", 1)
    _durable_gap_ack_loss("delay", 2)
