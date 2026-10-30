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

Build these artifacts without booting machines:

```sh
nix build .#checks.x86_64-linux.teams-browser.checkedBrowser \
  .#checks.x86_64-linux.control-room-browser.checkedBrowser \
  .#checks.x86_64-linux.credential-self-service-browser.checkedBrowser \
  .#checks.x86_64-linux.default-oss-creation.defaultOssBrowser \
  .#checks.x86_64-linux.inception.checkedBrowser \
  .#checks.x86_64-linux.audi-fleet.audiBrowser \
  .#checks.x86_64-linux.porsche-fleet.porscheBrowser
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

| Flake check | Location | Verified behavior |
| --- | --- | --- |
| `host-replacement` | `machines/fleet/` | Nine-node Audi fleet journey: enrolled host serves real nested guest private services (llm.internal) with Marshall credentials, retirement runs the real drain chain with the row persisted, stale compute and Ziggy credentials are refused over the real TLS listener, and the replacement host enrolls disabled through the pinned protected SSH bridge with a fresh machine identity, name and storage GUIDs, then restores service after readiness-gated enable. Not claimed: physical providers, production DNS/CA/load, multi-region. Execution scope is recorded in the [replacement review](../../../docs/architecture/reviews/2026-09-27-host-replacement.md). |
| `executor-loss` | `machines/executor-loss/` | Strict real guest started-effect interruption, exact process cleanup, uncertain outcome, fresh executor fence, ordinary browser-approved CLI retry and withdrawal. Execution status and pre-start gap are recorded in the [loss review](../../../docs/architecture/reviews/2026-09-26-executor-loss-histories.md). |
| `guest-cli-recovery` | `machines/guest-cli-recovery/` | Strict real NixOS guest candidate spawn/registration failure recovery, restored inode/digest, fresh Marshall fence and operator tool result. Direct candidate injection bypasses delivery; execution status is recorded in the [recovery review](../../../docs/architecture/reviews/2026-09-26-guest-cli-recovery.md). Also covers an interrupted artifact fetch: partial staging never activates and one real check reconverges without poisoning the rejection cooldown. |
| `guest-cli-recovery-ubuntu` | `machines/guest-cli-recovery/` (ubuntu composition) | The same strict candidate failure/interrupted-fetch recovery journey against the Ubuntu guest image. |
| `agent-cli-journey` | `machines/agent-cli-journey/` | Strictly typed ordinary-browser explicit approval, packaged CLI, real stopped NixOS guest wake/model/tool result, profile refusal and stale approval after UI sharing withdrawal. Execution and isolated-provider limits are recorded in the [CLI review](../../../docs/architecture/reviews/2026-09-25-agent-cli-verification.md). |
| `mfa-login-browser` | `machines/mfa-login/` | Three colocated packaged Marshall replicas over verified TLS; subsequent magic-link and remembered MFA, actual backend/WebSocket observations, admin revocation and copied-cookie refusal, plus an SQL-backdated expired-ceremony refusal with a fresh cross-replica retry. Virtual authenticators only; execution is recorded in the campaign review. |
| `resize-browser` | `machines/resize/` | Typed nine-node Audi-compatible fleet: browser draft/reload and stale/foreign refusal; running/stopped resizing with real Firecracker data, block/filesystem and CPU/memory probes. See [execution scope](../../../docs/architecture/reviews/2026-09-25-resize-verification.md). |
| `teams-browser` | `machines/teams/` | Real Marshall/PostgreSQL and three Chromium accounts over verified HTTPS: owner replacement refusal, consent transfer, stale owner/member refusal and exactly one committed owner. No shared VM/integration or independent-Marshall race claim. |
| `credential-self-service-browser` | `machines/credential-self-service/` | Single-VM packaged Marshall/HAProxy/Chromium with virtual WebAuthn: enroll two passkeys, rename, remove non-proving (session/elevation survive), remove proving (immediate mounted elevation loss), ordinary last removal (MFA disabled, tokens revoked, mounted session invalidated), administrator last-passkey refusal and post-sign-out stale refusal, with exact PostgreSQL assertions. |
| `team-ssh` | `machines/team-ssh/` | Two NixOS machines with packaged Porsche, strict SSH host trust and verified internal TLS: ordinary account creation/retry, stable permanent refusals, transfer/removal, unchanged durable inventories and historical request replay. No guest or team integration access claim. |
| `database-recovery` | `machines/database-recovery/` | Two machines with production release Repo parameters and verified PostgreSQL TLS. Requires one holder and three real queued lock waiters before machine loss, preserves the 20-second holder/35-second connection bounds, and checks an independent healthy active query. Execution is recorded separately; this is not full terminal recovery acceptance. |
| `nix-compact-core` | pinned `nix-compact` flake `lib.mkCoreCheck` | C++ classification/archive regressions and Hegel properties for lossless capture, structured severity, budgets, interleaving, pagination and retention. |
| `nix-compact-native` | pinned `nix-compact` flake `lib.mkNativeCheck` | Development-input native Nix: Hegel real-build status/capture checks, clean stdout, TTY, Unix daemon, remote protocols, heartbeat and SIGINT. |
| `nix-compact-native-host` | pinned `nix-compact` flake `lib.mkNativeCheck` | The same native checks against the stable NixOS package input. |
| `nix-compact-configuration` | `../packages/nix-compact/configuration-check.nix` | NixOS package selection, opt-out, explicit override and unchanged daemon libraries. |
| `ubuntu-build-boundaries` | `evaluation/ubuntu-build-boundaries.nix` | Actual offline assembly rejects missing requested packages and missing dependencies. |
| `ubuntu-guest-unit` | `evaluation/ubuntu-guest.*` | Builder input rejection, lock records, shared networking and readiness unit/property tests. |
| `native-fixture-unit` | `evaluation/native-fixtures.nix` | Pinned Python/Git/OpenSSH/OpenSSL/FAT tools execute host parser, refusal, authority, cleanup, Git and EFI inventory boundaries. Recorded 59-test pass; no native boot, kernel transport, isolation, growth or admission claim. |
| `native-os-guest-unit` | `evaluation/native-os-guests.nix` | Evaluates pinned FreeBSD 14.3 and OmniOS r151050 source pins, the explicit illumos downstream constructor, native artifact assembly and v6 manifest fields. Evaluation only; it does not download, boot or establish native guest isolation. |
| `native-image-promotion` | `../../domains/artifacts/guest/native-promotion/` | Checks exact image/firmware/disk identity, hash-bound five-scenario native evidence and immutable production registry admission; refuses stale/foreign/incomplete evidence. Host verifier tests only; native machine execution remains separate evidence. |
| `foreign-linux-guest-unit` | `evaluation/foreign-linux-guests.nix` | Evaluates pinned Arch Linux and AlmaLinux root assembly, version-4 manifest shape and distinct source markers. Evaluation only; it does not download, boot or establish distro-native guest-agent behavior. |
| `foreign-linux-pam-helper` | `evaluation/foreign-linux-pam-helper.nix` | Runs the pinned PAM helper installer in an isolated VM/chroot, checks exact root-owned mode-04755 bytes and unsafe-node refusals, and verifies root PAM account success/refusals on nosuid runtime storage. It does not establish foreign guest boot, SSH login or nonroot setuid elevation. |
| `ubuntu-guest` | `machines/zfs-guest/` | Customized Ubuntu on real Firecracker: package/file/CA installation, boot, growth, persistence and lifecycle. |
| `firecracker-vmm` | `evaluation/firecracker-vmm.nix` | Patched static Firecracker identity, jailer pair and `--enable-pci` surface used by firmware guests. Structural package evidence; no guest boot. |
| `firecracker-patch-tests` | `evaluation/firecracker-patch-tests.nix` | Unit coverage for PVH RSDP, ACPI timer, Hyper-V leaves, CMOS, PCI BAR relocation and configuration notifications, virtio reset/scatter-gather and vsock indirect descriptors. No native guest or Windows acceptance. |
| `native-vsock-core` | `../../domains/artifacts/guest/native-kernels/common/default.nix` | Shared C wire parser, credit and half-close properties under ASan/UBSan, including 400,000 generated transitions. No socket, queue or native driver acceptance. |
| `native-freebsd-transport` | `machines/native-transport/default.nix` | Nested-KVM boot of the actual candidate kernel and patched Firecracker, compiled transport identity, host CID, malformed/disconnected histories, reconnects and exact echoes through 1 MiB. The final ordinary catalog gate passed in 246 seconds on exact test image `19658a4a`, with immutable receipt and token/firmware/VMM hashes in the native review. This image is distinct from reset/service images; no production service or image admission claim. |
| `native-reset-probes` | `evaluation/native-reset-probes.nix` | Cross-builds isolated C probes for both native OS families; source/ABI evidence only. |
| `native-freebsd-reset` | `machines/native-reset/default.nix` | Test-only guest with a peerless identity socket and pending accept/read/write during a private fixture Unix API pause/full-snapshot/resume. The formal nested-KVM gate passed in 232 seconds with exact test image/kernel/probe/firmware/VMM receipts, idle ECONNRESET, blocked-operation errors and fresh-socket refusal until a new VM. No DMA/race stress, physical, service/recovery or admission claim. |
| `native-freebsd-services` | `machines/native-services/default.nix` | Native MMDS/network bootstrap, kernel/trust/flush/refusals and complete readiness with isolated HTTPS/SSH/Git/DNS authority; certified SSH, fenced execution, actual checkout and PTY over two clean boots. The final reviewed image `5022d714`, including canonical roots, SSH and blocking UFS flush, passed all 22 service checks. No isolation, crash recovery or admission claim from this variant. |
| `native-freebsd-isolation` | `machines/native-isolation/driver.py` | Real native Standard IPv4 against packaged Lilly router and TAP source guard, reachable TCP sink controls before policy, public connection after policy, private/protected/sibling/local refusals and an unassigned-source drop counter over two clean boots. The final reviewed image `5022d714` passed two clean boots with independent policy receipts and complete service oracles. The sibling is a Linux sink, not another native VM/TAP; no OmniOS, jail, physical-host, multi-host or admission claim. |
| `native-freebsd-growth` | `machines/native-services/default.nix` | Three native boots with two host-side disk increases, retained data, root-capacity increases, exact nonroot GPT/file inventories with only bounded root EFI NvVars mutable, untouched foreign disk and unprivileged helper refusal. The final reviewed image `5022d714` passed three distinct clean boots and complete service oracles. No OmniOS, interrupted-growth, crash-recovery or admission claim from this variant. |
| `native-freebsd-recovery` | `machines/native-services/default.nix` | Actual native daemon termination, readiness withheld while its executable cannot restart, exact mode restoration, supervisor replacement and same-boot protocol recovery over two clean boots. The final reviewed image `5022d714` passed both boots with per-boot recovery receipts and complete service oracles. No whole-guest crash, storage crash-durability, physical recovery or admission claim from this variant. |
| `native-freebsd-crash-recovery` | `machines/native-services/default.nix` | Actual first-boot VMM SIGKILL, restart of the same disk under fresh MMDS and boot identity, retained synchronized home data, native filesystem recovery, stale-authority refusal and a final clean exit. The final reviewed image `5022d714` passed all 8 crash checks and both complete service oracles in 224 seconds after the native UFS suspension/resume flush correction. No interrupted-write durability, physical recovery or admission claim. |
| `native-omnios-services` | `machines/native-services/default.nix` | OmniOS/illumos complete native service fixture on the separately promoted image, with current boot identity, trust, workspace, terminal, SSH, executor fencing and clean shutdown. The explicit admitted-image test opt-in keeps the receipt `native_admission=false`; no production admission follows. |
| `native-omnios-isolation` | `machines/native-services/default.nix` | OmniOS/illumos service fixture with the native isolation policy variant. The machine scope is limited to the exercised IPv4 routing and guard boundary; physical, jail and multi-host isolation remain unclaimed. |
| `native-omnios-growth` | `machines/native-services/default.nix` | OmniOS/illumos three-boot, two-expansion ZFS growth fixture with retained data and foreign-disk checks. Interrupted growth, physical recovery and admission remain outside scope. |
| `native-omnios-recovery` | `machines/native-services/default.nix` | OmniOS/illumos supervised daemon recovery fixture over two clean boots, with readiness withholding and same-boot protocol recovery. Whole-guest crash durability and admission remain outside scope. |
| `native-omnios-crash-recovery` | `machines/native-services/default.nix` | OmniOS/illumos first-boot SIGKILL, fresh authority, retained synchronized data, completed ZFS scrub and clean exit. Interrupted-write durability, physical recovery and admission remain outside scope. |
| `native-omnios-transport` | `machines/native-services/ordinary-transport-driver.py` | Nested-KVM OmniOS ordinary transport over two clean boots on the non-admitted Nix KVM-assembled `omnios-image-candidate`: complete service baseline, exact token, CIDs 3/2, malformed-length refusal, disconnected-history recovery, nine echoes through 1 MiB, same-boot production restoration and loaded viosock/sockvsock file digests equal to the assembly receipt. Passed in 761.59 seconds, and in 681.84 seconds on the final formatted driver, on disk `1db6ac13` after an earlier unexplained `shutdown-send` timeout on the same inputs. No reset, DMA, wrong-CID or admission claim. |
| `native-omnios-reset` | `machines/native-services/omnios-reset-driver.py` | Nested-KVM OmniOS API pause/full-snapshot/resume after a complete service baseline on the same candidate: three 204 API responses, idle/read/write refusals, original listener reuse and current-CID revalidation. Passed in 721.76 seconds on disk `1db6ac13`. No service restoration, clean shutdown, DMA/race stress or admission claim. |
| `windows-firmware` | `nix/domains/artifacts/guest/windows/firmware.nix` | Pinned edk2 CloudHv PVH firmware and Firecracker MMCONFIG aperture. Build and ELF provenance only. |
| `windows-guest-unit` | `evaluation/windows-guest.nix` | Offline Windows builder rules, pinned installer inputs, EMS/no-autologon, version-5 manifest, viosock and agent/task wiring. No installation or boot. |
| `windows-editor-runtime` | `evaluation/windows-editor-runtime.nix` | Hash-pinned Windows Node and ripgrep staging closure with an explicit editor=false marker. It does not establish a Code OSS bundle, broker, service identity or browser acceptance. |
| `windows-guest` | `machines/windows-guest/` | Nested-KVM operator launcher installs and boots the Windows image to `SAC>`, and probes the launcher's vsock transport. No Lilly jail, Audi, roster or Marshall claim. |
| `windows-lilly-guest` | `machines/windows-lilly-guest/` | Real nested-KVM Lilly launch of the agentless firmware image: MMDS identity, skipped trust, `unattested` lifecycle, /32 reachability through the test-only policy allowance, restart and delete. No readiness or user-agent claim. |
| `windows-lilly-guest-agents` | `machines/windows-lilly-guest/` (agents composition) | Real nested-KVM `windows-v1`: trust and 600 s readiness, boot-bound ConPTY root session, workspace delivery, no-roster SSH refusal, restart with a new boot UUID and delete. Roster-user SSH, agent turn, scheduled-task crash recovery and Marshall-driven fleet repetition remain gaps. |
| `fleet-guest-trust-configuration` | `evaluation/fleet-guest-trust.nix` | Evaluates all seven feature-fleet variants: exact retained names and complete feature fragments, independent trust setup, required DNS/private services and SSH CA signers, image counts and matching enrollment descriptors. Configuration evidence only. |
| `fleet-guest-trust` | `machines/fleet-guest-trust/` | Strict composed driver; both distributions on actual ZFS/Firecracker, current trust receipts, wrong-boot refusal with positive controls, a bounded wrong/forged/expired delivery sweep exhausted to completed peer-EOF refusals, trust/network/SSH order, local HTTP and retained-data restart. Execution is recorded separately in the campaign reviews; no full feature-fleet matrix acceptance. |
| `ubuntu-fleet` | `machines/fleet/` | Standard Ubuntu through website and Porsche management API, native cloning and relocation. |
| `remote-builders-configuration` | `evaluation/remote-builders.nix` | Reciprocal cache-only configuration, self exclusion, no build delegation, cache preservation, access and invalid inputs. |
| `fleet-roster` | `evaluation/fleet-roster.nix` | The `nix/policy/fleet` host, service and port roster: reviewed fleet accepted, derived tunnel ports, and rejection of duplicate ports, undeclared or missing hosts, non-reciprocal or unknown peers, misplaced control plane or telemetry worker, builder-free build participants and invalid service placement. |
| `remote-builders` | `machines/remote-builders/` | Actual two-machine cache substitution, local-build placement, SSH restrictions, private SOPS delivery, rotation and outage fallback. |
| `ziggy-release` | `release/` | Packaged independent Ziggy runtime, protocol and model catalog; absence of control-plane/provisioner dependencies. |
| `ziggy-configuration` | `evaluation/ziggy.nix` | Lilly placement, private-only Audi, secret delivery and monitoring wiring. |
| `ziggy-service` | `machines/ziggy-service/` | Packaged proxy, real SOPS credentials, native provider streaming, bounded spool, revocation and restart without replay. Local TLS/control fixtures, no Firecracker acceptance. |
| `galileo-service` | `machines/galileo-service/` | Packaged Audi-to-Galileo across two NixOS machines, verified TLS, exact uploads, query/method denial, bounded source/destination stalls, binding-change fencing, authority outage and 64-request concurrent load. Lilly binding and Marshall authority are controlled fixtures; no real attachment, relocation, peer gateway or Firecracker claim. |
| `underclass-package` | `packages/underclass/` | Source-built Rust package pinned to an immutable upstream revision and locked Cargo dependencies. |
| `underclass-configuration` | `evaluation/underclass.nix` | Default-off reuse, loopback-only execution, runtime secret ordering, resource bounds, Tailscale Serve command wiring and two-stage opt-in egress (isolated userspace node; loopback-only Underclass behind the exit-node start gate). No live tailnet claim. |
| `underclass-service` | `machines/underclass-service/` | Actual packaged daemon, API/admin authentication, loopback isolation, secret-free diagnostics, systemd bounds and state persistence over restart/reboot. No provider account or live tailnet claim. |
| `underclass-egress` | `machines/underclass-egress/` | Real headscale tailnet, kernel exit node and dedicated userspace egress node: start refusal before login, exit-node source address and DNS resolution, unit confinement to loopback, no direct fallback when the exit node stops, gate re-assertion and reboot persistence. No production tailnet, Mac Mini or provider account claim. |
| `private-services-guest` | `evaluation/private-services.nix` | Explicit public-root trust, private-key rejection and split DNS ordering. |
| `audi-private-pki` | `evaluation/private-pki.nix` | Offline fleet wildcard issuance, exact SANs, issuer constraints, 20/10/10-year lifetimes and runtime/recovery custody. |
| `private-services-network` | `machines/private-services/` | Real Audi DNS/TLS and Lilly nftables in isolated namespaces; no Firecracker claim. |
| `audi-fleet` | `machines/fleet/` | Native NixOS guest SSH through Audi, per-user homes, registered keys, Cedar sharing and revocation, durable guest login reports and live-stream fencing. |
| `sharing-surfaces` | `machines/fleet/` + `machines/sharing-surfaces/` | Nine-node Audi fleet: one member concurrently holds live Audi SSH, a shared read-only browser terminal and private web streams on a nested guest; one direct share revocation closes all three within documented bounds, guest origin counters prove refused traffic never arrives, and re-sharing restores fresh admission with new lease artifacts. |
| `audi-ubuntu-fleet` | `machines/fleet/` | The same native Audi guest SSH scenarios on the Ubuntu guest image. |
| `ssh-bootstrap-fleet`, `ssh-bootstrap-ubuntu-fleet` | `machines/fleet/` | Customer clone/source restoration and resize with real SSH roster bootstrap; temporary outage, full readiness timeout, private-log retention, and authorized recovery preserving placement/data/account ownership on NixOS and Ubuntu. |
| `ssh-roster-matrix-fleet`, `ssh-roster-matrix-ubuntu-fleet` | `machines/fleet/scenarios/ssh-roster-matrix.py` | Nine-node Audi fleet retained-image matrix on NixOS and Ubuntu guests: stop/start, clone of a stopped source, resize restart and cross-host relocation, each followed by real per-user SSH proving exact durable name/UID/mode-0700 home and retained markers; guest account ledger compared directly to the PostgreSQL writer set after each leg; clone-only accounts are expired-but-retained; stale-regression and digest-mismatch roster feeds refuse mutation on a live guest; team removal closes an already-open stream within its lease. |
| `brady-release` | `release/` | Source-built independent proxy payload, pinned runtime and configuration rejection; does not start privileged listeners. |
| `brady-native-storage` | `machines/brady-network/` | Native ZFS preparation/pressure, transparent cache hits/ranges/recovery, secret bypass, stale pressure, actual quota/parent headroom and pool hysteresis. No Firecracker attribution claim. |
| `brady-fleet` | `machines/fleet/` | Real enrolled Marshall/Lilly/Firecracker HTTP/TLS, exact owner-attributed events, restart survival, unchanged legacy intent, real monitoring history and old-flow refusal after address reuse. |
| `brady-network` | `machines/brady-network/` | Packaged transparent HTTP/TLS, restricted socket capabilities, native firewall isolation, outage and log redaction. Veth peers; no Firecracker, attribution or ZFS claim. |
| `brady-flow` | `machines/brady-flow/` | Packaged read-only helper against real kernel TCP labels, retained old-flow labels and unlabeled-flow refusal. No TAP, TPROXY, owner attribution or Firecracker claim. |
| `brady-storage` | `evaluation/brady-storage.py` | Bounded subprocess output and refusal of changed parent identity, guest descendants or unowned cache datasets. No native ZFS claim. |
| `brady-configuration` | `evaluation/brady.nix` | Dedicated UID, namespace/credential wiring, monitoring role and invalid port/pool rejection. No native interception or ZFS claim. |
| `inception-runtime` | `evaluation/inception-*.py` | Private bootstrap identity, real local TLS preparation, retained workspace edits and bounded SMTP refresh; no physical VM or live mail claim. |
| `inception-proof-broker` | `evaluation/inception-proof-broker.py` | Packaged Audi and Python Unix proof exchange, peer identity, generation/proof mismatch and expiry; no native DNS propagation claim. |
| `inception` | `machines/inception/` | Native nesting prerequisite, two-disk development stack, persistence, real outer admission and inner lifecycle. See the Inception architecture review for executed outcomes and remaining limits. |
| `porsche-release` | `release/` | Independent source-built Porsche release and pinned runtime. |
| `porsche-configuration` | `evaluation/porsche.nix` | Service options, port separation and credential assertions. |
| `installer-trust` | `machines/installer-trust/` | Two NixOS machines: actual Marshall HTTPS script/artifacts, packaged Linux Lyra account proof through Porsche, first/repeat hashed trust, conflict/revocation preservation, revoked-account-key refusal and re-registration restore, four-way digest agreement, appended-byte upgrade preservation, served-digest-mismatch refusal, and PATH-shimmed unsupported-platform/Darwin-selection/shasum-fallback probes. Final guest connection is intentionally absent; no macOS runtime or guest acceptance. |
| `porsche-service` | `machines/porsche-service/` | Native SSH listener, fail-closed readiness without Marshall, metrics and service restart. |
| `porsche-secrets` | `machines/porsche-secrets/` | Encrypted credential delivery and custody. |
| `porsche-crash-dumps` | `machines/porsche-crash-dumps/` | Actual encrypted OTP crash capture. |
| `administrative-ssh` | `machines/administrative-ssh/` | Staged port migration with pinned administrative identity. |
| `audi-release` | `release/` | Source-built Audi payload, pinned runtime, shared protocol and absence of Marshall/Lilly application dependencies and privileged host-tool metadata; no running gateway claim. |
| `audi-relocation-fleet` | `machines/fleet/scenarios/audi-relocation.py` | Adds real relocation to Audi's fleet: stable names, strict destination gateway lookup, retained guest identity/data, interrupted streams and stale-source refusal. Runtime acceptance pending. |
| `audi-configuration` | `evaluation/audi.nix` | Gateway/admin/Porsche port separation and systemd credential wiring. |
| `audi-openssh` | `machines/audi-openssh/` | Generated client profile with real nested OpenSSH and verified HTTPS curl; separate guest trust, stale gateway keys and lookup failures. Uses stock sshd/HTTPS fixtures, not Marshall publication or Firecracker. |
| `audi-dns` | `machines/audi-dns/` | Packaged independent DNS role on UDP/TCP 53; empty replica SERVFAIL, external-zone refusal and restart. No publication replication. |
| `audi-service` | `machines/audi-service/` | Actual packaged Audi/Lilly startup, UID-bound connector and crash recovery, private credential/key custody, host identity persistence and invalid-credential rejection. No Marshall or Firecracker guest. |
| `audi-ingress-network` | `machines/audi-ingress/` | Packaged Lilly namespace sockets and actual nftables: marked SSH, unmarked/wrong-port denial, guest-to-host/lateral denial and unsolicited forwarding denial. Uses veth echo fixtures, not Firecracker guests. |
| `porsche-release` | `release/` | Source-built Porsche runtime, parser and configuration checks; excludes Ash/Oban/Ecto, other applications and privileged host tools. |
| `application-metrics` | `machines/application-metrics/` | Actual Marshall and Lilly periodic summaries through journald and native Fluent Bit output; no injected summaries, guests or live AWS. |
| `porsche-service` | `machines/porsche-service/` | Actual NixOS service startup, private key custody, separate administrative SSH, persistent host identity, invalid-credential rejection, private readiness socket, updater manifest wiring and actual aggregate emission through Fluent Bit; no Marshall or guest execution. |
| `porsche-crash-dumps` | `machines/porsche-crash-dumps/` | Actual encrypted service crashes, off-host decryption, private custody, configured byte/time bounds, count/age retention, metadata-only journal reports and weak/missing-key rejection. |
| `porsche-secrets` | `machines/porsche-secrets/` | Real Ash gateway rotation, encrypted SecretSpec/SOPS publication, Porsche readiness recovery, wrong-recipient rejection and failed-publication startup fencing. |
| `porsche-fleet` | `machines/fleet/` | Porsche variant of the real fleet: browser keys, native SSH lifecycle/sharing, and the existing three-Marshall/two-Lilly guest scenarios. The Porsche subtest covers clone relocation out and back with durable replay, guest-data and source-cleanup checks; later complete-suite capacity coverage remains independently timing-sensitive. |
| `cloning-fleet` | `machines/fleet/` | Isolated Porsche/cloning acceptance, including source creation, clone, two cross-host relocations returning the clone to its original host, exact request replay, real guest-data verification and old ZFS dataset cleanup. The scenario also covers OSS-profile cloning with its image removed from the catalog, retained image/profile/shape rows, native ZFS origin emptiness and GUID distinctness, guest-console divergent-write invisibility, stopped-source power invariance, public mid-copy `request cancel` cleanup and post-publication cancel refusal. |
| `clone-destination-loss` | `machines/clone-permutations/destination-loss.py` | Real fleet clone canceled while the destination host is crashed mid-receive: source restoration, retained holds/slots under physical uncertainty, exact recovery after rejoin and cancelled-request retry refusal. |
| `clone-marshall-restart` | `machines/clone-permutations/marshall-restart.py` | Real fleet clone surviving a whole-Marshall restart mid-copy with exactly one complete copy, plus one-slot-per-host arbitration between two-source clones with durable refusal and explicit retry. |
| `administrative-ssh` | `machines/administrative-ssh/` | Pinned administrative SSH and Nix store transport on selected ports, including staged handoff of port 22 to Porsche with administrative identity retained. |
| `porsche-configuration` | `evaluation/porsche.nix` | Administrative port preconditions, listener collision rejection and systemd credential wiring. |
| `access-configuration` | `evaluation/access.nix` | Typed fleet users, groups, admin policy, Mosh firewall, lingering and independent host-key generation. |
| `public-grafana` | `machines/public-grafana/` | Actual Grafana behind the production HTTPS proxy and perimeter: verified TLS, login/Host refusal, private backend refusal, 57-panel dashboard, WebSocket upgrade and validated reload. |
| `public-grafana-configuration` | `evaluation/public-grafana.nix` | Default-off and generated port configurations under both firewall backends; prerequisite, wildcard, zero-port, SSH and socket conflict refusal; ADR-0181 public HTTP-01 opt-in sharing the proxy perimeter entry. |
| `fleet-firewall-configuration` | `evaluation/fleet-firewall.nix` | Typed, commented source registry; trusted Tailscale ingress; exact TCP/UDP rules for nftables and iptables; malformed and duplicate address rejection; runtime-address listener chain, ordering and refusals (ADR-0232). |
| `fleet-addresses` | `machines/fleet-addresses/` | SOPS-delivered fleet addresses (ADR-0233) on nftables and iptables nodes: nothing admitted or addressed before decryption, runtime source grants and destination listeners, reload/restart refill, rotation, malformed-document closure, and the runtime uplink drop-in with its recovery copy. Test VLAN addresses; no Hetzner network claim. |
| `proxy-runtime-address` | `machines/proxy-runtime-address/` | Runtime listener addresses (ADR-0233): HAProxy binds only the published IPv4 on 443 and the relay socket drop-in only on 5443; empty, wildcard and malformed values leave both down and a corrected value restores them. Firewall disabled; perimeter covered by the fleet-firewall checks. |
| `access` | `machines/access/` | Real named SSH/sudo and Mosh terminal input on two hosts, user lingering, centralized keys and activation revocation. |
| `secret-reconciliation` | `evaluation/secrets.nix` | Actual SOPS recipient changes, revocation, payload preservation and safe publication; generated recipient/recovery-only and interrupted-rekey/retry histories, two-generation turnover ceremonies and direct full-turnover refusal pairs. |
| `backup-custody` | `evaluation/backup-custody.*` | Real runtime/Restic/SOPS composition: the zero-failure password key ceremony, the exact `repository`-label wedge after rotation without it with previous-generation recovery, and restore→decrypt→repository-access composition with the historical-generation refusal leg; synthetic custody only. |
| `guest-readiness` | `evaluation/guest-readiness.nix` | Guest readiness configuration, boot identity validation, live-probe failure refusal and local socket responses; no KVM/vsock transport claim. |
| `backup-types` | `evaluation/backup-types.nix` | Strict Python typing (ruff + ty), durable state/credential failure cases, cleanup replay and generated retention reference sets. |
| `backup-operators` | `evaluation/backup-operators.nix` | Generated operator histories against the real runtime and local encrypted Restic: complete reference/retention graphs, malformed-manifest matrix, credential custody refusals on every repository operation, generated SIGTERM/SIGKILL/timeout interruption histories per restore component and manifest-publication window, kill-mid-upload recovery, orphan grace, real concurrent prune-vs-restore lock semantics, and mid-restore credential swap. |
| `python-static` | `evaluation/python-static.nix` | Repository-wide Python formatting, linting and type checking with pinned ruff and ty; the same gate runs locally through prek. |
| `backup-configuration` | `evaluation/backup-configuration.nix` | Module defaults, jitter overrides, private credentials and independent cleanup wiring. |
| `guest-flush` | `evaluation/guest-flush.nix` | Bounded sync requests, boot identity and host-only transport checks. |
| `backup-recovery` | `machines/backups/` | Real ZFS and TLS S3 capture, configured remote PostgreSQL, outage preservation, isolated file/database restore, short retention and credential-independent cleanup. The restore drill also pins the operator-mode boot against the restored database: no serving listeners and no Oban queues, plugins, staging or peer leadership. |
| `backup-recovery` | `machines/backups/` | Real ZFS and TLS S3 capture, configured remote PostgreSQL, outage preservation, isolated file/database restore, short retention and credential-independent cleanup. Operators SIGKILL mid-upload reconciles through the cleanup unit with retained orphan grace; held host lock refuses operator reads while scheduled services skip; credential custody refusals apply through the real unit EnvironmentFile. |
| `guest-backups` | `machines/zfs-guest/backups.py` | Actual Firecracker flush without process interruption, stopped/unresponsive guests, restored disk data, transfer coexistence, foreign snapshot refusal and process loss after native snapshot creation. |
| `module-configuration` | `evaluation/module-configuration.nix` | Valid service combinations and rejection of incomplete options/budgets. |
| `sysctl` | `machines/sysctl/` | Explicit opt-in, effective BBR/fq, inherited resource/forwarding policy, connected TCP sockets and reboot persistence. |
| `nix-ld` | `machines/nix-ld/` | Host `programs.nix-ld` runs an unpackaged dynamically linked ELF through a login shell; the disabled stub loader refuses the same binary. No Firecracker claim. |
| `auto-update` | `machines/auto-update/` | Actual Git candidates, exact NixOS switches, phase failures, corrective commits and backoff. |
| `auto-update-compatibility` | `evaluation/auto-update-compatibility.nix` | Existing fixed updater assertions and generated key/authority histories through actual compatibility and preflight, including all serving baselines and inactive fallback; isolated seams do not establish activation. |
| `auto-update-custody` | `evaluation/auto-update-custody.nix` | Generated rotation-recovery and custody-mismatch histories through the actual updater state machine, real SecretSpec/SOPS staging and descriptor handoff inside a disposable uid-0 namespace: deterministic refusal backoff, verify-only recovery after operator switch, wedge label and post-fix recovery; world-model seams do not establish systemd or native activation. |
| `nix-gc-configuration` | `evaluation/nix-gc.nix` | Threshold-gated bounded store collection: opt-in units, script bounds and pinned Nix, typed option rejection and fleet default enablement. No guest or runtime GC claim. |
| `tailscale-configuration` | `evaluation/tailscale.nix` | Fleet profile runs the Tailscale daemon with networkd integration on every host fixture; service-only module imports stay opt-in. No live tailnet claim. |
| `storage-configuration` | `evaluation/storage-configuration.nix` | Mirrored layout, storage properties, budgets and installation boundaries. |
| `marshall-release`, `lilly-release` | `release/` | Actual source-built release payloads, runtime versions and application independence. |
| `smtp-relay` | `machines/smtp-relay/` | Actual Marshall mail through synchronous TLS forwarding, failure/retry, loopback isolation and SecretSpec/SOPS rotation. |
| `push-notifications` | `machines/push-notifications/` | Actual Marshall release pokes a fake Susan at the compiled origin over OS-trusted TLS: 503/503/200 sends once, 410 invalidates, bodies are signed ciphertext only, and the operator switch refuses registration. |
| `push-relay` | `machines/push-relay/` | Actual Marshall release delivers through the actual Susan release behind TLS at the compiled origin to fake APNs: Susan verifies Marshall's install signature, provider 503/503/200 sends once, only the device key opens what the provider received, and provider 410 invalidates the device. |
| `service-roles` | `machines/service-roles/` | Neither/either/both roles; three colocated Marshall instances, Lilly, resource limits and proxy failover. |
| `porsche-fleet` | `machines/fleet/` | Adds real native SSH management, browser approval, lifecycle, revocation and accepted-work recovery to the complete fleet scenarios. |
| `cloning-fleet` | `machines/fleet/` | Runs the Porsche and clone audit scenarios without the unrelated terminal/capacity scenario set. |
| `customer-isolation-fleet` | `machines/fleet/` | Six real guests across two Lilly hosts: Customer egress denial, unrestricted positive controls, spoofing/lateral denial, release/credential updates, daemon death and Customer stop/start. Sequential admission keeps capacity-race timing separate. |
| `fleet` | `machines/fleet/` | Nine machines, three Marshall instances, two Lilly hosts, six real guests, Lilly release/credential updates with retained processes/data/networking, browser sharing, isolation, capacity and recovery. |
| `secret-custody` | `machines/secret-custody/` | SecretSpec/SOPS delivery with Hegel-drawn EnvironmentFile roundtrips, permission/health invariants, engine-explored seal/recover/rotate/missing/restore interleavings, reboot identity stability, adoption refusal, host recipient rotation and replacement recovery. |
| `fleet` | `machines/fleet/` | Nine machines, three Marshall instances, two Lilly hosts, six real guests, Lilly release/credential updates with retained processes/data/networking, browser sharing, isolation, capacity (fixed and generated respending races) and recovery. |
| `secret-custody` | `machines/secret-custody/` | SecretSpec/SOPS delivery, permission/property checks, persistent host identity, recipient rotation and recovery. |
| `credential-rotation` | `machines/credential-rotation/` | Three Marshall machines, coordinated authority rotation, concurrent updater migrations, staged-secret consistency and compatible secret-only updates. |
| `acme-lookup` | `evaluation/acme-lookup.nix` | Actual lookup helper with local HTTP responders: all nine owner/ingress combinations, bounds, cancellation and credential isolation. |
| `acme-http01` | `machines/acme-http01/` | Three actual frontends and a separate Pebble/DNS validator, peer forwarding, concurrent renewal, HTTP redirects and failures. |
| `acme-route53` | `machines/acme-route53/` | Real ACME client with local DNS/Route 53/CA fixtures, TLS publication, renewal and failure recovery. |
| `native-zfs` | `machines/native-zfs/` | Real dataset identity, sparse accounting, policy, pressure and observation conflicts. |
| `zfs-lifecycle` | `machines/zfs-lifecycle/` | Owned sparse disks and interrupted create/copy/delete recovery. |
| `zfs-guest` | `machines/zfs-guest/` | Real Firecracker confinement, retained disks, flushed writes after simulated host loss and independent cleanup. |
| `guest-boot-profile` | `machines/zfs-guest/boot-profile.py` | Real Firecracker NixOS boot through trust and readiness, twice; asserts host line offsets and the guest boot profile (ADR-0154) and prints its marker lines. |
| `ubuntu-guest-boot-profile` | `machines/zfs-guest/boot-profile.py` | The same boot-profile measurement for the Ubuntu fixture image through trust delivery. |
| `zfs-guest-clone` | `machines/zfs-guest/clone-matrix.py` | Same-pool block-copy clones (ADR-0145): a clone after a completed 4 GiB resize with grown-disk capture and guest-shape checks, a chained clone whose first adopted copy becomes the next source, `bcloneused` growth and discard of a copied, unadopted destination; native origin emptiness, distinct GUIDs, divergent-write invisibility and deletion independence. |
| `zfs-namespace-cleanup` | `machines/zfs-guest/namespace-cleanup.py` | Real Firecracker deletion with late sandboxed mount copies, a live file holder and a surviving guest. |
| `zfs-transfer` | `machines/zfs-transfer/` | Native full and resumed streams of the single stopped-source snapshot (ADR-0155) between two block-backed pools, parentless resume-token validation, native-helper EOF cancellation/resume, Lilly staging receipt/ownership rejection, guarded intent, interrupted full disk adoption and ext4 data after source reclamation; no Lilly/SSH orchestration claim. |
| `ssh-transfer` | `machines/ssh-transfer/` | Production pinned SSH client and native pipe against real OpenSSH, 32 MiB integrity, authenticated-key delivery, permit fencing, wrong host/client key refusal and retired-key rejection; no native ZFS or Oban coordination claim. |
| `source-export` | `machines/source-export/` | Native owned single-snapshot full send, permit issuance/renewal/fencing, stale identity and removed-lineage descriptor rejection and blocked-sender revocation with process absence; no installed SSH or coordinator claim. |
| `export-endpoint` | `machines/export-endpoint/` | Installed restricted source service, native channel and ZFS send to another NixOS machine over pinned SSH; command rejection, listener-stop cancellation and typed live-listener source revocation with sender PID absence. Synthetic control distribution does not establish Marshall coordination or guest relocation. |
| `zfs-io` | `machines/zfs-io/` | Real pool-scoped traffic observations and uncertain-sample recovery. |
| `mirrored-installation` | `machines/mirrored-installation/` | Installer and installed UEFI boot, both surviving disks and persistent SSH identity. |
| `host-images` | `machines/host-images/` | Production-profile fixture disks through firmware, fresh identities, reboot and surviving disks. |
| `host-planning` | `evaluation/host-planning.py` | Complete inventories, EBS exclusion, budgets, erasure guards and binding/receipt refusal. |

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

```sh
nix flake check --no-build
nix build -L .#checks.x86_64-linux.sysctl
nix build -L .#checks.x86_64-linux.service-roles --extra-system-features nested-kvm
nix build -L .#checks.x86_64-linux.fleet --extra-system-features nested-kvm
nix flake check -L --extra-system-features nested-kvm
```

### Continuous integration

`ci.nix` wraps every exported check with `meta.ci = { enable, machine,
nestedKvm }`. A check is a machine test when it has a test driver, requires
`kvm`, or is listed as a machine aggregate; it is excluded from CI only by name
in `ci.nix` (the exclusion list is currently empty). GitHub Actions derives its
matrices by evaluation: `publish-cache.yml` builds every enabled non-machine
check and publishes it to Cachix, and `nixos-machine-tests.yml` fans out one
job per enabled machine test. Both selections in
`.github/scripts/select-checks.sh` start from `meta.ci` alone, never the
machine-test derivations: machine tests build guest images at evaluation time,
which belongs to each matrix job rather than to choosing the matrix, and
evaluating every fleet test together exhausts the runner's memory.
`select-checks.sh build` then evaluates every check not known to be a machine
test in isolation with `nix-eval-jobs`, so a check that fails to evaluate is
reported (and fails the run) without hiding the others. A machine test whose
derivation does not evaluate fails its own matrix job.

A scheduled or dispatched run is execution evidence only for the commit it
ran; a selected matrix entry is not a passing result.

Machine tests require a Linux builder with usable KVM. Nested-guest tests also
require nested virtualization and the `nested-kvm` feature. The build user needs
device access; declaring a feature does not provide it. See the
[runner guidance](../../../docs/operations/nixos.md#machine-checks). Fleet allocates roughly
24 GiB across its nine outer VMs; run large suites sequentially on this builder.
Retain each suite's timeouts and the framework's lint/type checks. An evaluation
or driver build alone does not establish a successful machine run.

For an interactive driver, build the suite's `.driver` attribute, for example
`nix build .#checks.x86_64-linux.fleet.driver`, then run
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

`nix build .#checks.x86_64-linux.account-lifecycle` runs a strictly typed bounded
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
