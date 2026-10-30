# @cc [owner:ghuntley,label:verification] inception-native-stack-scope
# This fixture MUST boot the source-built Inception image through actual Lilly
# and Firecracker. Console bytes and credential contents MUST remain withheld.
# Driver-only creation MUST NOT establish outer Marshall profile admission.
import json
import os
import shlex
import tempfile
from pathlib import Path


# @cc [owner:ghuntley,label:verification] inception-native-state-capacity
# The native fixture MUST refuse a VM state filesystem with less than 64 GiB
# free before starting machines, so fixture disk exhaustion cannot masquerade
# as an Inception or PostgreSQL runtime failure.
def require_vm_state_space() -> None:
    directory = Path(os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir()))
    filesystem = os.statvfs(directory)
    assert filesystem.f_bavail * filesystem.f_frsize >= 64 * 1024**3, (
        "Inception test VM state requires at least 64 GiB free"
    )


# @cc [owner:ghuntley,label:verification;recovery] inception-native-command-deadline
# Fixture probe deadlines MUST escalate to SIGKILL before the test driver's
# outer timeout. A process ignoring SIGTERM MUST NOT hold the result pipe open
# indefinitely. Commands and their existing acceptance assertions remain intact.
def bounded_succeed(*commands: str, timeout: int) -> None:
    try:
        outer.succeed(
            *(
                f"timeout --kill-after=10s {timeout - 15}s bash -c {shlex.quote(command)}"
                for command in commands
            ),
            timeout=timeout,
        )
    except Exception:
        # A timed-out probe's stdout is lost with the command. Report only its
        # last fixed phase label; never replay the journal's arbitrary bytes.
        status, phase = outer.execute(
            "awk '/^[a-z0-9 -]+ at [0-9]+$/ { value=$0 } "
            'END { if (value == "") exit 1; print value }\' '
            "/run/inception-test/probe-steps.log"
        )
        print(f"inception probe last phase (status {status}): {phase}")
        raise


require_vm_state_space()
internet.start()
internet.wait_for_unit("public-fixture.service")
internet.wait_for_unit("inception-fixture-issuer.service")
internet.wait_for_unit("inception-provider-fixture.service")
internet.wait_until_succeeds(
    "curl --fail --silent --cacert /var/lib/inception-fixture-issuer/ca.crt https://localhost:9444/roots/0 > /var/lib/inception-fixture-issuer/root.pem"
)
internet.wait_until_succeeds("dig @11.0.0.2 github.com A +short | grep -q .")
internet.wait_until_succeeds(
    "GIT_SSL_CAINFO=/var/lib/inception-fixture-issuer/ca.crt "
    "git ls-remote https://github.com/ghuntley/overalls >/dev/null"
)
outer.start()
# The fixture's public egress must use the isolated provider router.  This
# catches a DHCP default-route preference that would make the nested guest's
# resolver appear configured while silently bypassing the DNS/GitHub path.
outer.wait_until_succeeds("ip route get 1.1.1.1 | grep -q 'via 11.0.0.2 dev eth1'", timeout=120)
# Schema migration remains an explicit driver action.
outer.wait_for_unit("postgresql.service")
transfer(
    internet,
    "/var/lib/inception-fixture-issuer/ca.crt",
    outer,
    "/run/inception-public-issuer-ca.pem",
)
transfer(
    internet, "/var/lib/inception-fixture-issuer/root.pem", outer, "/run/inception-public-roots.pem"
)
outer.succeed(
    "python3 -c "
    + shlex.quote("""
import json, os
from pathlib import Path
os.umask(0o077)
value = json.loads(Path('/etc/inception-public-settings.json').read_bytes())
value['issuer_ca_pem'] = Path('/run/inception-public-issuer-ca.pem').read_text()
value['trust_pem'] = Path('/run/inception-public-roots.pem').read_text()
Path('/run/inception-public-settings.json').write_text(json.dumps(value))
""")
)
outer.succeed("systemctl start overalls-test-migrate.service")
outer.wait_for_unit("multi-user.target")
# The inner slice must admit ADR-0054's minimum 32 GiB/16-vCPU VM shape;
# systemd rejects a transient child MemoryMax above its parent before jailer
# can start, so check the effective cap before exercising lifecycle dispatch.
outer.succeed(
    "test -c /dev/kvm",
    "systemctl is-active lilly.slice",
    "test $(systemctl show lilly.slice -p MemoryMax --value) -ge 34359738368",
    # The outer fixture allocates 32 vCPUs to its nested Lilly slice while
    # ADR-0054 only requires 16.  Check the effective seconds-per-second
    # quota as a minimum so the assertion follows the profile contract rather
    # than this fixture's larger host allocation.
    "quota=$(systemctl show -p CPUQuotaPerSecUSec --value lilly.slice); "
    'case "$quota" in *us) test "${quota%us}" -ge 16000000 ;; *s) test "${quota%s}" -ge 16 ;; *) exit 1 ;; esac',
)
outer.wait_for_unit("lilly-hostd.service")
outer.succeed("test -S /run/lilly-hostd/control.sock")
outer.succeed(
    "systemctl is-active lilly-inception-preflight.service",
    "test -s /run/lilly-inception/proof.json",
)
outer.succeed("zpool create -O compression=lz4 -O mountpoint=/tank tank /dev/vdb")
outer.succeed("zfs create -o mountpoint=/pool -o quota=800G tank/lilly")
outer.succeed("zfs create -o mountpoint=/direct-pool -o quota=400G tank/direct-lilly")

