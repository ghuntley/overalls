# Nix checks

`telemetry-diagnostics` checks fixed diagnostic Prometheus rules and generated
missing/stale/warming/gap/idle/history cases. `public-grafana-configuration`
checks ninety-day defaults and generated retention settings. `underclass-slo`
exercises additive histogram migration, a real twelve-second provider response,
unknown interruption duration and independent exporter custody. These fixtures
do not establish ninety days of production observation.

`default-oss-creation` uses the real nine-node Audi-enabled fleet with a separately typed
driver. It covers ordinary browser and native Porsche creation without selecting
a profile, persisted OSS identity, request replay/conflict, explicit Customer
creation and sharing/foreign-read/agent-registration refusals, plus actual
Firecracker DNS/HTTP egress to a live local fixture and Customer timeouts.
The same journey drives the Customer owner through real Porsche CLI
stop/start/delete with receipt replay, real guest process death and recreation
around the retained ZFS identity, member/stranger CLI and browser member-page
refusals with unchanged intent inventories — including after fixture promotion
of the member to administrator — and an egress denial re-probe after the real
CLI restart.
See the [execution review](../../../docs/architecture/reviews/2026-09-25-default-oss-verification.md)
for earlier results and scope; the Customer lifecycle extension is recorded by
the [customer controls review](../../../docs/architecture/reviews/2026-09-26-customer-controls.md);
broader isolation and guest SSH remain separate checks.

`default.nix` explicitly exports the checks. It receives separate
application-build and NixOS-test package sets from the flake. Adding a file does
not automatically export or execute a check. The root flake also explicitly adds
the compact-Nix and terminal-daemon checks.

## Standalone browser typing

The Teams and Control room checks execute their `checkedBrowser`
artifacts. The default OSS fleet command executes `defaultOssBrowser`; the fleet
client executes the typed Audi and Porsche browser artifacts; Inception deploys
its checked browser artifact to the guest. Each artifact copies the actual helper
and passes pinned `ty` against the same Python and Playwright used at runtime.
Composed-driver typing cannot check these separate processes, and ordinary
repository type discovery excludes machine helpers.

