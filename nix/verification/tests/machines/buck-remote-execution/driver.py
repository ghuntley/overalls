"""Exercise Buck2 remote execution on NativeLink workers (ADR-0272, M10)."""

import json

from test_driver.machine import QemuMachine as Machine

F = "/etc/fixtures"
TAILNET = "192.168.1.4"
READ, UPLOAD, EXECUTE, WORKER = 50071, 50072, 50073, 50074
INSTANCE = "main"
PROJECT = "/root/project"
CAPABILITIES = {"instanceName": INSTANCE}


def grpc(node: Machine, port: int, identity: str | None, method: str, request: object) -> str:
    """Call an REv2 method; returns combined output and never raises."""
    credentials = f"-cert {F}/{identity}.crt -key {F}/{identity}.key " if identity else ""
    command = (
        f"grpcurl -max-time 10 -cacert {F}/ca.crt {credentials}"
        "-import-path /etc/rev2-protos -proto build/bazel/remote/execution/v2/remote_execution.proto "
        f"-d '{json.dumps(request)}' {TAILNET}:{port} build.bazel.remote.execution.v2.{method} 2>&1"
    )
    return node.execute(command)[1]


def fresh(node: Machine, port: int | None = None, identity: str | None = None) -> None:
    """A clean project; with a port, a client configuration that executes remotely."""
    node.succeed(
        f"(cd {PROJECT} 2>/dev/null && HOME=/root buck2 kill >/dev/null 2>&1) || true;"
        f" rm -rf {PROJECT}; cp -rL /etc/buck-project {PROJECT} && chmod -R u+w {PROJECT}"
    )
    if port is not None:
        node.succeed(
            f"cat > {PROJECT}/.buckconfig.local <<EOF\n"
            "[buck2_re_client]\n"
            f"  address = grpc://{TAILNET}:{port}\n"
            "  tls = true\n"
            f"  instance_name = {INSTANCE}\n"
            f"  tls_ca_certs = {F}/ca.crt\n"
            f"  tls_client_cert = {F}/{identity}.pem\n"
            "[buck2]\n"
            f"  default_allow_cache_upload = {'true' if port == UPLOAD else 'false'}\n"
            "[overalls]\n"
            "  remote_execution = true\n"
            "EOF"
        )


def build(node: Machine, target: str, kind: str, *flags: str) -> list[str]:
    """Build a probe, check how its one action ran, and return its output lines."""
    output = node.succeed(
        f"cd {PROJECT} && HOME=/root timeout 300 buck2 build {' '.join(flags)} {target}"
        " --materializations=all --show-full-output 2>&1"
    )
    assert f"{kind}: 1" in output, output
    if kind != "remote":
        assert "remote: 0" in output, output
    path = output.strip().splitlines()[-1].split(" ", 1)[1]
    return node.succeed(f"cat {path}").splitlines()


def worker_pid(node: Machine) -> str:
    return node.succeed("systemctl show -p MainPID --value nativelink-worker").strip()


start_all()
for node in [ci, dev, outsider]:
    node.wait_for_unit("multi-user.target")
with subtest("without credentials buck2 builds locally"):
    fresh(ci)
    assert build(ci, "//:ci_probe", "local")[0] == "ci"

for node in [scheduler, worker]:
    node.wait_for_unit("sshd.service")
    node.succeed("python3 /etc/seal.py buck-re-worker")
scheduler.succeed("python3 /etc/seal.py buck-re")
for node in [scheduler, worker]:
    # The bundles retried against the absent fixtures at boot and gave up.
    node.succeed("systemctl reset-failed")
scheduler.succeed("systemctl restart overalls-secrets-buck-re && systemctl restart nativelink")
scheduler.wait_for_unit("nativelink.service")
for port in (READ, UPLOAD, EXECUTE, WORKER):
    scheduler.wait_for_open_port(port, TAILNET)
for node in [scheduler, worker]:
    # Starting the bundle starts the worker, which boot skipped without it.
    node.succeed("systemctl restart overalls-secrets-buck-re-worker")
    node.wait_for_unit("nativelink-worker.service")
    node.succeed("test $(stat -c %U /run/nativelink-worker/identity.pem) = nativelink-worker")
    node.fail("su -s /bin/sh nobody -c 'cat /run/overalls-secrets/buck-re-worker/worker.pem'")