with subtest("eligibility requires the current boot image probe and Firecracker receipt"):
    # Keep a bounded, category-only phase receipt running while the probe is
    # active. The outer test VM is isolated in the NixOS driver namespace, so
    # this is the only way to distinguish a slow BEAM start from a blocked
    # proof check without exposing journal or credential contents.
    outer.succeed(
        "systemd-run --unit=inception-reject-phase --collect /bin/sh -c "
        + shlex.quote(
            """
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  phase=none
  for label in \
    'fixture entered' 'pool inspected' 'pool built' 'image loaded' \
    'config prepared' 'reject-proof branch entered' 'loop exited'; do
    if grep -q "^${label} at [0-9][0-9]*$" /run/inception-test/probe-steps.log 2>/dev/null; then
      phase=${label}
    fi
  done
  printf 'inception reject phase=%s\\n' "$phase"
  /run/current-system/sw/bin/sleep 30
done
"""
        )
    )
    bounded_succeed("inception-probe reject-proof", timeout=1800)

with subtest("an ordinary user creates Inception through real outer Marshall and Lilly"):
    outer.wait_for_unit("marshall-outer.service")
    bounded_succeed(
        "inception-probe outer-request",
        "systemctl start inception-outer@enroll.service",
        # Outer admission may need to wait for a fresh post-enrollment Lilly
        # capacity sample; keep the driver deadline beyond that bounded retry.
        timeout=1200,
    )
    outer.succeed("systemctl start inception-outer@enroll-dns.service")
    for machine, address in [(ns1, "11.0.0.3"), (ns2, "11.0.0.4")]:
        machine.start()
        machine.succeed("install -d -m 0700 /run/inception-dns")
        transfer(
            outer,
            "/run/inception-outer/" + machine.name + ".token",
            machine,
            "/run/inception-dns/dns.token",
        )
        transfer(outer, "/run/overalls-test/ca.crt", machine, "/run/inception-dns/control-ca.pem")
        machine.succeed("chmod 0600 /run/inception-dns/*; systemctl start audi-dns.service")
        machine.wait_for_open_port(53, addr=address)
        machine.wait_until_succeeds(
            "python3 /etc/public-dns-probe.py /etc/public-dns-probe.json " + address
        )
        machine.wait_until_succeeds(
            "python3 -c "
            + shlex.quote("""
import json, socket
with socket.socket(socket.AF_UNIX) as peer:
    peer.settimeout(2)
    peer.connect('/run/audi-dns/status.sock')
    with peer.makefile('rb') as stream:
        value = json.loads(stream.readline(4097))
    assert value == {'version': 1, 'role': 'dns', 'ready': True}
""")
        )
    outer.succeed(
        'install -d -m 0700 /run/inception-test; umask 077; printf \'%s\' \'{"version":1,"host":"smtp.example.test","port":587,"username":"fixture","password":"outer-synthetic","from":"dev@example.test","tls":"starttls"}\' > /run/inception-test/smtp.json'
    )
    # The production Lilly service is disabled in this fixture, so the
    # manually launched root Lilly uses a private hostd.  Give its connector
    # the same root-owned parent that hostd accepts while retaining Audi's
    # group access to the socket.
    outer.succeed("chown root:audi /run/lilly-ingress; chmod 2750 /run/lilly-ingress")
    outer.succeed("systemctl start inception-outer-lilly.service")
    # This fixture keeps the enrolled Lilly release root-launched so its
    # private credential file remains root-only.  Hand the resulting connector
    # socket to Audi explicitly after Lilly binds it.
    outer.wait_until_succeeds(
        "test -S /run/lilly-ingress/audi.sock && chown root:audi /run/lilly-ingress/audi.sock"
    )
    outer.succeed("systemctl start inception-outer@enroll-gateway.service")
    # systemd resolves every LoadCredential source before executing Audi. Keep
    # the fixture failure local and actionable if a bootstrap phase omitted a
    # source; report only type, mode and size, never credential bytes.
    outer.succeed(
        "for path in /run/inception-outer/audi.token /run/inception-outer/audi.json "
        "/run/overalls-test/ca.crt /run/inception-public-roots.pem; do "
        'test -f "$path"; stat -c \'%n %a %s\' "$path"; namei -l "$path"; done'
    )
    outer.succeed(
        "systemctl show audi.service -p User -p LoadCredential; "
        "for spec in "
        "gateway.token:/run/inception-outer/audi.token "
        "ca.pem:/run/overalls-test/ca.crt "
        "certificate-roots.pem:/run/inception-public-roots.pem "
        "runtime.json:/run/inception-outer/audi.json; do "
        "systemd-run --quiet --wait --pipe --collect "
        '--property=LoadCredential="$spec" true; done'
    )
    outer.succeed("systemctl start audi.service")
    outer.wait_for_open_port(22, addr="11.0.0.5")
    outer.wait_for_open_port(443, addr="11.0.0.5")
    # The nested Lilly host performs its first Firecracker/network readiness
    # reconciliation only after Audi has completed its credentialed startup.
    # Keep this bounded, but allow a cold 36-vCPU fixture enough time to report
    # host readiness before treating enrollment as failed.
    outer.wait_until_succeeds("systemctl start inception-outer@enable.service", timeout=900)
    # The cache-only rebuild can consume much of the nested VM's boot window.
    # Sample near the image build bound while retaining margin before Lilly's forty-minute
    # production readiness deadline stops an unsuccessful guest.
    outer.succeed(
        # The nested image must report a fixed boot classification before the
        # outer readiness deadline. A cold image can fail during the first few
        # minutes, so schedule this before create's usual failure window while
        # keeping the diagnostic command's own bounded console probes.
        "systemd-run --unit=inception-core-diagnostics --on-active=3min "
        "--property=TimeoutStartSec=180 "
        "/run/current-system/sw/bin/inception-probe diagnose-core 1 1"
    )
    # The host diagnostic is installed immediately before create below. The
    # nested image probe cannot inspect a host-side jailer failure when
    # Firecracker dies before a vsock appears; a timer installed here would
    # fire before the large root image copy and miss the transient VM unit.
    host_diagnostic = """
units=$$(/run/current-system/sw/bin/systemctl list-units --type=service --all --plain --no-legend | while read -r unit rest; do
  case "$$unit" in lilly-vm-*.service) printf '%s\\n' "$$unit";; esac
done)
if test -z "$$units"; then
  echo 'Host VM unit absent'
fi
for unit in $$units; do
  state=$$(/run/current-system/sw/bin/systemctl show "$$unit" -p ActiveState --value)
  substate=$$(/run/current-system/sw/bin/systemctl show "$$unit" -p SubState --value)
  status=$$(/run/current-system/sw/bin/systemctl show "$$unit" -p ExecMainStatus --value)
  printf 'Host VM state=%s substate=%s status=%s\\n' "$$state" "$$substate" "$$status"
  for category in 'No such file' 'Permission denied' failed KVM kvm modprobe memory; do
    if /run/current-system/sw/bin/journalctl -u "$$unit" --no-pager -o cat | /run/current-system/sw/bin/grep -qiF "$$category"; then
      printf 'Host VM journal category=%s\\n' "$$category"
    fi
  done
done
for log in /var/lib/lilly/vms/*/boot.log; do
  if test -f "$$log"; then
    printf 'Host boot log bytes=%s\\n' "$$(/run/current-system/sw/bin/stat -c %s "$$log")"
    if test -s "$$log"; then
      echo 'Host boot log nonempty'
    fi
    # The boot log is deliberately reduced to fixed diagnostic categories. It
    # must never replay arbitrary serial bytes, while still distinguishing an
    # initrd/root failure, a service failure, and a guest that reached the
    # bounded boot report before its vsock readiness endpoint appeared.
    for category in \
      'Kernel panic' 'VFS:' 'No such file' 'Permission denied' \
      'lilly-guest boot complete' 'lilly-boot-report: end' 'NixOS' \
      'Failed' 'Emergency' 'Switch Root' 'Find NixOS closure' \
      'lilly-readiness' 'lilly-network' 'overalls-guest-trust' \
      'inception-identity' 'inception-credentials' 'inception-image' \
      'inception-storage' 'postgresql-setup' 'inception-database' \
      'inception-environment' 'inception-migrate' 'inception-enrollment' \
      'inception-source' 'kvm' 'modprobe'; do
      if /run/current-system/sw/bin/grep -aqiF "$$category" "$$log"; then
        printf 'Host boot log category=%s\\n' "$$category"
      fi
    done
    # boot_report.py emits fixed unit timeline lines. Preserve only the unit
    # name and its bounded activation classification; this distinguishes an
    # inactive prerequisite from a guest that reached the report without
    # replaying serial output or journal payloads.
    for unit in \
      overalls-guest-trust lilly-network lilly-readiness inception-identity \
      inception-credentials inception-image inception-storage postgresql-setup \
      inception-database inception-environment inception-migrate inception-enrollment \
      inception-source inception-enable lilly \
      marshall-inception postgresql; do
      if /run/current-system/sw/bin/grep -aqiE \
        "lilly-boot-report: unit $${unit}\\.service .* active=-" "$$log"; then
        printf 'Host boot log report=unit-%s-inactive\\n' "$$unit"
      elif /run/current-system/sw/bin/grep -aqiE \
        "lilly-boot-report: unit $${unit}\\.service .* active=[0-9]" "$$log"; then
        printf 'Host boot log report=unit-%s-active\\n' "$$unit"
      elif /run/current-system/sw/bin/grep -aqiF "lilly-boot-report: unit $${unit}.service" "$$log"; then
        printf 'Host boot log report=unit-%s-unclassified\\n' "$$unit"
      fi
    done
    for unit in \
      overalls-guest-trust lilly-network lilly-readiness inception-identity \
      inception-credentials inception-image inception-storage postgresql-setup \
      inception-database inception-environment inception-migrate inception-enrollment \
      inception-source inception-enable lilly \
      marshall-inception postgresql; do
      for state in active inactive failed activating unknown; do
        if /run/current-system/sw/bin/grep -aqF \
          "lilly-boot-report: status unit=$${unit}.service active=$${state}" "$$log"; then
          printf 'Host boot log status=unit-%s-%s\\n' "$$unit" "$$state"
        fi
      done
    done
    if /run/current-system/sw/bin/grep -aqF \
      'lilly-boot-report: status unit=multi-user.target active=active' "$$log"; then
      printf 'Host boot log status=unit-multi-user-target-active\\n'
    elif /run/current-system/sw/bin/grep -aqF \
      'lilly-boot-report: status unit=multi-user.target active=activating' "$$log"; then
      printf 'Host boot log status=unit-multi-user-target-activating\\n'
    fi
    for category in 'Bootup is not yet finished' 'critical-chain unavailable' \
      'Inception image rebuild failed:' 'trust-rejected' 'missing-path' \
      'capacity' 'permission' 'feature' 'daemon' 'evaluation-assertion' \
      'evaluation-path' 'evaluation-symbol' 'evaluation-type' \
      'evaluation-recursion' 'evaluation-other' 'builder'; do
      if /run/current-system/sw/bin/grep -aqiF "$$category" "$$log"; then
        printf 'Host boot log report=%s\\n' "$$category"
      fi
    done
    for category in multi_user_inactive lilly_network_inactive required_unit_inactive \
      ssh_unit_inactive address_missing gateway_route_missing default_route_missing \
      root_write_failed probe_error peer_rejected; do
      if /run/current-system/sw/bin/grep -aqF \
        "lilly-boot-report: readiness-failure=$$category" "$$log"; then
        printf 'Host boot log readiness-failure=%s\\n' "$$category"
      fi
    done
  fi
done
printf 'Host Firecracker log files=%s\\n' "$$(/run/current-system/sw/bin/find /run/overalls-firecracker -type f -size +0c 2>/dev/null | /run/current-system/sw/bin/wc -l)"
for kind in v.sock api.sock firecracker.json; do
  count=$$(/run/current-system/sw/bin/find /pool/.lilly-jails /var/lib/lilly/vms -type s -name "$$kind" 2>/dev/null | /run/current-system/sw/bin/wc -l)
  if test "$$kind" = firecracker.json; then
    count=$$(/run/current-system/sw/bin/find /pool/.lilly-jails /var/lib/lilly/vms -type f -name "$$kind" 2>/dev/null | /run/current-system/sw/bin/wc -l)
  fi
  printf 'Host jail artifact=%s count=%s\\n' "$$kind" "$$count"
done
for socket in $(/run/current-system/sw/bin/find /pool/.lilly-jails /var/lib/lilly/vms -type s -name v.sock 2>/dev/null); do
  if test -S "$$socket"; then
    /run/current-system/sw/bin/timeout --kill-after=2s 5s /run/current-system/sw/bin/python3 -c '
import socket
import sys

peer = socket.socket(socket.AF_UNIX)
peer.settimeout(2)
try:
    peer.connect(sys.argv[1])
    peer.sendall(b"CONNECT 1024\\n")
    handshake = peer.recv(64)
    if not handshake.startswith(b"OK "):
        print("readiness-proxy=handshake_invalid")
    else:
        body = peer.recv(512)
        print("readiness-proxy=response" if body.endswith(b"\\n") else "readiness-proxy=body_incomplete")
except TimeoutError:
    print("readiness-proxy=timeout")
except OSError:
    print("readiness-proxy=error")
finally:
    peer.close()
' "$$socket" || printf 'readiness-proxy=command_timeout\\n'
  fi
done
"""
    try:
        # Keep host evidence bounded and category-only: no unit command lines,
        # journal text, paths or guest bytes leave the VM. Starting this timer
        # with create means it observes the actual transient VM unit even when
        # jailer or Firecracker fails before a vsock appears.
        outer.succeed(
            # The outer image copy and launch take about twenty minutes on the
            # native fixture. Sample shortly after launch so a transient VMM
            # failure leaves boot evidence before lifecycle cleanup removes it.
            "/run/current-system/sw/bin/systemd-run --unit=inception-host-diagnostics --on-active=300s "
            "--property=TimeoutStartSec=180 /bin/sh -c " + shlex.quote(host_diagnostic)
        )
        outer.succeed("systemctl start inception-outer@create.service", timeout=2700)
        # Admission must retain the Inception profile's documented default
        # shape in the durable command snapshot: 16 vCPUs, 32 GiB memory and
        # a 64 GiB root. This catches a UI/request default drifting below the
        # profile contract even when the nested guest happens to boot.
        outer.succeed(
            "jq -e "
            + shlex.quote(
                ".vcpu == 16 and .memory_bytes == 34359738368 and .disk_bytes == 68719476736"
            )
            + " /run/inception-outer/command.json"
        )
    except Exception:
        # The diagnostic command emits only the fixed predicates documented in
        # probe.exs. Replay those bounded results at the assertion site; the
        # complete guest journal and terminal bytes remain withheld.
        status, diagnostics = outer.execute(
            "journalctl -u inception-core-diagnostics.service --no-pager -o cat"
        )
        print(f"inception core diagnostics (status {status}):\n{diagnostics}")
        status, diagnostics = outer.execute(
            "journalctl -u inception-host-diagnostics.service --no-pager -o cat"
        )
        print(f"inception host diagnostics (status {status}):\n{diagnostics}")
        raise
    bounded_succeed("inception-probe verify 1 1", timeout=960)
    outer.succeed("systemctl start inception-outer@create-two.service", timeout=2700)
    bounded_succeed("inception-probe verify 1 1 2", timeout=900)