Build these artifacts without booting machines. They are attributes of the
checks, not Buck2 targets, so they come from lib.assemble directly (see
[Run checks](#run-checks)):

```sh
for a in '"teams-browser".checkedBrowser' '"control-room-browser".checkedBrowser' \
  '"credential-self-service-browser".checkedBrowser' '"default-oss-creation".defaultOssBrowser' \
  'inception.checkedBrowser' '"audi-fleet".audiBrowser' '"porsche-fleet".porscheBrowser'; do
  nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks.'"$a" --no-link
done
```

The [gate review](../../../docs/architecture/reviews/2026-09-25-browser-type-gates.md)
records actual checker execution and its scope; the
[sweep review](../../../docs/architecture/reviews/2026-09-26-browser-typing-sweep.md)
records the Audi/Porsche/Inception artifacts and the closed fleet exclusion.
Existing MFA, resize and account-lifecycle helpers have separate artifact gates.
Installer trust has no standalone browser helper; its composed driver keeps
framework typing. Every fleet variant's composed driver passes the framework's
ty type check and ruff lint; no explicit typing exclusion remains. A type-check
pass adds no native runtime acceptance.

## Hegel property-based testing

Machine checks can opt into property-based testing through `hegel.runTest` in
[../hegel/](../hegel/README.md), which composes `pkgs.testers.runNixOSTest` with
Hegel's native engine: value-level properties (`@given`) draw inputs, and
`MachineStateMachine` rules explore restart/reboot/crash interleavings with
invariants checked at engine-chosen join points. Failures shrink to a minimal
counterexample and fail the check; the
[user guide](../../../docs/development/testing-with-hegel.md) has a worked example and the
[framework README](../hegel/README.md) lists the `properties` options
(`profile`, `testCases`, `statefulStepCount`, `redact`, replay blobs).

The catalog exports `hegel-framework-packages` as a direct build check. It
executes the binding's shrink, replay, mismatch, state-machine and concurrency
smoke suite before any machine-specific evidence is considered. The remaining
Hypothesis references are confined to evaluation `runCommand` checks or helper
programs that run inside a guest namespace (backup cleanup and auto-update
history fixtures); they are not composed NixOS driver properties and therefore
are not mislabeled as Hegel machine evidence.

A check declares `properties` beside its ordinary `testScript` assertions:

```nix
{ pkgs, module, hegel, ... }:
hegel.runTest {
  name = "overalls-myservice";
  properties = { enable = true; profile = "ci"; testCases = 10; statefulStepCount = 30; };
  nodes.machine = { ... };
  testScript = '' ... @given / MachineStateMachine properties ... '';
}
```

Catalog registration stays explicit: extend the check's argument set in
`default.nix` with `hegel`, e.g.
`myservice = import ./machines/myservice (service // { inherit hegel; })`
(matches must supply exactly the suite's lambda arguments; several take no
`module`). `underclass-service`, `secret-custody`, `zfs-transfer` and
`agent-cli` are the original migrated examples; bounded telemetry, recorder,
fleet-recovery and actor-recovery histories are migrated in the accompanying
Hegel coverage review. Omitting `properties`
(or `enable = false`) composes to the plain upstream test unchanged. The Python
binding's own smoke properties run in its package `checkPhase`, not as a
separate flake check.

Hegel is the property engine for NixOS verification. New or migrated machine
properties MUST use Hegel generators and state machines; Hypothesis imports and
dependencies are not permitted in composed machine drivers. Fixed browser,
firmware, installation, image, exact-configuration and other one-shot checks
remain imperative because their evidence depends on a specific acceptance
journey rather than generated replayable operations. A suite is not labelled
property-covered merely because a decorator exists: the Hegel run and its
counterexample/replay or concurrent schedule evidence must be recorded.

## Find a test

Every machine test and assembled check, from the Buck2 graph. Run one with
`tools/buck2 test <target>`; machine tests that need nested KVM carry the
`nested_kvm` label. Edit the location and behaviour in
[`find_a_test.bzl`](find_a_test.bzl), then run `tools/docs`; a test without
an entry shows `—`.

<!-- BEGIN generated by tools/docs from buck/bxl/docs.bxl:find_a_test; edit find_a_test.bzl -->
| Test | Buck2 target | Location | Verified behavior |
| --- | --- | --- | --- |
| `access` | `//nix/verification/tests/machines/access:access` | `machines/access/` | Real named SSH/sudo and Mosh terminal input on two hosts, user lingering, centralized keys and activation revocation. |
| `access-configuration` | `//:check-access-configuration` | `evaluation/access.nix` | Typed fleet users, groups, admin policy, Mosh firewall, lingering and independent host-key generation. |
| `account-lifecycle` | `//nix/verification/tests/machines/fleet:account-lifecycle` | `machines/fleet/` | — |
| `account-lifecycle-ubuntu` | `//nix/verification/tests/machines/fleet:account-lifecycle-ubuntu` | `machines/fleet/` | — |
| `acme-http01` | `//nix/verification/tests/machines/acme-http01:acme-http01` | `machines/acme-http01/` | Three actual frontends and a separate Pebble/DNS validator, peer forwarding, concurrent renewal, HTTP redirects and failures. |
| `acme-lookup` | `//:check-acme-lookup` | `evaluation/acme-lookup.nix` | Actual lookup helper with local HTTP responders: all nine owner/ingress combinations, bounds, cancellation and credential isolation. |
| `acme-route53` | `//nix/verification/tests/machines/acme-route53:acme-route53` | `machines/acme-route53/` | Real ACME client with local DNS/Route 53/CA fixtures, TLS publication, renewal and failure recovery. |
| `admin-account-browser` | `//nix/verification/tests/machines/admin-account:admin-account-browser` | `machines/admin-account/` | — |
| `administrative-ssh` | `//nix/verification/tests/machines/administrative-ssh:administrative-ssh` | `machines/administrative-ssh/` | Pinned administrative SSH and Nix store transport on selected ports, including staged handoff of port 22 to Porsche with administrative identity retained. |
| `agent-cli` | `//nix/verification/tests/machines/agent-cli:agent-cli` | `machines/agent-cli/` | — |
| `agent-cli-journey` | `//nix/verification/tests/machines/fleet:agent-cli-journey` | `machines/agent-cli-journey/` | Strictly typed ordinary-browser explicit approval, packaged CLI, real stopped NixOS guest wake/model/tool result, profile refusal and stale approval after UI sharing withdrawal. Execution and isolated-provider limits are recorded in the [CLI review](../../../docs/architecture/reviews/2026-09-25-agent-cli-verification.md). |
| `agent-fleet` | `//nix/verification/tests/machines/fleet:agent-fleet` | `machines/fleet/` | — |
| `agent-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:agent-ubuntu-fleet` | `machines/fleet/` | — |
| `android-emulator-software` | `//nix/verification/tests/machines/android-emulator:android-emulator-software` | `machines/android-emulator/` | — |
| `android-firecracker` | `//nix/verification/tests/machines/zfs-guest:android-firecracker` | `machines/zfs-guest/` | — |
| `android-guest-unit` | `//:check-android-guest-unit` | — | — |
| `application-metrics` | `//nix/verification/tests/machines/application-metrics:application-metrics` | `machines/application-metrics/` | Actual Marshall and Lilly periodic summaries through journald and native Fluent Bit output; no injected summaries, guests or live AWS. |
| `artifact-agent-publish` | `//nix/verification/tests/machines/fleet:artifact-agent-publish` | `machines/fleet/` | — |
| `artifact-origin` | `//nix/verification/tests/machines/artifact-origin:artifact-origin` | `machines/artifact-origin/` | — |
| `audi-configuration` | `//:check-audi-configuration` | `evaluation/audi.nix` | Gateway/admin/Porsche port separation and systemd credential wiring. |
| `audi-dns` | `//nix/verification/tests/machines/audi-dns:audi-dns` | `machines/audi-dns/` | Packaged independent DNS role on UDP/TCP 53; empty replica SERVFAIL, external-zone refusal and restart. No publication replication. |
| `audi-fleet` | `//nix/verification/tests/machines/fleet:audi-fleet` | `machines/fleet/` | Native NixOS guest SSH through Audi, per-user homes, registered keys, Cedar sharing and revocation, durable guest login reports and live-stream fencing. |
| `audi-ingress-network` | `//nix/verification/tests/machines/audi-ingress:audi-ingress-network` | `machines/audi-ingress/` | Packaged Lilly namespace sockets and actual nftables: marked SSH, unmarked/wrong-port denial, guest-to-host/lateral denial and unsolicited forwarding denial. Uses veth echo fixtures, not Firecracker guests. |
| `audi-openssh` | `//nix/verification/tests/machines/audi-openssh:audi-openssh` | `machines/audi-openssh/` | Generated client profile with real nested OpenSSH and verified HTTPS curl; separate guest trust, stale gateway keys and lookup failures. Uses stock sshd/HTTPS fixtures, not Marshall publication or Firecracker. |
| `audi-private-pki` | `//:check-audi-private-pki` | `evaluation/private-pki.nix` | Offline fleet wildcard issuance, exact SANs, issuer constraints, 20/10/10-year lifetimes and runtime/recovery custody. |
| `audi-release` | `//:check-audi-release` | `release/` | Source-built Audi payload, pinned runtime, shared protocol and absence of Marshall/Lilly application dependencies and privileged host-tool metadata; no running gateway claim. |
| `audi-relocation-fleet` | `//nix/verification/tests/machines/fleet:audi-relocation-fleet` | `machines/fleet/scenarios/audi-relocation.py` | Adds real relocation to Audi's fleet: stable names, strict destination gateway lookup, retained guest identity/data, interrupted streams and stale-source refusal. Runtime acceptance pending. |
| `audi-service` | `//nix/verification/tests/machines/audi-service:audi-service` | `machines/audi-service/` | Actual packaged Audi/Lilly startup, UID-bound connector and crash recovery, private credential/key custody, host identity persistence and invalid-credential rejection. No Marshall or Firecracker guest. |
| `audi-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:audi-ubuntu-fleet` | `machines/fleet/` | The same native Audi guest SSH scenarios on the Ubuntu guest image. |
| `audi-ubuntu-relocation-fleet` | `//nix/verification/tests/machines/fleet:audi-ubuntu-relocation-fleet` | `machines/fleet/` | — |
| `auto-update` | `//nix/verification/tests/machines/auto-update:auto-update` | `machines/auto-update/` | Actual Git candidates, exact NixOS switches, phase failures, corrective commits and backoff. |
| `auto-update-compatibility` | `//:check-auto-update-compatibility` | `evaluation/auto-update-compatibility.nix` | Existing fixed updater assertions and generated key/authority histories through actual compatibility and preflight, including all serving baselines and inactive fallback; isolated seams do not establish activation. |
| `auto-update-custody` | `//:check-auto-update-custody` | `evaluation/auto-update-custody.nix` | Generated rotation-recovery and custody-mismatch histories through the actual updater state machine, real SecretSpec/SOPS staging and descriptor handoff inside a disposable uid-0 namespace: deterministic refusal backoff, verify-only recovery after operator switch, wedge label and post-fix recovery; world-model seams do not establish systemd or native activation. |
| `backup-configuration` | `//:check-backup-configuration` | `evaluation/backup-configuration.nix` | Module defaults, jitter overrides, private credentials and independent cleanup wiring. |
| `backup-custody` | `//:check-backup-custody` | `evaluation/backup-custody.*` | Real runtime/Restic/SOPS composition: the zero-failure password key ceremony, the exact `repository`-label wedge after rotation without it with previous-generation recovery, and restore→decrypt→repository-access composition with the historical-generation refusal leg; synthetic custody only. |
| `backup-operators` | `//:check-backup-operators` | `evaluation/backup-operators.nix` | Generated operator histories against the real runtime and local encrypted Restic: complete reference/retention graphs, malformed-manifest matrix, credential custody refusals on every repository operation, generated SIGTERM/SIGKILL/timeout interruption histories per restore component and manifest-publication window, kill-mid-upload recovery, orphan grace, real concurrent prune-vs-restore lock semantics, and mid-restore credential swap. |
| `backup-recovery` | `//nix/verification/tests/machines/backups:backup-recovery` | `machines/backups/` | Real ZFS and TLS S3 capture, configured remote PostgreSQL, outage preservation, isolated file/database restore, short retention and credential-independent cleanup. Operators SIGKILL mid-upload reconciles through the cleanup unit with retained orphan grace; held host lock refuses operator reads while scheduled services skip; credential custody refusals apply through the real unit EnvironmentFile. |
| `backup-types` | `//:check-backup-types` | `evaluation/backup-types.nix` | Strict Python typing (ruff + ty), durable state/credential failure cases, cleanup replay and generated retention reference sets. |
| `brady-configuration` | `//:check-brady-configuration` | `evaluation/brady.nix` | Dedicated UID, namespace/credential wiring, monitoring role and invalid port/pool rejection. No native interception or ZFS claim. |
| `brady-fleet` | `//nix/verification/tests/machines/fleet:brady-fleet` | `machines/fleet/` | Real enrolled Marshall/Lilly/Firecracker HTTP/TLS, exact owner-attributed events, restart survival, unchanged legacy intent, real monitoring history and old-flow refusal after address reuse. |
| `brady-flow` | `//nix/verification/tests/machines/brady-flow:brady-flow` | `machines/brady-flow/` | Packaged read-only helper against real kernel TCP labels, retained old-flow labels and unlabeled-flow refusal. No TAP, TPROXY, owner attribution or Firecracker claim. |
| `brady-large-storage` | `//nix/verification/tests/machines/brady-network:brady-large-storage` | `machines/brady-network/` | — |
| `brady-native-storage` | `//nix/verification/tests/machines/brady-network:brady-native-storage` | `machines/brady-network/` | Native ZFS preparation/pressure, transparent cache hits/ranges/recovery, secret bypass, stale pressure, actual quota/parent headroom and pool hysteresis. No Firecracker attribution claim. |
| `brady-network` | `//nix/verification/tests/machines/brady-network:brady-network` | `machines/brady-network/` | Packaged transparent HTTP/TLS, restricted socket capabilities, native firewall isolation, outage and log redaction. Veth peers; no Firecracker, attribution or ZFS claim. |
| `brady-release` | `//:check-brady-release` | `release/` | Source-built independent proxy payload, pinned runtime and configuration rejection; does not start privileged listeners. |
| `brady-storage` | `//:check-brady-storage` | `evaluation/brady-storage.py` | Bounded subprocess output and refusal of changed parent identity, guest descendants or unowned cache datasets. No native ZFS claim. |
| `buck-remote-cache` | `//nix/verification/tests/machines/buck-remote-cache:buck-remote-cache` | `machines/buck-remote-cache/` | — |
| `buck-remote-execution` | `//nix/verification/tests/machines/buck-remote-execution:buck-remote-execution` | `machines/buck-remote-execution/` | — |
| `clone-cancellation` | `//nix/verification/tests/machines/fleet:clone-cancellation` | `machines/fleet/` | — |
| `clone-destination-loss` | `//nix/verification/tests/machines/fleet:clone-destination-loss` | `machines/clone-permutations/destination-loss.py` | Real fleet clone canceled while the destination host is crashed mid-receive: source restoration, retained holds/slots under physical uncertainty, exact recovery after rejoin and cancelled-request retry refusal. |
| `clone-marshall-restart` | `//nix/verification/tests/machines/fleet:clone-marshall-restart` | `machines/clone-permutations/marshall-restart.py` | Real fleet clone surviving a whole-Marshall restart mid-copy with exactly one complete copy, plus one-slot-per-host arbitration between two-source clones with durable refusal and explicit retry. |
| `cloning-fleet` | `//nix/verification/tests/machines/fleet:cloning-fleet` | `machines/fleet/` | Isolated Porsche/cloning acceptance, including source creation, clone, two cross-host relocations returning the clone to its original host, exact request replay, real guest-data verification and old ZFS dataset cleanup. The scenario also covers OSS-profile cloning with its image removed from the catalog, retained image/profile/shape rows, native ZFS origin emptiness and GUID distinctness, guest-console divergent-write invisibility, stopped-source power invariance, public mid-copy `request cancel` cleanup and post-publication cancel refusal. |
| `coding-clis-nixos-fleet` | `//nix/verification/tests/machines/fleet:coding-clis-nixos-fleet` | `machines/fleet/` | — |
| `coding-clis-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:coding-clis-ubuntu-fleet` | `machines/fleet/` | — |
| `control-room-browser` | `//nix/verification/tests/machines/control-room:control-room-browser` | `machines/control-room/` | — |
| `credential-rotation` | `//nix/verification/tests/machines/credential-rotation:credential-rotation` | `machines/credential-rotation/` | Three Marshall machines, coordinated authority rotation, concurrent updater migrations, staged-secret consistency and compatible secret-only updates. |
| `credential-self-service-browser` | `//nix/verification/tests/machines/credential-self-service:credential-self-service-browser` | `machines/credential-self-service/` | Single-VM packaged Marshall/HAProxy/Chromium with virtual WebAuthn: enroll two passkeys, rename, remove non-proving (session/elevation survive), remove proving (immediate mounted elevation loss), ordinary last removal (MFA disabled, tokens revoked, mounted session invalidated), administrator last-passkey refusal and post-sign-out stale refusal, with exact PostgreSQL assertions. |
| `customer-isolation-fleet` | `//nix/verification/tests/machines/fleet:customer-isolation-fleet` | `machines/fleet/` | Six real guests across two Lilly hosts: Customer egress denial, unrestricted positive controls, spoofing/lateral denial, release/credential updates, daemon death and Customer stop/start. Sequential admission keeps capacity-race timing separate. |
| `database-recovery` | `//nix/verification/tests/machines/database-recovery:database-recovery` | `machines/database-recovery/` | Two machines with production release Repo parameters and verified PostgreSQL TLS. Requires one holder and three real queued lock waiters before machine loss, preserves the 20-second holder/35-second connection bounds, and checks an independent healthy active query. Execution is recorded separately; this is not full terminal recovery acceptance. |
| `database-recovery-active` | `//nix/verification/tests/machines/database-recovery:database-recovery-active` | `machines/database-recovery/` | — |
| `database-recovery-active-asymmetric` | `//nix/verification/tests/machines/database-recovery:database-recovery-active-asymmetric` | `machines/database-recovery/` | — |
| `database-recovery-active-silent` | `//nix/verification/tests/machines/database-recovery:database-recovery-active-silent` | `machines/database-recovery/` | — |
| `database-recovery-asymmetric` | `//nix/verification/tests/machines/database-recovery:database-recovery-asymmetric` | `machines/database-recovery/` | — |
| `database-recovery-silent` | `//nix/verification/tests/machines/database-recovery:database-recovery-silent` | `machines/database-recovery/` | — |
| `default-oss-creation` | `//nix/verification/tests/machines/fleet:default-oss-creation` | `machines/fleet/` | — |
| `editor-target-boundaries` | `//:check-editor-target-boundaries` | — | — |
| `encrypted-crash-dumps` | `//:check-encrypted-crash-dumps` | — | — |
| `enrico-release` | `//:check-enrico-release` | — | — |
| `enrico-service` | `//nix/verification/tests/machines/enrico-service:enrico-service` | `machines/enrico-service/` | — |
| `enrollment-configuration` | `//:check-enrollment-configuration` | — | — |
| `enrollment-operator` | `//nix/verification/tests/machines/enrollment-operator:enrollment-operator` | `machines/enrollment-operator/` | — |
| `enrollment-preparation` | `//:check-enrollment-preparation` | — | — |
| `executor-loss` | `//nix/verification/tests/machines/fleet:executor-loss` | `machines/executor-loss/` | Strict real guest started-effect interruption, exact process cleanup, uncertain outcome, fresh executor fence, ordinary browser-approved CLI retry and withdrawal. Execution status and pre-start gap are recorded in the [loss review](../../../docs/architecture/reviews/2026-09-26-executor-loss-histories.md). |
| `export-endpoint` | `//nix/verification/tests/machines/export-endpoint:export-endpoint` | `machines/export-endpoint/` | Installed restricted source service, native channel and ZFS send to another NixOS machine over pinned SSH; command rejection, listener-stop cancellation and typed live-listener source revocation with sender PID absence. Synthetic control distribution does not establish Marshall coordination or guest relocation. |
| `firecracker-patch-tests` | `//nix/verification/tests/machines:firecracker-patch-tests` | `evaluation/firecracker-patch-tests.nix` | Unit coverage for PVH RSDP, ACPI timer, Hyper-V leaves, CMOS, PCI BAR relocation and configuration notifications, virtio reset/scatter-gather and vsock indirect descriptors. No native guest or Windows acceptance. |
| `firecracker-vmm` | `//:check-firecracker-vmm` | `evaluation/firecracker-vmm.nix` | Patched static Firecracker identity, jailer pair and `--enable-pci` surface used by firmware guests. Structural package evidence; no guest boot. |
| `fleet` | `//nix/verification/tests/machines/fleet:fleet` | `machines/fleet/` | Nine machines, three Marshall instances, two Lilly hosts, six real guests, Lilly release/credential updates with retained processes/data/networking, browser sharing, isolation, capacity (fixed and generated respending races) and recovery. |
| `fleet-addresses` | `//nix/verification/tests/machines/fleet-addresses:fleet-addresses` | `machines/fleet-addresses/` | SOPS-delivered fleet addresses (ADR-0233) on nftables and iptables nodes: nothing admitted or addressed before decryption, runtime source grants and destination listeners, reload/restart refill, rotation, malformed-document closure, and the runtime uplink drop-in with its recovery copy. Test VLAN addresses; no Hetzner network claim. |
| `fleet-builds` | `//nix/verification/tests/machines/fleet-builds:fleet-builds` | `machines/fleet-builds/` | — |
| `fleet-builds-configuration` | `//:check-fleet-builds-configuration` | — | — |
| `fleet-exporter-native` | `//nix/verification/tests/machines/fleet-exporter:fleet-exporter-native` | `machines/fleet-exporter/` | — |
| `fleet-firewall-configuration` | `//:check-fleet-firewall-configuration` | `evaluation/fleet-firewall.nix` | Typed, commented source registry; trusted Tailscale ingress; exact TCP/UDP rules for nftables and iptables; malformed and duplicate address rejection; runtime-address listener chain, ordering and refusals (ADR-0232). |
| `fleet-guest-trust` | `//nix/verification/tests/machines/fleet:fleet-guest-trust` | `machines/fleet-guest-trust/` | Strict composed driver; both distributions on actual ZFS/Firecracker, current trust receipts, wrong-boot refusal with positive controls, a bounded wrong/forged/expired delivery sweep exhausted to completed peer-EOF refusals, trust/network/SSH order, local HTTP and retained-data restart. Execution is recorded separately in the campaign reviews; no full feature-fleet matrix acceptance. |
| `fleet-guest-trust-configuration` | `//:check-fleet-guest-trust-configuration` | `evaluation/fleet-guest-trust.nix` | Evaluates all seven feature-fleet variants: exact retained names and complete feature fragments, independent trust setup, required DNS/private services and SSH CA signers, image counts and matching enrollment descriptors. Configuration evidence only. |
| `fleet-monitor` | `//:check-fleet-monitor` | — | — |
| `fleet-monitor-configuration` | `//:check-fleet-monitor-configuration` | — | — |
| `fleet-network` | `//nix/verification/tests/machines/fleet-network:fleet-network` | `machines/fleet-network/` | — |
| `fleet-roster` | `//:check-fleet-roster` | `evaluation/fleet-roster.nix` | The `nix/policy/fleet` host, service and port roster: reviewed fleet accepted, derived tunnel ports, and rejection of duplicate ports, undeclared or missing hosts, non-reciprocal or unknown peers, misplaced control plane or telemetry worker, builder-free build participants and invalid service placement. |
| `foreign-linux-guest-filesystem` | `//:check-foreign-linux-guest-filesystem` | — | — |
| `foreign-linux-guest-unit` | `//:check-foreign-linux-guest-unit` | `evaluation/foreign-linux-guests.nix` | Evaluates pinned Arch Linux and AlmaLinux root assembly, version-4 manifest shape and distinct source markers. Evaluation only; it does not download, boot or establish distro-native guest-agent behavior. |
| `foreign-linux-pam-helper` | `//nix/verification/tests/machines:foreign-linux-pam-helper` | `evaluation/foreign-linux-pam-helper.nix` | Runs the pinned PAM helper installer in an isolated VM/chroot, checks exact root-owned mode-04755 bytes and unsafe-node refusals, and verifies root PAM account success/refusals on nosuid runtime storage. It does not establish foreign guest boot, SSH login or nonroot setuid elevation. |
| `galileo-fleet` | `//nix/verification/tests/machines/fleet:galileo-fleet` | `machines/fleet/` | — |
| `galileo-release` | `//:check-galileo-release` | — | — |
| `galileo-service` | `//nix/verification/tests/machines/galileo-service:galileo-service` | `machines/galileo-service/` | Packaged Audi-to-Galileo across two NixOS machines, verified TLS, exact uploads, query/method denial, bounded source/destination stalls, binding-change fencing, authority outage and 64-request concurrent load. Lilly binding and Marshall authority are controlled fixtures; no real attachment, relocation, peer gateway or Firecracker claim. |
| `git-mirrors-browser` | `//nix/verification/tests/machines/git-mirrors:git-mirrors-browser` | `machines/git-mirrors/` | — |
| `github-integration` | `//nix/verification/tests/machines/github-integration:github-integration` | `machines/github-integration/` | — |
| `github-integration-almalinux-fleet` | `//nix/verification/tests/machines/fleet:github-integration-almalinux-fleet` | `machines/fleet/` | — |
| `github-integration-arch-fleet` | `//nix/verification/tests/machines/fleet:github-integration-arch-fleet` | `machines/fleet/` | — |
| `github-integration-fleet` | `//nix/verification/tests/machines/fleet:github-integration-fleet` | `machines/fleet/` | — |
| `github-integration-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:github-integration-ubuntu-fleet` | `machines/fleet/` | — |
| `github-integration-windows-fleet` | `//nix/verification/tests/machines/fleet:github-integration-windows-fleet` | `machines/fleet/` | — |
| `github-tools-freebsd-retained` | `//nix/verification/tests/machines/native-services:github-tools-freebsd-retained` | `machines/native-services/` | — |
| `github-tools-illumos-retained` | `//nix/verification/tests/machines/native-services:github-tools-illumos-retained` | `machines/native-services/` | — |
| `guest-backups` | `//nix/verification/tests/machines/zfs-guest:guest-backups` | `machines/zfs-guest/backups.py` | Actual Firecracker flush without process interruption, stopped/unresponsive guests, restored disk data, transfer coexistence, foreign snapshot refusal and process loss after native snapshot creation. |
| `guest-boot-profile` | `//nix/verification/tests/machines/zfs-guest:guest-boot-profile` | `machines/zfs-guest/boot-profile.py` | Real Firecracker NixOS boot through trust and readiness, twice; asserts host line offsets and the guest boot profile (ADR-0154) and prints its marker lines. |
| `guest-cli-recovery` | `//nix/verification/tests/machines/fleet:guest-cli-recovery` | `machines/guest-cli-recovery/` | Strict real NixOS guest candidate spawn/registration failure recovery, restored inode/digest, fresh Marshall fence and operator tool result. Direct candidate injection bypasses delivery; execution status is recorded in the [recovery review](../../../docs/architecture/reviews/2026-09-26-guest-cli-recovery.md). Also covers an interrupted artifact fetch: partial staging never activates and one real check reconverges without poisoning the rejection cooldown. |
| `guest-cli-recovery-ubuntu` | `//nix/verification/tests/machines/fleet:guest-cli-recovery-ubuntu` | `machines/guest-cli-recovery/` (ubuntu composition) | The same strict candidate failure/interrupted-fetch recovery journey against the Ubuntu guest image. |
| `guest-flush` | `//:check-guest-flush` | `evaluation/guest-flush.nix` | Bounded sync requests, boot identity and host-only transport checks. |
| `guest-readiness` | `//:check-guest-readiness` | `evaluation/guest-readiness.nix` | Guest readiness configuration, boot identity validation, live-probe failure refusal and local socket responses; no KVM/vsock transport claim. |
| `guest-ssh` | `//:check-guest-ssh` | — | — |
| `guest-toolset` | `//:check-guest-toolset` | — | — |
| `hegel-framework-packages` | `//:check-hegel-framework-packages` | — | — |
| `host-conversion` | `//nix/verification/tests/machines/host-conversion:host-conversion` | `machines/host-conversion/` | — |
| `host-ec2-bios` | `//nix/verification/tests/machines/mirrored-installation:host-ec2-bios` | `machines/mirrored-installation/` | — |
| `host-ec2-uefi` | `//nix/verification/tests/machines/mirrored-installation:host-ec2-uefi` | `machines/mirrored-installation/` | — |
| `host-enrollment` | `//nix/verification/tests/machines/host-enrollment:host-enrollment` | `machines/host-enrollment/` | — |
| `host-hetzner-bios` | `//nix/verification/tests/machines/mirrored-installation:host-hetzner-bios` | `machines/mirrored-installation/` | — |
| `host-images` | `//nix/verification/tests/machines/host-images:host-images` | `machines/host-images/` | Production-profile fixture disks through firmware, fresh identities, reboot and surviving disks. |
| `host-planning` | `//:check-host-planning` | `evaluation/host-planning.py` | Complete inventories, EBS exclusion, budgets, erasure guards and binding/receipt refusal. |
| `host-replacement` | `//nix/verification/tests/machines/fleet:host-replacement` | `machines/fleet/` | Nine-node Audi fleet journey: enrolled host serves real nested guest private services (llm.internal) with Marshall credentials, retirement runs the real drain chain with the row persisted, stale compute and Ziggy credentials are refused over the real TLS listener, and the replacement host enrolls disabled through the pinned protected SSH bridge with a fresh machine identity, name and storage GUIDs, then restores service after readiness-gated enable. Not claimed: physical providers, production DNS/CA/load, multi-region. Execution scope is recorded in the [replacement review](../../../docs/architecture/reviews/2026-09-27-host-replacement.md). |
| `image-copy` | `//nix/verification/tests/machines/image-copy:image-copy` | `machines/image-copy/` | — |
| `image-template` | `//nix/verification/tests/machines/image-template:image-template` | `machines/image-template/` | — |
| `inception` | `//nix/verification/tests/machines/inception:inception` | `machines/inception/` | Native nesting prerequisite, two-disk development stack, persistence, real outer admission and inner lifecycle. See the Inception architecture review for executed outcomes and remaining limits. |
| `inception-checkout` | `//nix/verification/tests/machines/inception:inception-checkout` | `machines/inception/` | — |
| `inception-image-builder` | `//:check-inception-image-builder` | — | — |
| `inception-probe` | `//:check-inception-probe` | — | — |
| `inception-proof-broker` | `//:check-inception-proof-broker` | `evaluation/inception-proof-broker.py` | Packaged Audi and Python Unix proof exchange, peer identity, generation/proof mismatch and expiry; no native DNS propagation claim. |
| `inception-runtime` | `//:check-inception-runtime` | `evaluation/inception-*.py` | Private bootstrap identity, real local TLS preparation, retained workspace edits and bounded SMTP refresh; no physical VM or live mail claim. |
| `inception-ssh-host-ca` | `//nix/verification/tests/machines/inception-ssh-host-ca:inception-ssh-host-ca` | `machines/inception-ssh-host-ca/` | — |
| `inception-systemd` | `//:check-inception-systemd` | — | — |
| `installer-trust` | `//nix/verification/tests/machines/installer-trust:installer-trust` | `machines/installer-trust/` | Two NixOS machines: actual Marshall HTTPS script/artifacts, packaged Linux Lyra account proof through Porsche, first/repeat hashed trust, conflict/revocation preservation, revoked-account-key refusal and re-registration restore, four-way digest agreement, appended-byte upgrade preservation, served-digest-mismatch refusal, and PATH-shimmed unsupported-platform/Darwin-selection/shasum-fallback probes. Final guest connection is intentionally absent; no macOS runtime or guest acceptance. |
| `integration-renewals` | `//nix/verification/tests/machines/fleet:integration-renewals` | `machines/fleet/` | — |
| `job-history-browser` | `//nix/verification/tests/machines/job-history:job-history-browser` | `machines/job-history/` | — |
| `lilly-native-actor-recovery` | `//nix/verification/tests/machines/zfs-guest:lilly-native-actor-recovery` | `machines/zfs-guest/` | — |
| `lilly-observability-recovery` | `//nix/verification/tests/machines/fleet:lilly-observability-recovery` | `machines/fleet/` | — |
| `lilly-release` | `//:check-lilly-release` | `release/` | Actual source-built release payloads, runtime versions and application independence. |
| `lilly-runtime-readiness` | `//nix/verification/tests/machines/fleet:lilly-runtime-readiness` | `machines/fleet/` | — |
| `localization-account-porsche` | `//nix/verification/tests/machines/localization:localization-account-porsche` | `machines/localization/` | — |
| `log-store` | `//nix/verification/tests/machines/log-store:log-store` | `machines/log-store/` | — |
| `logging` | `//nix/verification/tests/machines/logging:logging` | `machines/logging/` | — |
| `logging-transports` | `//:check-logging-transports` | — | — |
| `lyra` | `//:check-lyra` | — | — |
| `maintenance-evacuation` | `//nix/verification/tests/machines/fleet:maintenance-evacuation` | `machines/fleet/` | — |
| `marshall-release` | `//:check-marshall-release` | `release/` | Actual source-built release payloads, runtime versions and application independence. |
| `memory-suspension-fleet` | `//nix/verification/tests/machines/fleet:memory-suspension-fleet` | `machines/fleet/` | — |
| `mfa-login-browser` | `//nix/verification/tests/machines/mfa-login:mfa-login-browser` | `machines/mfa-login/` | Three colocated packaged Marshall replicas over verified TLS; subsequent magic-link and remembered MFA, actual backend/WebSocket observations, admin revocation and copied-cookie refusal, plus an SQL-backdated expired-ceremony refusal with a fresh cross-replica retry. Virtual authenticators only; execution is recorded in the campaign review. |
| `mila-journey` | `//nix/verification/tests/machines/mila-journey:mila-journey` | `machines/mila-journey/` | — |
| `mila-journey-fixture` | `//:check-mila-journey-fixture` | — | — |
| `mila-journey-terminal` | `//nix/verification/tests/machines/fleet:mila-journey-terminal` | `machines/fleet/` | — |
| `mila-rust` | `//:check-mila-rust` | — | — |
| `mirrored-installation` | `//nix/verification/tests/machines/mirrored-installation:mirrored-installation` | `machines/mirrored-installation/` | Installer and installed UEFI boot, both surviving disks and persistent SSH identity. |
| `module-configuration` | `//:check-module-configuration` | `evaluation/module-configuration.nix` | Valid service combinations and rejection of incomplete options/budgets. |
| `native-backup-cleanup` | `//nix/verification/tests/machines/backup-cleanup:native-backup-cleanup` | `machines/backup-cleanup/` | — |
| `native-fixture-unit` | `//:check-native-fixture-unit` | `evaluation/native-fixtures.nix` | Pinned Python/Git/OpenSSH/OpenSSL/FAT tools execute host parser, refusal, authority, cleanup, Git and EFI inventory boundaries. Recorded 59-test pass; no native boot, kernel transport, isolation, growth or admission claim. |
| `native-freebsd-crash-recovery` | `//nix/verification/tests/machines/native-services:native-freebsd-crash-recovery` | `machines/native-services/default.nix` | Actual first-boot VMM SIGKILL, restart of the same disk under fresh MMDS and boot identity, retained synchronized home data, native filesystem recovery, stale-authority refusal and a final clean exit. The final reviewed image `5022d714` passed all 8 crash checks and both complete service oracles in 224 seconds after the native UFS suspension/resume flush correction. No interrupted-write durability, physical recovery or admission claim. |
| `native-freebsd-growth` | `//nix/verification/tests/machines/native-services:native-freebsd-growth` | `machines/native-services/default.nix` | Three native boots with two host-side disk increases, retained data, root-capacity increases, exact nonroot GPT/file inventories with only bounded root EFI NvVars mutable, untouched foreign disk and unprivileged helper refusal. The final reviewed image `5022d714` passed three distinct clean boots and complete service oracles. No OmniOS, interrupted-growth, crash-recovery or admission claim from this variant. |
| `native-freebsd-interrupted-growth` | `//nix/verification/tests/machines/native-durability:native-freebsd-interrupted-growth` | `machines/native-durability/` | — |
| `native-freebsd-isolation` | `//nix/verification/tests/machines/native-services:native-freebsd-isolation` | `machines/native-isolation/driver.py` | Real native Standard IPv4 against packaged Lilly router and TAP source guard, reachable TCP sink controls before policy, public connection after policy, private/protected/sibling/local refusals and an unassigned-source drop counter over two clean boots. The final reviewed image `5022d714` passed two clean boots with independent policy receipts and complete service oracles. The sibling is a Linux sink, not another native VM/TAP; no OmniOS, jail, physical-host, multi-host or admission claim. |
| `native-freebsd-power-loss` | `//nix/verification/tests/machines/native-durability:native-freebsd-power-loss` | `machines/native-durability/` | — |
| `native-freebsd-recovery` | `//nix/verification/tests/machines/native-services:native-freebsd-recovery` | `machines/native-services/default.nix` | Actual native daemon termination, readiness withheld while its executable cannot restart, exact mode restoration, supervisor replacement and same-boot protocol recovery over two clean boots. The final reviewed image `5022d714` passed both boots with per-boot recovery receipts and complete service oracles. No whole-guest crash, storage crash-durability, physical recovery or admission claim from this variant. |
| `native-freebsd-relocation` | `//nix/verification/tests/machines/native-durability:native-freebsd-relocation` | `machines/native-durability/` | — |
| `native-freebsd-reset` | `//nix/verification/tests/machines/native-reset:native-freebsd-reset` | `machines/native-reset/default.nix` | Test-only guest with a peerless identity socket and pending accept/read/write during a private fixture Unix API pause/full-snapshot/resume. The formal nested-KVM gate passed in 232 seconds with exact test image/kernel/probe/firmware/VMM receipts, idle ECONNRESET, blocked-operation errors and fresh-socket refusal until a new VM. No DMA/race stress, physical, service/recovery or admission claim. |
| `native-freebsd-services` | `//nix/verification/tests/machines/native-services:native-freebsd-services` | `machines/native-services/default.nix` | Native MMDS/network bootstrap, kernel/trust/flush/refusals and complete readiness with isolated HTTPS/SSH/Git/DNS authority; certified SSH, fenced execution, actual checkout and PTY over two clean boots. The final reviewed image `5022d714`, including canonical roots, SSH and blocking UFS flush, passed all 22 service checks. No isolation, crash recovery or admission claim from this variant. |
| `native-freebsd-transport` | `//nix/verification/tests/machines/native-transport:native-freebsd-transport` | `machines/native-transport/default.nix` | Nested-KVM boot of the actual candidate kernel and patched Firecracker, compiled transport identity, host CID, malformed/disconnected histories, reconnects and exact echoes through 1 MiB. The final ordinary catalog gate passed in 246 seconds on exact test image `19658a4a`, with immutable receipt and token/firmware/VMM hashes in the native review. This image is distinct from reset/service images; no production service or image admission claim. |
| `native-freebsd-wrong-cid` | `//nix/verification/tests/machines/native-transport:native-freebsd-wrong-cid` | `machines/native-transport/` | — |
| `native-image-promotion` | `//:check-native-image-promotion` | `../../domains/artifacts/guest/native-promotion/` | Checks exact image/firmware/disk identity, hash-bound five-scenario native evidence and immutable production registry admission; refuses stale/foreign/incomplete evidence. Host verifier tests only; native machine execution remains separate evidence. |
| `native-omnios-crash-recovery` | `//nix/verification/tests/machines/native-services:native-omnios-crash-recovery` | `machines/native-services/default.nix` | OmniOS/illumos first-boot SIGKILL, fresh authority, retained synchronized data, completed ZFS scrub and clean exit. Interrupted-write durability, physical recovery and admission remain outside scope. |
| `native-omnios-growth` | `//nix/verification/tests/machines/native-services:native-omnios-growth` | `machines/native-services/default.nix` | OmniOS/illumos three-boot, two-expansion ZFS growth fixture with retained data and foreign-disk checks. Interrupted growth, physical recovery and admission remain outside scope. |
| `native-omnios-interrupted-growth` | `//nix/verification/tests/machines/native-durability:native-omnios-interrupted-growth` | `machines/native-durability/` | — |
| `native-omnios-isolation` | `//nix/verification/tests/machines/native-services:native-omnios-isolation` | `machines/native-services/default.nix` | OmniOS/illumos service fixture with the native isolation policy variant. The machine scope is limited to the exercised IPv4 routing and guard boundary; physical, jail and multi-host isolation remain unclaimed. |
| `native-omnios-power-loss` | `//nix/verification/tests/machines/native-durability:native-omnios-power-loss` | `machines/native-durability/` | — |
| `native-omnios-recovery` | `//nix/verification/tests/machines/native-services:native-omnios-recovery` | `machines/native-services/default.nix` | OmniOS/illumos supervised daemon recovery fixture over two clean boots, with readiness withholding and same-boot protocol recovery. Whole-guest crash durability and admission remain outside scope. |
| `native-omnios-relocation` | `//nix/verification/tests/machines/native-durability:native-omnios-relocation` | `machines/native-durability/` | — |
| `native-omnios-reset` | `//nix/verification/tests/machines/native-services:native-omnios-reset` | `machines/native-services/omnios-reset-driver.py` | Nested-KVM OmniOS API pause/full-snapshot/resume after a complete service baseline on the same candidate: three 204 API responses, idle/read/write refusals, original listener reuse and current-CID revalidation. Passed in 721.76 seconds on disk `1db6ac13`. No service restoration, clean shutdown, DMA/race stress or admission claim. |
| `native-omnios-services` | `//nix/verification/tests/machines/native-services:native-omnios-services` | `machines/native-services/default.nix` | OmniOS/illumos complete native service fixture on the separately promoted image, with current boot identity, trust, workspace, terminal, SSH, executor fencing and clean shutdown. The explicit admitted-image test opt-in keeps the receipt `native_admission=false`; no production admission follows. |
| `native-omnios-transport` | `//nix/verification/tests/machines/native-services:native-omnios-transport` | `machines/native-services/ordinary-transport-driver.py` | Nested-KVM OmniOS ordinary transport over two clean boots on the non-admitted Nix KVM-assembled `omnios-image-candidate`: complete service baseline, exact token, CIDs 3/2, malformed-length refusal, disconnected-history recovery, nine echoes through 1 MiB, same-boot production restoration and loaded viosock/sockvsock file digests equal to the assembly receipt. Passed in 761.59 seconds, and in 681.84 seconds on the final formatted driver, on disk `1db6ac13` after an earlier unexplained `shutdown-send` timeout on the same inputs. No reset, DMA, wrong-CID or admission claim. |
| `native-os-guest-unit` | `//:check-native-os-guest-unit` | `evaluation/native-os-guests.nix` | Evaluates pinned FreeBSD 14.3 and OmniOS r151050 source pins, the explicit illumos downstream constructor, native artifact assembly and v6 manifest fields. Evaluation only; it does not download, boot or establish native guest isolation. |
| `native-reset-probes` | `//:check-native-reset-probes` | `evaluation/native-reset-probes.nix` | Cross-builds isolated C probes for both native OS families; source/ABI evidence only. |
| `native-vsock-core` | `//:check-native-vsock-core` | `../../domains/artifacts/guest/native-kernels/common/default.nix` | Shared C wire parser, credit and half-close properties under ASan/UBSan, including 400,000 generated transitions. No socket, queue or native driver acceptance. |
| `native-zfs` | `//nix/verification/tests/machines/native-zfs:native-zfs` | `machines/native-zfs/` | Real dataset identity, sparse accounting, policy, pressure and observation conflicts. |
| `nix-cache-configuration` | `//:check-nix-cache-configuration` | — | — |
| `nix-compact-configuration` | `//:check-nix-compact-configuration` | `../packages/nix-compact/configuration-check.nix` | NixOS package selection, opt-out, explicit override and unchanged daemon libraries. |
| `nix-compact-core` | `//:check-nix-compact-core` | pinned `nix-compact` flake `lib.mkCoreCheck` | C++ classification/archive regressions and Hegel properties for lossless capture, structured severity, budgets, interleaving, pagination and retention. |
| `nix-compact-native` | `//:check-nix-compact-native` | pinned `nix-compact` flake `lib.mkNativeCheck` | Development-input native Nix: Hegel real-build status/capture checks, clean stdout, TTY, Unix daemon, remote protocols, heartbeat and SIGINT. |
| `nix-compact-native-host` | `//:check-nix-compact-native-host` | pinned `nix-compact` flake `lib.mkNativeCheck` | The same native checks against the stable NixOS package input. |
| `nix-gc-configuration` | `//:check-nix-gc-configuration` | `evaluation/nix-gc.nix` | Threshold-gated bounded store collection: opt-in units, script bounds and pinned Nix, typed option rejection and fleet default enablement. No guest or runtime GC claim. |
| `nix-ld` | `//nix/verification/tests/machines/nix-ld:nix-ld` | `machines/nix-ld/` | Host `programs.nix-ld` runs an unpackaged dynamically linked ELF through a login shell; the disabled stub loader refuses the same binary. No Firecracker claim. |
| `otel-audi-ssh-native` | `//nix/verification/tests/machines/fleet:otel-audi-ssh-native` | `machines/fleet/` | — |
| `otel-burn-delivery` | `//nix/verification/tests/machines/otel-burn-delivery:otel-burn-delivery` | `machines/otel-burn-delivery/` | — |
| `otel-fleet` | `//nix/verification/tests/machines/otel-fleet:otel-fleet` | `machines/otel-fleet/` | — |
| `otel-galileo-native` | `//nix/verification/tests/machines/fleet:otel-galileo-native` | `machines/fleet/` | — |
| `otel-guest-native` | `//nix/verification/tests/machines/fleet:otel-guest-native` | `machines/fleet/` | — |
| `otel-marshall` | `//nix/verification/tests/machines/otel-marshall:otel-marshall` | `machines/otel-marshall/` | — |
| `otel-porsche-native` | `//nix/verification/tests/machines/fleet:otel-porsche-native` | `machines/fleet/` | — |
| `otel-request-recorder` | `//nix/verification/tests/machines/otel-request-recorder:otel-request-recorder` | `machines/otel-request-recorder/` | — |
| `otel-request-recorder-commit-reply-loss` | `//nix/verification/tests/machines/otel-request-recorder:otel-request-recorder-commit-reply-loss` | `machines/otel-request-recorder/` | — |
| `otel-slo-rules` | `//:check-otel-slo-rules` | — | — |
| `packaged-backup-cleanup` | `//nix/verification/tests/machines/backup-cleanup:packaged-backup-cleanup` | `machines/backup-cleanup/` | — |
| `peach-release` | `//:check-peach-release` | — | — |
| `peach-service` | `//:check-peach-service` | — | — |
| `porsche-configuration` | `//:check-porsche-configuration` | `evaluation/porsche.nix` | Administrative port preconditions, listener collision rejection and systemd credential wiring. |
| `porsche-crash-dumps` | `//nix/verification/tests/machines/porsche-crash-dumps:porsche-crash-dumps` | `machines/porsche-crash-dumps/` | Actual encrypted service crashes, off-host decryption, private custody, configured byte/time bounds, count/age retention, metadata-only journal reports and weak/missing-key rejection. |
| `porsche-fleet` | `//nix/verification/tests/machines/fleet:porsche-fleet` | `machines/fleet/` | Porsche variant of the real fleet: browser keys, native SSH lifecycle/sharing, and the existing three-Marshall/two-Lilly guest scenarios. The Porsche subtest covers clone relocation out and back with durable replay, guest-data and source-cleanup checks; later complete-suite capacity coverage remains independently timing-sensitive. |
| `porsche-lifecycle-fleet` | `//nix/verification/tests/machines/fleet:porsche-lifecycle-fleet` | `machines/fleet/` | — |
| `porsche-lifecycle-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:porsche-lifecycle-ubuntu-fleet` | `machines/fleet/` | — |
| `porsche-release` | `//:check-porsche-release` | `release/` | Source-built Porsche runtime, parser and configuration checks; excludes Ash/Oban/Ecto, other applications and privileged host tools. |
| `porsche-secrets` | `//nix/verification/tests/machines/porsche-secrets:porsche-secrets` | `machines/porsche-secrets/` | Real Ash gateway rotation, encrypted SecretSpec/SOPS publication, Porsche readiness recovery, wrong-recipient rejection and failed-publication startup fencing. |
| `porsche-service` | `//nix/verification/tests/machines/porsche-service:porsche-service` | `machines/porsche-service/` | Actual NixOS service startup, private key custody, separate administrative SSH, persistent host identity, invalid-credential rejection, private readiness socket, updater manifest wiring and actual aggregate emission through Fluent Bit; no Marshall or guest execution. |
| `porsche-terminal-fleet` | `//nix/verification/tests/machines/fleet:porsche-terminal-fleet` | `machines/fleet/` | — |
| `porsche-threads` | `//nix/verification/tests/machines/fleet:porsche-threads` | `machines/fleet/` | — |
| `private-services-guest` | `//:check-private-services-guest` | `evaluation/private-services.nix` | Explicit public-root trust, private-key rejection and split DNS ordering. |
| `private-services-network` | `//nix/verification/tests/machines/private-services:private-services-network` | `machines/private-services/` | Real Audi DNS/TLS and Lilly nftables in isolated namespaces; no Firecracker claim. |
| `private-web` | `//nix/verification/tests/machines/fleet:private-web` | `machines/fleet/` | — |
| `proxy-runtime-address` | `//nix/verification/tests/machines/proxy-runtime-address:proxy-runtime-address` | `machines/proxy-runtime-address/` | Runtime listener addresses (ADR-0233): HAProxy binds only the published IPv4 on 443 and the relay socket drop-in only on 5443; empty, wildcard and malformed values leave both down and a corrected value restores them. Firewall disabled; perimeter covered by the fleet-firewall checks. |
| `public-grafana` | `//nix/verification/tests/machines/public-grafana:public-grafana` | `machines/public-grafana/` | Actual Grafana behind the production HTTPS proxy and perimeter: verified TLS, login/Host refusal, private backend refusal, 57-panel dashboard, WebSocket upgrade and validated reload. |
| `public-grafana-configuration` | `//:check-public-grafana-configuration` | `evaluation/public-grafana.nix` | Default-off and generated port configurations under both firewall backends; prerequisite, wildcard, zero-port, SSH and socket conflict refusal; ADR-0181 public HTTP-01 opt-in sharing the proxy perimeter entry. |
| `push-notifications` | `//nix/verification/tests/machines/push-notifications:push-notifications` | `machines/push-notifications/` | Actual Marshall release pokes a fake Susan at the compiled origin over OS-trusted TLS: 503/503/200 sends once, 410 invalidates, bodies are signed ciphertext only, and the operator switch refuses registration. |
| `push-relay` | `//nix/verification/tests/machines/push-relay:push-relay` | `machines/push-relay/` | Actual Marshall release delivers through the actual Susan release behind TLS at the compiled origin to fake APNs: Susan verifies Marshall's install signature, provider 503/503/200 sends once, only the device key opens what the provider received, and provider 410 invalidates the device. |
| `py-static` | `//:py-static` | `buck/python.bzl` | Repository-wide Python formatting, linting and type checking with pinned ruff and ty; the same gate runs locally through prek. |
| `relocation-diagnostics` | `//:check-relocation-diagnostics` | — | — |
| `relocation-fleet` | `//nix/verification/tests/machines/fleet:relocation-fleet` | `machines/fleet/` | — |
| `remote-builders` | `//nix/verification/tests/machines/remote-builders:remote-builders` | `machines/remote-builders/` | Actual two-machine cache substitution, local-build placement, SSH restrictions, private SOPS delivery, rotation and outage fallback. |
| `remote-builders-configuration` | `//:check-remote-builders-configuration` | `evaluation/remote-builders.nix` | Reciprocal cache-only configuration, self exclusion, no build delegation, cache preservation, access and invalid inputs. |
| `repository-launch` | `//nix/verification/tests/machines/fleet:repository-launch` | `machines/fleet/` | — |
| `repository-launch-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:repository-launch-ubuntu-fleet` | `machines/fleet/` | — |
| `resize-browser` | `//nix/verification/tests/machines/fleet:resize-browser` | `machines/resize/` | Typed nine-node Audi-compatible fleet: browser draft/reload and stale/foreign refusal; running/stopped resizing with real Firecracker data, block/filesystem and CPU/memory probes. See [execution scope](../../../docs/architecture/reviews/2026-09-25-resize-verification.md). |
| `runtime-socket-configuration` | `//:check-runtime-socket-configuration` | — | — |
| `scim` | `//nix/verification/tests/machines/scim:scim` | `machines/scim/` | — |
| `secret-custody` | `//nix/verification/tests/machines/secret-custody:secret-custody` | `machines/secret-custody/` | SecretSpec/SOPS delivery with Hegel-drawn EnvironmentFile roundtrips, permission/health invariants, engine-explored seal/recover/rotate/missing/restore interleavings, reboot identity stability, adoption refusal, host recipient rotation and replacement recovery. |
| `secret-reconciliation` | `//:check-secret-reconciliation` | `evaluation/secrets.nix` | Actual SOPS recipient changes, revocation, payload preservation and safe publication; generated recipient/recovery-only and interrupted-rekey/retry histories, two-generation turnover ceremonies and direct full-turnover refusal pairs. |
| `service-roles` | `//nix/verification/tests/machines/service-roles:service-roles` | `machines/service-roles/` | Neither/either/both roles; three colocated Marshall instances, Lilly, resource limits and proxy failover. |
| `sharing-surfaces` | `//nix/verification/tests/machines/fleet:sharing-surfaces` | `machines/fleet/` + `machines/sharing-surfaces/` | Nine-node Audi fleet: one member concurrently holds live Audi SSH, a shared read-only browser terminal and private web streams on a nested guest; one direct share revocation closes all three within documented bounds, guest origin counters prove refused traffic never arrives, and re-sharing restores fresh admission with new lease artifacts. |
| `smtp-relay` | `//nix/verification/tests/machines/smtp-relay:smtp-relay` | `machines/smtp-relay/` | Actual Marshall mail through synchronous TLS forwarding, failure/retry, loopback isolation and SecretSpec/SOPS rotation. |
| `source-export` | `//nix/verification/tests/machines/source-export:source-export` | `machines/source-export/` | Native owned single-snapshot full send, permit issuance/renewal/fencing, stale identity and removed-lineage descriptor rejection and blocked-sender revocation with process absence; no installed SSH or coordinator claim. |
| `ssh-bootstrap-fleet` | `//nix/verification/tests/machines/fleet:ssh-bootstrap-fleet` | `machines/fleet/` | Customer clone/source restoration and resize with real SSH roster bootstrap; temporary outage, full readiness timeout, private-log retention, and authorized recovery preserving placement/data/account ownership on NixOS and Ubuntu. |
| `ssh-bootstrap-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:ssh-bootstrap-ubuntu-fleet` | `machines/fleet/` | Customer clone/source restoration and resize with real SSH roster bootstrap; temporary outage, full readiness timeout, private-log retention, and authorized recovery preserving placement/data/account ownership on NixOS and Ubuntu. |
| `ssh-host-certificates` | `//nix/verification/tests/machines/ssh-host-certificates:ssh-host-certificates` | `machines/ssh-host-certificates/` | — |
| `ssh-roster-matrix-fleet` | `//nix/verification/tests/machines/fleet:ssh-roster-matrix-fleet` | `machines/fleet/scenarios/ssh-roster-matrix.py` | Nine-node Audi fleet retained-image matrix on NixOS and Ubuntu guests: stop/start, clone of a stopped source, resize restart and cross-host relocation, each followed by real per-user SSH proving exact durable name/UID/mode-0700 home and retained markers; guest account ledger compared directly to the PostgreSQL writer set after each leg; clone-only accounts are expired-but-retained; stale-regression and digest-mismatch roster feeds refuse mutation on a live guest; team removal closes an already-open stream within its lease. |
| `ssh-roster-matrix-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:ssh-roster-matrix-ubuntu-fleet` | `machines/fleet/scenarios/ssh-roster-matrix.py` | Nine-node Audi fleet retained-image matrix on NixOS and Ubuntu guests: stop/start, clone of a stopped source, resize restart and cross-host relocation, each followed by real per-user SSH proving exact durable name/UID/mode-0700 home and retained markers; guest account ledger compared directly to the PostgreSQL writer set after each leg; clone-only accounts are expired-but-retained; stale-regression and digest-mismatch roster feeds refuse mutation on a live guest; team removal closes an already-open stream within its lease. |
| `ssh-transfer` | `//nix/verification/tests/machines/ssh-transfer:ssh-transfer` | `machines/ssh-transfer/` | Production pinned SSH client and native pipe against real OpenSSH, 32 MiB integrity, authenticated-key delivery, permit fencing, wrong host/client key refusal and retired-key rejection; no native ZFS or Oban coordination claim. |
| `storage-configuration` | `//:check-storage-configuration` | `evaluation/storage-configuration.nix` | Mirrored layout, storage properties, budgets and installation boundaries. |
| `susan-image` | `//nix/verification/tests/machines/susan-image:susan-image` | `machines/susan-image/` | — |
| `susan-release` | `//:check-susan-release` | — | — |
| `susan-secrets` | `//nix/verification/tests/machines/susan-secrets:susan-secrets` | `machines/susan-secrets/` | — |
| `susan-service` | `//nix/verification/tests/machines/susan-service:susan-service` | `machines/susan-service/` | — |
| `sysctl` | `//nix/verification/tests/machines/sysctl:sysctl` | `machines/sysctl/` | Explicit opt-in, effective BBR/fq, inherited resource/forwarding policy, connected TCP sockets and reboot persistence. |
| `tailscale-configuration` | `//:check-tailscale-configuration` | `evaluation/tailscale.nix` | Fleet profile runs the Tailscale daemon with networkd integration on every host fixture; service-only module imports stay opt-in. No live tailnet claim. |
| `team-resources` | `//nix/verification/tests/machines/fleet:team-resources` | `machines/fleet/` | — |
| `team-ssh` | `//nix/verification/tests/machines/team-ssh:team-ssh` | `machines/team-ssh/` | Two NixOS machines with packaged Porsche, strict SSH host trust and verified internal TLS: ordinary account creation/retry, stable permanent refusals, transfer/removal, unchanged durable inventories and historical request replay. No guest or team integration access claim. |
| `teams-browser` | `//nix/verification/tests/machines/teams:teams-browser` | `machines/teams/` | Real Marshall/PostgreSQL and three Chromium accounts over verified HTTPS: owner replacement refusal, consent transfer, stale owner/member refusal and exactly one committed owner. No shared VM/integration or independent-Marshall race claim. |
| `telemetry-diagnostics` | `//:check-telemetry-diagnostics` | — | — |
| `terminal-fleet` | `//nix/verification/tests/machines/fleet:terminal-fleet` | `machines/fleet/` | — |
| `terminal-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:terminal-ubuntu-fleet` | `machines/fleet/` | — |
| `terminald-windows` | `//:check-terminald-windows` | — | — |
| `thread-tool` | `//nix/verification/tests/machines/fleet:thread-tool` | `machines/fleet/` | — |
| `trace-spool-native` | `//nix/verification/tests/machines/trace-spool:trace-spool-native` | `machines/trace-spool/` | — |
| `ubuntu-build-boundaries` | `//:check-ubuntu-build-boundaries` | `evaluation/ubuntu-build-boundaries.nix` | Actual offline assembly rejects missing requested packages and missing dependencies. |
| `ubuntu-fleet` | `//nix/verification/tests/machines/fleet:ubuntu-fleet` | `machines/fleet/` | Standard Ubuntu through website and Porsche management API, native cloning and relocation. |
| `ubuntu-guest` | `//nix/verification/tests/machines/zfs-guest:ubuntu-guest` | `machines/zfs-guest/` | Customized Ubuntu on real Firecracker: package/file/CA installation, boot, growth, persistence and lifecycle. |
| `ubuntu-guest-boot-profile` | `//nix/verification/tests/machines/zfs-guest:ubuntu-guest-boot-profile` | `machines/zfs-guest/boot-profile.py` | The same boot-profile measurement for the Ubuntu fixture image through trust delivery. |
| `ubuntu-guest-unit` | `//:check-ubuntu-guest-unit` | `evaluation/ubuntu-guest.*` | Builder input rejection, lock records, shared networking and readiness unit/property tests. |
| `underclass-configuration` | `//:check-underclass-configuration` | `evaluation/underclass.nix` | Default-off reuse, loopback-only execution, runtime secret ordering, resource bounds, Tailscale Serve command wiring and two-stage opt-in egress (isolated userspace node; loopback-only Underclass behind the exit-node start gate). No live tailnet claim. |
| `underclass-egress` | `//nix/verification/tests/machines/underclass-egress:underclass-egress` | `machines/underclass-egress/` | Real headscale tailnet, kernel exit node and dedicated userspace egress node: start refusal before login, exit-node source address and DNS resolution, unit confinement to loopback, no direct fallback when the exit node stops, gate re-assertion and reboot persistence. No production tailnet, Mac Mini or provider account claim. |
| `underclass-package` | `//:check-underclass-package` | `packages/underclass/` | Source-built Rust package pinned to an immutable upstream revision and locked Cargo dependencies. |
| `underclass-service` | `//nix/verification/tests/machines/underclass-service:underclass-service` | `machines/underclass-service/` | Actual packaged daemon, API/admin authentication, loopback isolation, secret-free diagnostics, systemd bounds and state persistence over restart/reboot. No provider account or live tailnet claim. |
| `underclass-slo` | `//nix/verification/tests/machines/underclass-slo:underclass-slo` | `machines/underclass-slo/` | — |
| `user-ssh-journey-fleet` | `//nix/verification/tests/machines/fleet:user-ssh-journey-fleet` | `machines/fleet/` | — |
| `user-ssh-journey-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:user-ssh-journey-ubuntu-fleet` | `machines/fleet/` | — |
| `vm-watch` | `//nix/verification/tests/machines/vm-watch:vm-watch` | `machines/vm-watch/` | — |
| `vscode-web-almalinux-fleet` | `//nix/verification/tests/machines/fleet:vscode-web-almalinux-fleet` | `machines/fleet/` | — |
| `vscode-web-arch-fleet` | `//nix/verification/tests/machines/fleet:vscode-web-arch-fleet` | `machines/fleet/` | — |
| `vscode-web-broker` | `//:check-vscode-web-broker` | — | — |
| `vscode-web-extensions` | `//:check-vscode-web-extensions` | — | — |
| `vscode-web-nixos-fleet` | `//nix/verification/tests/machines/fleet:vscode-web-nixos-fleet` | `machines/fleet/` | — |
| `vscode-web-package` | `//nix/verification/tests/machines/vscode-web:vscode-web-package` | `machines/vscode-web/` | — |
| `vscode-web-ubuntu-fleet` | `//nix/verification/tests/machines/fleet:vscode-web-ubuntu-fleet` | `machines/fleet/` | — |
| `windows-editor-acceptance-harness` | `//:check-windows-editor-acceptance-harness` | — | — |
| `windows-editor-runtime` | `//:check-windows-editor-runtime` | `evaluation/windows-editor-runtime.nix` | Hash-pinned Windows Node and ripgrep staging closure with an explicit editor=false marker. It does not establish a Code OSS bundle, broker, service identity or browser acceptance. |
| `windows-firmware` | `//:check-windows-firmware` | `nix/domains/artifacts/guest/windows/firmware.nix` | Pinned edk2 CloudHv PVH firmware and Firecracker MMCONFIG aperture. Build and ELF provenance only. |
| `windows-guest` | `//nix/verification/tests/machines/windows-guest:windows-guest` | `machines/windows-guest/` | Nested-KVM operator launcher installs and boots the Windows image to `SAC>`, and probes the launcher's vsock transport. No Lilly jail, Audi, roster or Marshall claim. |
| `windows-guest-unit` | `//:check-windows-guest-unit` | `evaluation/windows-guest.nix` | Offline Windows builder rules, pinned installer inputs, EMS/no-autologon, version-5 manifest, viosock and agent/task wiring. No installation or boot. |
| `windows-lilly-guest` | `//nix/verification/tests/machines/windows-lilly-guest:windows-lilly-guest` | `machines/windows-lilly-guest/` | Real nested-KVM Lilly launch of the agentless firmware image: MMDS identity, skipped trust, `unattested` lifecycle, /32 reachability through the test-only policy allowance, restart and delete. No readiness or user-agent claim. |
| `windows-lilly-guest-agents` | `//nix/verification/tests/machines/windows-lilly-guest:windows-lilly-guest-agents` | `machines/windows-lilly-guest/` (agents composition) | Real nested-KVM `windows-v1`: trust and 600 s readiness, boot-bound ConPTY root session, workspace delivery, no-roster SSH refusal, restart with a new boot UUID and delete. Roster-user SSH, agent turn, scheduled-task crash recovery and Marshall-driven fleet repetition remain gaps. |
| `zfs-guest` | `//nix/verification/tests/machines/zfs-guest:zfs-guest` | `machines/zfs-guest/` | Real Firecracker confinement, retained disks, flushed writes after simulated host loss and independent cleanup. |
| `zfs-guest-clone` | `//nix/verification/tests/machines/zfs-guest:zfs-guest-clone` | `machines/zfs-guest/clone-matrix.py` | Same-pool block-copy clones (ADR-0145): a clone after a completed 4 GiB resize with grown-disk capture and guest-shape checks, a chained clone whose first adopted copy becomes the next source, `bcloneused` growth and discard of a copied, unadopted destination; native origin emptiness, distinct GUIDs, divergent-write invisibility and deletion independence. |
| `zfs-io` | `//nix/verification/tests/machines/zfs-io:zfs-io` | `machines/zfs-io/` | Real pool-scoped traffic observations and uncertain-sample recovery. |
| `zfs-lifecycle` | `//nix/verification/tests/machines/zfs-lifecycle:zfs-lifecycle` | `machines/zfs-lifecycle/` | Owned sparse disks and interrupted create/copy/delete recovery. |
| `zfs-namespace-cleanup` | `//nix/verification/tests/machines/zfs-guest:zfs-namespace-cleanup` | `machines/zfs-guest/namespace-cleanup.py` | Real Firecracker deletion with late sandboxed mount copies, a live file holder and a surviving guest. |
| `zfs-retained-bundle` | `//nix/verification/tests/machines/zfs-lifecycle:zfs-retained-bundle` | `machines/zfs-lifecycle/` | — |
| `zfs-transfer` | `//nix/verification/tests/machines/zfs-transfer:zfs-transfer` | `machines/zfs-transfer/` | Native full and resumed streams of the single stopped-source snapshot (ADR-0155) between two block-backed pools, parentless resume-token validation, native-helper EOF cancellation/resume, Lilly staging receipt/ownership rejection, guarded intent, interrupted full disk adoption and ext4 data after source reclamation; no Lilly/SSH orchestration claim. |
| `ziggy-configuration` | `//:check-ziggy-configuration` | `evaluation/ziggy.nix` | Lilly placement, private-only Audi, secret delivery and monitoring wiring. |
| `ziggy-release` | `//:check-ziggy-release` | `release/` | Packaged independent Ziggy runtime, protocol and model catalog; absence of control-plane/provisioner dependencies. |
| `ziggy-service` | `//nix/verification/tests/machines/ziggy-service:ziggy-service` | `machines/ziggy-service/` | Packaged proxy, real SOPS credentials, native provider streaming, bounded spool, revocation and restart without replay. Local TLS/control fixtures, no Firecracker acceptance. |
| `ziggy-underclass` | `//nix/verification/tests/machines/ziggy-underclass:ziggy-underclass` | `machines/ziggy-underclass/` | — |
<!-- END generated by tools/docs -->

The `control-room-browser` machine test boots source-built Marshall, PostgreSQL,
HAProxy and Chromium. It checks ordinary reads across all Control room landing
pages, forged-event refusal, virtual WebAuthn enrollment and elevation, audited
role changes, and mounted-session demotion, revocation and expiry over verified
TLS. It uses one Marshall replica and makes no hardware-authenticator or
cross-replica propagation claim. Its standalone browser script also requires
explicit `ty check` with the development shell's pinned Python interpreter.

The `credential-self-service-browser` machine test boots the same packaged
single-VM stack. It drives passkey self-service in a real browser with virtual
WebAuthn authenticators: two-credential enrollment, rename through the mounted
form, non-proving removal with surviving session and mounted elevation, proving
removal with immediate mounted-page elevation loss, an ordinary account's
last-credential removal disabling MFA and revoking its own mounted session, the
administrator last-passkey refusal, and post-sign-out stale-view refusal. Every
step lands on exact PostgreSQL assertions. It makes no hardware-authenticator
claim, and its browser artifact is typed through
`credential-self-service-browser.checkedBrowser` like the other helpers.

The `mfa-login-browser` test adds three colocated Marshall replicas, independent
subsequent magic-link and remembered MFA, and cross-replica revocation. Its browser
subprocess is checked separately from the composed machine driver: the
`mfa-login-browser.checkedBrowser` artifact copies the source outside repository
type-check exclusions and runs pinned `ty` with the execution Python and
Playwright. The machine executes that checked artifact.

## Suite ownership

Each machine suite has a `default.nix` defining its topology and a `driver.py`.
Guest-side fixtures and Elixir probes stay beside that definition. ACME and secret
drivers receive generated paths through explicit Nix preambles; their Python
scenarios are ordinary source files.

Fleet initialization lives in `driver.py`; helpers and browser coordination are
separate files. Its `default.nix` lists scenario fragments in execution order:
bootstrap, enrollment, storage/image failures, idempotency, capacity, networking,
release/credential updates, terminal, control-plane recovery, provisioner recovery, lifecycle, stale-capacity
recovery and provisioner credential revocation. These
scenarios intentionally share the same running machines and state. Read them in
that order; they are not independent unit tests. Nix assembles their source before
the framework performs its normal lint/type checks. No runtime loader hides code
from those checks.

`support/` contains only shared fixtures:

- `acme-fixture.py`: private ACME material, trust, WebSocket and publication/recovery checks shared by HTTP and DNS suites.
- `role-node.nix` and `role-fixture.py`: service-role, custody and ACME setup.
- `fleet-database.nix` and `fleet-credentials.py`: fleet/rotation/recovery PostgreSQL and
  runtime credentials; callers explicitly supply connection budgets, allowed
  network and generation-service identity.
- `transfer.py`: private temporary machine-to-machine delivery, outside retained
  output and cleaned up on exit.
- `vm-processes.py`: actual VMM process identity checks used by fleet and guest tests.
- `zfs-node.nix`: the native observation/lifecycle node and its fault controls;
  each suite supplies its own memory, disks and driver.

Keep new one-suite helpers local. Shared setup must retain authentication, TLS,
explicit migrations, guest execution and failure assertions.

## Run checks

Buck2 is the only entry point (ADR-0269). Each test's target is in
[Find a test](#find-a-test):

```sh
tools/buck2 test //nix/verification/tests/machines/sysctl:sysctl
tools/buck2 test //nix/verification/tests/machines/service-roles:service-roles
tools/buck2 test //nix/verification/tests/machines/fleet:fleet
tools/buck2 build //:check-module-configuration
tools/buck2 build //nix/verification/tests/machines/fleet:fleet.assembly[drv]   # evaluate only
tools/affected --base origin/trunk   # what a change selects
```

Nested-KVM suites carry the `nested_kvm` label; the builder still needs the
`nested-kvm` system feature. Attributes of a check that are not targets (an
interactive `.driver`, a typed browser artifact) come from lib.assemble over
the checkout. That is a plain Nix build without the Buck2 artifacts, so use it
for debugging, never as test evidence:

```sh
nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks.fleet.driver'
```

### Continuous integration

Every check here is also a Buck2 target (ADR-0270). Machine tests are
`nixos_machine_test` targets (below); the other checks are `//:check-<name>`
assemblies of lib.assemble (label `flake_output`, BUCK.v2), which
`publish-cache.yml` selects with a Buck2 query that loads targets only and
builds in shards, the five 60-80 GB closures (label `isolated_build`) each on a
runner of its own. `tools/buck2 build --keep-going` reports every failing
check by target, evaluation errors included, and `ci.yml` evaluates each
affected one (`[drv]`) per push.

Machine tests are Buck2 targets (ADR-0270): each machine check is a
`nixos_machine_test` in `machines/<suite>/BUCK`, generated from this catalog by
`buck/machine_tests.py` and named after the check. `ci.yml` runs the targets
that each trunk push affects (`tools/affected`), and `nixos-machine-tests.yml`
runs all of them daily, one job per target:

```sh
tools/buck2 test //nix/verification/tests/machines/sysctl:sysctl
python3 buck/machine_tests.py generate   # after changing this catalog
```

A scheduled or dispatched run is execution evidence only for the commit it
ran; a selected matrix entry is not a passing result.

Machine tests require a Linux builder with usable KVM. Nested-guest tests also
require nested virtualization and the `nested-kvm` feature. The build user needs
device access; declaring a feature does not provide it. See the
[runner guidance](../../../docs/operations/nixos.md#machine-checks). Fleet allocates roughly
24 GiB across its nine outer VMs; run large suites sequentially on this builder.
Retain each suite's timeouts and the framework's lint/type checks. An evaluation
or driver build alone does not establish a successful machine run.

For an interactive driver, build the check's `.driver` attribute from
lib.assemble ([Run checks](#run-checks)), then run
`result/bin/nixos-test-driver`. Failed builds can retain diagnostic artifacts with
`--keep-failed`; private fixture material must not be copied into public logs.

Before a structural refactor, capture exported names and scenario coverage.
Rebuild changed derivations and reuse a prior result only when its immutable
derivation is unchanged. Run the ADR and contract gates as well. Machine results
remain functional evidence within one physical failure domain, not production
performance or external-provider acceptance.

## Complementary checks

Deployment uses the NixOS modules; no separate hand-written service fixtures
remain.

`logging` verifies three independent host exporters with TLS CloudWatch/OTLP,
outage/SIGKILL recovery, restricted audit routing and journal replay across reboot. `logging-transports` checks native CloudWatch partial
rejections, OTLP delivery and metric conversion. `encrypted-crash-dumps` verifies
actual pinned OTP encryption/decryption with a disposable key. The `zfs-guest`
check also exercises native Firecracker logging and collector restart survival.

Host provisioning additionally exports `host-hetzner-bios`, `host-ec2-bios`,
`host-ec2-uefi` and `host-conversion`. The existing `mirrored-installation` name
now tests the Hetzner UEFI production profile. Conversion uses a checksum-pinned
Ubuntu cloud image and recovery Linux, authenticated kexec and installed boot.
These fixtures remain separate from physical provider acceptance.

`enrollment-preparation` exercises real SOPS host/recovery custody with simulated SSH, lost replies and partial publication. It does not establish machine activation.

`enrollment-configuration` evaluates generated Lilly bindings and conflicting
manual overrides. `enrollment-operator` exercises pinned administrative SSH,
unprivileged systemd operator execution, concurrent retries, native ZFS identity,
the actual host preparation command, SecretSpec/SOPS delivery and Lilly readiness
across immediate rotation. It requires nested KVM and uses generated fixture keys.

`host-enrollment` boots the production host profile with isolated fixture hardware,
then uses real SSH, SOPS, published Git revisions and native Nix builds to exercise
failed Git-server authentication, enrollment retry, durable receipts and a subsequent
automatic update. Application roles remain disabled in this host-specific suite.

### Account lifecycle journey

`tools/buck2 test //nix/verification/tests/machines/fleet:account-lifecycle` runs a strictly typed bounded
fleet driver with source-built Marshall, Lilly, real Firecracker and ZFS. The
browser invites an ordinary user, registers real virtual-WebAuthn and SSH
credentials, creates a Customer machine and retires the account with elevated
typed confirmation. A stopped provisioner and accepted resize keep cleanup
pending; same-email signup receives a fresh identity while those holds remain.
Recovery must reclaim only the retired user's owned machine and retain the
shared-only and fresh-identity guests. Recovery restores Lilly and its dependent
Audi private frontend, waiting for real readiness. Fixed guest egress probes do not
establish fresh-user SSH. ADR-0156 assigns each User UUID a permanent GuestAccount
UUID/UID, generated `u<uid>` login and `/home/u<uid>` home. Email edits preserve
that allocation; retirement reserves it permanently and same-email registration
receives a distinct never-reused UID/login/home.
Mail tokens come from the isolated encrypted outbox through
private files; this is not SMTP or hardware-authenticator acceptance. Exact
historical email-derived execution is in the
[review](../../../docs/architecture/reviews/2026-09-25-account-lifecycle-verification.md).
The fleet now also closes the invited account's already-open guest SSH stream
within its lease after browser retirement and observes the shared guest's roster
timer expiring the account and removing its sudo policy while the retained home
keeps its historical UID. `account-lifecycle-ubuntu` runs the identical journey
on the Ubuntu guest image, extending fresh same-email canonical allocation,
retained-home and explicit re-sharing controls to Ubuntu. Both complete durable
identity lifecycle witnesses passed on base `63a1443c` plus feature `f1bd0e05`,
before incoming stopped-only relocation integration; their exact records are in
the [durable identity review](../../../docs/architecture/reviews/2026-10-10-durable-guest-identities.md).
Current combined native acceptance must be recorded separately.

`admin-account-browser` adds packaged WebAuthn reset and current-authority refusals from stale mounted administration pages. See the [execution review](../../../docs/architecture/reviews/2026-09-25-admin-account-authority-verification.md) for exact passing scope; presence alone is not native acceptance.

`lilly-runtime-readiness` reuses the source-built nine-machine fleet and six
nested Firecracker guests. Its generated Hegel scenario restarts daemon mains
under actual PostgreSQL outage, requires complete negative private readiness
replies, checks bounded negative watches and restores authenticated epochs and
positive readiness without changing VMM process snapshots. Native execution is
recorded in the [readiness review](../../../docs/architecture/reviews/2026-10-03-lilly-runtime-readiness.md): 897.72 seconds of machine script and 248.40 seconds for histories. This is neither a hosted Antithesis nor physical fleet result.
