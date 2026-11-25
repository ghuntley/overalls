"""Exercise fleet builds: grpc delegation to the scheduler, caches and refusals."""

nodes = [alpha, beta]
F = "/etc/fixtures"

start_all()
for node in nodes:
    node.wait_for_unit("sshd.service")
    node.succeed(
        # Units retried against the absent fixture at boot and hit their start limit.
        "python /etc/seal.py && systemctl reset-failed && systemctl restart overalls-secrets-fleet-builds"
        " && systemctl restart nix-daemon nix-grpc-daemon.socket"
    )
    node.succeed("test $(stat -c %a /run/overalls-secrets/fleet-builds/grpc.key) = 600")
    node.fail('su -s /bin/sh nobody -c "cat /run/overalls-secrets/fleet-builds/grpc.key"')

with subtest("topology: one scheduler, no delegation from it, one grpc builder on the peer"):
    alpha.fail("test -s /etc/nix/machines")
    alpha.succeed("nix config show external-builders | grep -qx '\\[\\]'")
    beta.succeed("grep -c '^grpc://192.168.1.1:50051' /etc/nix/machines | grep -qx 1")
    beta.succeed("test $(stat -L -c %a /run/nix-grpc-store/client.key) = 600")
    beta.succeed("nix config show external-builders | grep -qx '\\[\\]'")

with subtest("peer builds are delegated to the scheduler"):
    paths = beta.succeed(
        "nix-build /etc/jobs.nix --argstr batch spread --no-out-link --max-jobs 0", timeout=240
    ).splitlines()
    assert len(paths) == 4, paths
    for path in paths:
        assert beta.succeed(f"cat {path}/batch").strip() == "spread"
        # Built by the scheduler's daemon, so the output is in its store.
        alpha.succeed(f"test -e {path}/batch")

with subtest("scheduler builds stay local"):
    alpha.succeed(
        "nix-build /etc/jobs.nix --argstr batch local --arg count 1 --arg seconds 1 --no-out-link",
        timeout=120,
    )

with subtest("peers substitute unsigned outputs from each other over grpc"):
    source = beta.succeed(
        "nix-build /etc/jobs.nix --argstr batch cached --arg count 1 --arg seconds 1 --no-out-link"
        ' --option builders "" --option substitute false'
    ).strip()
    fetched = alpha.succeed(
        "nix-build /etc/jobs.nix --argstr batch cached --arg count 1 --arg seconds 1 --no-out-link"
        " --max-jobs 0",
        timeout=60,
    ).strip()
    assert source == fetched

with subtest("refusals: unmatched grpc CN, read-only peer"):
    grpc = (
        f"grpc://192.168.1.1:50051?ca-cert={F}/grpc-ca.crt"
        f"&client-cert={F}/grpc-mallory.crt&client-key={F}/grpc-mallory.key"
    )
    beta.fail(f"nix store info --store '{grpc}'")
    # alpha's certificate is read-only on beta: an unsigned import is refused.
    readonly = (
        f"grpc://192.168.1.2:50051?ca-cert={F}/grpc-ca.crt"
        f"&client-cert={F}/grpc-alpha.crt&client-key={F}/grpc-alpha.key"
    )
    # Read-only permits path queries but not the raw worker-protocol tunnel.
    alpha.succeed(f"nix path-info --store '{readonly}' {source}")
    alpha.fail(f"nix store info --store '{readonly}'")
    alpha.fail(f"nix copy --no-check-sigs --to '{readonly}' {source}")

with subtest("scheduler outage falls back to local builds"):
    alpha.succeed("systemctl stop nix-grpc-daemon.socket nix-grpc-daemon.service")
    started = beta.succeed("date +%s").strip()
    beta.succeed(
        "nix-build /etc/jobs.nix --argstr batch scheduler-down --arg count 1 --arg seconds 1 --no-out-link",
        timeout=300,
    )
    print("scheduler-down fallback seconds:", int(beta.succeed("date +%s")) - int(started))
