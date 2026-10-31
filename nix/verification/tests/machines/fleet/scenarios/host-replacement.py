# @cc [owner:ghuntley,label:verification;security;recovery] fleet-host-replacement-journey
# The replacement journey MUST use the real topology end to end: enrolled l1
# serves a nested guest through real Audi/Ziggy private services, retirement
# runs the real drain chain, stale compute and Ziggy credentials MUST be
# refused over the real TLS listener forever, and the replacement host MUST
# enroll disabled with a fresh machine identity, name and storage GUIDs.
"""Host retirement and replacement with fresh physical identity."""

import hashlib
from typing import Any


def host_binding(machine: MachineLike) -> str:
    binding: str = host_bindings[machine.name]["host"]
    return binding


def probe(mode: str, session_id: str, epoch: int, credential_path: str) -> str:
    result = old_host.succeed(
        "fleet-host-probe "
        + shlex.join(
            [
                mode,
                credential_path,
                "https://control.example.test:5443",
                f"{root}/ca.crt",
                session_id,
                str(epoch),
                old_machine_id,
            ]
        ),
        timeout=60,
    ).strip()
    return result


def storage_identity(value: object) -> dict[str, object]:
    """Narrow a decoded storage identity to string keys."""
    assert isinstance(value, dict)
    return {str(key): item for key, item in value.items()}


def ziggy_refusal(status: int, error: str) -> str:
    """Classify a control-socket answer; refusals carry only closed names."""
    if status == 101 and error == "":
        return "accepted"
    if status == 401 or (status == 101 and error in {"unauthorized", "invalid_request"}):
        return "refused"
    assert status in {0, 101} or status >= 500, f"unexpected ziggy answer {status} {error}"
    return "transport"


# Minimal ADR-0142 control client: upgrade with the Ziggy credential, bind the
# host, send one request and print "<upgrade status> <error name or empty>".
ZIGGY_SOCKET = r"""
import base64, json, os, socket, ssl, struct, sys
origin, cafile, token, host_id, op, body = sys.argv[1:7]
ctx = ssl.create_default_context(cafile=cafile)
try:
    raw = socket.create_connection((origin, 5443), timeout=20)
except OSError:
    print("0 transport"); sys.exit(0)
tls = ctx.wrap_socket(raw, server_hostname=origin)
key = base64.b64encode(os.urandom(16)).decode()
tls.sendall((
    f"GET /api/control/v1 HTTP/1.1\r\nHost: {origin}:5443\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
    f"Sec-WebSocket-Key: {key}\r\noveralls-control: 1\r\noveralls-service: ziggy\r\n"
    f"Authorization: Bearer {token}\r\n\r\n").encode())
head = b""
while b"\r\n\r\n" not in head:
    chunk = tls.recv(1)
    if not chunk:
        break
    head += chunk
status = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/1.1 ") else 0
if status != 101:
    print(status); sys.exit(0)
def send(doc):
    data = json.dumps(doc).encode()
    mask = os.urandom(4)
    size = len(data)
    header = bytes([0x81, 0x80 | size]) if size < 126 else bytes([0x81, 0xFE]) + struct.pack("!H", size)
    tls.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
def exact(n):
    out = b""
    while len(out) < n:
        chunk = tls.recv(n - len(out))
        if not chunk:
            print("101 transport"); sys.exit(0)
        out += chunk
    return out
def receive():
    while True:
        first, second = exact(2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", exact(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", exact(8))[0]
        payload = exact(size)
        if first & 0x0F == 0x8:
            print("101 transport"); sys.exit(0)
        if first & 0x0F == 0x1:
            doc = json.loads(payload)
            if doc.get("k") in {"welcome", "res"}:
                return doc
send({"k": "hello", "v": 1, "service": "ziggy", "bind": {"host_id": host_id}})
receive()
send({"k": "req", "id": 1, "op": "ziggy." + op, "body": json.loads(body)})
res = receive()
print("101 " + ("" if res.get("ok") else str(res.get("error"))))
"""


