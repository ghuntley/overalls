"""Actual Git polling, Buck2 deployment builds and NixOS activation against
isolated, prebuilt candidate systems (support/update.py is prepended)."""

import json

start_all()
host.wait_for_unit("multi-user.target")
repo, candidates = update_repository(host)
cells = host.succeed(f"cat {UPDATE_FIXTURE}/cells").strip()


def publish(name: str) -> str:
    return update_publish(host, repo, candidates[name], name)


def no_buck2_daemon() -> None:
    # buckd and its forkserver leave the updater's process group.
    host.succeed("! pgrep -f 'buck2[d][[]|buck2-forkserve[r]'")


def status() -> dict[str, object]:
    value: object = json.loads(host.succeed("overalls-auto-update status"))
    return status_object(value)


def status_object(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        result[key] = item
    return result


# @cc [owner:ghuntley,label:verification] updater-status-json-boundary
# The machine driver MUST narrow parsed status data before treating nested
# revision fields as strings. Malformed status is a failed acceptance assertion.
def last_healthy_revision() -> str:
    healthy = status_object(status().get("lastHealthy"))
    revision = healthy.get("revision")
    assert isinstance(revision, str)
    return revision


def update() -> None:
    code, _ = host.execute("systemctl start overalls-auto-update.service", timeout=240)
    if code:
        # This suite has no credentials or application processes. Only its
        # public Git/Nix build diagnostics may be printed here.
        print(host.succeed("cat /var/lib/overalls-auto-update/attempt.log"))
        # buckd's own diagnostics name no credentials in this fixture.
        print(
            host.succeed(
                "find /var/lib/overalls-auto-update/buck2-home -type f -name 'buckd.*' "
                "-exec sh -c 'echo == $1; tail -n 60 $1' _ {} \\; ; ps -eo pid,args | grep -i buck || true"
            )
        )
        failure = status().get("failure")
        raise AssertionError(
            "candidate update failed: " + (failure if isinstance(failure, str) else "unknown")
        )


with subtest("fixed candidate switches and records verified success"):
    first = publish("one")
    update()
    assert last_healthy_revision() == first
    host.succeed("test $(cat /etc/overalls-update-generation) = one")
    # The bundle came from the Buck2 deployment target of the fixed checkout.
    assert status().get("builder") == "buck2"
    host.succeed("test $(git -C /var/lib/overalls-auto-update/checkout rev-parse HEAD) = " + first)
    host.succeed("test ! -e /var/lib/overalls-auto-update/checkouts")
    candidate = host.succeed("readlink /var/lib/overalls-auto-update/candidate").strip()
    reported = host.succeed(
        "cat /var/lib/overalls-auto-update/checkout/buck-out/overalls-update/art/root/*/fleet/hosts/host/__deployment__/store-path"
    ).strip()
    assert candidate == reported, (candidate, reported)
    no_buck2_daemon()

with subtest("unchanged successful revision does not activate again"):
    generation = host.succeed("readlink /nix/var/nix/profiles/system").strip()
    host.succeed("systemctl start overalls-auto-update.service", timeout=120)
    assert host.succeed("readlink /nix/var/nix/profiles/system").strip() == generation

with subtest("new revision with identical system verifies without activation"):
    host.succeed("systemctl start update-relay.socket update-relay.service")
    relay_pid = host.succeed("systemctl show update-relay.service -p MainPID --value").strip()
    host.succeed(f"printf 'same deployment, new revision\n' > {repo}/README")
    host.succeed(f"git -C {repo} add README && git -C {repo} commit -m no-op")
    identical = host.succeed(f"git -C {repo} rev-parse HEAD").strip()
    update()
    assert last_healthy_revision() == identical
    assert host.succeed("readlink /nix/var/nix/profiles/system").strip() == generation
    assert (
        host.succeed("systemctl show update-relay.service -p MainPID --value").strip() == relay_pid
    )

with subtest("a concurrent invocation cannot mutate deployment state"):
    host.succeed(
        "install -d -m 700 /run/overalls-auto-update/staging/fixture/runtime /run/overalls-auto-update/staging/fixture/files"
    )
    host.succeed(
        "printf synthetic-identity > /run/overalls-auto-update/staging/fixture/runtime/identity"
    )
    host.succeed("printf retained > /run/overalls-auto-update/staging/fixture/files/value")
    host.succeed(
        "systemd-run --unit=update-lock --property=Type=exec flock /run/overalls-auto-update/update.lock /run/current-system/sw/bin/sleep 120"
    )
    host.wait_until_fails("flock -n /run/overalls-auto-update/update.lock true", timeout=10)
    before = status()
    update()
    assert status() == before
    host.succeed("test -f /run/overalls-auto-update/staging/fixture/runtime/identity")
    host.succeed("systemctl stop update-lock.service")
    # The real post-stop hook removes a leftover identity only after the owner
    # releases the lock, retaining staged files needed for switch recovery.
    update()
    host.succeed("test ! -e /run/overalls-auto-update/staging/fixture/runtime/identity")
    host.succeed("test $(cat /run/overalls-auto-update/staging/fixture/files/value) = retained")
    host.succeed("rm -r /run/overalls-auto-update/staging/fixture")

with subtest("failed build preserves active system and backs off"):
    host.succeed(f"echo 'not a flake' > {repo}/flake.nix")
    host.succeed(f"git -C {repo} commit -am broken")
    host.fail("systemctl start overalls-auto-update.service", timeout=120)
    failed = status()
    assert failed["failedPhase"] == "build"
    assert failed["failures"] == 1
    host.succeed("systemctl start overalls-auto-update.service", timeout=120)
    assert status()["failures"] == 1
    host.succeed("test $(cat /etc/overalls-update-generation) = one")
    no_buck2_daemon()

with subtest("a candidate without its build tool fails closed without another build path"):
    publish("one")
    host.succeed(f"git -C {repo} rm -q tools/buck2 && git -C {repo} commit -qm no-buck2")
    host.fail("systemctl start overalls-auto-update.service", timeout=120)
    failed = status()
    assert failed["failedPhase"] == "build"
    assert failed["failure"] == "build_tool_unavailable"
    assert '"reason": "build_tool_unavailable"' in host.succeed(
        "journalctl -u overalls-auto-update.service -o cat --no-pager"
    )
    host.succeed("test $(cat /etc/overalls-update-generation) = one")
    host.succeed(f"git -C {repo} checkout -q HEAD~1 -- tools/buck2")

with subtest("a hanging candidate build times out and leaves no Buck2 daemon"):
    hanging = update_fixture_flake(
        candidates["two"],
        cells,
        '{ host.config.system.build.overallsDeployment = derivation { name = "overalls-deployment"; '
        'system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "kill -STOP $$" ]; }; }',
    )
    host.succeed(f"cat > {repo}/flake.nix <<'NIX'\n{hanging}\nNIX")
    host.succeed(f"git -C {repo} add -A && git -C {repo} commit -qm hanging")
    host.fail("systemctl start overalls-auto-update.service", timeout=240)
    failed = status()
    assert failed["failedPhase"] == "build"
    assert failed["failure"] == "build_failed"
    no_buck2_daemon()
    # The stopped builder goes with its cancelled build.
    host.wait_until_fails("pgrep -f 'kill -ST[O]P'", timeout=60)
    host.succeed("test $(cat /etc/overalls-update-generation) = one")

with subtest("new corrective revision bypasses old backoff and updater survives self-switch"):
    host.succeed("systemd-run --unit=retained-guest --slice=lilly.slice sleep infinity")
    guest_pid = host.succeed("systemctl show retained-guest.service -p MainPID --value").strip()
    host.succeed("systemctl start update-relay.socket update-relay-probe.service")
    host.wait_until_succeeds("systemctl is-active update-relay.service")
    relay_pid = host.succeed("systemctl show update-relay.service -p MainPID --value").strip()
    second = publish("two")
    update()
    assert last_healthy_revision() == second
    host.succeed("test $(cat /etc/overalls-update-generation) = two")
    assert (
        host.succeed("systemctl show retained-guest.service -p MainPID --value").strip()
        == guest_pid
    )
    host.succeed("systemctl is-active update-relay.socket")
    host.succeed("systemctl is-active update-relay.service")
    # The relay's unit and socket are identical in both candidates, so the
    # activation retains them instead of restarting every consumer.
    assert (
        host.succeed("systemctl show update-relay.service -p MainPID --value").strip() == relay_pid
    )
    assert '"event": "update.units_retained"' in host.succeed(
        "journalctl -u overalls-auto-update.service -o cat --no-pager"
    )
    host.succeed("systemctl stop update-relay-probe.service")

with subtest("installation binding changes cannot use ordinary updates"):
    generation = host.succeed("readlink /nix/var/nix/profiles/system").strip()
    publish("binding-change")
    host.fail("systemctl start overalls-auto-update.service", timeout=120)
    assert status()["failedPhase"] == "preflight"
    assert status()["failure"] == "installation_binding_change"
    assert last_healthy_revision() == second
    assert host.succeed("readlink /nix/var/nix/profiles/system").strip() == generation

with subtest("failed activation does not advance last healthy"):
    publish("unhealthy")
    host.fail("systemctl start overalls-auto-update.service", timeout=240)
    assert last_healthy_revision() == second
    assert status()["failedPhase"] == "activate"
    host.succeed("systemctl is-active update-relay.socket")
    host.succeed("systemctl is-active update-relay.service")

with subtest("health failure retries the active system without another activation"):
    unready = publish("unready")
    host.fail("systemctl start overalls-auto-update.service", timeout=240)
    if status()["failedPhase"] != "verify":
        print(host.succeed("cat /var/lib/overalls-auto-update/attempt.log"))
    assert status()["failedPhase"] == "verify"
    assert last_healthy_revision() == second
    generation = host.succeed("readlink /nix/var/nix/profiles/system").strip()
    host.succeed("test ! -e /var/lib/unwanted-updater-start")
    host.succeed("touch /var/lib/update-health-allowed")
    host.succeed("systemctl start update-health.service")
    # Expire only the persisted delay; the candidate and activation evidence
    # remain untouched, so this exercises the production retry branch.
    host.succeed(
        'python -c \'import json; p="/var/lib/overalls-auto-update/status.json"; s=json.load(open(p)); s["retryAt"]=0; json.dump(s,open(p,"w"))\''
    )
    update()
    assert last_healthy_revision() == unready
    assert host.succeed("readlink /nix/var/nix/profiles/system").strip() == generation

with subtest("fetch failure is reported without erasing the last healthy revision"):
    host.succeed(f"mv {repo} {repo}-offline")
    host.fail("systemctl start overalls-auto-update.service", timeout=120)
    assert status()["failedPhase"] == "fetch"
    assert last_healthy_revision() == unready
    host.succeed(f"mv {repo}-offline {repo}")


def update_healthy_events() -> int:
    count = host.succeed(
        "journalctl -u overalls-auto-update.service --no-pager -o cat "
        "| grep -c 'update.healthy' || true"
    ).strip()
    return int(count)


with subtest("out-of-band system drift reconverges exactly once with one healthy record"):
    # Operator-style rollback drift: point the live system at the earlier
    # closure without touching updater state, leaving /etc and systemd active.
    healthy_before = update_healthy_events()
    drift_system = host.succeed(f"readlink {candidates['one']}/system").strip()
    assert drift_system != host.succeed("readlink /run/current-system").strip()
    host.succeed(f"{drift_system}/bin/switch-to-configuration switch", timeout=240)
    assert host.succeed("readlink /run/current-system").strip() == drift_system
    host.succeed("test $(cat /etc/overalls-update-generation) = one")
    # Expire only the persisted fetch-failure backoff; the candidate revision,
    # drifted live system and activation evidence remain untouched, so the next
    # attempt exercises the production retry boundary against the drift.
    host.succeed(
        'python -c \'import json; p="/var/lib/overalls-auto-update/status.json"; s=json.load(open(p)); s["retryAt"]=0; json.dump(s,open(p,"w"))\''
    )
    update()
    assert last_healthy_revision() == unready
    reconverged = status()
    assert reconverged["phase"] == "healthy"
    assert reconverged["failures"] == 0
    assert reconverged["retryAt"] == 0
    assert reconverged["failure"] is None
    assert reconverged["activeSystem"] == reconverged["lastHealthySystem"]
    host.succeed("test $(cat /etc/overalls-update-generation) = two")
    assert update_healthy_events() == healthy_before + 1
    # A further run is a no-op fast path: no second reconvergence, no duplicate
    # healthy record, and no staged residue beyond the successful handoff
    # cleanup the same record performs.
    host.succeed("systemctl start overalls-auto-update.service", timeout=120)
    settled = status()
    assert update_healthy_events() == healthy_before + 1
    assert settled["phase"] == "healthy"
    assert settled["lastHealthy"] == reconverged["lastHealthy"]
    assert settled["activeSystem"] == reconverged["activeSystem"]
    host.succeed("test ! -e /run/overalls-auto-update/handoff.json")
    host.succeed("test ! -e /run/overalls-auto-update/staging")