with subtest("listeners bind only the tailnet address"):
    listening = scheduler.succeed("ss -Htln")
    for port in (READ, UPLOAD, EXECUTE, WORKER):
        assert f"{TAILNET}:{port}" in listening, listening
        assert f"0.0.0.0:{port}" not in listening and f"*:{port}" not in listening, listening
    outsider.fail(f"timeout 5 bash -c '</dev/tcp/192.168.2.4/{EXECUTE}'")
    outsider.succeed(f"ip route add {TAILNET}/32 via 192.168.2.4 dev eth1")
    outsider.wait_until_succeeds(f"timeout 5 bash -c '</dev/tcp/{TAILNET}/22'", timeout=30)
    for port in (READ, UPLOAD, EXECUTE, WORKER):
        outsider.fail(f"timeout 5 bash -c '</dev/tcp/{TAILNET}/{port}'")

with subtest("execution and worker listeners admit only their own CA"):
    for port, identity in [(EXECUTE, "executor-dev"), (UPLOAD, "uploader-ci")]:
        answer = grpc(dev, port, identity, "Capabilities/GetCapabilities", CAPABILITIES)
        assert "executionCapabilities" in answer, (port, answer)
    assert "cacheCapabilities" in grpc(
        dev, WORKER, "worker-worker", "Capabilities/GetCapabilities", CAPABILITIES
    )
    for port, identity in [
        (EXECUTE, "reader-host"),
        (EXECUTE, "uploader-ci"),
        (EXECUTE, "worker-worker"),
        (EXECUTE, None),
        (WORKER, "executor-dev"),
        (WORKER, "reader-host"),
        (WORKER, "uploader-ci"),
        (WORKER, None),
        (UPLOAD, "executor-dev"),
        (READ, "executor-dev"),
        (READ, "worker-worker"),
    ]:
        answer = grpc(dev, port, identity, "Capabilities/GetCapabilities", CAPABILITIES)
        assert "Capabilities" not in answer, (port, identity, answer)

with subtest("a developer identity executes but cannot write the action cache"):
    refused = grpc(
        dev,
        EXECUTE,
        "executor-dev",
        "ActionCache/UpdateActionResult",
        {
            "instanceName": INSTANCE,
            "actionDigest": {"hash": "c" * 64, "sizeBytes": "10"},
            "actionResult": {"exitCode": 0},
        },
    )
    assert "PermissionDenied" in refused, refused

with subtest("hosts cannot execute: the read listener has no execution service"):
    answer = grpc(dev, READ, "reader-host", "Capabilities/GetCapabilities", CAPABILITIES)
    assert "cacheCapabilities" in answer and "execEnabled" not in answer, answer
    fresh(dev, READ, "reader-host")
    assert build(dev, "//:host_probe", "local")[0] == "dev"

with subtest("CI executes remotely on a worker, and the result is cached"):
    fresh(ci, UPLOAD, "uploader-ci")
    lines = build(ci, "//:ci_probe", "remote")
    assert lines[0] in ("scheduler", "worker") and lines[1] == "built by the CI identity", lines
    ci.succeed(f"cd {PROJECT} && HOME=/root buck2 clean")
    assert build(ci, "//:ci_probe", "cached") == lines
    # A developer sees the worker's result through the action cache.
    fresh(dev, EXECUTE, "executor-dev")
    assert build(dev, "//:ci_probe", "cached") == lines

with subtest("each worker host executes actions and records results"):
    for runs, stopped, target in [
        (worker, scheduler, "//:worker_probe"),
        (scheduler, worker, "//:scheduler_probe"),
    ]:
        stopped.succeed("systemctl stop nativelink-worker")
        fresh(dev, EXECUTE, "executor-dev")
        lines = build(dev, target, "remote")
        assert lines[0] == runs.name, (runs.name, lines)
        dev.succeed(f"cd {PROJECT} && HOME=/root buck2 clean")
        assert build(dev, target, "cached") == lines
        stopped.succeed("systemctl start nativelink-worker")
        stopped.wait_for_unit("nativelink-worker.service")