def ziggy_call(route: str, body: dict[str, Any], token: str, via_proxy: bool = True) -> str:
    """Invoke one Ziggy op over the fleet control WebSocket with stdlib TLS."""
    origin = "control.example.test" if via_proxy else "m1"
    args = [origin, root + "/ca.crt", token, old_host_id, route, json.dumps(body)]
    output = client.succeed(
        "python3 -c " + shlex.quote(ZIGGY_SOCKET) + " " + shlex.join(args), timeout=40
    ).strip()
    status, _, error = output.partition(" ")
    assert status.isdigit(), f"ziggy returned invalid status: {output!r}"
    return ziggy_refusal(int(status), error)


old_host = l1
new_host = l2
old_host_id = host_binding(old_host)
old_fleet_identity = host_identity(old_host)
old_machine_id = str(old_fleet_identity["machine_id"])
old_storage_identity = storage_identity(old_fleet_identity["storage"])
retired_credential = root + "/retired-lilly-credential.json"

bridge = (
    "ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes"
    " -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null"
    " -o UserKnownHostsFile=/root/enrollment/known_hosts"
    " -i /root/enrollment/key operator@m1 sudo -n overalls-marshall-enrollment"
)


def bridge_call(operation_id: str, action: str, request: dict[str, Any]) -> dict[str, Any]:
    """Invoke the protected Marshall enrollment bridge over pinned SSH."""
    payload = json.dumps({"operation_id": operation_id, "action": action, "request": request})
    return json.loads(
        new_host.succeed("printf %s " + shlex.quote(payload) + " | " + bridge, timeout=180)
    )


def bridge_refusal(operation_id: str, action: str, request: dict[str, Any]) -> None:
    payload = json.dumps({"operation_id": operation_id, "action": action, "request": request})
    code, _output = new_host.execute(
        "printf %s " + shlex.quote(payload) + " | " + bridge, timeout=180
    )
    assert code != 0, "protected bridge unexpectedly accepted the request"


def install_replacement_credentials() -> None:
    """Seal the replacement's Lilly credential and start only its compute path."""
    # The control CA goes to the replacement exactly as at initial enrollment.
    transfer(db, f"{root}/ca.crt", new_host, f"{root}/ca.crt")
    new_host.succeed("fleet-seal-lilly")
    new_host.succeed(f"touch {root}/ready")
    new_host.succeed("systemctl restart fleet-credentials.service overalls-secrets-lilly.service")
    new_host.succeed("systemctl start lilly.service")


def install_replacement_service_credentials() -> None:
    """Seal every service bundle, then start the private services."""
    new_host.succeed("fleet-seal-ziggy")
    new_host.succeed("fleet-seal-galileo")
    transfer(m1, f"{root}/audi-root.pem", new_host, "/run/galileo-audi-root.pem")
    new_host.succeed("chmod 0444 /run/galileo-audi-root.pem")
    new_host.succeed("fleet-seal-audi-private")
    write_netns_override(new_host, new_host_id)
    new_host.succeed("systemctl restart fleet-ziggy-credentials.service")
    new_host.succeed(
        "systemctl restart overalls-secrets-ziggy.service overalls-secrets-galileo.service"
    )
    new_host.succeed("systemctl restart ziggy.service galileo.service")
    new_host.succeed("systemctl restart overalls-secrets-audi-private.service")
    new_host.succeed("systemctl restart audi-private.service")


def audi_private_ready(machine: MachineLike, host_id: str) -> bool:
    """Gate on the same netns evidence Audi's own health margin uses."""
    ns = ns_for_host(host_id)
    code, _output = machine.execute(
        "ip netns exec "
        + shlex.quote(ns)
        + " curl --silent --fail --max-time 8 "
        + "--cacert /run/audi-private/credentials/roots.pem "
        + "--resolve llm.internal:443:169.254.254.1 "
        + "https://llm.internal/health/ready -o /dev/null",
        timeout=15,
    )
    return code == 0


def await_private_gate(machine: MachineLike, host_id: str) -> None:
    machine.wait_for_unit("audi-private.service")
    try:
        eventually(lambda: audi_private_ready(machine, host_id), timeout=480)
    except Exception:
        private_chain_diag(machine, host_id)
        raise


