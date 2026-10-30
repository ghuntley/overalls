"""Exercise the Buck2 NativeLink cache: identities, the write split and tailnet-only listeners."""

import json

from test_driver.machine import QemuMachine as Machine

F = "/etc/fixtures"
TAILNET = "192.168.1.1"
READ, UPLOAD = 50071, 50072
INSTANCE = "main"
# A sha256 action digest the test owns, and a small blob.
ACTION = {"hash": "a" * 64, "sizeBytes": "10"}
HOST_ACTION = {"hash": "b" * 64, "sizeBytes": "10"}
BLOB = "aGVsbG8gYnVjaw=="  # "hello buck"
BLOB_DIGEST = {
    "hash": "5e9ad51e3ae4bf7b3df1252b5618f9423d03899a86afdb4e5bad11bc3ce4af5e",
    "sizeBytes": "10",
}


def grpc(node: Machine, port: int, identity: str | None, method: str, request: object) -> str:
    """Call an REv2 method; returns combined output and never raises."""
    credentials = f"-cert {F}/{identity}.crt -key {F}/{identity}.key " if identity else ""
    command = (
        f"grpcurl -max-time 10 -cacert {F}/ca.crt {credentials}"
        "-import-path /etc/rev2-protos -proto build/bazel/remote/execution/v2/remote_execution.proto "
        f"-d '{json.dumps(request)}' {TAILNET}:{port} build.bazel.remote.execution.v2.{method} 2>&1"
    )
    return node.execute(command)[1]


def buck(node: Machine, target: str) -> str:
    return node.succeed(f"cd /root/project && HOME=/root buck2 build {target} 2>&1")


def assert_ran(node: Machine, target: str, kind: str) -> None:
    output = buck(node, target)
    assert f"{kind}: 1" in output, output


UPDATER_HOME = "/var/lib/updater-buck2-home"


def fresh(node: Machine) -> None:
    node.succeed(
        "(cd /root/project 2>/dev/null && HOME=/root buck2 kill >/dev/null 2>&1) || true;"
        f" (cd /root/project 2>/dev/null && HOME={UPDATER_HOME} buck2 kill >/dev/null 2>&1) || true;"
        " rm -rf /root/project;"
        " cp -rL /etc/buck-project /root/project && chmod -R u+w /root/project"
    )


start_all()
with subtest("without credentials buck2 builds locally"):
    fresh(ci)
    assert_ran(ci, "//:uploaded", "local")
    # The host's client configuration exists only once its identity does.
    host.wait_for_unit("multi-user.target")
    host.fail("test -e /root/.buckconfig.d/overalls-remote-cache")
    fresh(host)
    assert_ran(host, "//:uploaded", "local")

for node in [cache, host]:
    node.wait_for_unit("sshd.service")
    # The bundle retried against the absent fixture at boot and hit its limit.
    node.succeed(
        "python3 /etc/seal.py && systemctl reset-failed && systemctl restart overalls-secrets-buck-re"
    )
cache.succeed("systemctl restart nativelink")
cache.wait_for_unit("nativelink.service")
cache.wait_for_open_port(READ, TAILNET)
cache.wait_for_open_port(UPLOAD, TAILNET)

with subtest("listeners bind only the tailnet address and the key stays private"):
    listening = cache.succeed("ss -Htln")
    for port in (READ, UPLOAD):
        assert f"{TAILNET}:{port}" in listening, listening
        assert f"0.0.0.0:{port}" not in listening and f"*:{port}" not in listening, listening
    cache.succeed("test $(stat -c %a /run/overalls-secrets/buck-re/server.key) = 600")
    cache.fail('su -s /bin/sh nobody -c "cat /run/overalls-secrets/buck-re/server.key"')
    cache.succeed(
        "test -d /var/lib/nativelink/cas/content && test -d /var/lib/nativelink/ac/content"
    )

