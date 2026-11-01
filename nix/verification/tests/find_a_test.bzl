# The curated "Find a test" entries of nix/verification/tests/README.md.
# buck/bxl/docs.bxl renders the table: one row per test target in the graph,
# in name order, with the location and behaviour recorded here (ADR-0269).
# Keys MUST name a machine test, a `//:check-<name>` target or a root check;
# `tools/docs --check` fails on a stale key or an out-of-date README.
FIND_A_TEST = {
    "access": {
        "location": "`machines/access/`",
        "description": "Real named SSH/sudo and Mosh terminal input on two hosts, user lingering, centralized keys and activation revocation.",
    },
    "access-configuration": {
        "location": "`evaluation/access.nix`",
        "description": "Typed fleet users, groups, admin policy, Mosh firewall, lingering and independent host-key generation.",
    },
    "acme-http01": {
        "location": "`machines/acme-http01/`",
        "description": "Three actual frontends and a separate Pebble/DNS validator, peer forwarding, concurrent renewal, HTTP redirects and failures.",
    },
    "acme-lookup": {
        "location": "`evaluation/acme-lookup.nix`",
        "description": "Actual lookup helper with local HTTP responders: all nine owner/ingress combinations, bounds, cancellation and credential isolation.",
    },
    "acme-route53": {
        "location": "`machines/acme-route53/`",
        "description": "Real ACME client with local DNS/Route 53/CA fixtures, TLS publication, renewal and failure recovery.",
    },
    "administrative-ssh": {
        "location": "`machines/administrative-ssh/`",
        "description": "Pinned administrative SSH and Nix store transport on selected ports, including staged handoff of port 22 to Porsche with administrative identity retained.",
    },
    "agent-cli-journey": {
        "location": "`machines/agent-cli-journey/`",
        "description": "Strictly typed ordinary-browser explicit approval, packaged CLI, real stopped NixOS guest wake/model/tool result, profile refusal and stale approval after UI sharing withdrawal. Execution and isolated-provider limits are recorded in the [CLI review](../../../docs/architecture/reviews/2026-09-25-agent-cli-verification.md).",
    },
    "application-metrics": {
        "location": "`machines/application-metrics/`",
        "description": "Actual Marshall and Lilly periodic summaries through journald and native Fluent Bit output; no injected summaries, guests or live AWS.",
    },
    "audi-configuration": {
        "location": "`evaluation/audi.nix`",
        "description": "Gateway/admin/Porsche port separation and systemd credential wiring.",
    },
    "audi-dns": {
        "location": "`machines/audi-dns/`",
        "description": "Packaged independent DNS role on UDP/TCP 53; empty replica SERVFAIL, external-zone refusal and restart. No publication replication.",
    },
    "audi-fleet": {
        "location": "`machines/fleet/`",
        "description": "Native NixOS guest SSH through Audi, per-user homes, registered keys, Cedar sharing and revocation, durable guest login reports and live-stream fencing.",
    },
    "audi-ingress-network": {
        "location": "`machines/audi-ingress/`",
        "description": "Packaged Lilly namespace sockets and actual nftables: marked SSH, unmarked/wrong-port denial, guest-to-host/lateral denial and unsolicited forwarding denial. Uses veth echo fixtures, not Firecracker guests.",
    },
    "audi-openssh": {
        "location": "`machines/audi-openssh/`",
        "description": "Generated client profile with real nested OpenSSH and verified HTTPS curl; separate guest trust, stale gateway keys and lookup failures. Uses stock sshd/HTTPS fixtures, not Marshall publication or Firecracker.",
    },
    "audi-private-pki": {
        "location": "`evaluation/private-pki.nix`",
        "description": "Offline fleet wildcard issuance, exact SANs, issuer constraints, 20/10/10-year lifetimes and runtime/recovery custody.",
    },
    "audi-release": {
        "location": "`release/`",
        "description": "Source-built Audi payload, pinned runtime, shared protocol and absence of Marshall/Lilly application dependencies and privileged host-tool metadata; no running gateway claim.",
    },
    "audi-relocation-fleet": {
        "location": "`machines/fleet/scenarios/audi-relocation.py`",
        "description": "Adds real relocation to Audi's fleet: stable names, strict destination gateway lookup, retained guest identity/data, interrupted streams and stale-source refusal. Runtime acceptance pending.",
    },
    "audi-service": {
        "location": "`machines/audi-service/`",
        "description": "Actual packaged Audi/Lilly startup, UID-bound connector and crash recovery, private credential/key custody, host identity persistence and invalid-credential rejection. No Marshall or Firecracker guest.",
    },
    "audi-ubuntu-fleet": {
        "location": "`machines/fleet/`",
        "description": "The same native Audi guest SSH scenarios on the Ubuntu guest image.",
    },
    "auto-update": {
        "location": "`machines/auto-update/`",
        "description": "Actual Git candidates, exact NixOS switches, phase failures, corrective commits and backoff.",
    },
    "auto-update-compatibility": {
        "location": "`evaluation/auto-update-compatibility.nix`",
        "description": "Existing fixed updater assertions and generated key/authority histories through actual compatibility and preflight, including all serving baselines and inactive fallback; isolated seams do not establish activation.",
    },
    "auto-update-custody": {
        "location": "`evaluation/auto-update-custody.nix`",
        "description": "Generated rotation-recovery and custody-mismatch histories through the actual updater state machine, real SecretSpec/SOPS staging and descriptor handoff inside a disposable uid-0 namespace: deterministic refusal backoff, verify-only recovery after operator switch, wedge label and post-fix recovery; world-model seams do not establish systemd or native activation.",
    },
    "backup-configuration": {
        "location": "`evaluation/backup-configuration.nix`",
        "description": "Module defaults, jitter overrides, private credentials and independent cleanup wiring.",
    },
    "backup-custody": {
        "location": "`evaluation/backup-custody.*`",
        "description": "Real runtime/Restic/SOPS composition: the zero-failure password key ceremony, the exact `repository`-label wedge after rotation without it with previous-generation recovery, and restore→decrypt→repository-access composition with the historical-generation refusal leg; synthetic custody only.",
    },
    "backup-operators": {
        "location": "`evaluation/backup-operators.nix`",
        "description": "Generated operator histories against the real runtime and local encrypted Restic: complete reference/retention graphs, malformed-manifest matrix, credential custody refusals on every repository operation, generated SIGTERM/SIGKILL/timeout interruption histories per restore component and manifest-publication window, kill-mid-upload recovery, orphan grace, real concurrent prune-vs-restore lock semantics, and mid-restore credential swap.",
    },
    "backup-recovery": {
        "location": "`machines/backups/`",
        "description": "Real ZFS and TLS S3 capture, configured remote PostgreSQL, outage preservation, isolated file/database restore, short retention and credential-independent cleanup. Operators SIGKILL mid-upload reconciles through the cleanup unit with retained orphan grace; held host lock refuses operator reads while scheduled services skip; credential custody refusals apply through the real unit EnvironmentFile.",
    },
    "backup-types": {
        "location": "`evaluation/backup-types.nix`",
        "description": "Strict Python typing (ruff + ty), durable state/credential failure cases, cleanup replay and generated retention reference sets.",
    },
    "brady-configuration": {
        "location": "`evaluation/brady.nix`",
        "description": "Dedicated UID, namespace/credential wiring, monitoring role and invalid port/pool rejection. No native interception or ZFS claim.",
    },
    "brady-fleet": {
        "location": "`machines/fleet/`",
        "description": "Real enrolled Marshall/Lilly/Firecracker HTTP/TLS, exact owner-attributed events, restart survival, unchanged legacy intent, real monitoring history and old-flow refusal after address reuse.",
    },
    "brady-flow": {
        "location": "`machines/brady-flow/`",
        "description": "Packaged read-only helper against real kernel TCP labels, retained old-flow labels and unlabeled-flow refusal. No TAP, TPROXY, owner attribution or Firecracker claim.",
    },
    "brady-native-storage": {
        "location": "`machines/brady-network/`",
        "description": "Native ZFS preparation/pressure, transparent cache hits/ranges/recovery, secret bypass, stale pressure, actual quota/parent headroom and pool hysteresis. No Firecracker attribution claim.",
    },
    "brady-network": {
        "location": "`machines/brady-network/`",
        "description": "Packaged transparent HTTP/TLS, restricted socket capabilities, native firewall isolation, outage and log redaction. Veth peers; no Firecracker, attribution or ZFS claim.",
    },
    "brady-release": {
        "location": "`release/`",
        "description": "Source-built independent proxy payload, pinned runtime and configuration rejection; does not start privileged listeners.",
    },
    "brady-storage": {
        "location": "`evaluation/brady-storage.py`",
        "description": "Bounded subprocess output, exact combined pressure properties, start-anchored one-second sampling and refusal of changed parent identity, guest descendants or unowned cache datasets. No native ZFS claim.",
    },
    "clone-destination-loss": {
        "location": "`machines/clone-permutations/destination-loss.py`",
        "description": "Real fleet clone canceled while the destination host is crashed mid-receive: source restoration, retained holds/slots under physical uncertainty, exact recovery after rejoin and cancelled-request retry refusal.",
    },
    "clone-marshall-restart": {
        "location": "`machines/clone-permutations/marshall-restart.py`",
        "description": "Real fleet clone surviving a whole-Marshall restart mid-copy with exactly one complete copy, plus one-slot-per-host arbitration between two-source clones with durable refusal and explicit retry.",
    },
    "cloning-fleet": {
        "location": "`machines/fleet/`",
        "description": "Isolated Porsche/cloning acceptance, including source creation, clone, two cross-host relocations returning the clone to its original host, exact request replay, real guest-data verification and old ZFS dataset cleanup. The scenario also covers OSS-profile cloning with its image removed from the catalog, retained image/profile/shape rows, native ZFS origin emptiness and GUID distinctness, guest-console divergent-write invisibility, stopped-source power invariance, public mid-copy `request cancel` cleanup and post-publication cancel refusal.",
    },
    "credential-rotation": {
        "location": "`machines/credential-rotation/`",
        "description": "Three Marshall machines, coordinated authority rotation, concurrent updater migrations, staged-secret consistency and compatible secret-only updates.",
    },
    "credential-self-service-browser": {
        "location": "`machines/credential-self-service/`",
        "description": "Single-VM packaged Marshall/HAProxy/Chromium with virtual WebAuthn: enroll two passkeys, rename, remove non-proving (session/elevation survive), remove proving (immediate mounted elevation loss), ordinary last removal (MFA disabled, tokens revoked, mounted session invalidated), administrator last-passkey refusal and post-sign-out stale refusal, with exact PostgreSQL assertions.",
    },
    "customer-isolation-fleet": {
        "location": "`machines/fleet/`",
        "description": "Six real guests across two Lilly hosts: Customer egress denial, unrestricted positive controls, spoofing/lateral denial, release/credential updates, daemon death and Customer stop/start. Sequential admission keeps capacity-race timing separate.",
    },
    "database-recovery": {
        "location": "`machines/database-recovery/`",
        "description": "Two machines with production release Repo parameters and verified PostgreSQL TLS. Requires one holder and three real queued lock waiters before machine loss, preserves the 20-second holder/35-second connection bounds, and checks an independent healthy active query. Execution is recorded separately; this is not full terminal recovery acceptance.",
    },
    "executor-loss": {
        "location": "`machines/executor-loss/`",
        "description": "Strict real guest started-effect interruption, exact process cleanup, uncertain outcome, fresh executor fence, ordinary browser-approved CLI retry and withdrawal. Execution status and pre-start gap are recorded in the [loss review](../../../docs/architecture/reviews/2026-09-26-executor-loss-histories.md).",
    },
    "export-endpoint": {
        "location": "`machines/export-endpoint/`",
        "description": "Installed restricted source service, native channel and ZFS send to another NixOS machine over pinned SSH; command rejection, listener-stop cancellation and typed live-listener source revocation with sender PID absence. Synthetic control distribution does not establish Marshall coordination or guest relocation.",
    },
    "firecracker-patch-tests": {
        "location": "`evaluation/firecracker-patch-tests.nix`",
        "description": "Unit coverage for PVH RSDP, ACPI timer, Hyper-V leaves, CMOS, PCI BAR relocation and configuration notifications, virtio reset/scatter-gather and vsock indirect descriptors. No native guest or Windows acceptance.",
    },
    "firecracker-vmm": {
        "location": "`evaluation/firecracker-vmm.nix`",
        "description": "Patched static Firecracker identity, jailer pair and `--enable-pci` surface used by firmware guests. Structural package evidence; no guest boot.",
    },
    "fleet": {
        "location": "`machines/fleet/`",
        "description": "Nine machines, three Marshall instances, two Lilly hosts, six real guests, Lilly release/credential updates with retained processes/data/networking, browser sharing, isolation, capacity (fixed and generated respending races) and recovery.",
    },
    "fleet-addresses": {
        "location": "`machines/fleet-addresses/`",
        "description": "SOPS-delivered fleet addresses (ADR-0233) on nftables and iptables nodes: nothing admitted or addressed before decryption, runtime source grants and destination listeners, reload/restart refill, rotation, malformed-document closure, and the runtime uplink drop-in with its recovery copy. Test VLAN addresses; no Hetzner network claim.",
    },
    "fleet-firewall-configuration": {
        "location": "`evaluation/fleet-firewall.nix`",
        "description": "Typed, commented source registry; trusted Tailscale ingress; exact TCP/UDP rules for nftables and iptables; malformed and duplicate address rejection; runtime-address listener chain, ordering and refusals (ADR-0232).",
    },
    "fleet-guest-trust": {
        "location": "`machines/fleet-guest-trust/`",
        "description": "Strict composed driver; both distributions on actual ZFS/Firecracker, current trust receipts, wrong-boot refusal with positive controls, a bounded wrong/forged/expired delivery sweep exhausted to completed peer-EOF refusals, trust/network/SSH order, local HTTP and retained-data restart. Execution is recorded separately in the campaign reviews; no full feature-fleet matrix acceptance.",
    },
    "fleet-guest-trust-configuration": {
        "location": "`evaluation/fleet-guest-trust.nix`",
        "description": "Evaluates all seven feature-fleet variants: exact retained names and complete feature fragments, independent trust setup, required DNS/private services and SSH CA signers, image counts and matching enrollment descriptors. Configuration evidence only.",
    },
    "fleet-roster": {
        "location": "`evaluation/fleet-roster.nix`",
        "description": "The `nix/policy/fleet` host, service and port roster: reviewed fleet accepted, derived tunnel ports, and rejection of duplicate ports, undeclared or missing hosts, non-reciprocal or unknown peers, misplaced control plane or telemetry worker, builder-free build participants and invalid service placement.",
    },
    "foreign-linux-guest-unit": {
        "location": "`evaluation/foreign-linux-guests.nix`",
        "description": "Evaluates pinned Arch Linux and AlmaLinux root assembly, version-4 manifest shape and distinct source markers. Evaluation only; it does not download, boot or establish distro-native guest-agent behavior.",
    },
    "foreign-linux-pam-helper": {
        "location": "`evaluation/foreign-linux-pam-helper.nix`",
        "description": "Runs the pinned PAM helper installer in an isolated VM/chroot, checks exact root-owned mode-04755 bytes and unsafe-node refusals, and verifies root PAM account success/refusals on nosuid runtime storage. It does not establish foreign guest boot, SSH login or nonroot setuid elevation.",
    },
    "galileo-service": {
        "location": "`machines/galileo-service/`",
        "description": "Packaged Audi-to-Galileo across two NixOS machines, verified TLS, exact uploads, query/method denial, bounded source/destination stalls, binding-change fencing, authority outage and 64-request concurrent load. Lilly binding and Marshall authority are controlled fixtures; no real attachment, relocation, peer gateway or Firecracker claim.",
    },
    "guest-backups": {
        "location": "`machines/zfs-guest/backups.py`",
        "description": "Actual Firecracker flush without process interruption, stopped/unresponsive guests, restored disk data, transfer coexistence, foreign snapshot refusal and process loss after native snapshot creation.",
    },
    "guest-boot-profile": {
        "location": "`machines/zfs-guest/boot-profile.py`",
        "description": "Real Firecracker NixOS boot through trust and readiness, twice; asserts host line offsets and the guest boot profile (ADR-0154) and prints its marker lines.",
    },
    "guest-cli-recovery": {
        "location": "`machines/guest-cli-recovery/`",
        "description": "Strict real NixOS guest candidate spawn/registration failure recovery, restored inode/digest, fresh Marshall fence and operator tool result. Direct candidate injection bypasses delivery; execution status is recorded in the [recovery review](../../../docs/architecture/reviews/2026-09-26-guest-cli-recovery.md). Also covers an interrupted artifact fetch: partial staging never activates and one real check reconverges without poisoning the rejection cooldown.",
    },
    "guest-cli-recovery-ubuntu": {
        "location": "`machines/guest-cli-recovery/` (ubuntu composition)",
        "description": "The same strict candidate failure/interrupted-fetch recovery journey against the Ubuntu guest image.",
    },
    "guest-flush": {
        "location": "`evaluation/guest-flush.nix`",
        "description": "Bounded sync requests, boot identity and host-only transport checks.",
    },
    "guest-readiness": {
        "location": "`evaluation/guest-readiness.nix`",
        "description": "Guest readiness configuration, boot identity validation, live-probe failure refusal and local socket responses; no KVM/vsock transport claim.",
    },
    "host-images": {
        "location": "`machines/host-images/`",
        "description": "Production-profile fixture disks through firmware, fresh identities, reboot and surviving disks.",
    },
    "host-planning": {
        "location": "`evaluation/host-planning.py`",
        "description": "Complete inventories, EBS exclusion, budgets, erasure guards and binding/receipt refusal.",
    },
    "host-replacement": {
        "location": "`machines/fleet/`",
        "description": "Nine-node Audi fleet journey: enrolled host serves real nested guest private services (llm.internal) with Marshall credentials, retirement runs the real drain chain with the row persisted, stale compute and Ziggy credentials are refused over the real TLS listener, and the replacement host enrolls disabled through the pinned protected SSH bridge with a fresh machine identity, name and storage GUIDs, then restores service after readiness-gated enable. Not claimed: physical providers, production DNS/CA/load, multi-region. Execution scope is recorded in the [replacement review](../../../docs/architecture/reviews/2026-09-27-host-replacement.md).",
    },
    "inception": {
        "location": "`machines/inception/`",
        "description": "Native nesting prerequisite, two-disk development stack, persistence, real outer admission and inner lifecycle. See the Inception architecture review for executed outcomes and remaining limits.",
    },
    "inception-proof-broker": {
        "location": "`evaluation/inception-proof-broker.py`",
        "description": "Packaged Audi and Python Unix proof exchange, peer identity, generation/proof mismatch and expiry; no native DNS propagation claim.",
    },
    "inception-runtime": {
        "location": "`evaluation/inception-*.py`",
        "description": "Private bootstrap identity, real local TLS preparation, retained workspace edits and bounded SMTP refresh; no physical VM or live mail claim.",
    },
    "installer-trust": {
        "location": "`machines/installer-trust/`",
        "description": "Two NixOS machines: actual Marshall HTTPS script/artifacts, packaged Linux Lyra account proof through Porsche, first/repeat hashed trust, conflict/revocation preservation, revoked-account-key refusal and re-registration restore, four-way digest agreement, appended-byte upgrade preservation, served-digest-mismatch refusal, and PATH-shimmed unsupported-platform/Darwin-selection/shasum-fallback probes. Final guest connection is intentionally absent; no macOS runtime or guest acceptance.",
    },
    "lilly-release": {
        "location": "`release/`",
        "description": "Actual source-built release payloads, runtime versions and application independence.",
    },
    "marshall-release": {
        "location": "`release/`",
        "description": "Actual source-built release payloads, runtime versions and application independence.",
    },
    "mfa-login-browser": {
        "location": "`machines/mfa-login/`",
        "description": "Three colocated packaged Marshall replicas over verified TLS; subsequent magic-link and remembered MFA, actual backend/WebSocket observations, admin revocation and copied-cookie refusal, plus an SQL-backdated expired-ceremony refusal with a fresh cross-replica retry. Virtual authenticators only; execution is recorded in the campaign review.",
    },
    "mirrored-installation": {
        "location": "`machines/mirrored-installation/`",
        "description": "Installer and installed UEFI boot, both surviving disks and persistent SSH identity.",
    },
    "module-configuration": {
        "location": "`evaluation/module-configuration.nix`",
        "description": "Valid service combinations and rejection of incomplete options/budgets.",
    },
    "native-fixture-unit": {
        "location": "`evaluation/native-fixtures.nix`",
        "description": "Pinned Python/Git/OpenSSH/OpenSSL/FAT tools execute host parser, refusal, authority, cleanup, Git and EFI inventory boundaries. Recorded 59-test pass; no native boot, kernel transport, isolation, growth or admission claim.",
    },
    "native-freebsd-crash-recovery": {
        "location": "`machines/native-services/default.nix`",
        "description": "Actual first-boot VMM SIGKILL, restart of the same disk under fresh MMDS and boot identity, retained synchronized home data, native filesystem recovery, stale-authority refusal and a final clean exit. The final reviewed image `5022d714` passed all 8 crash checks and both complete service oracles in 224 seconds after the native UFS suspension/resume flush correction. No interrupted-write durability, physical recovery or admission claim.",
    },
    "native-freebsd-growth": {
        "location": "`machines/native-services/default.nix`",
        "description": "Three native boots with two host-side disk increases, retained data, root-capacity increases, exact nonroot GPT/file inventories with only bounded root EFI NvVars mutable, untouched foreign disk and unprivileged helper refusal. The final reviewed image `5022d714` passed three distinct clean boots and complete service oracles. No OmniOS, interrupted-growth, crash-recovery or admission claim from this variant.",
    },
    "native-freebsd-isolation": {
        "location": "`machines/native-isolation/driver.py`",
        "description": "Real native Standard IPv4 against packaged Lilly router and TAP source guard, reachable TCP sink controls before policy, public connection after policy, private/protected/sibling/local refusals and an unassigned-source drop counter over two clean boots. The final reviewed image `5022d714` passed two clean boots with independent policy receipts and complete service oracles. The sibling is a Linux sink, not another native VM/TAP; no OmniOS, jail, physical-host, multi-host or admission claim.",
    },
    "native-freebsd-recovery": {
        "location": "`machines/native-services/default.nix`",
        "description": "Actual native daemon termination, readiness withheld while its executable cannot restart, exact mode restoration, supervisor replacement and same-boot protocol recovery over two clean boots. The final reviewed image `5022d714` passed both boots with per-boot recovery receipts and complete service oracles. No whole-guest crash, storage crash-durability, physical recovery or admission claim from this variant.",
    },
    "native-freebsd-reset": {
        "location": "`machines/native-reset/default.nix`",
        "description": "Test-only guest with a peerless identity socket and pending accept/read/write during a private fixture Unix API pause/full-snapshot/resume. The formal nested-KVM gate passed in 232 seconds with exact test image/kernel/probe/firmware/VMM receipts, idle ECONNRESET, blocked-operation errors and fresh-socket refusal until a new VM. No DMA/race stress, physical, service/recovery or admission claim.",
    },
    "native-freebsd-services": {
        "location": "`machines/native-services/default.nix`",
        "description": "Native MMDS/network bootstrap, kernel/trust/flush/refusals and complete readiness with isolated HTTPS/SSH/Git/DNS authority; certified SSH, fenced execution, actual checkout and PTY over two clean boots. The final reviewed image `5022d714`, including canonical roots, SSH and blocking UFS flush, passed all 22 service checks. No isolation, crash recovery or admission claim from this variant.",
    },
    "native-freebsd-transport": {
        "location": "`machines/native-transport/default.nix`",
        "description": "Nested-KVM boot of the actual candidate kernel and patched Firecracker, compiled transport identity, host CID, malformed/disconnected histories, reconnects and exact echoes through 1 MiB. The final ordinary catalog gate passed in 246 seconds on exact test image `19658a4a`, with immutable receipt and token/firmware/VMM hashes in the native review. This image is distinct from reset/service images; no production service or image admission claim.",
    },
    "native-image-promotion": {
        "location": "`../../domains/artifacts/guest/native-promotion/`",
        "description": "Checks exact image/firmware/disk identity, hash-bound five-scenario native evidence and immutable production registry admission; refuses stale/foreign/incomplete evidence. Host verifier tests only; native machine execution remains separate evidence.",
    },
    "native-omnios-crash-recovery": {
        "location": "`machines/native-services/default.nix`",
        "description": "OmniOS/illumos first-boot SIGKILL, fresh authority, retained synchronized data, completed ZFS scrub and clean exit. Interrupted-write durability, physical recovery and admission remain outside scope.",
    },
    "native-omnios-growth": {
        "location": "`machines/native-services/default.nix`",
        "description": "OmniOS/illumos three-boot, two-expansion ZFS growth fixture with retained data and foreign-disk checks. Interrupted growth, physical recovery and admission remain outside scope.",
    },
    "native-omnios-isolation": {
        "location": "`machines/native-services/default.nix`",
        "description": "OmniOS/illumos service fixture with the native isolation policy variant. The machine scope is limited to the exercised IPv4 routing and guard boundary; physical, jail and multi-host isolation remain unclaimed.",
    },
    "native-omnios-recovery": {
        "location": "`machines/native-services/default.nix`",
        "description": "OmniOS/illumos supervised daemon recovery fixture over two clean boots, with readiness withholding and same-boot protocol recovery. Whole-guest crash durability and admission remain outside scope.",
    },
    "native-omnios-reset": {
        "location": "`machines/native-services/omnios-reset-driver.py`",
        "description": "Nested-KVM OmniOS API pause/full-snapshot/resume after a complete service baseline on the same candidate: three 204 API responses, idle/read/write refusals, original listener reuse and current-CID revalidation. Passed in 721.76 seconds on disk `1db6ac13`. No service restoration, clean shutdown, DMA/race stress or admission claim.",
    },
    "native-omnios-services": {
        "location": "`machines/native-services/default.nix`",
        "description": "OmniOS/illumos complete native service fixture on the separately promoted image, with current boot identity, trust, workspace, terminal, SSH, executor fencing and clean shutdown. The explicit admitted-image test opt-in keeps the receipt `native_admission=false`; no production admission follows.",
    },
    "native-omnios-transport": {
        "location": "`machines/native-services/ordinary-transport-driver.py`",
        "description": "Nested-KVM OmniOS ordinary transport over two clean boots on the non-admitted Nix KVM-assembled `omnios-image-candidate`: complete service baseline, exact token, CIDs 3/2, malformed-length refusal, disconnected-history recovery, nine echoes through 1 MiB, same-boot production restoration and loaded viosock/sockvsock file digests equal to the assembly receipt. Passed in 761.59 seconds, and in 681.84 seconds on the final formatted driver, on disk `1db6ac13` after an earlier unexplained `shutdown-send` timeout on the same inputs. No reset, DMA, wrong-CID or admission claim.",
    },
    "native-os-guest-unit": {
        "location": "`evaluation/native-os-guests.nix`",
        "description": "Evaluates pinned FreeBSD 14.3 and OmniOS r151050 source pins, the explicit illumos downstream constructor, native artifact assembly and v6 manifest fields. Evaluation only; it does not download, boot or establish native guest isolation.",
    },
    "native-reset-probes": {
        "location": "`evaluation/native-reset-probes.nix`",
        "description": "Cross-builds isolated C probes for both native OS families; source/ABI evidence only.",
    },
    "native-vsock-core": {
        "location": "`../../domains/artifacts/guest/native-kernels/common/default.nix`",
        "description": "Shared C wire parser, credit and half-close properties under ASan/UBSan, including 400,000 generated transitions. No socket, queue or native driver acceptance.",
    },
    "native-zfs": {
        "location": "`machines/native-zfs/`",
        "description": "Real dataset identity, sparse accounting, policy, pressure and observation conflicts.",
    },
    "nix-compact-configuration": {
        "location": "`../packages/nix-compact/configuration-check.nix`",
        "description": "NixOS package selection, opt-out, explicit override and unchanged daemon libraries.",
    },
    "nix-compact-core": {
        "location": "pinned `nix-compact` flake `lib.mkCoreCheck`",
        "description": "C++ classification/archive regressions and Hegel properties for lossless capture, structured severity, budgets, interleaving, pagination and retention.",
    },
    "nix-compact-native": {
        "location": "pinned `nix-compact` flake `lib.mkNativeCheck`",
        "description": "Development-input native Nix: Hegel real-build status/capture checks, clean stdout, TTY, Unix daemon, remote protocols, heartbeat and SIGINT.",
    },
    "nix-compact-native-host": {
        "location": "pinned `nix-compact` flake `lib.mkNativeCheck`",
        "description": "The same native checks against the stable NixOS package input.",
    },
    "nix-gc-configuration": {
        "location": "`evaluation/nix-gc.nix`",
        "description": "Threshold-gated bounded store collection: opt-in units, script bounds and pinned Nix, typed option rejection and fleet default enablement. No guest or runtime GC claim.",
    },
    "nix-ld": {
        "location": "`machines/nix-ld/`",
        "description": "Host `programs.nix-ld` runs an unpackaged dynamically linked ELF through a login shell; the disabled stub loader refuses the same binary. No Firecracker claim.",
    },
    "porsche-configuration": {
        "location": "`evaluation/porsche.nix`",
        "description": "Administrative port preconditions, listener collision rejection and systemd credential wiring.",
    },
    "porsche-crash-dumps": {
        "location": "`machines/porsche-crash-dumps/`",
        "description": "Actual encrypted service crashes, off-host decryption, private custody, configured byte/time bounds, count/age retention, metadata-only journal reports and weak/missing-key rejection.",
    },
    "porsche-fleet": {
        "location": "`machines/fleet/`",
        "description": "Porsche variant of the real fleet: browser keys, native SSH lifecycle/sharing, and the existing three-Marshall/two-Lilly guest scenarios. The Porsche subtest covers clone relocation out and back with durable replay, guest-data and source-cleanup checks; later complete-suite capacity coverage remains independently timing-sensitive.",
    },
    "porsche-release": {
        "location": "`release/`",
        "description": "Source-built Porsche runtime, parser and configuration checks; excludes Ash/Oban/Ecto, other applications and privileged host tools.",
    },
    "porsche-secrets": {
        "location": "`machines/porsche-secrets/`",
        "description": "Real Ash gateway rotation, encrypted SecretSpec/SOPS publication, Porsche readiness recovery, wrong-recipient rejection and failed-publication startup fencing.",
    },
    "porsche-service": {
        "location": "`machines/porsche-service/`",
        "description": "Actual NixOS service startup, private key custody, separate administrative SSH, persistent host identity, invalid-credential rejection, private readiness socket, updater manifest wiring and actual aggregate emission through Fluent Bit; no Marshall or guest execution.",
    },
    "private-services-guest": {
        "location": "`evaluation/private-services.nix`",
        "description": "Explicit public-root trust, private-key rejection and split DNS ordering.",
    },
    "private-services-network": {
        "location": "`machines/private-services/`",
        "description": "Real Audi DNS/TLS and Lilly nftables in isolated namespaces; no Firecracker claim.",
    },
    "proxy-runtime-address": {
        "location": "`machines/proxy-runtime-address/`",
        "description": "Runtime listener addresses (ADR-0233): HAProxy binds only the published IPv4 on 443 and the relay socket drop-in only on 5443; empty, wildcard and malformed values leave both down and a corrected value restores them. Firewall disabled; perimeter covered by the fleet-firewall checks.",
    },
    "public-grafana": {
        "location": "`machines/public-grafana/`",
        "description": "Actual Grafana behind the production HTTPS proxy and perimeter: verified TLS, login/Host refusal, private backend refusal, 57-panel dashboard, WebSocket upgrade and validated reload.",
    },
    "public-grafana-configuration": {
        "location": "`evaluation/public-grafana.nix`",
        "description": "Default-off and generated port configurations under both firewall backends; prerequisite, wildcard, zero-port, SSH and socket conflict refusal; ADR-0181 public HTTP-01 opt-in sharing the proxy perimeter entry.",
    },
    "push-notifications": {
        "location": "`machines/push-notifications/`",
        "description": "Actual Marshall release pokes a fake Susan at the compiled origin over OS-trusted TLS: 503/503/200 sends once, 410 invalidates, bodies are signed ciphertext only, and the operator switch refuses registration.",
    },
    "push-relay": {
        "location": "`machines/push-relay/`",
        "description": "Actual Marshall release delivers through the actual Susan release behind TLS at the compiled origin to fake APNs: Susan verifies Marshall's install signature, provider 503/503/200 sends once, only the device key opens what the provider received, and provider 410 invalidates the device.",
    },
    "py-static": {
        "location": "`buck/python.bzl`",
        "description": "Repository-wide Python formatting, linting and type checking with pinned ruff and ty; the same gate runs locally through prek.",
    },
    "remote-builders": {
        "location": "`machines/remote-builders/`",
        "description": "Actual two-machine cache substitution, local-build placement, SSH restrictions, private SOPS delivery, rotation and outage fallback.",
    },
    "remote-builders-configuration": {
        "location": "`evaluation/remote-builders.nix`",
        "description": "Reciprocal cache-only configuration, self exclusion, no build delegation, cache preservation, access and invalid inputs.",
    },
    "resize-browser": {
        "location": "`machines/resize/`",
        "description": "Typed nine-node Audi-compatible fleet: browser draft/reload and stale/foreign refusal; running/stopped resizing with real Firecracker data, block/filesystem and CPU/memory probes. See [execution scope](../../../docs/architecture/reviews/2026-09-25-resize-verification.md).",
    },
    "secret-custody": {
        "location": "`machines/secret-custody/`",
        "description": "SecretSpec/SOPS delivery with Hegel-drawn EnvironmentFile roundtrips, permission/health invariants, engine-explored seal/recover/rotate/missing/restore interleavings, reboot identity stability, adoption refusal, host recipient rotation and replacement recovery.",
    },
    "secret-reconciliation": {
        "location": "`evaluation/secrets.nix`",
        "description": "Actual SOPS recipient changes, revocation, payload preservation and safe publication; generated recipient/recovery-only and interrupted-rekey/retry histories, two-generation turnover ceremonies and direct full-turnover refusal pairs.",
    },
    "service-roles": {
        "location": "`machines/service-roles/`",
        "description": "Neither/either/both roles; three colocated Marshall instances, Lilly, resource limits and proxy failover.",
    },
    "sharing-surfaces": {
        "location": "`machines/fleet/` + `machines/sharing-surfaces/`",
        "description": "Nine-node Audi fleet: one member concurrently holds live Audi SSH, a shared read-only browser terminal and private web streams on a nested guest; one direct share revocation closes all three within documented bounds, guest origin counters prove refused traffic never arrives, and re-sharing restores fresh admission with new lease artifacts.",
    },
    "smtp-relay": {
        "location": "`machines/smtp-relay/`",
        "description": "Actual Marshall mail through synchronous TLS forwarding, failure/retry, loopback isolation and SecretSpec/SOPS rotation.",
    },
    "source-export": {
        "location": "`machines/source-export/`",
        "description": "Native owned single-snapshot full send, permit issuance/renewal/fencing, stale identity and removed-lineage descriptor rejection and blocked-sender revocation with process absence; no installed SSH or coordinator claim.",
    },
    "ssh-bootstrap-fleet": {
        "location": "`machines/fleet/`",
        "description": "Customer clone/source restoration and resize with real SSH roster bootstrap; temporary outage, full readiness timeout, private-log retention, and authorized recovery preserving placement/data/account ownership on NixOS and Ubuntu.",
    },
    "ssh-bootstrap-ubuntu-fleet": {
        "location": "`machines/fleet/`",
        "description": "Customer clone/source restoration and resize with real SSH roster bootstrap; temporary outage, full readiness timeout, private-log retention, and authorized recovery preserving placement/data/account ownership on NixOS and Ubuntu.",
    },
    "ssh-roster-matrix-fleet": {
        "location": "`machines/fleet/scenarios/ssh-roster-matrix.py`",
        "description": "Nine-node Audi fleet retained-image matrix on NixOS and Ubuntu guests: stop/start, clone of a stopped source, resize restart and cross-host relocation, each followed by real per-user SSH proving exact durable name/UID/mode-0700 home and retained markers; guest account ledger compared directly to the PostgreSQL writer set after each leg; clone-only accounts are expired-but-retained; stale-regression and digest-mismatch roster feeds refuse mutation on a live guest; team removal closes an already-open stream within its lease.",
    },
    "ssh-roster-matrix-ubuntu-fleet": {
        "location": "`machines/fleet/scenarios/ssh-roster-matrix.py`",
        "description": "Nine-node Audi fleet retained-image matrix on NixOS and Ubuntu guests: stop/start, clone of a stopped source, resize restart and cross-host relocation, each followed by real per-user SSH proving exact durable name/UID/mode-0700 home and retained markers; guest account ledger compared directly to the PostgreSQL writer set after each leg; clone-only accounts are expired-but-retained; stale-regression and digest-mismatch roster feeds refuse mutation on a live guest; team removal closes an already-open stream within its lease.",
    },
    "ssh-transfer": {
        "location": "`machines/ssh-transfer/`",
        "description": "Production pinned SSH client and native pipe against real OpenSSH, 32 MiB integrity, authenticated-key delivery, permit fencing, wrong host/client key refusal and retired-key rejection; no native ZFS or Oban coordination claim.",
    },
    "storage-configuration": {
        "location": "`evaluation/storage-configuration.nix`",
        "description": "Mirrored layout, storage properties, budgets and installation boundaries.",
    },
    "sysctl": {
        "location": "`machines/sysctl/`",
        "description": "Explicit opt-in, effective BBR/fq, inherited resource/forwarding policy, connected TCP sockets and reboot persistence.",
    },
    "tailscale-configuration": {
        "location": "`evaluation/tailscale.nix`",
        "description": "Fleet profile runs the Tailscale daemon with networkd integration on every host fixture; service-only module imports stay opt-in. No live tailnet claim.",
    },
    "team-ssh": {
        "location": "`machines/team-ssh/`",
        "description": "Two NixOS machines with packaged Porsche, strict SSH host trust and verified internal TLS: ordinary account creation/retry, stable permanent refusals, transfer/removal, unchanged durable inventories and historical request replay. No guest or team integration access claim.",
    },
    "teams-browser": {
        "location": "`machines/teams/`",
        "description": "Real Marshall/PostgreSQL and three Chromium accounts over verified HTTPS: owner replacement refusal, consent transfer, stale owner/member refusal and exactly one committed owner. No shared VM/integration or independent-Marshall race claim.",
    },
    "ubuntu-build-boundaries": {
        "location": "`evaluation/ubuntu-build-boundaries.nix`",
        "description": "Actual offline assembly rejects missing requested packages and missing dependencies.",
    },
    "ubuntu-fleet": {
        "location": "`machines/fleet/`",
        "description": "Standard Ubuntu through website and Porsche management API, native cloning and relocation.",
    },
    "ubuntu-guest": {
        "location": "`machines/zfs-guest/`",
        "description": "Customized Ubuntu on real Firecracker: package/file/CA installation, boot, growth, persistence and lifecycle.",
    },
    "ubuntu-guest-boot-profile": {
        "location": "`machines/zfs-guest/boot-profile.py`",
        "description": "The same boot-profile measurement for the Ubuntu fixture image through trust delivery.",
    },
    "ubuntu-guest-unit": {
        "location": "`evaluation/ubuntu-guest.*`",
        "description": "Builder input rejection, lock records, shared networking and readiness unit/property tests.",
    },
    "underclass-configuration": {
        "location": "`evaluation/underclass.nix`",
        "description": "Default-off reuse, loopback-only execution, runtime secret ordering, resource bounds, Tailscale Serve command wiring and two-stage opt-in egress (isolated userspace node; loopback-only Underclass behind the exit-node start gate). No live tailnet claim.",
    },
    "underclass-egress": {
        "location": "`machines/underclass-egress/`",
        "description": "Real headscale tailnet, kernel exit node and dedicated userspace egress node: start refusal before login, exit-node source address and DNS resolution, unit confinement to loopback, no direct fallback when the exit node stops, gate re-assertion and reboot persistence. No production tailnet, Mac Mini or provider account claim.",
    },
    "underclass-package": {
        "location": "`packages/underclass/`",
        "description": "Source-built Rust package pinned to an immutable upstream revision and locked Cargo dependencies.",
    },
    "underclass-service": {
        "location": "`machines/underclass-service/`",
        "description": "Actual packaged daemon, API/admin authentication, loopback isolation, secret-free diagnostics, systemd bounds and state persistence over restart/reboot. No provider account or live tailnet claim.",
    },
    "windows-editor-runtime": {
        "location": "`evaluation/windows-editor-runtime.nix`",
        "description": "Hash-pinned Windows Node and ripgrep staging closure with an explicit editor=false marker. It does not establish a Code OSS bundle, broker, service identity or browser acceptance.",
    },
    "windows-firmware": {
        "location": "`nix/domains/artifacts/guest/windows/firmware.nix`",
        "description": "Pinned edk2 CloudHv PVH firmware and Firecracker MMCONFIG aperture. Build and ELF provenance only.",
    },
    "windows-guest": {
        "location": "`machines/windows-guest/`",
        "description": "Nested-KVM operator launcher installs and boots the Windows image to `SAC>`, and probes the launcher's vsock transport. No Lilly jail, Audi, roster or Marshall claim.",
    },
    "windows-guest-unit": {
        "location": "`evaluation/windows-guest.nix`",
        "description": "Offline Windows builder rules, pinned installer inputs, EMS/no-autologon, version-5 manifest, viosock and agent/task wiring. No installation or boot.",
    },
    "windows-lilly-guest": {
        "location": "`machines/windows-lilly-guest/`",
        "description": "Real nested-KVM Lilly launch of the agentless firmware image: MMDS identity, skipped trust, `unattested` lifecycle, /32 reachability through the test-only policy allowance, restart and delete. No readiness or user-agent claim.",
    },
    "windows-lilly-guest-agents": {
        "location": "`machines/windows-lilly-guest/` (agents composition)",
        "description": "Real nested-KVM `windows-v1`: trust and 600 s readiness, boot-bound ConPTY root session, workspace delivery, no-roster SSH refusal, restart with a new boot UUID and delete. Roster-user SSH, agent turn, scheduled-task crash recovery and Marshall-driven fleet repetition remain gaps.",
    },
    "zfs-guest": {
        "location": "`machines/zfs-guest/`",
        "description": "Real Firecracker confinement, retained disks, flushed writes after simulated host loss and independent cleanup.",
    },
    "zfs-guest-clone": {
        "location": "`machines/zfs-guest/clone-matrix.py`",
        "description": "Same-pool block-copy clones (ADR-0145): a clone after a completed 4 GiB resize with grown-disk capture and guest-shape checks, a chained clone whose first adopted copy becomes the next source, `bcloneused` growth and discard of a copied, unadopted destination; native origin emptiness, distinct GUIDs, divergent-write invisibility and deletion independence.",
    },
    "zfs-io": {
        "location": "`machines/zfs-io/`",
        "description": "Real pool-scoped traffic observations and uncertain-sample recovery.",
    },
    "zfs-lifecycle": {
        "location": "`machines/zfs-lifecycle/`",
        "description": "Owned sparse disks and interrupted create/copy/delete recovery.",
    },
    "zfs-namespace-cleanup": {
        "location": "`machines/zfs-guest/namespace-cleanup.py`",
        "description": "Real Firecracker deletion with late sandboxed mount copies, a live file holder and a surviving guest.",
    },
    "zfs-transfer": {
        "location": "`machines/zfs-transfer/`",
        "description": "Native full and resumed streams of the single stopped-source snapshot (ADR-0155) between two block-backed pools, parentless resume-token validation, native-helper EOF cancellation/resume, Lilly staging receipt/ownership rejection, guarded intent, interrupted full disk adoption and ext4 data after source reclamation; no Lilly/SSH orchestration claim.",
    },
    "ziggy-configuration": {
        "location": "`evaluation/ziggy.nix`",
        "description": "Lilly placement, private-only Audi, secret delivery and monitoring wiring.",
    },
    "ziggy-release": {
        "location": "`release/`",
        "description": "Packaged independent Ziggy runtime, protocol and model catalog; absence of control-plane/provisioner dependencies.",
    },
    "ziggy-service": {
        "location": "`machines/ziggy-service/`",
        "description": "Packaged proxy, real SOPS credentials, native provider streaming, bounded spool, revocation and restart without replay. Local TLS/control fixtures, no Firecracker acceptance.",
    },
}