def private_chain_diag(machine: MachineLike, host_id: str) -> None:
    """Failure-only host-side inspection of the private gateway chain."""
    namespace = "lilly-" + hashlib.sha256(host_id.encode()).hexdigest()[:12]
    _unit = machine.execute(
        "systemctl show audi-private.service -p ActiveState -p NRestarts -p Result"
    )
    events = machine.execute(
        "journalctl -u audi-private.service --no-pager -o cat -n 200 "
        "| grep -aoE 'event\\\\\":\\\\\"[a-z_]+' | sort | uniq -c"
    )
    print("replacement diagnostic events:", events)
    state = machine.succeed(
        "systemctl show audi-private.service -p ActiveState -p SubState -p NRestarts -p Result"
    ).strip()
    print("replacement diagnostic unit: " + state.replace("\n", " "))
    connector = machine.execute("test -S /run/lilly-ingress/private.sock && echo present")
    print("replacement diagnostic connector: " + str(connector))
    state_events = machine.execute(
        "journalctl -u audi-private.service --no-pager -o cat -n 240 "
        "| grep -aoE '(startup_configuration_rejected|startup_configuration_ok|configuration_ready|"
        "private_listener_started|private_listener_failed|dns_server_started|dns_ready|health_ready|"
        'reason\\":\\"[a-z_]+)\' | sort | uniq -c'
    )
    print("replacement diagnostic audi events:", state_events)
    for label, command in [
        ("netns-addr", f"ip netns exec {namespace} ip -o addr 2>&1 || true"),
        ("netns-routes", f"ip netns exec {namespace} ip -o route 2>&1 || true"),
        ("audi-private-status", "cat /run/audi-private/status.sock 2>&1 || true"),
        (
            "audi-private-fetch",
            f"ip netns exec {namespace} curl --silent --show-error --max-time 5 "
            f"--cacert /run/audi-private/credentials/roots.pem https://llm.internal/health/ready "
            f"-o /dev/null -w '%{{http_code}}' 2>&1 || true",
        ),
        (
            "ziggy-health",
            "curl --silent --unix-socket /run/ziggy/proxy.sock http://localhost/health/ready || true",
        ),
        ("netns-list", "ip netns list 2>&1 || true"),
        ("netns-dig", f"ip netns exec {namespace} getent hosts llm.internal 2>&1 || true"),
    ]:
        code, output = machine.execute(command)
        print(f"replacement diagnostic {label}: rc={code} {output[:400]}")


def ns_for_host(host_id: str) -> str:
    return "lilly-" + hashlib.sha256(host_id.encode()).hexdigest()[:12]


def write_netns_override(machine: MachineLike, host_id: str) -> None:
    """Point Audi private at the runtime netns named by Lilly's live host identity."""
    ns = ns_for_host(host_id)
    machine.succeed(
        "install -d -m 755 /run/systemd/system/audi-private.service.d && printf '%s' "
        + shlex.quote("[Service]\nNetworkNamespacePath=/run/netns/" + ns + "\n")
        + " > /run/systemd/system/audi-private.service.d/netns.conf"
    )
    machine.succeed("systemctl daemon-reload")


def new_host_report_ready(host_id: str) -> bool:
    row = sql_json(
        "SELECT json_build_object('ready', inventory->>'execution_ready'='true',"
        "'fresh', reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds')"
        f" FROM compute_hosts WHERE id='{host_id}'"
    )
    return isinstance(row, dict) and row["ready"] is True and row["fresh"] is True


with subtest("baseline: the enrolled host serves llm.internal to a real guest"):
    assert sql(f"SELECT count(*) FROM compute_hosts WHERE name='{replacement_host}'") == "0"
    row = sql_json(
        f"SELECT json_build_object('name',name) FROM compute_hosts WHERE id='{old_host_id}'"
    )
    assert isinstance(row, dict) and row["name"] == "l1"
    vm = provision_when_available(m1, "standard")
    await_running(vm["vm_id"])
    assert vm["host_id"] == old_host_id
    try:
        old_host.wait_until_succeeds(
            "fleet-galileo-guest llm-dns " + shlex.quote(vm["placement_id"]), timeout=480
        )
        old_host.wait_until_succeeds(
            "fleet-galileo-guest llm-health " + shlex.quote(vm["placement_id"]), timeout=480
        )
    except Exception:
        private_chain_diag(old_host, old_host_id)
        raise
    print("replacement scenario stage: baseline guest reached llm.internal")