with subtest("workers cannot see guest datasets"):
    for node in [scheduler, worker]:
        node.succeed("test -e /srv/pool/guest/marker")
        pid = worker_pid(node)
        pool_mounts = f"nsenter -t {pid} -m grep ' /srv/pool' /proc/self/mountinfo || true"
        assert node.succeed(pool_mounts).strip() == "", node.succeed(pool_mounts)
        # A guest dataset mounted after the worker started never reaches it.
        node.succeed("mkdir -p /srv/pool/later && mount -t tmpfs later /srv/pool/later")
        assert node.succeed(pool_mounts).strip() == "", node.succeed(pool_mounts)
        node.succeed("umount /srv/pool/later")
        status = node.succeed(f"cat /proc/{pid}/status")
        assert f"Uid:\t{node.succeed('id -u nativelink-worker').strip()}" in status, status
        assert "CapEff:\t0000000000000000" in status, status
    # The remote probes ran in those namespaces.
    fresh(ci, UPLOAD, "uploader-ci")
    lines = build(ci, "//:ci_probe", "cached")
    assert lines[2:] == ["guest-hidden", "0", "state-hidden"], lines


with subtest("the worker unit is sandboxed and capped below guests"):
    expected = {
        "CPUWeight": "20",
        "CPUQuotaPerSecUSec": "2s",
        "IOWeight": "20",
        "MemorySwapMax": "0",
        "TasksMax": "8192",
        "OOMScoreAdjust": "1000",
        "Nice": "10",
        "PrivateMounts": "yes",
        "PrivateDevices": "yes",
        "PrivateTmp": "yes",
        "ProtectSystem": "strict",
        "ProtectHome": "yes",
        "RestrictSUIDSGID": "yes",
        "IPAddressDeny": "0.0.0.0/0 ::/0",
    }
    for node in [scheduler, worker]:
        shown = node.succeed(
            "systemctl show nativelink-worker --property="
            + ",".join(
                [
                    *expected,
                    "MemoryHigh",
                    "MemoryMax",
                    "InaccessiblePaths",
                    "RestrictNetworkInterfaces",
                    "CapabilityBoundingSet",
                ]
            )
        )
        props = dict(line.split("=", 1) for line in shown.strip().splitlines())
        props["IPAddressDeny"] = " ".join(sorted(props["IPAddressDeny"].split()))
        wrong = {key: props[key] for key, value in expected.items() if props[key] != value}
        assert not wrong, (node.name, wrong)
        total = int(node.succeed("awk '/MemTotal/ { print $2 * 1024 }' /proc/meminfo"))
        assert 0 < int(props["MemoryMax"]) <= total * 26 // 100, (props["MemoryMax"], total)
        assert 0 < int(props["MemoryHigh"]) < int(props["MemoryMax"]), props["MemoryHigh"]
        for hidden in [
            "/run/overalls-secrets",
            "/etc/ssh",
            "/run/lilly",
            "/run/lilly-hostd",
            "/var/lib/lilly",
            "/var/lib/overalls-firecracker",
        ]:
            assert f"-{hidden}" in props["InaccessiblePaths"].split(), (
                hidden,
                props["InaccessiblePaths"],
            )
        # The running cgroup carries the caps, not just the unit file.
        cgroup = node.succeed(
            "systemctl show nativelink-worker --property=ControlGroup --value"
        ).strip()
        assert node.succeed(f"cat /sys/fs/cgroup{cgroup}/cpu.max").split()[0] == "200000"
        assert node.succeed(f"cat /sys/fs/cgroup{cgroup}/memory.swap.max").strip() == "0"
        assert node.succeed(f"cat /sys/fs/cgroup{cgroup}/pids.max").strip() == "8192"
        # The worker cannot reach Lilly's control state, sockets, devices or secrets.
        pid = worker_pid(node)
        for path in [
            "/run/lilly/marker",
            "/var/lib/lilly/marker",
            "/run/overalls-secrets/buck-re-worker",
            "/etc/ssh/ssh_host_ed25519_key",
        ]:
            node.succeed(f"test -e {path}")
            node.fail(f"nsenter -t {pid} -m test -e {path}")

with subtest("local_only actions never go remote"):
    fresh(ci, UPLOAD, "uploader-ci")
    lines = build(ci, "//:local_probe", "local")
    assert lines[0] == "ci", lines

with subtest("an action no worker can run falls back to local execution"):
    fresh(dev, EXECUTE, "executor-dev")
    other = "0" * 64
    lines = build(dev, "//:unmatched_probe", "local", f"-c nix.cells_id={other}")
    assert lines[0] == "dev", lines

with subtest("an unreachable scheduler falls back to local execution"):
    scheduler.succeed("systemctl stop nativelink")
    fresh(dev, EXECUTE, "executor-dev")
    lines = build(dev, "//:unreachable_probe", "local")
    assert lines[0] == "dev", lines
    scheduler.succeed("systemctl start nativelink")
    scheduler.wait_for_open_port(EXECUTE, TAILNET)