with subtest("the port is unreachable from a non-tailnet interface"):
    # The public address has no listener at all.
    outsider.fail(f"timeout 5 bash -c '</dev/tcp/192.168.2.1/{READ}'")
    # Route the tailnet address through the cache's public interface. Linux
    # accepts any local address on any interface, so sshd answers there; the
    # cache's interface restriction must still drop it.
    outsider.succeed(f"ip route add {TAILNET}/32 via 192.168.2.1 dev eth1")
    outsider.wait_until_succeeds(f"timeout 5 bash -c '</dev/tcp/{TAILNET}/22'", timeout=30)
    for port in (READ, UPLOAD):
        outsider.fail(f"timeout 5 bash -c '</dev/tcp/{TAILNET}/{port}'")

with subtest("each listener admits only certificates from its own CA"):
    assert "cacheCapabilities" in grpc(
        ci, UPLOAD, "uploader-ci", "Capabilities/GetCapabilities", {"instanceName": INSTANCE}
    )
    assert "cacheCapabilities" in grpc(
        host, READ, "reader-host", "Capabilities/GetCapabilities", {"instanceName": INSTANCE}
    )
    for node, port, identity in [
        (host, UPLOAD, "reader-host"),
        (ci, READ, "uploader-ci"),
        (ci, READ, "rogue"),
        (ci, UPLOAD, "rogue"),
        (ci, READ, None),
        (ci, UPLOAD, None),
    ]:
        output = grpc(
            node, port, identity, "Capabilities/GetCapabilities", {"instanceName": INSTANCE}
        )
        assert "cacheCapabilities" not in output, (port, identity, output)

with subtest("the CI identity writes an action result and blob that a host reads"):
    result = {"exitCode": 0, "stdoutRaw": BLOB}
    written = grpc(
        ci,
        UPLOAD,
        "uploader-ci",
        "ActionCache/UpdateActionResult",
        {"instanceName": INSTANCE, "actionDigest": ACTION, "actionResult": result},
    )
    assert "ERROR" not in written, written
    read = grpc(
        host,
        READ,
        "reader-host",
        "ActionCache/GetActionResult",
        {"instanceName": INSTANCE, "actionDigest": ACTION},
    )
    assert BLOB in read, read
    blob = grpc(
        ci,
        UPLOAD,
        "uploader-ci",
        "ContentAddressableStorage/BatchUpdateBlobs",
        {"instanceName": INSTANCE, "requests": [{"digest": BLOB_DIGEST, "data": BLOB}]},
    )
    assert "ERROR" not in blob and '"code"' not in blob, blob
    read = grpc(
        host,
        READ,
        "reader-host",
        "ContentAddressableStorage/BatchReadBlobs",
        {"instanceName": INSTANCE, "digests": [BLOB_DIGEST]},
    )
    assert BLOB in read, read

with subtest("a host identity cannot write the action cache or persist blobs"):
    refused = grpc(
        host,
        READ,
        "reader-host",
        "ActionCache/UpdateActionResult",
        {"instanceName": INSTANCE, "actionDigest": HOST_ACTION, "actionResult": {"exitCode": 0}},
    )
    assert "PermissionDenied" in refused, refused
    missing = grpc(
        ci,
        UPLOAD,
        "uploader-ci",
        "ActionCache/GetActionResult",
        {"instanceName": INSTANCE, "actionDigest": HOST_ACTION},
    )
    assert "NotFound" in missing, missing
    host_blob = "aG9zdCBibG9i"  # "host blob"
    host_digest = {
        "hash": host.succeed("printf 'host blob' | sha256sum | cut -d' ' -f1").strip(),
        "sizeBytes": "9",
    }
    grpc(
        host,
        READ,
        "reader-host",
        "ContentAddressableStorage/BatchUpdateBlobs",
        {"instanceName": INSTANCE, "requests": [{"digest": host_digest, "data": host_blob}]},
    )
    absent = grpc(
        ci,
        UPLOAD,
        "uploader-ci",
        "ContentAddressableStorage/FindMissingBlobs",
        {"instanceName": INSTANCE, "blobDigests": [host_digest]},
    )
    assert host_digest["hash"] in absent, absent