with subtest("retirement runs the real drain chain and persists the row"):
    # The fleet's services.lilly.credentialFile is the bundle's credential.json.
    old_credential_path = "/run/overalls-secrets/lilly/credential.json"
    old_host.succeed("install -m 0600 " + old_credential_path + " " + retired_credential)
    deleted = operator(
        m1,
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            kind="delete",
            key=str(uuid.uuid4()),
        ),
    )
    assert deleted["requested"] is True

    def vm_deleted() -> bool:
        return vm_state(vm["vm_id"]) == "deleted"

    eventually(vm_deleted, timeout=480)

    def pools_quiet() -> bool:
        return (
            sql("SELECT count(*) FROM compute_reservations WHERE compute_held OR disk_held") == "0"
        )

    eventually(pools_quiet, timeout=180)

    # Live-token control: the active ziggy credential answers 200 at identity.
    ziggy_live_token = old_host.succeed(f"cat {root}/ziggy.token").strip()
    live_identity = ziggy_call("identity", dict(version=1), ziggy_live_token)
    assert live_identity == "accepted", "live ziggy identity must answer 200"

    # Start one mid-flight exchange against the live session, then retire.
    session = sql_json(
        f"SELECT json_build_object('session',connection_session_id,'epoch',connection_epoch,"
        f"'sequence',report_sequence) FROM compute_hosts WHERE id='{old_host_id}'"
    )
    assert isinstance(session, dict) and session["session"] and session["epoch"]
    before_sequence = int(session["sequence"])
    assert (
        probe("exchange", str(session["session"]), int(session["epoch"]), retired_credential)
        == "exchange:ok"
    )

    with ThreadPoolExecutor(max_workers=2) as pool:
        exchange_probe = pool.submit(
            probe, "exchange", str(session["session"]), int(session["epoch"]), retired_credential
        )
        retire = pool.submit(
            operator,
            m1,
            dict(action="host-retire", host_id=old_host_id),
        )
        fence_result = exchange_probe.result(timeout=120)
        retired = retire.result(timeout=180)

    assert fence_result in ("exchange:ok", "exchange:error_unauthorized")
    assert retired["status"] == "retired"
    assert retired["host_mode"] == "retired"
    assert retired["enabled"] is False

    # The host row persists as retired evidence with its drain history.
    retired_row = sql_json(
        f"SELECT json_build_object('name',name,'mode',maintenance_mode,'enabled',enabled) "
        f"FROM compute_hosts WHERE id='{old_host_id}'"
    )
    assert retired_row == {"name": "l1", "mode": "retired", "enabled": False}
    assert (
        sql(f"SELECT status FROM compute_host_drains WHERE id='{retired['drain_id']}'") == "retired"
    )
    print("replacement scenario stage: old host retired")

with subtest("stale credentials are refused over the real TLS listener forever"):
    got_open = probe("open", str(session["session"]), int(session["epoch"]), retired_credential)
    assert got_open == "open:error_unauthorized", f"stale open refusal class: {got_open}"
    got_exchange = probe(
        "exchange", str(session["session"]), int(session["epoch"]), retired_credential
    )
    assert got_exchange == "exchange:error_unauthorized", (
        f"stale exchange refusal class: {got_exchange}"
    )
    # The running old Lilly can no longer advance its report history.
    eventually(
        lambda: (
            int(sql(f"SELECT report_sequence FROM compute_hosts WHERE id='{old_host_id}'"))
            >= before_sequence
        ),
        timeout=30,
    )
    stale_sequence = sql(f"SELECT report_sequence FROM compute_hosts WHERE id='{old_host_id}'")

    def sequence_frozen() -> bool:
        current = sql(f"SELECT report_sequence FROM compute_hosts WHERE id='{old_host_id}'")
        return current == stale_sequence

    time.sleep(6)
    assert sequence_frozen()
    # The old Ziggy service credential is fenced at admission and renewal.
    ziggy_token = old_host.succeed(f"cat {root}/ziggy.token").strip()
    verify_code, verify_out = m1.execute(
        "fleet-op ziggy-verify " + shlex.quote(root + "/l1-ziggy.token")
    )
    print("replacement ziggy-verify of retired credential:", verify_code)
    assert verify_code != 0, "Marshall verifier unexpectedly authenticates retired authority"
    direct_identity = ziggy_call("identity", dict(version=1), ziggy_token, via_proxy=False)
    print("ziggy identity direct to m1:", direct_identity)
    ziggy_identity = ziggy_call("identity", dict(version=1), ziggy_token)
    assert ziggy_identity == "refused", f"stale ziggy identity refused class: {ziggy_identity}"
    ziggy_renew = ziggy_call("renew", dict(version=1, request_id=str(uuid.uuid4())), ziggy_token)
    assert ziggy_renew == "refused", f"stale ziggy renew refused class: {ziggy_renew}"
    print("replacement scenario stage: stale credentials refused")