with subtest("inner control obtains a real DNS-01 certificate through both parent replicas"):
    first = json.loads(outer.succeed("cat /run/inception-outer/origins.json"))
    second = json.loads(outer.succeed("cat /run/inception-outer/two-origins.json"))
    assert first["namespace"] != second["namespace"]
    try:
        for origins in [first, second]:
            control_hostname = origins["control"]
            assert all(
                part and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in part)
                for part in control_hostname.split(".")
            )
            for server in ["11.0.0.3", "11.0.0.4"]:
                for transport in ["", "+tcp"]:
                    command = (
                        "dig @"
                        + server
                        + " "
                        + shlex.quote(control_hostname)
                        + " A +short "
                        + transport
                    )
                    # Parent DNS observation and Pebble's bounded ACME polling
                    # can each consume several minutes under native pool load.
                    # The issuer job has a single fifteen-minute authority
                    # window; keep this probe inside that same bound so a
                    # valid certificate is not declared absent while Lego is
                    # completing its final certificate fetch.
                    internet.wait_until_succeeds(
                        'test "$(' + command + ')" = 11.0.0.5', timeout=900
                    )
            internet.wait_until_succeeds(
                "curl --fail --silent --show-error --max-time 5 --cacert /var/lib/inception-fixture-issuer/root.pem "
                + "--resolve "
                + shlex.quote(control_hostname + ":443:11.0.0.5")
                + " "
                + shlex.quote("https://" + control_hostname + "/health/ready")
                + " >/dev/null",
                timeout=900,
            )
    except Exception:
        for instance in [1, 2]:
            try:
                status, diagnostics = outer.execute(
                    "timeout --kill-after=10s 285s bash -c "
                    + shlex.quote(f"inception-probe diagnose-public 1 1 {instance}")
                )
                print(f"Public diagnostics instance {instance} (status {status}):\n{diagnostics}")
            except Exception:
                print(f"Public diagnostics unavailable for fixture instance {instance}")
        raise