with subtest("buck2 with the CI identity uploads, then hits the cache"):
    fresh(ci)
    ci.succeed(
        "cat > /root/project/.buckconfig.local <<EOF\n"
        "[buck2_re_client]\n"
        f"  address = grpc://{TAILNET}:{UPLOAD}\n"
        "  tls = true\n"
        f"  instance_name = {INSTANCE}\n"
        f"  tls_ca_certs = {F}/ca.crt\n"
        f"  tls_client_cert = {F}/uploader-ci.pem\n"
        "[buck2]\n"
        "  default_allow_cache_upload = true\n"
        "EOF"
    )
    assert_ran(ci, "//:uploaded", "local")
    ci.succeed("cd /root/project && HOME=/root buck2 clean")
    assert_ran(ci, "//:uploaded", "cached")

with subtest("a host reads through its module configuration and cannot upload"):
    host.succeed("systemctl restart overalls-buck-re-client")
    host.succeed("test -f /root/.buckconfig.d/overalls-remote-cache")
    fresh(host)
    assert_ran(host, "//:uploaded", "cached")
    # Even with uploads requested, the read-only listener refuses them.
    host.succeed(
        "printf '[buck2]\\n  default_allow_cache_upload = true\\n' > /root/project/.buckconfig.local"
    )
    assert_ran(host, "//:host_attempt", "local")
    ci.succeed("cd /root/project && HOME=/root buck2 clean")
    assert_ran(ci, "//:host_attempt", "local")


def updater_build(expected_state: str, kind: str) -> None:
    """Build as the updater does: its own HOME and its checkout configuration."""
    fresh(host)
    state = host.succeed("python3 /etc/updater-config.py /root/project/.buckconfig.local").strip()
    assert state == expected_state, state
    host.succeed("grep -qx '  default_allow_cache_upload = false' /root/project/.buckconfig.local")
    output = host.succeed(
        f"mkdir -p -m 0700 {UPDATER_HOME} && cd /root/project"
        f" && HOME={UPDATER_HOME} buck2 build //:uploaded 2>&1"
    )
    assert f"{kind}: 1" in output, output


with subtest("the updater reads the CI-built action through its own configuration"):
    # Root's ~/.buckconfig.d is not the updater's: it runs Buck2 with a
    # private HOME, so the cache settings come from the checkout's
    # .buckconfig.local that the production runtime writes.
    host.fail(f"test -e {UPDATER_HOME}/.buckconfig.d")
    updater_build("enabled", "cached")

with subtest("the updater builds locally when the cache is unreachable"):
    cache.succeed("systemctl stop nativelink")
    updater_build("unreachable", "local")
    cache.succeed("systemctl start nativelink")
    cache.wait_for_open_port(READ, TAILNET)

with subtest("the updater builds locally without its identity"):
    # As when the bundle could not be decrypted: the identity file is absent.
    identity = "/run/overalls-secrets/buck-re/client.pem"
    host.succeed(f"mv {identity} /root/client.pem.aside")
    updater_build("identity_missing", "local")
    host.succeed(f"mv /root/client.pem.aside {identity}")
    updater_build("enabled", "cached")

with subtest("the updater builds locally when the cache rejects its identity"):
    # Configured and reachable, but the handshake fails: an identity from an
    # untrusted CA, then one that is not a certificate at all. Buck2 treats
    # the failed action-cache query as a miss and builds locally.
    identity = "/run/overalls-secrets/buck-re/client.pem"
    host.succeed(f"cp {identity} /root/client.pem.good")
    for replacement in ["cat /etc/fixtures/rogue.pem", "echo not-a-certificate"]:
        host.succeed(f"{replacement} > {identity}")
        updater_build("enabled", "local")
    host.succeed(f"cp /root/client.pem.good {identity}")
    updater_build("enabled", "cached")