with subtest("the replacement prepares over the protected SSH bridge with fresh identity"):
    # Replacement hardware arrives with fresh physical identity: rebuild the
    # provisioner pool so its ZFS GUIDs differ from the retired host's.
    new_host.wait_for_unit("fleet-storage.service")
    new_host.succeed("zpool reguid zroot")
    new_host.succeed(
        "zfs unmount zroot/lilly && zfs destroy zroot/lilly && zfs create"
        " -o mountpoint=/var/lib/lilly/pool -o compression=lz4 -o reservation=none -o refreservation=none"
        f" -o quota={storage_budget} zroot/lilly"
    )
    new_identity = host_identity(new_host)
    assert isinstance(new_identity, dict)
    assert new_identity["machine_id"] != old_machine_id
    new_storage = storage_identity(new_identity["storage"])
    for key in ("zpool_guid", "dataset_guid"):
        assert str(new_storage[key]) != str(old_storage_identity[key]), key

    # Arm the pinned operator SSH transport between the replacement and m1.
    new_host.succeed(
        "install -d -m 700 /root/enrollment; ssh-keygen -q -t ed25519 -N '' -f /root/enrollment/key"
    )
    public = new_host.succeed("cat /root/enrollment/key.pub").strip()
    m1.succeed(
        "install -d -m 700 -o operator -g users /home/operator/.ssh; printf '%s\\n' "
        + shlex.quote(public)
        + " > /home/operator/.ssh/authorized_keys; chown operator:users /home/operator/.ssh/authorized_keys; chmod 600 /home/operator/.ssh/authorized_keys"
    )
    host_key = m1.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    new_host.succeed(
        "printf '%s\\n' " + shlex.quote("m1 " + host_key) + " > /root/enrollment/known_hosts"
    )

    new_request: dict[str, Any] = dict(
        version=3,
        name=replacement_host,
        architecture="x86_64",
        machine_id=new_identity["machine_id"],
        overhead_cores=1,
        overhead_memory_bytes=1073741824,
        credential_ttl_seconds=3600,
        pools=[
            dict(
                name="guests",
                storage=new_storage,
                overhead_bytes=536870912,
            )
        ],
    )
    operation = str(uuid.uuid4())
    prepared = bridge_call(operation, "prepare-enrollment", new_request)
    assert bridge_call(operation, "prepare-enrollment", new_request) == prepared
    metadata = prepared["metadata"]
    assert isinstance(metadata, dict)
    assert metadata["enabled"] is False
    new_host_id = str(metadata["host_id"])
    envelope = prepared["envelope"]
    assert isinstance(envelope, dict)
    assert envelope["host_id"] == new_host_id
    assert envelope["credential_id"] == metadata["credential_id"]

    # The retired host's name is never recycled, even by a fresh machine.
    recycled = dict(new_request, name="l1", machine_id="sha256:" + uuid.uuid4().hex * 2)
    bridge_refusal(str(uuid.uuid4()), "prepare-enrollment", recycled)
    assert sql("SELECT count(*) FROM compute_hosts WHERE name='l1'") == "1"

    # Admission before any authority observation refuses at the database.
    refused = operator(m1, dict(action="enable-once", host_id=new_host_id, enabled=True))
    assert refused["refused"] is True and refused["reason"] == "host_not_ready"
    assert sql(f"SELECT enabled FROM compute_hosts WHERE id='{new_host_id}'") == "f"

    # Deliver the private envelope only through the sealed secret bundle.
    envelope_path = f"{root}/credential.json"
    for_content = json.dumps(envelope)
    new_host.succeed(
        "printf %s "
        + shlex.quote(for_content)
        + " > "
        + shlex.quote(envelope_path)
        + " && chmod 0600 "
        + shlex.quote(envelope_path)
    )
    private_meta = json.dumps({"host_id": new_host_id, "pools": prepared["metadata"]["pools"]})
    new_host.succeed("install -d -m 755 /run/lilly-release")
    new_host.succeed(
        "printf %s "
        + shlex.quote(private_meta)
        + " > /run/enrollment-metadata.json"
        + " && printf %s "
        + shlex.quote(new_host_id)
        + " > /run/lilly-release-host-id"
    )
    install_replacement_credentials()
    new_host.wait_for_unit("lilly.service")
    eventually(lambda: new_host_report_ready(new_host_id), timeout=300)


