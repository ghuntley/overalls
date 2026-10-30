"""Hermetic Mila journey (ADR-0264): the real Mila Rust core over Porsche SSH.

Every step runs the `mila-journey` driver, which reaches the deployment only
through the C ABI that the native shells use (HTTPS trust document plus
Porsche `--json` commands). Each subtest then asserts the backend effect in
Marshall's PostgreSQL ledger. The synthetic host stands in for the absent
provisioner only through explicit `observe` calls; no guest executes here, so
terminal attach is asserted as Marshall's closed `terminal_unavailable`
refusal and native terminal evidence stays with the fleet PTY scenarios.
"""

import base64
import json
import os
import shlex

from test_driver.machine import QemuMachine

node: QemuMachine = control
descriptor_path = "/home/mila/fixture/descriptor.json"


def object_fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        result[key] = field
    return result


def field(value: object, *path: str) -> object:
    for key in path:
        value = object_fields(value)[key]
    return value


def text(value: object, *path: str) -> str:
    result = field(value, *path)
    assert isinstance(result, str), path
    return result


def items(value: object, *path: str) -> list[object]:
    result = field(value, *path)
    assert isinstance(result, list), path
    return [entry for entry in result]


def sql(statement: str) -> str:
    return node.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc " + shlex.quote(statement)
    ).strip()


def literal(value: str) -> str:
    assert "'" not in value
    return "'" + value + "'"


def mila(*args: str) -> dict[str, object]:
    """Runs one driver step as the unprivileged mila user and returns its value."""
    status, output = mila_raw(*args)
    lines = output.strip().splitlines()
    assert lines, f"mila-journey {args[0]} printed nothing"
    result = object_fields(json.loads(lines[-1]))
    assert status == 0 and result.get("ok") is True, f"mila-journey {args[0]} failed: {result}"
    return object_fields(result["value"])


def mila_refusal(*args: str) -> str:
    """Runs one step that must be refused and returns the closed refusal reason."""
    status, output = mila_raw(*args)
    result = object_fields(json.loads(output.strip().splitlines()[-1]))
    assert status != 0 and result.get("ok") is False, f"{args[0]} unexpectedly succeeded"
    return text(result, "reason")


def mila_raw(*args: str) -> tuple[int, str]:
    command = "sudo -u mila mila-journey --descriptor {} --state /home/mila/state {}".format(
        descriptor_path, " ".join(shlex.quote(arg) for arg in args)
    )
    return node.execute(command, timeout=600)


def action(name: str, **environment: str) -> dict[str, object]:
    assignments = " ".join(f"{key}={shlex.quote(value)}" for key, value in environment.items())
    node.succeed(f"env {assignments} mila-fixture-action {name}", timeout=300)
    return object_fields(json.loads(node.succeed(f"cat /run/mila-fixture/{name}.json")))


def observe(machine: str) -> None:
    action("observe", MILA_FIXTURE_MACHINE=machine)


def receipt_operation(step: dict[str, object]) -> str:
    receipt = field(step, "receipt")
    assert text(receipt, "status") in ("accepted", "succeeded"), receipt
    operation = field(receipt, "operation_id")
    assert isinstance(operation, str), receipt
    return operation


def desired(machine: str) -> str:
    return sql(f"SELECT desired_state FROM compute_virtual_machines WHERE id = {literal(machine)}")


def base64url(size: int) -> str:
    return base64.urlsafe_b64encode(os.urandom(size)).decode().rstrip("=")


start_all()
node.wait_for_unit("multi-user.target")

with subtest("fixture backend is ready and publishes the v1 descriptor"):
    node.succeed("systemctl start mila-fixture.service", timeout=900)
    descriptor = object_fields(json.loads(node.succeed("cat /run/mila-fixture/descriptor.json")))
    assert descriptor["version"] == 1
    assert (
        text(descriptor, "deployment", "host")
        == text(descriptor, "tls", "server_name")
        == "localhost"
    )
    assert node.succeed("stat -c %a /run/mila-fixture/descriptor.json").strip() == "600"
    node.succeed(
        "install -d -m 0700 -o mila /home/mila/fixture && "
        f"install -m 0600 -o mila /run/mila-fixture/descriptor.json {descriptor_path}"
    )
    seed = object_fields(json.loads(node.succeed("cat /run/mila-fixture/seed.json")))
    machine = text(seed, "machine_id")
    owner = text(seed, "owner_id")
    member = text(seed, "member_email")

with subtest("trust enrollment, sign-in and real browser approval"):
    enrolled = mila("enroll")
    assert enrolled["approved_by_browser"] is True
    assert enrolled["public_key_matches"] is True
    assert text(enrolled, "email") == "mila-owner@example.test"
    fingerprint = text(enrolled, "fingerprint")
    assert (
        sql(
            f"SELECT count(*) FROM ssh_keys WHERE user_id = {literal(owner)} "
            f"AND fingerprint = {literal(fingerprint)}"
            " AND archived_at IS NULL"
        )
        == "1"
    )
    assert node.succeed("stat -c %a /home/mila/state /home/mila/state/device.key").split() == [
        "700",
        "600",
    ]

