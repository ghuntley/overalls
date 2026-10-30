"""Published enrollment and updates using real SSH, SOPS, Nix and activation."""

import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import time
from collections.abc import Sequence
from pathlib import Path

os.umask(0o077)
os.environ["NIX_CONFIG"] = "substituters =\n"
root = Path("/root/enrollment-test")
spec = importlib.util.spec_from_file_location("host_remote", root / "remote.py")
if spec is None or spec.loader is None:
    raise RuntimeError("host remote helper unavailable")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


def run(args: Sequence[str | Path], **kwargs: object) -> str:
    return subprocess.check_output(
        [str(a) for a in args], text=True, timeout=1200, **kwargs
    ).strip()


host = json.loads(Path("/etc/overalls-host.json").read_text())
public = remote.public_key("/etc/ssh/ssh_host_ed25519_key")
baseline = remote.storage(host)
remote.atomic(Path("/var/lib/overalls-host/storage.json"), baseline)
receipt = root / "install.json"
receipt.write_text(json.dumps({"host": host["name"], "hostKey": public, "storage": baseline}))
known = root / "known-hosts"
known.write_text("127.0.0.1 " + public + "\n")
Path("/root/.ssh").mkdir(mode=0o700, exist_ok=True)
Path("/root/.ssh/config").write_text(
    f"Host 127.0.0.1\n  IdentityFile {root}/operator\n  IdentitiesOnly yes\n  UserKnownHostsFile {known}\n  StrictHostKeyChecking yes\n"
)
repo = Path("/home/tester/public-fleet")
run(["sudo", "-u", "tester", "git", "init", "-b", "trunk", repo])
run(["sudo", "-u", "tester", "git", "-C", repo, "config", "user.name", "Fixture"])
run(["sudo", "-u", "tester", "git", "-C", repo, "config", "user.email", "fixture@example.test"])
# Offline Buck2 fixture: the real tools/buck2, rules and host package file.
fixture = Path((root / "buck2-fixture").read_text().strip())
shutil.copytree(fixture, repo, dirs_exist_ok=True, symlinks=False)
# copytree copies the read-only store mode onto the existing repository root.
repo.chmod(0o755)
(repo / "cells").unlink()
(repo / "fleet/hosts/host").rename(repo / "fleet/hosts" / host["name"])
(repo / "BUCK").chmod(0o644)
(repo / "BUCK").write_text(
    (repo / "BUCK")
    .read_text()
    .replace("//fleet/hosts/host:", "//fleet/hosts/" + host["name"] + ":")
)
(repo / "flake.nix").write_text((root / "flake.nix").read_text())
(repo / "common.nix").write_text((root / "common.nix").read_text())
(repo / "generation").write_text("one")
declaration = repo / "fleet/hosts" / host["name"] / "host.json"
declaration.parent.mkdir(parents=True, exist_ok=True)
(repo / "secrets").mkdir()
url = "ssh://tester@127.0.0.1/home/tester/public-fleet"
host["identity"]["sshKeys"] = [public]
host["git"] = {"repository": url, "knownHosts": "127.0.0.1 " + public + "\n"}
host["credentials"] = [{"name": host["name"] + "-git", "path": "secrets/git.enc.json"}]
plain = root / "plaintext.json"
plain.write_text(
    json.dumps(
        {"overalls-git": {"production": {"GIT_DEPLOY_KEY": (root / "operator").read_text()}}}
    )
)
recipients = [run(["ssh-to-age"], input=public)]
recovery_public = run(["ssh-keygen", "-y", "-f", root / "operator"])
recipients.append(run(["ssh-to-age"], input=recovery_public))
with (repo / "secrets/git.enc.json").open("w") as output:
    subprocess.run(
        [
            "sops",
            "--encrypt",
            "--age",
            ",".join(recipients),
            "--input-type",
            "json",
            "--output-type",
            "json",
            str(plain),
        ],
        stdout=output,
        check=True,
    )
plain.unlink()