with subtest("rotation+retry then readiness-gated enable, then service restored"):
    rotate_operation = str(uuid.uuid4())
    rotated = bridge_call(rotate_operation, "rotate-credential", new_request)
    assert bridge_call(rotate_operation, "rotate-credential", new_request) == rotated
    rotated_metadata = rotated["metadata"]
    assert isinstance(rotated_metadata, dict)
    assert rotated_metadata["credential_id"] != metadata["credential_id"]

    # Rotation fatally ages the old session until a fresh report establishes
    # readiness again; deliver the new envelope and re-enable.
    new_host.succeed(
        "printf %s "
        + shlex.quote(json.dumps(rotated["envelope"]))
        + " > "
        + shlex.quote(root + "/credential.json")
        + " && chmod 0600 "
        + shlex.quote(root + "/credential.json")
    )
    install_replacement_credentials()
    new_host.wait_for_unit("lilly.service")
    eventually(lambda: new_host_report_ready(new_host_id), timeout=300)

    enabled = operator(m1, dict(action="enable", host_id=new_host_id, enabled=True))
    assert enabled["enabled"] is True
    assert sql(f"SELECT enabled FROM compute_hosts WHERE id='{new_host_id}'") == "t"

with subtest("a fresh guest on the replacement reaches llm.internal again"):
    # With the replacement admitted, issue its dedicated service credentials.
    m1.succeed(
        "fleet-op ziggy-rotate " + shlex.quote(new_host_id) + " 14400 " + root + "/l2-ziggy.token"
    )
    transfer(m1, root + "/l2-ziggy.token", new_host, root + "/ziggy.token")
    galileo_issue = operator(
        m1, dict(action="galileo-enroll", host_id=new_host_id, output=root + "/galileo-l2.token")
    )
    assert galileo_issue["issued"] is True
    transfer(m1, root + "/galileo-l2.token", new_host, root + "/galileo.token")
    install_replacement_service_credentials()
    new_host.wait_for_unit("ziggy.service")
    new_host.wait_for_unit("galileo.service")
    new_host.wait_until_succeeds(
        "curl --fail --silent --unix-socket /run/ziggy/proxy.sock http://localhost/health/ready "
        "| jq -e --arg host "
        + shlex.quote(new_host_id)
        + " '(.version == 1) and (.ready == true) and (.role == \"ziggy\") and (.host_id == $host)'",
        timeout=120,
    )
    print("replacement scenario stage: replacement enrolled and reporting")

    restored = provision_when_available(m1, "standard")
    assert restored["host_id"] == new_host_id
    await_running(restored["vm_id"])
    try:
        new_host.wait_until_succeeds(
            "fleet-galileo-guest llm-dns " + shlex.quote(restored["placement_id"]), timeout=480
        )
        new_host.wait_until_succeeds(
            "fleet-galileo-guest llm-health " + shlex.quote(restored["placement_id"]), timeout=480
        )
    except Exception:
        private_chain_diag(new_host, new_host_id)
        raise

    # The retired host's credentials stay buried after recovery too.
    got_open = probe("open", str(session["session"]), int(session["epoch"]), retired_credential)
    assert got_open == "open:error_unauthorized", f"stale open refusal class: {got_open}"
    ziggy_identity = ziggy_call("identity", dict(version=1), ziggy_token)
    assert ziggy_identity == "refused", f"stale ziggy refusal class: {ziggy_identity}"

    removed = operator(
        m1,
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=restored["vm_id"],
            kind="delete",
            key=str(uuid.uuid4()),
        ),
    )
    assert removed["requested"] is True
    eventually(lambda: vm_state(restored["vm_id"]) == "deleted", timeout=480)
    print("replacement scenario stage: guest service reachability restored")