with subtest("neither inner public listener accepts fleet APIs or forwarding-header bypasses"):
    for origins in [first, second]:
        internet.succeed(
            "python3 /etc/inception-public-boundary.py "
            + shlex.quote(origins["control"])
            + " 11.0.0.5 /var/lib/inception-fixture-issuer/root.pem",
            timeout=120,
        )

with subtest("two public browsers authenticate independently and establish inner WebSockets"):
    internet.succeed("install -d -m 0700 /run/inception-browser")
    for instance, filename in [(1, "first"), (2, "second")]:
        bounded_succeed(f"inception-probe browser-token 1 1 {instance}", timeout=300)
        transfer(
            outer,
            f"/run/inception-test/browser-{instance}.json",
            internet,
            f"/run/inception-browser/{filename}.json",
        )
    internet.succeed(
        "python3 /etc/inception-browser.py "
        + shlex.quote(first["control"])
        + " "
        + shlex.quote(second["control"]),
        timeout=180,
    )

with subtest("each environment starts private services with independent provider credentials"):
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe private-services 1 1 {instance}", timeout=900)

with subtest("both independent inner control planes manage real nested guests"):
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe inner-create 1 1 {instance}", timeout=900)
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe wildcard 1 1 {instance}", timeout=660)
    for action, limit in [("stop", 600), ("start", 900), ("delete", 600)]:
        for instance in [1, 2]:
            bounded_succeed(f"inception-probe inner-{action} 1 1 {instance}", timeout=limit)