with subtest("reconnect reuses the approved key without a second approval"):
    approvals = sql("SELECT count(*) FROM ssh_approvals")
    whoami = mila("whoami")
    assert text(whoami, "whoami", "result", "email") == "mila-owner@example.test", whoami
    assert sql("SELECT count(*) FROM ssh_approvals") == approvals

with subtest("deployment forget drops the pin and key; re-enrollment approves a new key"):
    forgotten = mila("forget")
    assert forgotten["forgotten"] is True
    node.fail("test -e /home/mila/state/device.key")
    again = mila("enroll")
    assert again["approved_by_browser"] is True
    assert text(again, "fingerprint") != fingerprint
    fingerprint = text(again, "fingerprint")
    assert (
        sql(
            f"SELECT count(*) FROM ssh_keys WHERE user_id = {literal(owner)} AND archived_at IS NULL"
        )
        == "2"
    )

with subtest("machine list and detail come from Marshall's ledger"):
    listing = mila("ls")
    listed = {text(entry, "id") for entry in items(listing, "listing", "machines")}
    assert machine in listed, listing
    ledger = set(
        sql(
            f"SELECT id FROM compute_virtual_machines WHERE owner_id = {literal(owner)} "
            "AND archived_at IS NULL"
        ).split()
    )
    assert listed == ledger, (listed, ledger)
    snapshot = mila("snapshot")
    assert machine in json.dumps(snapshot["snapshot"])

with subtest("create admits a new machine through Porsche"):
    created = mila("create", "mila-made", "1", "512", "2")
    receipt_operation(created)
    made = text(created, "receipt", "result", "id")
    assert (
        sql(
            f"SELECT name || ':' || vcpu || ':' || memory_bytes FROM compute_virtual_machines WHERE id = {literal(made)}"
        )
        == "mila-made:1:536870912"
    )
    observe(made)

with subtest("stop and start record lifecycle intent once"):
    observe(machine)
    for verb, state in [("stop", "stopped"), ("start", "running")]:
        step = mila("action", machine, verb)
        operation = receipt_operation(step)
        assert desired(machine) == state, (verb, desired(machine))
        assert (
            sql(
                f"SELECT count(*) FROM compute_operations WHERE id = {literal(operation)} AND vm_id = {literal(machine)}"
            )
            == "1"
        )
        assert (
            sql(
                f"SELECT count(*) FROM ssh_requests WHERE request_id = {literal(text(step, 'request_id'))}"
            )
            == "1"
        )
        observe(machine)

with subtest("pause records checkpoint intent and resume admits a wake"):
    paused = mila("action", made, "pause")
    receipt_operation(paused)
    assert desired(made) == "paused"
    # The unobserved pause keeps an operation open, so Marshall refuses a
    # resize with its closed vm_busy reason (not temporarily_unavailable).
    busy = mila_refusal("resize", made, "2", "1024", "3")
    assert "(vm_busy)" in busy, busy
    # Resume is a durable wake request. A synthetic host records no
    # checkpoint, so the wake is asserted as admitted, not as restored.
    resumed = mila("action", made, "resume")
    assert text(resumed, "receipt", "status") == "accepted", resumed
    assert text(resumed, "receipt", "result", "phase") in ("pending", "ready"), resumed
    assert (
        sql(
            "SELECT count(*) FROM compute_wake_requests w JOIN ssh_requests s ON s.wake_request_id = w.id "
            f"WHERE s.request_id = {literal(text(resumed, 'request_id'))} AND w.vm_id = {literal(made)}"
        )
        == "1"
    )

with subtest("resize records a pinned resize request"):
    resized = mila("resize", machine, "2", "1024", "3")
    assert text(resized, "receipt", "status") in ("accepted", "succeeded"), resized
    assert (
        sql(
            "SELECT count(*) FROM compute_resize_requests r JOIN ssh_requests s ON s.resize_request_id = r.id "
            f"WHERE s.request_id = {literal(text(resized, 'request_id'))} AND r.vm_id = {literal(machine)}"
        )
        == "1"
    )

with subtest("delete records delete intent"):
    deleted = mila("action", made, "rm")
    receipt_operation(deleted)
    assert desired(made) == "deleted"

with subtest("sharing add and remove change the member's grant"):
    added = mila("share-add", machine, member, "operator")
    assert text(added, "receipt", "result", "role") == "operator"
    grant = (
        "SELECT role FROM access_grants g JOIN users u ON u.id = g.user_id "
        f"WHERE g.vm_id = {literal(machine)} AND u.email = {literal(member)} AND g.revoked_by_id IS NULL"
    )
    assert sql(grant) == "operator"
    removed = mila("share-remove", machine, member)
    assert text(removed, "receipt", "result", "role") == "revoked"
    assert sql(grant) == ""