def publish(generation: str, good_pin: bool = True) -> str:
    (repo / "generation").write_text(generation)
    candidate: dict[str, object] = json.loads(json.dumps(host))
    if not good_pin:
        candidate["git"]["knownHosts"] = "127.0.0.1 " + recovery_public + "\n"
    declaration.write_text(json.dumps(candidate))
    # Publications contain only public configuration and encrypted credentials.
    private_line = (root / "operator").read_bytes().splitlines()[1]
    for path in repo.rglob("*"):
        if path.is_file() and ".git" not in path.parts:
            assert private_line not in path.read_bytes()
    for path in repo.rglob("*"):
        if ".git" not in path.parts:
            executable = path.is_dir() or path in {
                repo / "tools/buck2",
                repo / "buck/nix_assemble.sh",
            }
            path.chmod(0o755 if executable else 0o644)
    run(["chown", "-R", "tester:users", repo])
    run(["sudo", "-u", "tester", "git", "-C", repo, "add", "."])
    run(["sudo", "-u", "tester", "nix", "flake", "lock", "--offline", str(repo)])
    run(["chown", "-R", "tester:users", repo])
    run(["sudo", "-u", "tester", "git", "-C", repo, "add", "."])
    run(["sudo", "-u", "tester", "git", "-C", repo, "commit", "-m", generation])
    return run(["sudo", "-u", "tester", "git", "-C", repo, "rev-parse", "HEAD"])


args = [
    "host",
    "enroll",
    "--host",
    host["name"],
    "--repository",
    url,
    "--install-receipt",
    receipt,
    "--target",
    "tester@127.0.0.1",
    "--known-hosts",
    known,
    "--identity",
    root / "operator",
]
failed = publish("bad-pin", good_pin=False)
assert subprocess.run([str(a) for a in [*args, "--revision", failed]], timeout=1200).returncode != 0
status_path = Path("/var/lib/overalls-auto-update/status.json")
if not status_path.exists():
    # Replay the real entry point with a traceback only in this isolated fixture.
    # Every key used here is generated for the test or a public upstream fixture.
    for wrapper in Path("/nix/store").glob("*-overalls-enrollment-runtime"):
        lines = wrapper.read_text().splitlines()
        environment = dict(os.environ)
        environment["PATH"] = next(
            line.removeprefix("export PATH=") for line in lines if line.startswith("export PATH=")
        )
        command = shlex.split(next(line for line in lines if line.startswith("exec ")))[1:]
        subprocess.run(
            [
                command[0],
                "-c",
                "import runpy,sys; sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='fixture_diagnostic')['main']()",
                *command[1:-1],
                failed,
            ],
            env=environment,
            timeout=180,
        )
    raise AssertionError("Enrollment failed before reaching the expected Git-pin boundary")
assert json.loads(status_path.read_text())["failedPhase"] == "enrollment-preflight", (
    status_path.read_text()
)
assert not Path("/var/lib/overalls-host/enrollment.json").exists()
assert remote.public_key("/etc/ssh/ssh_host_ed25519_key") == public
assert subprocess.run(["systemctl", "is-active", "overalls-auto-update.timer"]).returncode != 0
first = publish("one")
try:
    run([*args, "--revision", first])
except subprocess.CalledProcessError:
    # Phase records contain fixed reason codes and public candidate identity.
    print(status_path.read_text(), flush=True)
    raise
remote.verify(json.loads(Path("/etc/overalls-host.json").read_text()), receipt=True)
assert Path("/run/overalls-secrets/git/deploy-key").read_bytes() == (root / "operator").read_bytes()
assert json.loads(Path("/var/lib/overalls-host/enrollment.json").read_text())["revision"] == first
second = publish("two")
deadline = time.monotonic() + 600
while time.monotonic() < deadline:
    if Path("/etc/overalls-enrollment-generation").read_text() == "two":
        status = json.loads(Path("/var/lib/overalls-auto-update/status.json").read_text())
        if status.get("lastHealthy", {}).get("revision") == second:
            break
    time.sleep(2)
else:
    # This fixture's build diagnostics name only public test inputs.
    attempt = Path("/var/lib/overalls-auto-update/attempt.log")
    if attempt.exists():
        print(attempt.read_text()[-12000:], flush=True)
    raise AssertionError("Published update did not become healthy")
remote.verify(json.loads(Path("/etc/overalls-host.json").read_text()), receipt=True)
assert remote.public_key("/etc/ssh/ssh_host_ed25519_key") == public
print(
    "Published enrollment, pinned-key failure/retry, encrypted Git key and subsequent update passed"
)