with subtest("deleting one environment preserves its sibling before paired cleanup"):
    outer.succeed("systemctl start inception-outer@delete.service", timeout=240)
    bounded_succeed("inception-probe deleted 1 1", timeout=600)
    bounded_succeed("inception-probe verify 1 1 2", timeout=900)
    outer.succeed("systemctl start inception-outer@delete-two.service", timeout=240)
    bounded_succeed("inception-probe deleted 1 1 2", timeout=600)
    outer.succeed("systemctl stop inception-outer-lilly.service")
    bounded_succeed("inception-probe network-restore", timeout=600)

with subtest("Inception boots an enrolled PostgreSQL Marshall Lilly stack"):
    bounded_succeed("inception-probe start", timeout=2700)
    bounded_succeed("inception-probe verify", timeout=900)
    bounded_succeed("inception-probe storage-refusal", timeout=600)

with subtest("restart preserves storage identity credentials and developer edits"):
    bounded_succeed("inception-probe remember", "inception-probe rotate", timeout=600)
    bounded_succeed("inception-probe stop 2", timeout=600)
    bounded_succeed("inception-probe start 3", timeout=2700)
    bounded_succeed("inception-probe retained 3", timeout=600)

with subtest("deletion reclaims both owned disks"):
    bounded_succeed("inception-probe delete 4", timeout=600)
    outer.fail("test -e /direct-pool/vms/dddddddd-dddd-4ddd-8ddd-000000000140/rootfs.ext4")
    outer.fail("test -e /direct-pool/vms/dddddddd-dddd-4ddd-8ddd-000000000140/data.raw")