with subtest("web show and set move the endpoint policy revision"):
    shown = mila("web-show", machine)
    revision = field(shown, "web", "result", "policy_revision")
    assert isinstance(revision, int)
    updated = mila("web-set", machine, "8080", "public", str(revision))
    assert field(updated, "receipt", "result", "policy_revision") == revision + 1
    assert (
        sql(
            "SELECT policy_revision || ':' || primary_port || ':' || visibility FROM ingress_endpoints "
            f"WHERE vm_id = {literal(machine)}"
        )
        == f"{revision + 1}:8080:public"
    )

with subtest("threads list, prompt, answer and plan approval"):
    thread = text(action("thread-create"), "thread_id")
    assert text(action("thread-ready", MILA_FIXTURE_THREAD=thread), "status") == "ready"
    listed_threads = mila("thread", "thread ls")
    assert thread in json.dumps(listed_threads)
    turns = f"SELECT count(*) FROM agent_turns t JOIN threads h ON h.agent_thread_id = t.thread_id WHERE h.id = {literal(thread)}"
    before = int(sql(turns))
    prompted = mila("thread", "thread prompt", thread, "", "Report the hostname please")
    assert text(prompted, "result", "result", "status") == "queued", prompted
    assert int(sql(turns)) == before + 1
    question = text(action("thread-question", MILA_FIXTURE_THREAD=thread), "question_id")
    shown_thread = mila("thread", "thread show", thread)
    assert question in json.dumps(shown_thread), shown_thread
    mila("thread", "thread answer", thread, question, '{"approach":{"selected":"First","text":""}}')
    plan = text(action("thread-proposal", MILA_FIXTURE_THREAD=thread), "plan_id")
    mila("thread", "thread plan approve", thread, plan)
    assert (
        sql(
            f"SELECT implementing_turn_id IS NOT NULL FROM agent_plan_proposals WHERE id = {literal(plan)}"
        )
        == "t"
    )


def hook(action: str, body: str, bearer: bool = True) -> tuple[int, str]:
    """POSTs to the descriptor's fixture hook; the bearer stays in a private file."""
    header = "-H @/run/mila-fixture/hook.header " if bearer else ""
    output = node.succeed(
        "curl -sS --cacert /run/overalls-test/ca.crt -o /run/mila-fixture/hook.out "
        "-w '%{http_code}' -H 'content-type: application/json' "
        + header
        + "--data "
        + shlex.quote(body)
        + " "
        + shlex.quote(text(descriptor, "approver", "fixture_url") + action)
    )
    return int(output), node.succeed("cat /run/mila-fixture/hook.out")


with subtest("bearer-protected fixture hooks run only closed stand-in actions"):
    node.succeed(
        "umask 077; printf 'Authorization: Bearer %s\\n' "
        '"$(jq -r .approver.bearer_token /run/mila-fixture/descriptor.json)" > /run/mila-fixture/hook.header'
    )
    status, body = hook("observe", json.dumps({"machine_id": machine}))
    assert status == 200 and text(json.loads(body), "observed_state") == desired(machine), body
    assert hook("observe", json.dumps({"machine_id": machine}), bearer=False)[0] == 403
    assert hook("observe", json.dumps({"machine_id": "not-a-uuid"}))[0] == 400
    assert hook("thread-create", json.dumps({"extra": 1}))[0] == 400
    assert hook("shell", "{}")[0] == 404


with subtest("terminal attach is refused with Marshall's closed reason without a guest"):
    reason = mila_refusal("terminal", machine)
    assert "terminal_unavailable" in reason, reason

with subtest("notification device register, list, preferences and remove"):
    registered = mila("device-register", "android", base64url(48), base64url(32))
    device = text(registered, "receipt", "result", "id")
    listed_devices = mila("device-ls")
    assert device in json.dumps(listed_devices)
    mila("device-prefs", device, "false")
    assert sql(f"SELECT enabled FROM notification_devices WHERE id = {literal(device)}") == "f"
    mila("device-prefs", device, "true")
    assert sql(f"SELECT enabled FROM notification_devices WHERE id = {literal(device)}") == "t"
    mila("device-rm", device)
    assert sql(f"SELECT state FROM notification_devices WHERE id = {literal(device)}") == "revoked"

with subtest("SSH key list and revoke; the revoked key is no longer authorized"):
    keys = items(mila("ssh-keys"), "keys", "result", "keys")
    fingerprints = {text(key, "fingerprint") for key in keys}
    assert fingerprint in fingerprints, keys
    current = next(key for key in keys if text(key, "fingerprint") == fingerprint)
    mila("ssh-key-revoke", text(current, "id"))
    assert (
        sql(
            f"SELECT count(*) FROM ssh_keys WHERE fingerprint = {literal(fingerprint)} AND archived_at IS NULL"
        )
        == "0"
    )
    whoami_after = json.dumps(mila_raw("whoami"))
    assert "approval_required" in whoami_after or "unauthorized" in whoami_after, whoami_after
