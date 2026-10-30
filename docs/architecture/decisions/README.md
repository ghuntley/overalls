# Architecture decision records

[ADR-0269](0269-buck2-build-system-with-nix-toolchains.md) makes Buck2 the
only build entry point, with Nix supplying pinned toolchains and assembling
NixOS. [ADR-0270](0270-graph-driven-machine-test-selection.md) selects each
pull request's machine tests from the Buck2 graph,
[ADR-0271](0271-buck2-host-self-deployment.md) moves host self-deployment to
Buck2, [ADR-0272](0272-nativelink-remote-cache-and-execution.md) adds a
NativeLink cache and remote execution, and
[ADR-0273](0273-single-rust-workspace-and-toolchain.md) merges Rust into one
workspace and toolchain.

[ADR-0268](0268-cedar-single-authorization-source.md) makes Cedar Marshall's single
authorization source: one Marshall-owned authorizer with per-resource Cedar
mappings, record decisions and list filters translated from Cedar residuals into
SQL, and no Ash.Policy, bypasses or dual paths (partial: Galileo machine eligibility remains).

[ADR-0267](0267-single-dependency-pin-registry.md) pins every third-party
input in `flake.lock`, `dependency-hashes.json` or a reviewed ecosystem lock
file, enforced by the `pins` check.

[ADR-0266](0266-anonymous-restored-guest-memory.md) restores checkpointed guest
RAM into anonymous memory instead of a private mapping of the memory file, so a
restored VM stays within its accounted memory and can be checkpointed again.

[ADR-0264](0264-hermetic-mila-journey-fixture.md) adds a hermetic Mila journey
fixture: source-built Marshall, Porsche and a browser approver, used by the
`mila-journey` machine test and the `mila-journey-fixture` launcher.

[ADR-0253](0253-artifacts-domain.md) adds the Marshall Artifacts domain for
versioned, Cedar-shared agent-published pages with per-artifact storage.
[ADR-0254](0254-isolated-artifact-content-origin.md) serves their content from a
locked-down, cookie-free content origin.
[ADR-0255](0255-thread-lifecycle-and-server-tool-dispatch.md) dispatches the
Marshall-owned `thread`, `message_board` and `artifact` tools through an Oban job
instead of a polling worker, excludes them from guest executor claims, and makes
Thread status a state machine.
[ADR-0261](0261-thread-feed-turn-notifications-and-subscription-revocation.md)
adds `turn_finished` feed notifications and audited subscription revocation jobs.

[ADR-0263](0263-retire-hldd.md) retires the HLDD handbook, its review receipts
and every HLDD gate, superseding ADR-0250. ADRs and architecture reviews remain.

[ADR-0248](0248-fleet-build-scheduling.md) makes Panterloons the single
tribuchet build scheduler for itself and Dungarees, which delegates over a
`grpc://` store; the two hosts substitute from each other over `grpc://`,
superseding ADR-0086 for them while other hosts stay cache-only.

[ADR-0249](0249-mila-rust-core-native-clients.md) moves Mila's shared protocol,
cryptography and state logic into Rust crates with thin Swift, Kotlin, GTK4 and
WinUI clients; implementation remains partial while native parity is built.
The separate `mila-session` crate now composes validated machine reads with SSH;
native session adapters and full feature parity remain pending.

[ADR-0247](0247-sops-operator-source-grant.md) restores Geoffrey Huntley's
operator source as a reviewed fleet-wide grant whose address lives only in the
fleet-addresses SOPS document.

[ADR-0246](0246-panterloons-control-plane-deployment.md) runs Panterloons as a
copy of the Overalls deployment from the same parameterised host roles, with
fresh secrets and a bootstrap stage before its own Marshall issues credentials.

[ADR-0245](0245-underclass-egress-node-tag.md) makes `underclass-egress up`
advertise `tag:underclass` so tailnet policy can identify the Underclass
egress node.

[ADR-0243](0243-native-guest-durability-verification.md) makes a native flush
receipt mean durable across host power loss under Lilly's Writeback drives,
adds a FreeBSD device cache flush after UFS resume, and verifies interrupted
root growth, dm-log-writes power-cut replay and two-host relocation for
FreeBSD and OmniOS without admission or orchestration claims.

[ADR-0241](0241-sops-tailscale-auto-join.md) delivers a shared Tailscale
authentication key through SOPS so enrolled hosts join the tailnet
automatically; base systems still join by explicit operator action.

[ADR-0240](0240-account-machine-creation-presets.md) accepts three account creation presets: launch starts with OSS, machine and thread creation start with Standard (Work), with validated saved image and resource preferences and original-request launch replay. Implementation remains partial pending native and rollout acceptance.

[ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) moves Salopettes into
the Panterloons tunnel, leaves Overalls alone in its own, and restores the
wildcard issuer's two-peer minimum.

[ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md) makes
Panterloons a separate deployment with its own fleet tunnel, moves Dungarees to
it, and gives fleet telemetry a per-deployment host roster.

[ADR-0237](0237-windows-custodian-same-boot-recovery.md) completes ADR-0208's
same-boot custodian restart: durable per-boot custodian generations scope jobs,
pipes and receipts, and a prior lifetime's receipt is retired only after its
job vanished and no process of the worker's exact account logon session remains,
terminating only re-verified stragglers. Native execution remains pending.

[ADR-0236](0236-susan-wns-provider.md) adds a WNS provider to Susan: Entra ID
client-credentials tokens, raw notifications, and egress to channel URIs
confined to `https://*.notify.windows.com:443`, amending ADR-0224's egress
rule; implementation remains partial.

[ADR-0235](0235-mila-desktop-clients.md) makes Mila a first-class macOS and
Windows client: a per-platform profile, Secure Enclave or CNG (TPM, else
software) device keys, owner-only DACL storage, APNs and WNS push, and dev and
release build targets for every platform; implementation remains partial.

[ADR-0234](0234-installer-source-administrative-grant.md) records the
authenticated installer's source at installation and admits only it to
administrative SSH through an optional runtime firewall rule, so a base system
without the fleet-address document stays reachable for enrollment.

[ADR-0233](0233-fleet-addresses-from-sops.md) keeps every fleet public address
out of the repository: one shared SOPS document, runtime uplinks with a recovery
copy, a runtime firewall chain on both backends, runtime WireGuard endpoints and
service binds, and salopettes on `fleet0` so Marshall reaches Susan over the
tunnel. It supersedes ADR-0232; implementation remains partial.

[ADR-0232](0232-sops-delivered-public-host-addresses.md), superseded by
ADR-0233, kept Hetzner Cloud host addresses out of the repository through a
host-bound SOPS document.

[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) accepts a KVM-less,
Lilly-free `hcloud` host platform with a single-disk ZFS root and places Susan
alone on the enrolled host salopettes behind ACME TLS for
`notifications.overalls.dev`; implementation remains partial.

[ADR-0230](0230-terminal-image-decoder-webassembly.md) accepts
`'wasm-unsafe-eval'` in Marshall's production `script-src` so the terminal image
addon decodes sixel, amending only ADR-0194's script clause; implementation
remains partial.

[ADR-0229](0229-scim-managed-identity-and-teams.md) accepts SCIM-managed users,
groups, identity retirement, runtime OIDC and authoritative team synchronization;
the endpoint, lifecycle, team fences, OIDC flow and Control Room page are
implemented and machine-tested, while administrator handoff of managed teams and
encrypted OIDC secret custody keep it partial.

[ADR-0220](0220-mila-client-over-porsche-ssh.md) through [ADR-0228](0228-strict-host-certificates-in-mila.md) introduce Mila, the Flutter client over one Porsche SSH connection with per-deployment P-256 device keys, canonical `overalls://` routes, the client command set, terminal attach, the Susan push relay and Notifications domain, The Monospace Web on Flutter, the patched dartssh2 toolchain and strict host-certificate trust. All nine are partial: code and tests exist for each, while device builds, real APNs/FCM delivery and Susan hosting remain open.

[ADR-0207](0207-bundled-multilingual-font-fallback.md) accepts local Noto script
fallbacks with native shaping and JetBrains Mono as the primary grid font. It
supersedes only ADR-0161's exclusive-typeface clause and carries forward its other
presentation constraints. Current browser rendering evidence remains partial.

[ADR-0205](0205-overview-newsletter.md) accepts a durable account-wide Overview newsletter invitation and fixed server-side Ghost subscription path; implementation remains partial.

[ADR-0204](0204-git-attribution-and-guest-identity.md) preserves the reconciled duplicate Git attribution decision and its settings-page evidence; implementation remains partial.

[ADR-0203](0203-guest-reflection.md) accepts a secret-free, execution-fenced reflection projection over the private service path; implementation remains partial.

[ADR-0202](0202-github-com-owner-integration.md) accepts owner-bound GitHub OAuth custody and managed guest forwarding, adding its fixed OAuth form origin to ADR-0194; implementation remains partial.
FreeBSD image `0150b6d1` now passed all five current-VMM scenarios, signed-cache
and independent fresh-store verification, then additive admission and default
selection. Immutable history/staging preserves the older identity and capability
absence. OmniOS selection remains unchanged; its historical failures and later
exact-runtime results remain scoped in the review. Live fleet/provider and native
checkpoint acceptance stay separate.

[ADR-0201](0201-localized-human-surfaces.md) accepts Localize-backed human surfaces, the central 28-locale policy, feature catalogs, browser language negotiation and validated account overrides with LTR/RTL presentation. Public guides are translated; HLDD contents remain English. Implementation remains partial.

[ADR-0200](0200-windows-browser-editor-candidate.md) accepts a source-built,
account-bound Windows editor candidate with a separate `windows-editor-v1`
manifest-v7/bundle-v4 contract. Native package, image and browser qualification
remain separate; the selected `windows-v1` editor capability stays false.

[ADR-0208](0208-windows-editor-job-custodian.md) replaces ADR-0200 in full,
preserving the immutable Windows editor candidate contract while moving worker/job
custody into an independently supervised SYSTEM task. Implementation remains
partial pending native custodian failure/recovery and exact-image browser evidence;
ADR-0237 supplies its same-boot recovery mechanism.


[ADR-0199](0199-memory-suspension-and-demand-wake.md) accepts full-memory
suspension, paused relocation, durable demand wake and the four-hour tool-idle
policy. It carries forward fencing, capacity and cleanup requirements while
replacing stopped-source reboot and the cross-host relay prohibition. The
[suspension review](../reviews/2026-10-18-memory-suspension.md) retains the
distinction between source implementation and recorded native acceptance.

[ADR-0198](0198-git-attribution-and-guest-identity.md) defines account Git preferences, immutable new-machine Git identity and optional agent commit attribution.

[ADR-0192](0192-staged-detached-ingress.md) moves the browser editor and
nested HTTPS onto ADR-0187's detached ingress bridges. The BEAM's only
essential role for them was setup: hostd now writes the preface Lilly derives
and compares the guest's reply with Lilly's exact ready frame before starting
the bridge, so live editor and nested HTTPS connections also survive
lilly-hostd and Lilly restarts, amending ADR-0187 decision 1.

[ADR-0191](0191-elixir-hegel-property-verification.md) standardizes test-only Hegel property verification in Elixir applications, with deterministic replay, redacted diagnostics, isolated fixtures and explicit limits on BEAM evidence.

[ADR-0189](0189-cachix-watch-store-publishing.md) enables the Cachix watch-store
agent on Overalls and Dungarees with a host-delivered SOPS token.

[ADR-0188](0188-signed-overalls-cachix-substitution.md) configures the signed
Overalls Cachix substituter for every Nix-running host and guest while retaining
`cache.nixos.org`, signature enforcement and local-build fallback. Configuration
evaluation is implemented; live cache availability and rollout remain partial.

[ADR-0187](0187-detached-ingress-bridges.md) bridges Audi's guest SSH and
plain web connections straight to the guest in detached `lilly-ingress-<key>`
scopes that survive lilly-hostd and Lilly restarts, while Lilly keeps the
execution fence through recorded bindings, keepers and re-adoption, amending
ADR-0184 decision 3.

[ADR-0186](0186-covenant-contract-verification.md) adopts Covenant as a test-only, deterministic contract verification layer across all twelve Elixir applications. It complements existing `CONTRACTS`, ADR, HLDD, native and integration evidence; the initial obligations establish module-loadability baselines and explicitly do not claim native or deployment guarantees.

[ADR-0260](0260-underclass-egress-without-exit-node.md) keeps Underclass behind
the dedicated egress node's proxy and loopback confinement with no exit node,
clearing stale exit-node preferences on every start, amending ADR-0185 stage 2.

[ADR-0185](0185-underclass-tailnet-exit-egress.md) routes Underclass provider
traffic, and only that traffic, through a dedicated userspace tailnet node and
an Australian exit node, confining the Underclass unit to loopback behind a
start gate that refuses to run without the exit node selected.

[ADR-0184](0184-lilly-owns-every-socket.md) keeps every socket the BEAM uses
one it created: lilly-hostd connects Lilly's own socket or bridges it to a
VM-namespace connection, and never passes a descriptor, replacing ADR-0182
step 2.

[ADR-0183](0183-guest-dataset-streams-in-hostd.md) runs every guest dataset
`send` and `receive` inside lilly-hostd from typed fields and removes the
unprivileged `lilly` user's ZFS delegation, replacing ADR-0182 step 3.

[ADR-0181](0181-public-proxy-http01-ingress.md) admits public TCP 80 for the
opted-in Marshall proxy's HTTP-01 ingress so Overalls' `ghuntley.dev`
certificate renews unattended, amending ADR-0075.

[ADR-0177](0177-retire-standby-guest-disks.md) retires ADR-0146's pre-cloned
standby disks on measured evidence: on-demand block-cloned creates were no
slower in a 26-create burst. Lilly first drains the remaining standbys, then
the subsystem is deleted.

[ADR-0178](0178-durable-agent-context-and-planning.md) accepts immutable agent
context snapshots and compaction checkpoints, durable Plan/Work collaboration,
questions and proposal implementation, and composer commands. It preserves
Marshall's model-loop authority and refusal to replay ambiguous provider work.
[ADR-0179](0179-guest-instructions-and-managed-skills.md) accepts guest-owned
project instruction discovery and pinned manager-controlled skill installation.
Implementation and scoped verification are being recorded in the
[context review](../reviews/2026-10-16-agent-context-and-planning.md).

[ADR-0176](0176-host-concurrency-single-writers-and-effects.md) replaces Lilly's
polling pool lock with one writer per pool that commits claims in batches,
turns VM actors into reconcilers that can be cancelled, verifies template
digests natively, and moves host mutation into a typed native
`lilly-hostd` engine with leases, an outcome ledger and durable jobs.

[ADR-0175](0175-thread-sharing-and-bound-machine-authority.md) adds durable
viewer/operator/manager thread sharing as a current source of bound-machine
authority. It supersedes only ADR-0174's creator/team-only authority clauses.
Shares survive archive/reopen, independent VM/team grants remain additive, and
VM-only access does not expose the task transcript. Focused database/UI and
synthetic browser checks passed for persisted grants and authority integration;
native transport revocation and physical recovery remain unverified.

[ADR-0190](0190-native-kernel-provenance-and-admission.md) replaces ADR-0180 and records the cross-OS guest
image contract: Arch Linux and AlmaLinux retain the version-4 Linux shape with
distinct distribution markers, while native FreeBSD and OmniOS use explicit
version-6 manifests and version-3 bundles. The illumos constructor records
illumos.org as the upstream source project and selects pinned OmniOS as the
installable downstream. Artifact names, OS facts and
capabilities come from the protocol; Lilly keeps its jailer, network and storage
boundaries while selecting the validated boot path. Native manifests bind
kernel provenance, and Lilly requires a boot-bound kernel response before
credentials or readiness. The implementation remains partial: unqualified native
rows are false, while complete image-qualified identity activates only the
reviewed FreeBSD and exact OmniOS subsets through separate immutable promotions and a runtime
registry. Editor and Inception remain false; stock/altered identities and
unreviewed OmniOS candidates remain refused. Stock source receipts contain no artifact bytes, and
those constructors refuse before copying a stock disk. Pinned builds link the complete
FreeBSD kernel, twenty native Lyra executables and both terminal daemons.
OmniOS native nine-module/full-payload clean-export assembly, QEMU file/runtime
checks and diagnostic Firecracker executing-token/transport checks passed. Its
earlier service, mounted-root growth and same-disk process-crash receipts remain
scoped evidence with `native_admission=false`; physical recovery, isolation,
reset/DMA safety and fleet acceptance remain open.
FreeBSD has source-qualified transport, complete-service, same-boot daemon
recovery, three-boot mounted-root growth and two-boot IPv4/router/TAP policy
results. The final reviewed image, including blocking UFS suspension/resume,
passed all five scoped service/growth/policy/daemon-recovery/SIGKILL-recovery
variants. OmniOS service, mounted-root growth and process-crash receipts are
recorded separately; direct native peer-VM/jail/host isolation, physical
stable-media/power-loss durability, reset/DMA and fleet acceptance remain open.
The completion-corrected OmniOS image reaches console login in the paired
direct-only QEMU diagnostic and retained nested Firecracker serial, with growth
maintenance before bootstrap authority. Exact corrected service replay is now
recorded separately. Final sealed disk `45983bb7` subsequently passed all five
direct host-KVM scenarios, ordinary transport and one reset event. Its exact
immutable promotion and registry qualification are recorded in the
[matrix review](../reviews/2026-10-18-guest-os-matrix.md); the selected OmniOS
fleet aliases first selected that exact immutable promotion; they now select the
later Nix-assembled `a96f291b` promotion, with `45983bb7` retained in history
and staging. Candidate constructors
remain unadmitted; deployment and live acceptance retain separate records.
The [review](../reviews/2026-10-17-native-kernel-attestation.md) records exact
artifacts and limits; the [activation review](../reviews/2026-10-17-native-image-admission.md)
records the separate exact FreeBSD promotion. Candidate evidence alone grants
no catalog admission. The
detailed Windows choices remain in ADR-0169 through ADR-0173.

[ADR-0174](0174-user-threads.md) adds the user-level Threads domain. Threads
persist a pending task and typed machine specification, then bind the existing
Compute VM and Agents root through an idempotent worker. Readiness requires the
running VM and initial objective; archive waits for Compute deletion, and reopen
uses a fresh machine admission key while preserving the create request and
retired binding history. Authorized prior-generation transcript browsing is
implemented through durable generation rows and a read-only selector. The
implementation remains partial pending native lifecycle, cross-node recovery
and broader provider acceptance.

Both hosts converged healthy on the machine-key expansion at
`d5e03c080204a33a11b8c136e983593630e4fccf` on 2026-10-15. The dependent contraction
backfills late null keys, enforces `NOT NULL`, and removes the row-key fallback
under ADR-0159. Both hosts subsequently converged healthy on
`32624e1bf80df120beb69b923eee4362427aee23`; read-only SQL confirmed `NOT NULL`
and zero null keys, completing that rollout obligation.

The [Underclass manual reset pin review](../reviews/2026-10-14-underclass-pin.md)
records an admin-token-gated manual Codex reset redemption operation within
ADR-0102's existing boundaries. Its accepted decision and partial implementation
status are unchanged; the package built offline and tests for this pin were not run.

The [Underclass stream statistics pin review](../reviews/2026-10-15-underclass-pin.md)
records bounded stream outcome and long-range capacity statistics behind the same
administrator token. ADR-0102's accepted decision and partial implementation
status remain unchanged; tests for this pin were not run.

The [Underclass saturation reselect pin review](../reviews/2026-10-16-underclass-pin.md)
records a proxy-internal fix for stale saturation 429s. ADR-0102's accepted
decision and partial implementation status remain unchanged.

[ADR-0168](0168-guest-coding-cli-dangerous-defaults.md) sets the requested
dangerous native execution defaults for the pinned guest coding CLIs and
supersedes ADR-0167's client-policy clauses. [ADR-0167](0167-native-guest-coding-clis.md)
still carries the image, Ziggy, Ubuntu closure and provider-boundary decisions.
It adds pinned Codex and Claude Code to
both guest images using native Ziggy settings and an explicit offline Ubuntu
application-closure exception. Ziggy accepts exactly `beta=true` on native
Anthropic Messages and token-counting POST routes. Production Anthropic remains
disabled; current acceptance is recorded separately in the
[review](../reviews/2026-10-13-native-guest-coding-clis.md).

The [Antithesis reset review](../reviews/2026-10-13-antithesis-reset.md) retires
the old harness before a fresh whole-repository rebuild. ADR-0017 retains its
accepted decision and partial implementation status; historical artifacts use
baseline-pinned links and the ordinary Lilly actor/fixture properties remain.
Fresh hosted and mutation evidence is pending.

The [native prerequisite review](../reviews/2026-10-13-antithesis-prerequisites.md)
adds captured Galileo/Enrico release and ZFS I/O machine results under the
inherited ADR-0033 verification boundary. It records the failed expanded
service-role attempt separately and corrects ADR-0142's decoder evidence to
the existing five-second catalog limit. ADR-0017, ADR-0033, ADR-0142 and
ADR-0149 retain their decision and implementation statuses; the ADR-0153–0158
guest/editor/source/identity chain gains no new acceptance from these fixtures.
The [new harness foundation review](../reviews/2026-10-13-antithesis-harness-foundation.md)
records optional source-built SDK/Compose wiring and the deliberately unavailable
hosted execution boundary under ADR-0017 and ADR-0033. It preserves ADR-0149's
diagnostic separation and leaves all three implementation statuses unchanged;
no current remote baseline or native guest outcome follows from source presence.

[ADR-0166](0166-resize-hardening.md) hardens resize: a Porsche `resize`
command with durable receipts, every refusal logged with its reason, a stop
confirmed without its disk recorded for retry instead of aborting the host
exchange, and cancellation while the machine is still stopping, which restores
the holds and restarts an originally running machine unchanged.

[ADR-0165](0165-restart-only-changed-units.md) makes host activation restart
only the units whose definition, drop-ins or secret bundle changed, so a
Marshall-only release no longer restarts Lilly and its guest actors.

[ADR-0164](0164-arc-budget-and-safe-memory-decrease.md) raises the fleet's ZFS
ARC budget to 24 GiB with a derived dnode limit, rebalances the guest memory
budget, and lets the resource policy lower the guest RAM ceiling live when the
slice's current use plus two GiB still fits, refusing otherwise.

[ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md) bounds the
host's own storage churn and damps capacity reporting: standby refill is a
planned pass within fill and retirement budgets that yields to pool-lock
waiters (32 standbys per image, 64 per pool at most), usage-counter drift is
resampled instead of withholding capacity, and a busy pool entry extends a
recent measurement's freshness for at most fifteen seconds, never past host
authority.

[ADR-0171](0171-windows-guest-agents.md) gives Windows guests agents over
virtio-vsock: a third agent set `windows-v1` with a pure capability table in
`OverallsProtocol.GuestAgents` (everything except the editor and Inception) that
Lilly and Marshall branch on instead of the binary agents status, the vsock
endpoint in firmware jails exactly when the agent set uses it, a 600 s readiness
budget, Rust agents cross-built as `lyraWindows` through the pinned zig
toolchain with a Windows-target type check in the Lyra gate, the virtio-win
`viosock` driver and a transport probe in the image, a ninth Firecracker patch
that lets the vsock device walk the indirect descriptor tables viosock posts
whether or not the feature was negotiated, per-image standby
eligibility (`{ path; standby }`) with a size-only cacheability filter in
standby refill and a 48 GiB template budget (96 GiB since ADR-0173), and a converged rollout in which
the image is built once, copied to both hosts and staged only after every host
runs the new code. Gates 2 to 5 (readiness and trust daemons, SSH, ConPTY
terminal, workspace and agent executor) are implemented. The nested machine
journey and named fleet proofs passed; browser-approved SSH, roster-user
ConPTY, agent turns and a Marshall-driven repeatable Windows matrix remain
unverified.

[ADR-0170](0170-lilly-firmware-guest-launch.md) makes the Windows image a
launchable guest: the protocol admits the eight-key version-5 manifest and a
version-2 firmware bundle beside the unchanged version-4 shapes, Lilly keeps
`rootfs.ext4` as the pool-side root slot, boots firmware bundles over virtio-pci
with the boot identity seeded into Firecracker's MMDS from a jail-local
`metadata.json`, records trust as skipped and provisioning as `unattested`
(running, never `guest_ready`), and refuses terminals, workspace sources and
the Inception profile for guests without agents. A SYSTEM task in the Windows
image reads MMDS and applies the delivered `/32`. Marshall derives finite guest
capabilities and hides and refuses Terminal, Agents, editor and SSH for agentless
images. The original agentless admission measured only the physical service level;
ADR-0198/0204 now require explicit Git identity support for new machines and refuse
agentless admission before allocation. Historical Lilly launch evidence remains in the
[Windows Lilly launch review](../reviews/2026-10-14-windows-lilly-launch.md).

[ADR-0169](0169-firmware-booted-windows-guests.md) proposes firmware-booted
Windows guests under Firecracker: the pinned static Firecracker 1.16.1 gains
eight reviewed patches (PVH start info carries the RSDP, a read-only ACPI PM
timer at port 0x608, opt-in Hyper-V CPUID leaves through the custom CPU
template, virtio-pci decode enabled at reset, a read-only CMOS clock,
guest-driven BAR relocation, virtio device reset and scatter-gather block
requests; ADR-0171 adds a ninth for vsock indirect descriptor tables), edk2's CloudHv UEFI is built as the PVH payload with its PCI aperture
ending at Firecracker's MMCONFIG, and a Windows Server 2025 evaluation image is
installed offline in a KVM sandbox with EMS on COM1. The image carries a
version-5 manifest (`boot.kind = firmware`, `root.format = raw-gpt`,
`guest_agents = none` or `windows-v1`) admitted beside the Linux shape; the
standalone launcher and Lilly machine checks reach the SAC prompt. Evidence is
recorded in the [Windows Firecracker spike review](../reviews/2026-10-13-windows-firecracker-spike.md)
and the [multi-OS review](../reviews/2026-10-16-multi-os-guest-images.md).

[ADR-0162](0162-clone-cleanup-liveness.md) makes clone cleanup live: unconfirmed
clone effects carry a closed reason end to end (clone protocol v5), a clone's
transfer slots release once both endpoint revocations are on record, a published
copy completes at a cleanup deadline while the source snapshot hold and the prune
offer are retained, transient refusals defer instead of failing, and a failed
source stop is recorded. It supersedes ADR-0055's slot release clause.

[ADR-0161](0161-monospace-web-presentation.md) replaces the Nekomo presentation
with The Monospace Web: a character grid, four colour tokens per theme, vendored
JetBrains Mono, semantic HTML with text glyphs and no external resources. It
removes Tailwind, daisyUI, heroicons, Cinder and the Mishka component set while
keeping navigation, authorization, terminal and hook contracts. Structural and
Playwright evidence are recorded in the
[presentation review](../reviews/2026-10-13-monospace-web-presentation.md).
[ADR-0207](0207-bundled-multilingual-font-fallback.md) replaces only its
exclusive-typeface clause with local multilingual script fallbacks.

[ADR-0160](0160-privileged-administrator-step-up.md) replaces ADR-0123's inherited
administrator step-up with fixed fifteen-minute elevation, inline exact
pending-action continuation and no-key Security setup followed by explicit retry.
Ordinary signed-in reads, passkey-change verification, remembered-browser
revocation and Cedar Customer isolation remain distinct. The accepted design is partial;
initial and final merged native evidence are recorded separately from historical
five-minute evidence. Final packaged browser checks passed ordinary access,
no-key setup/explicit retry, inline continuation and colocated replica revocation;
timed expiry and native machine-page recovery remain separate gaps.

[ADR-0159](0159-remove-legacy-compatibility.md) removes every remaining
backward-compatibility and legacy path. Compatibility exists only as push
ordering (consumer tolerant, producer stops, decoder strict); old-format data is
exported then purged and rollout switches are removed. It supersedes ADR-0088 and
ADR-0151 and the compatibility clauses of ADR-0087/0105/0126/0136/0138/0149/0155/0158,
carrying their remaining requirements forward. It was implemented in fourteen
ordered pushes and three host windows recorded in the
[removal review](../reviews/2026-10-11-legacy-compatibility-removal.md).

[ADR-0158](0158-durable-guest-identities.md) replaces email-derived guest names
and email-incarnation checks with immutable GuestAccount UUID/UID, `u<uid>` login
and `/home/u<uid>`. It supersedes the affected clauses in ADR-0125/0148/0153 while
carrying their remaining requirements forward. Mailbox syntax is independent of
Linux naming; profile names, retained-disk conversion and deployment are excluded.
On base `63a1443c` plus the durable-identity feature, both generated-identity
lifecycle journeys and complete NixOS SSH passed;
complete Ubuntu SSH/native editor acceptance and historical-restore reconciliation
remain separate gaps.
Separate integration with incoming `d4499c4c` passed Protocol/Lilly/Marshall gates
and both eight-subtest lifecycle journeys (NixOS 438.33 seconds, Ubuntu
574.18 seconds); later incoming browser-launcher/shared-observability source and
the native ZFS inventory helper are separate scopes. The helper passed inside a
complete native-zfs run that failed unrelated resource-tuning receipt validation.

Superseded [ADR-0155](0155-stopped-only-relocation.md) removed live pre-copy,
baseline/incremental streams and the strategy column. ADR-0199 retains one full
quiescent copy and replaces a running source's stop/reboot with pause/resume,
adding separately reserved checkpoint custody. Historical results keep their
original scope; inherited fencing and cleanup requirements remain in force.

[ADR-0157](0157-multi-provider-authenticated-repository-launch.md) supersedes
ADR-0128's GitHub-only/no-resume choices with source2, bounded signed-cookie
authentication resume and manifest4 capabilities. [ADR-0156](0156-browser-launcher-distribution.md)
adds explicitly configured unsigned browser packages at public `/bin` routes
and an exact-origin optional presence marker that only hides setup affordances.
ADR-0156 is accepted/partial pending Chrome and Firefox setup-visibility runtime
evidence; immutable package and browser launch checks are recorded; ADR-0157 is accepted/implemented after both captured provider/revision
journeys passed. Production deployment remains an explicit validation gap.

Proposed [ADR-0151](0151-existing-state-standard-profile-migration.md) reviews the
incoming existing-state Standard migration and its lifecycle custody correction.
ADR-0147's accepted fresh-only rationale is preserved; deployed-state policy and
native upgrade acceptance remain unresolved.

[ADR-0149](0149-independent-observability.md) moves service diagnostics into
independent OpenTelemetry custody and declarative Grafana views. The old diagnostic
transport/persistence/view clauses are superseded; transactional authority, audit,
accounting and historical verification remain separately scoped.

[ADR-0153](0153-official-source-browser-editor.md) adds the official-source personal
browser editor. Historical package/standalone results retain their scope; the
corrected startup-release snapshot now passes both complete NixOS and Ubuntu
Firecracker fleet scripts. Final release 7d2415 complete standalone acceptance
subsequently passed personal version/reversion, core refusals, actual languages
and recovery; its fixture authority retains native package/broker scope.
Both hosts activated 63a1443c/release 73ad without establishing a production
browser journey or configured recurring coverage. The decision remains
accepted/partial. ADR-0158 replaces only its email-bound identity clauses.
The durable feature's native editor runs on base `63a1443c` remain partial;
earlier editor snapshots do not establish that feature or this merged tree.

[ADR-0142](0142-overallsprotocol-control-websocket.md) confines shared socket
transport to Control.Client and WebSocket.Connection while codecs and state
primitives retain their pure boundaries. Protocol owns no Ash, database, host
mutation or durable credential store; the decision remains accepted/partial.

[ADR-0136's native recorder review](../reviews/2026-10-05-recorder-commit-reply-loss.md)
records generated durable commit/reply-loss and gap-acknowledgment baselines in
an isolated NixOS machine and local mutation falsifications. Real source/collector
journeys and final batch gates remain pending; its accepted decision and partial
implementation status are unchanged.

ADR-0097's [escaped-session review](../reviews/2026-10-05-enrico-escaped-session-ownership.md)
records eleven passing native ownership properties after the all-adopted-child
wait repair. Enrico remains partial; packaged cgroup recovery, physical quota
and durable Marshall retry are separate pending scopes.

[ADR-0132's review](../reviews/2026-10-02-provisional-seven-day-slos.md)
records historical seven-day burn threshold arithmetic and the former fixed,
fresh Marshall rule-state projection. ADR-0149 supersedes ADR-0132's diagnostic
reader; its historical implementation status remains partial. The captured
twenty-objective/forty-alert roster and native physical journeys retain their
original scope. Full source fault acceptance, native retry/cancellation
measurements, external delivery and observed history remain separate evidence
requirements; this historical review does not establish the ADR-0149 cutover.

The [updater compatibility history review](../reviews/2026-09-26-updater-compatibility-histories.md)
adds bounded generated and executable fixed-check evidence for ADR-0036 without
changing its inherited deployment policy or historical native acceptance scope.

The [updater custody history review](../reviews/2026-09-26-custody-updater.md)
adds generated rotation-refusal/backoff, verify-only manual-recovery, recipient-handoff
and custody-wedge evidence for ADR-0036, plus wedge-recovery evidence recorded under
ADR-0070; decisions and implementation statuses are unchanged.

The [operator recipient-history review](../reviews/2026-09-26-secret-recipient-histories.md)
extends ADR-0041/0044 verification within the custody policy carried forward by
ADR-0067/0086. Decisions and implementation statuses are unchanged.

The [guest CLI supervisor recovery review](../reviews/2026-09-26-guest-cli-recovery.md)
repairs candidate spawn failure under ADR-0104 without changing its accepted
recovery policy or partial implementation status.

The [Underclass pin review](../reviews/2026-09-26-underclass-pin.md) records
scheduled token rotation and credential-rejection recovery within ADR-0102's
existing boundaries. Its accepted decision and partial implementation status
are unchanged; tests for this pin were skipped at the user's request.

The [clone restart recovery review](../reviews/2026-09-26-clone-restart-recovery.md)
updates evidence for ADR-0017, ADR-0055 and ADR-0092 without replacing their
execution, cleanup or portable-storage decisions. Its owned-import staging
deferral grants neither execution authority nor capacity credit.

The [default-profile verification review](../reviews/2026-09-25-default-oss-verification.md)
extends ADR-0046 and ADR-0103 evidence and records a corrected Customer refusal
response. Their decision and implementation statuses are unchanged.

The [terminal startup recovery review](../reviews/2026-09-25-terminal-startup-recovery.md)
extends ADR-0083 and ADR-0117 evidence for bounded reply lifetimes and startup
presentation. Their decisions and implementation statuses are unchanged.

Decision status and implementation status are independent. `accepted` records
an authorized decision; it does not mean that feature exists. `partial` means
the evidence section identifies both implemented portions and remaining work.

ADR-0113 and ADR-0133 record the continuing-boot generation correction and its
scoped metadata properties, passing native process continuity and the complete
Lilly gate. Native clone retry/cancellation accounting and the full clone matrix
passed; foreign boot refusal and relocation retry/cancellation accounting remain
open. Both implementation statuses remain partial.

ADR-0136 now records native DNS admitted-request producer-loss acceptance in the
[retention review](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md).
It remains partial pending the remaining per-source and overload/storage faults.
Its source-local producer and pure aggregate arithmetic now live in the breaking
internal `elixir/request_accounting/` library; the [library review](../reviews/2026-10-10-request-accounting-library.md)
records the preserved recorder boundary and the separation from diagnostics.

ADR-0133's workflow extension adds independent clone, relocation, retry and
cancellation measurements without changing the deployed physical-source
denominators. The [accounting review](../reviews/2026-10-02-durable-physical-slos.md)
records generated histories and extended packaged collector/browser acceptance;
native workflow completion and production activation retain separate scopes.

| Decision | Status | Implementation | Title |
| --- | --- | --- | --- |
| [ADR-0171](0171-windows-guest-agents.md) | proposed | partial | Windows guest agents over virtio-vsock and fleet enablement |
| [ADR-0172](0172-windows-workstation-client.md) | proposed | partial | Windows workstation client |
| [ADR-0173](0173-windows-images-winget-desktop-experience.md) | proposed | partial | Windows images on Desktop Experience with pinned winget packages |
| [ADR-0181](0181-public-proxy-http01-ingress.md) | accepted | partial | Public HTTP-01 ingress for the Marshall proxy |
| [ADR-0182](0182-unprivileged-lilly-beam.md) | accepted | partial | Run the Lilly BEAM unprivileged behind lilly-hostd |
| [ADR-0183](0183-guest-dataset-streams-in-hostd.md) | accepted | partial | Guest dataset streams run in lilly-hostd |
| [ADR-0184](0184-lilly-owns-every-socket.md) | accepted | partial | Lilly owns every socket it uses |
| [ADR-0185](0185-underclass-tailnet-exit-egress.md) | accepted | partial | Underclass upstream egress through a tailnet exit node |
| [ADR-0186](0186-covenant-contract-verification.md) | accepted | partial | Covenant contract verification across Elixir applications |
| [ADR-0192](0192-staged-detached-ingress.md) | accepted | partial | Editor and nested HTTPS use staged detached ingress bridges |
| [ADR-0193](0193-per-user-machine-pins.md) | superseded | partial | Per-user machine pins and the owner-pin deletion guard |
| [ADR-0194](0194-marshall-http-security-headers.md) | accepted | partial | Marshall HTTP security headers, no-index and session cookie hardening |
| [ADR-0195](0195-user-time-zones.md) | accepted | partial | User time zone preference and local-time display |
| [ADR-0196](0196-single-account-settings-page.md) | accepted | partial | One account settings page |
| [ADR-0198](0198-git-attribution-and-guest-identity.md) | accepted | partial | Git attribution and guest identity |
| [ADR-0199](0199-memory-suspension-and-demand-wake.md) | accepted | partial | Memory-preserving suspension, relocation and demand wake |
| [ADR-0200](0200-windows-browser-editor-candidate.md) | superseded | partial | Account-bound Windows browser editor candidate |
| [ADR-0208](0208-windows-editor-job-custodian.md) | accepted | partial | Independent Windows editor job custodian |
| [ADR-0202](0202-github-com-owner-integration.md) | accepted | partial | Owner-bound GitHub.com integration |
| [ADR-0203](0203-guest-reflection.md) | accepted | partial | Guest reflection service |
| [ADR-0206](0206-android-firecracker-guest.md) | accepted | partial | Software-rendered Android in the Firecracker guest |
| [ADR-0204](0204-git-attribution-and-guest-identity.md) | accepted | partial | Git attribution and guest identity |
| [ADR-0205](0205-overview-newsletter.md) | accepted | partial | Overview newsletter signup |
| [ADR-0189](0189-cachix-watch-store-publishing.md) | accepted | partial | Publish fleet store paths to Overalls Cachix |
| [ADR-0188](0188-signed-overalls-cachix-substitution.md) | accepted | partial | Use the signed Overalls Cachix cache across Nix machines |
| [ADR-0187](0187-detached-ingress-bridges.md) | accepted | partial | Detached ingress bridges survive lilly-hostd and Lilly restarts |
| [ADR-0190](0190-native-kernel-provenance-and-admission.md) | accepted | partial | Native kernel provenance and fail-closed multi-OS admission |
| [ADR-0191](0191-elixir-hegel-property-verification.md) | accepted | partial | Elixir Hegel property verification |
| [ADR-0180](0180-multi-os-guest-image-contract.md) | superseded | partial | Multi-OS guest image families on the Firecracker fleet |
| [ADR-0174](0174-user-threads.md) | superseded | partial | User threads own isolated work machines |
| [ADR-0175](0175-thread-sharing-and-bound-machine-authority.md) | accepted | partial | Thread sharing and bound machine authority |
| [ADR-0176](0176-host-concurrency-single-writers-and-effects.md) | accepted | planned | Host concurrency through single writers, reconcilers and a host-effects engine |
| [ADR-0177](0177-retire-standby-guest-disks.md) | accepted | implemented | Retire pre-cloned standby guest disks |
| [ADR-0178](0178-durable-agent-context-and-planning.md) | accepted | partial | Durable agent context, compaction and planning |
| [ADR-0179](0179-guest-instructions-and-managed-skills.md) | accepted | partial | Guest project instructions and managed skills |
| [ADR-0170](0170-lilly-firmware-guest-launch.md) | proposed | partial | Lilly launches firmware-booted guests without guest agents |
| [ADR-0169](0169-firmware-booted-windows-guests.md) | proposed | partial | Firmware-booted Windows guests under Firecracker |
| [ADR-0168](0168-guest-coding-cli-dangerous-defaults.md) | accepted | partial | Dangerous native defaults for guest coding CLIs |
| [ADR-0167](0167-native-guest-coding-clis.md) | superseded | partial | Native guest coding CLIs configured for Ziggy |
| [ADR-0166](0166-resize-hardening.md) | accepted | partial | Resize hardening: Porsche command, named refusals, recorded stop evidence and pre-mutation cancellation |
| [ADR-0165](0165-restart-only-changed-units.md) | accepted | partial | Activation restarts only changed units |
| [ADR-0164](0164-arc-budget-and-safe-memory-decrease.md) | accepted | partial | ARC budget, dnode limit and safe guest memory decrease |
| [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md) | accepted | partial | Bounded standby refill and capacity damping |
| [ADR-0162](0162-clone-cleanup-liveness.md) | accepted | partial | Clone cleanup liveness and transfer slot release at quiescence |
| [ADR-0161](0161-monospace-web-presentation.md) | superseded | partial | Monospace Web presentation for Marshall |
| [ADR-0160](0160-privileged-administrator-step-up.md) | accepted | partial | Privileged administrator step-up and pending-action continuation |
| [ADR-0159](0159-remove-legacy-compatibility.md) | superseded | implemented | Remove legacy compatibility after convergence |
| [ADR-0158](0158-durable-guest-identities.md) | superseded | partial | Durable guest identities independent of email |
| [ADR-0157](0157-multi-provider-authenticated-repository-launch.md) | accepted | implemented | Multi-provider repository launch and authentication resume |
| [ADR-0156](0156-browser-launcher-distribution.md) | accepted | partial | Browser launcher build, distribution and exact-origin presence detection |
| [ADR-0151](0151-existing-state-standard-profile-migration.md) | superseded | partial | Existing-state Standard profile migration |
| [ADR-0152](0152-lean-pool-locked-preparation.md) | accepted | partial | Lean pool-locked disk preparation |
| [ADR-0154](0154-guest-boot-profile.md) | accepted | partial | Guest boot profile and measured boot reductions |
| [ADR-0155](0155-stopped-only-relocation.md) | superseded | partial | Stopped-only relocation |
| [ADR-0150](0150-default-guest-starship.md) | accepted | implemented | Default Starship prompts in guest images |
| [ADR-0149](0149-independent-observability.md) | superseded | partial | Independent observability and control documents |
| [ADR-0148](0148-open-domain-email-eligibility.md) | superseded | partial | Safe email eligibility across domains |
| [ADR-0147](0147-standard-profile-name.md) | accepted | partial | Standard profile naming for fresh installations |
| [ADR-0142](0142-overallsprotocol-control-websocket.md) | accepted | partial | OverallsProtocol control WebSocket |
| [ADR-0141](0141-control-plane-hints-and-resync.md) | accepted | partial | Control-plane hints and resync |
| [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md) | accepted | partial | Event-driven liveness and authority with single-writer views |
| [ADR-0143](0143-faster-create-clone-delete.md) | accepted | partial | Kernel copy offload, compressed local clone streams and identity-fenced deletion |
| [ADR-0144](0144-nix-builds-exclude-guest-datasets.md) | accepted | partial | Keep guest datasets out of Nix build namespaces |
| [ADR-0145](0145-same-pool-block-cloned-clones.md) | accepted | partial | Block-cloned disks for same-pool clones |
| [ADR-0146](0146-standby-guest-disks.md) | superseded | partial | Pre-cloned standby guest disks |
| [ADR-0137](0137-public-authenticated-grafana.md) | accepted | partial | Public authenticated Grafana |
| [ADR-0138](0138-telemetry-retention-and-measurement-diagnostics.md) | superseded | partial | Telemetry retention and measurement diagnostics |
| [ADR-0139](0139-private-slo-burn-delivery.md) | accepted | partial | Private SLO burn notification delivery |
| [ADR-0136](0136-durable-application-request-accounting.md) | superseded | partial | Durable application request accounting |
| [ADR-0133](0133-durable-physical-service-level-accounting.md) | superseded | partial | Durable physical service level accounting |
| [ADR-0135](0135-streaming-public-artifact-cache.md) | superseded | partial | Streaming public artifact cache |
| [ADR-0134](0134-personal-integration-owner-eligibility.md) | accepted | implemented | Explicit personal integration attachments |
| [ADR-0132](0132-seven-day-provisional-fleet-objectives.md) | superseded | partial | Seven-day provisional fleet objectives |
| [ADR-0131](0131-automatic-magic-link-sign-in.md) | superseded | partial | Automatic magic-link browser sign-in |
| [ADR-0130](0130-verified-provisioning-fastpath.md) | accepted | partial | Verified provisioning templates and boot readiness |
| [ADR-0129](0129-fleet-otel-slos.md) | superseded | partial | Fleet OpenTelemetry SLOs and guest diagnostic ingestion |
| [ADR-0128](0128-repository-launch-links.md) | superseded | implemented | Repository launch links and guest-cloned workspaces |
| [ADR-0127](0127-fleet-log-store-viewer.md) | superseded | partial | Fleet diagnostic log store and Control room viewer |
| [ADR-0125](0125-fresh-guest-identities.md) | superseded | partial | Fresh guest identities after mailbox reuse |
| [ADR-0126](0126-bounded-database-client-recovery.md) | superseded | implemented | Bounded database recovery after client machine loss |
| [ADR-0123](0123-remembered-browser-authority.md) | superseded | partial | Remembered browser authentication and revocation |
| [ADR-0120](0120-ssh-onboarding-guidance.md) | accepted | implemented | SSH onboarding guidance |
| [ADR-0119](0119-authenticated-control-room-reads.md) | superseded | implemented | Authenticated read access to the Control room |
| [ADR-0118](0118-installer-management-ssh-trust.md) | superseded | partial | Fingerprint-verified installer management SSH trust |
| [ADR-0117](0117-personal-terminal-machine-workspace.md) | superseded | partial | Personal terminals in the machine workspace |
| [ADR-0116](0116-overview-without-usage-summary.md) | superseded | implemented | Overview without a usage summary |
| [ADR-0115](0115-ssh-roster-boot-authority.md) | superseded | implemented | SSH roster authority during a verified boot |
| [ADR-0114](0114-overalls-workspace-design.md) | superseded | implemented | Overalls workspace navigation and Nekomo presentation |
| [ADR-0113](0113-guest-trust-at-boot.md) | accepted | partial | Boot-bound guest platform trust delivery |
| [ADR-0112](0112-zfs-namespace-delete.md) | accepted | implemented | Fenced ZFS deletion across mount namespaces |
| [ADR-0111](0111-private-service-tls-names.md) | accepted | partial | Verifiable private-service certificate names |
| [ADR-0110](0110-cedar-guest-ssh-accounts.md) | superseded | partial | Cedar-authorized guest SSH accounts |
| [ADR-0109](0109-brady-fleet-ca.md) | superseded | partial | Fleet Brady CA and host signers |
| [ADR-0108](0108-guest-agent-web-fetch.md) | accepted | partial | Guest-executed agent web fetch |
| [ADR-0107](0107-marshall-owned-agent-web-search.md) | accepted | partial | Marshall-owned agent web search |
| [ADR-0106](0106-inception-child-audi-wildcard.md) | accepted | partial | Inception child Audi wildcard |
| [ADR-0105](0105-public-audi-wildcard-custody.md) | superseded | partial | Public Audi wildcard issuance and encrypted custody |
| [ADR-0104](0104-private-guest-cli-updates.md) | accepted | partial | Private guest CLI updates |
| [ADR-0103](0103-profile-scoped-agent-capabilities.md) | superseded | implemented | Profile-scoped agent capabilities |
| [ADR-0102](0102-local-underclass-monitor-socket.md) | accepted | partial | Local Underclass monitor socket |
| [ADR-0101](0101-browser-approved-agent-cli.md) | accepted | partial | Browser-approved agent CLI sessions |
| [ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) | accepted | partial | Pulled agent work over Ziggy control |
| [ADR-0099](0099-marshall-owned-agent-threads.md) | superseded | partial | Marshall-owned agent threads and VM tool executors |
| [ADR-0098](0098-image-artifact-limits.md) | accepted | implemented | Expanded image artifact admission limits |
| [ADR-0096](0096-lyra-developer-ssh.md) | superseded | partial | Lyra developer SSH client |
| [ADR-0095](0095-dns-resolved-fleet-control-origin.md) | accepted | implemented | DNS-resolved fleet control origin |
| [ADR-0094](0094-default-development-environments.md) | superseded | partial | Default development environments on fleets and guests |
| [ADR-0093](0093-audi-mediated-guest-ssh.md) | superseded | implemented | Audi-mediated guest SSH |
| [ADR-0092](0092-portable-workload-bundles.md) | accepted | partial | Portable workload bundles and visible current hosts |
| [ADR-0091](0091-fleet-perimeter-public-listeners.md) | accepted | partial | Fleet perimeter public listeners for Audi |
| [ADR-0090](0090-second-audi-dns-replica-on-worker.md) | accepted | partial | Second Audi DNS replica on the worker host |
| [ADR-0089](0089-porsche-user-relocation.md) | superseded | implemented | User relocation through Porsche SSH |
| [ADR-0088](0088-legacy-vm-journal-import.md) | superseded | partial | Exact legacy VM journal import |
| [ADR-0087](0087-compact-nix-build-logs.md) | superseded | implemented | Native compact Nix build output and indexed local evidence |
| [ADR-0081](0081-independent-underclass-pools.md) | superseded | partial | Independent Underclass pools over the fleet overlay |
| [ADR-0080](0080-named-edge-integrations.md) | accepted | partial | Named edge integrations and renewable admission leases (Galileo) |
| [ADR-0079](0079-peer-vm-vm-attestation.md) | accepted | partial | Peer VM-to-VM integrations |
| [ADR-0078](0078-fleet-wildcard-certificate.md) | superseded | implemented | Fleet wildcard private-service certificate |
| [ADR-0077](0077-teams-and-shared-resources.md) | accepted | partial | Teams and shared resources |
| [ADR-0076](0076-default-guest-toolset.md) | superseded | implemented | Default guest toolset |
| [ADR-0075](0075-fleet-overlay-and-source-access.md) | accepted | partial | Fleet overlay and source access |
| [ADR-0073](0073-bounded-nix-store-reclamation.md) | accepted | partial | Bounded Nix store garbage collection |
| [ADR-0084](0084-browser-terminal-workspace.md) | superseded | implemented | Browser terminal workspace |
| [ADR-0083](0083-terminal-host-stream-and-registry.md) | accepted | implemented | Terminal host stream and registry |
| [ADR-0082](0082-guest-terminal-multiplexer.md) | accepted | partial | Guest terminal multiplexer |
| [ADR-0072](0072-multi-disk-workload-transfer.md) | superseded | partial | Multi-disk workload transfer |
| [ADR-0071](0071-required-lilly-transfer.md) | accepted | partial | Required Lilly transfer service |
| [ADR-0063](0063-private-services-and-ziggy.md) | superseded | partial | Private guest services and Ziggy inference |
| [ADR-0065](0065-passkey-administration.md) | superseded | partial | Passkey MFA and time-limited administrative authority |
| [ADR-0066](0066-account-retirement.md) | superseded | partial | Invitations and cascading account retirement |
| [ADR-0001](0001-architecture-governance.md) | accepted | implemented | Architecture governance and monorepo |
| [ADR-0002](0002-elixir-ash-and-types.md) | accepted | partial | Elixir, Ash domains and type checking |
| [ADR-0003](0003-control-plane-coordination.md) | accepted | partial | Control-plane coordination |
| [ADR-0004](0004-lilly-and-vm-actors.md) | accepted | partial | Lilly and VM actors |
| [ADR-0005](0005-vm-lifecycle-and-storage.md) | superseded | partial | VM lifecycle and local storage |
| [ADR-0006](0006-capacity-accounting.md) | superseded | partial | Capacity accounting and telemetry |
| [ADR-0007](0007-profile-networking.md) | superseded | partial | Profile networking and isolation |
| [ADR-0008](0008-identity-sharing-and-terminal.md) | superseded | partial | Identity, sharing and terminal access |
| [ADR-0009](0009-assurance-and-testing.md) | superseded | partial | Audit, secrets, logging and verification |
| [ADR-0010](0010-capacity-admission-transactions.md) | superseded | partial | Capacity admission transactions and Cedar entry points |
| [ADR-0011](0011-nixos-guest-and-console.md) | accepted | partial | NixOS guest image and local serial console |
| [ADR-0012](0012-provisioner-control-transport.md) | superseded | partial | Authenticated provisioner control exchanges |
| [ADR-0013](0013-capacity-collection-and-local-receipt.md) | superseded | partial | Capacity collection and durable Lilly receipt |
| [ADR-0014](0014-image-and-address-admission.md) | superseded | partial | Immutable images and profile address admission |
| [ADR-0015](0015-jailed-execution-and-host-networking.md) | superseded | partial | Jailed execution and host networking |
| [ADR-0016](0016-executable-generations-and-lifecycle.md) | superseded | partial | Executable generations and lifecycle outcomes |
| [ADR-0017](0017-durable-vm-actors-and-host-ownership.md) | accepted | partial | Durable VM actors and physical host ownership |
| [ADR-0018](0018-persisted-sharing-and-user-machine-access.md) | superseded | implemented | Persisted sharing and user machine access |
| [ADR-0019](0019-terminal-session-and-writer-authority.md) | superseded | implemented | Terminal session and writer authority |
| [ADR-0020](0020-local-console-fences-and-bounded-streams.md) | superseded | implemented | Local console fences and bounded streams |
| [ADR-0021](0021-console-relay-connections-and-mailboxes.md) | superseded | implemented | Console relay connections and bounded mailboxes |
| [ADR-0022](0022-browser-terminal-and-live-login-checks.md) | superseded | implemented | Browser terminal and fresh LiveView login checks |
| [ADR-0023](0023-retained-capacity-telemetry.md) | superseded | implemented | Retained capacity telemetry |
| [ADR-0024](0024-durable-magic-link-email.md) | superseded | implemented | Durable magic-link email |
| [ADR-0025](0025-protected-provisioner-enrollment.md) | superseded | implemented | Protected provisioner enrollment files |
| [ADR-0026](0026-host-maintenance-and-retirement.md) | accepted | implemented | Host maintenance drain and retirement |
| [ADR-0027](0027-production-release-deployment.md) | superseded | implemented | Production release deployment |
| [ADR-0028](0028-colocated-code-contracts.md) | accepted | implemented | Colocated code contracts and structural gates |
| [ADR-0029](0029-database-durability-and-recovery.md) | superseded | partial | Database durability and recovery boundaries |
| [ADR-0030](0030-nixos-deployment-and-tls.md) | superseded | partial | NixOS deployment and TLS |
| [ADR-0031](0031-sparse-zfs-storage-and-capacity.md) | superseded | partial | Sparse ZFS storage and capacity |
| [ADR-0032](0032-ssh-derived-age-identities.md) | superseded | partial | SSH-derived age identities |
| [ADR-0033](0033-nixos-machine-verification.md) | superseded | partial | NixOS machine verification |
| [ADR-0034](0034-mixed-workload-storage-tuning.md) | proposed | planned | Mixed-workload storage tuning |
| [ADR-0035](0035-zfs-only-provisioning.md) | superseded | implemented | ZFS-only provisioning and provisioner v2 |
| [ADR-0036](0036-automatic-host-updates.md) | superseded | partial | Automatic host updates with verified recovery |
| [ADR-0037](0037-workload-placement-and-relocation.md) | superseded | partial | Workload placements and fenced ZFS relocation |
| [ADR-0038](0038-http01-validation-and-peer-routing.md) | superseded | partial | HTTP-01 validation and peer routing |
| [ADR-0039](0039-opt-in-host-tcp-profile.md) | accepted | implemented | Opt-in host TCP profile |
| [ADR-0040](0040-host-local-smtp-relay.md) | accepted | implemented | Host-local synchronous SMTP relay |
| [ADR-0041](0041-declarative-fleet-users.md) | superseded | partial | Declarative fleet users and recovery recipients |

| [ADR-0042](0042-host-observability.md) | accepted | partial | Host-local observability and restricted diagnostic evidence |
| [ADR-0043](0043-declarative-host-provisioning.md) | superseded | partial | Declarative bare-metal host provisioning |
| [ADR-0044](0044-recovery-only-secret-documents.md) | superseded | implemented | Recovery-only secret documents |
| [ADR-0045](0045-declarative-lilly-enrollment.md) | accepted | implemented | Declarative Lilly enrollment preparation |
| [ADR-0046](0046-porsche-ssh-management.md) | accepted | implemented | Porsche SSH machine management |
| [ADR-0047](0047-audi-ingress-and-authoritative-dns.md) | superseded | implemented | Audi ingress and authoritative DNS |
| [ADR-0048](0048-single-host-service-deployment.md) | superseded | partial | Single-host service deployment |

| [ADR-0049](0049-organizational-email-registration.md) | superseded | implemented | Organizational email registration |

| [ADR-0050](0050-usage-based-overcommit.md) | superseded | implemented | Usage-based overcommit and mutable host budgets |
| [ADR-0051](0051-vm-resizing.md) | superseded | partial | Durable stopped VM resizing |

| [ADR-0052](0052-fenced-local-guest-ingress.md) | superseded | partial | Fenced local guest ingress |

ADR-0118's [verification review](../reviews/2026-09-25-installer-verification.md)
tracks generated refusal properties and the focused Linux installer/account-proof
journey; macOS and production rollout remain outside that evidence.

ADR-0031's partial implementation now includes scoped native pool I/O and separate
dataset-capacity provenance; ADR-0033 records its real machine verification.
The [I/O review](../reviews/2026-09-16-native-zfs-io.md) records results and limits.
The [completion audit](../reviews/2026-09-16-plan-completion-audit.md) reconciles
current source/test evidence with the original requirements and remaining inputs.
The [Nix refactor review](../reviews/2026-09-16-nix-layout-and-test-refactor.md)
tracks the new file organization and verification without changing these statuses.

ADR-0030/0033 also track generic mirrored installation artifacts and passing
firmware installation and surviving-disk checks in the
[installation review](../reviews/2026-09-16-mirrored-installation.md).
Both installer-created disks and the exact public QCOW2 artifacts have passed;
the latter required a clean root-pool export in the image builder.
The existing reference host has not been adapted or activated.

The [fleet review](../reviews/2026-09-16-nixos-fleet.md) tracks the new distinct
Marshall/Lilly machine suite and a corrected release-cookie launch defect.
Its execution evidence and remaining cases do not change partial statuses.

ADR-0030 replaces ADR-0027's deployment/TLS choices. ADR-0031 replaces the
storage portions of ADR-0013 and ADR-0015 and explicitly carries forward their
other contracts. Superseded records retain historical implementation evidence.
NixOS deployment, secret custody, ACME publication and machine tests are partially
implemented; ZFS identity/accounting contracts and native observation primitives
exist, and Lilly now connects owned sparse disks to v2 collection and lifecycle.
The ZFS-only revision passed all fifteen Nix checks and all three application
gates; the [review](../reviews/2026-09-16-zfs-only-provisioning.md) records exact
derivations and limits. Production deployment acceptance remains separate. ADR-0034's numerical tuning candidates
remain proposed pending measurements.

ADR-0037 remains partial. Explicit destination retry now has application evidence;
its native acceptance remains pending. One complete native guest move now passes; return
admission and the newly implemented native failure/pressure/update matrix remain
under verification. Its [relocation review](../reviews/2026-09-16-workload-relocation.md)
now records native exporter supervision and passing OpenSSH permit/key delivery
checks. The installed export service passed its two-node native check;
authenticated destination key preparation now connects PostgreSQL, Oban and
Lilly's local key worker. Source permits, received-final adoption and atomic
placement/epoch handoff with activation outbox now have control-plane tests.
The activation-bound readiness exchange now has durable timeout and boot receipt
checks. Source retirement now connects native cleanup receipts to ordinary delete
outcomes and destination key retirement before capacity release, with local, HTTPS
and three-Marshall verification. Cancellation intent excludes handoff and now
records source-export revocation, fresh-epoch source restoration and a separate
snapshot cleanup exchange with passing control checks. Native baseline-source
restoration passed. Destination reclamation now has a local execution fence and
intent-based cleanup with passing native storage checks, an authenticated exchange
and cancellation completion retaining the restored source. Ordinary start/stop and
bounded crash recovery now resume after restoration/readiness during pending cleanup.
Bounded failed-restoration retries now pass application tests and forced Dialyzer;
the source snapshot-cleanup guest suite passes. Logical Delete now coordinates both
copies with passing application/distributed checks; local native guest acceptance passes. Archived late-receipt locking is fixed and
verified across three Marshall nodes. Probe-only source leases now share export key
binding and revocation. Restricted probe endpoint dispatch passes local tests;
the destination client now compares bounded probe responses over the same pinned
transport. A shared codec now separates source grant and destination probe
results; Lilly effect guards check source execution and destination key identity.
Native pinned SSH probe/refusal checks pass; Lilly now has a separate probe worker.
Marshall probe route/outbox and fresh preflight stop validation are in progress;
full two-Lilly guest acceptance remains outstanding. Full-copy preflight, progress/resume refinements, public admission/UI
and end-to-end acceptance remain open.
Destination cancellation now has a separate key-fence/quiescence exchange and
both-receipt stream-slot release with passing application and native checks.
Committed moves now share this early slot-release path; all three application
gates and schema consistency pass.
ADR-0028 now covers installed skill assets through their development-only subtree
contract, preserving the existing release allowlist and validator behavior.

| [ADR-0068](0068-nix-built-ubuntu-guests.md) | accepted | partial | Nix-built customizable Ubuntu guests |
| [ADR-0064](0064-customer-workspace-isolation.md) | superseded | partial | Customer workspace isolation |

The [team creation verification](../reviews/2026-09-25-team-creation-verification.md)
adds execution evidence for ADR-0077 without changing its accepted or partial status.
The [Teams SSH verification](../reviews/2026-09-25-team-ssh-verification.md) adds
generated HTTP and packaged CLI execution for ADR-0046/0077: stable refusals,
consent/removal and pinned historical receipts retain their existing authority
boundaries. Native team-owned guest/integration access remains separate.

Audi terminal-version evidence now covers generated owner/job retirement and
packaged DNS expiry/operator restart under ADR-0090/0105; accepted decisions and
partial implementation statuses remain unchanged. See the
[review](../reviews/2026-10-03-audi-terminal-version-refusal.md).

## Format and lifecycle

ADR-0101's [CLI verification review](../reviews/2026-09-25-agent-cli-verification.md)
records passing generated current-authority histories and the ordinary
browser/packaged-CLI/native-guest journey. An earlier executor interruption
remains unexplained; the passing native capture predates the Underclass pin.
Accepted authority and partial status are preserved, and the obsolete curl
implementation description is reconciled with native HTTPS.

ADR-0082–0084's [integration follow-up](../reviews/2026-09-20-terminal-integration-follow-up.md)
tracks create recovery, background reconciliation and independent frontend TLS
peer routing. Component gates and the dedicated/full native fleet suites pass;
implementation remains partial for the remaining feature/load and deployment
acceptance described in that review.

ADR-0085 remains partial. Its
[current reconciliation audit](../reviews/2026-09-18-inception-public-ingress.md)
records passing application gates and isolated nested-image rebuilding, with
native first-environment readiness and full public acceptance still outstanding.

Copy [the template](template.md) to the next unused `NNNN-short-title.md`. Never
reuse an ID, including IDs belonging to rejected or superseded records. Use the
exact metadata keys and section headings in the template. Metadata values are
single-line text, not YAML. Dates use `YYYY-MM-DD` and components are comma
separated. `Supersedes` and `Superseded by` are `none` or comma-separated ADR IDs;
link related records in the Related decisions section.

- Decision status: `proposed`, `accepted`, `rejected`, `superseded`.
- Implementation: `planned`, `partial`, `implemented`.
- New unresolved choices are proposed. Existing explicit task/plan authorization
  can establish acceptance without a new confirmation ceremony.
- Correct facts and update evidence in place. Replace material accepted
  decisions through a new ADR; mark the previous record superseded and connect
  both records. A proposed replacement can describe its intended predecessor in
  Related decisions; activate metadata supersession only when it is accepted.
- A superseded ADR keeps its historical implementation status and evidence.
  Rejected/proposed records can document experimental implementations when the
  evidence clearly identifies them; implementation never implies acceptance.

Partial or implemented records must link to existing implementation artifacts
outside `docs/architecture/` in Implementation evidence. Describe the scope of
each link; a dependency entry is not proof of an operational capability. The
validator checks that links are repository paths outside `docs/architecture/`, not
that they still exist; reviewers assess presence and sufficiency.

Use inline Markdown links with relative paths and no spaces/parentheses in
targets. Local fragments may be used, but only file existence is checked.
External links are not fetched. The validator checks all Markdown files under
`docs/architecture/`, including the index, overview, template and reviews.

Run `elixir scripts/check_adrs.exs` from the repository root, or
`elixir ../scripts/check_adrs.exs` from Marshall. It rejects malformed metadata,
duplicate/mismatched IDs, invalid statuses/dates, missing sections, stale or
incomplete index entries, missing local/ADR references, contradictory
supersession, cycles and unsupported implementation claims without evidence.
It cannot establish semantic correctness, security or runtime behavior.

| [ADR-0097](0097-enrico-git-mirrors.md) | accepted | partial | Enrico Git mirrors |

ADR-0043 now has [physical overalls installation evidence](../reviews/2026-09-17-overalls-provisioning.md); its remaining provider matrix keeps implementation partial.

ADR-0037 now exposes authorized automatic relocation through its Compute Ash action;
focused authorization/idempotency/capacity tests and public-entry distributed races
pass. Initial manager move/cancel controls and bounded progress status pass 14
machine LiveView tests. Observed downtime passes focused source tests; rendered
desktop/mobile review also passes. One complete native move now passes after the
retry-clock correction; return and failure-matrix acceptance remain open. Authenticated bounded receive-progress
persistence is now wired through the shared protocol; its 45 focused tests pass. This carries forward relocation requirements through ADR-0050 and ADR-0053.


| [ADR-0058](0058-administrative-authority.md) | superseded | partial | Administrative account authority |

| [ADR-0059](0059-administrative-job-history.md) | superseded | partial | Administrative job history and intervention |

| [ADR-0060](0060-detailed-fleet-monitoring.md) | superseded | partial | Detailed fleet resource monitoring |
| [ADR-0061](0061-maintenance-evacuation.md) | superseded | partial | Maintenance evacuation campaigns |

| [ADR-0053](0053-vm-disk-limit.md) | superseded | implemented | Maximum VM disk capacity |

ADR-0017 directory reclamation now includes safe empty-mountpoint removal and
retained-record retries; see the [cleanup review](../reviews/2026-09-18-vm-directory-cleanup.md).

| [ADR-0054](0054-inception-development-profile.md) | superseded | partial | Inception development profile |

ADR-0036 and ADR-0047 now include private, role-bound Audi readiness in the
automatic updater. The bounded fleet test passes gateway and DNS package
updates, unhealthy-candidate rejection and corrective-revision recovery while
preserving the guest process. Final merged acceptance includes custody permission
loss, daemon crash and relocation; these bounded scenarios do not establish
production fleet capacity or arbitrary failure tolerance.

| [ADR-0055](0055-queued-machine-cloning.md) | superseded | implemented | Queued machine cloning through Ash and Oban |

The [2026-09-25 production clone/relocation acceptance](../reviews/2026-09-25-production-clone-relocation.md)
records a retained transfer slot after source restart failure that blocked new
copies and moves. Historical native verification remains scoped to its recorded
revisions; recovery and renewed production acceptance are outstanding.

ADR-0047's exported `audi-relocation-fleet` scenario now passes a real move,
stable names, strict gateway key lookup, retained guest data and stale-source
refusal. The final merged script passes in 1520.47 seconds, including the latest
cleanup and custody recovery changes. The user removed scale
investigation from implementation scope on September 18.

| [ADR-0062](0062-interactive-monitoring-dashboards.md) | superseded | implemented | Interactive monitoring dashboards |

| [ADR-0067](0067-reciprocal-nix-builders.md) | superseded | implemented | Reciprocal Nix builders and authenticated SSH caches |
| [ADR-0086](0086-reciprocal-nix-caches.md) | superseded | partial | Reciprocal Nix caches without peer build delegation |
| [ADR-0085](0085-inception-public-ingress.md) | superseded | partial | IPv4 service separation and public Inception ingress |
| [ADR-0074](0074-durable-lifecycle-state-machines.md) | superseded | partial | Durable lifecycle state machines and audit |

ADR-0046 now includes bounded interactive editing and channel-local history; see
the [prompt review](../reviews/2026-09-18-porsche-interactive-input.md).

| [ADR-0069](0069-brady-egress-cache.md) | superseded | implemented | Brady transparent guest egress cache |

ADR-0069's [cache history review](../reviews/2026-09-26-cache-history-verification.md)
adds component lifetime/privacy properties and clarifies the existing range
lookup contract; accepted behavior and implementation status are unchanged.

| [ADR-0070](0070-host-recovery-backups.md) | accepted | implemented | Short-retention host recovery backups |

| [ADR-0121](0121-authenticated-hldd.md) | superseded | implemented | Authenticated handbook and mandatory maintenance |
| [ADR-0122](0122-hldd-section-pages.md) | superseded | implemented | Separate handbook sections and bounded browser content |
| [ADR-0124](0124-unified-ssh-host-ca.md) | accepted | implemented | One SSH host CA for gateways and guests |

ADR-0119 and inherited ADR-0065 gain generated and native browser evidence in the
[Control room verification review](../reviews/2026-09-25-control-room-verification.md).

Account retirement verification adds generated identity histories and a scoped native journey;
see [ADR-0066](0066-account-retirement.md) and its current execution review.

ADR-0033's inherited verification requirement now records
[standalone browser type gates](../reviews/2026-09-25-browser-type-gates.md) and the
[completed legacy sweep](../reviews/2026-09-26-browser-typing-sweep.md).
Its historical native evidence and partial implementation status remain unchanged.

Credential registration/retirement ordering adds generated and three-Marshall evidence
under [ADR-0066](0066-account-retirement.md) and [ADR-0046](0046-porsche-ssh-management.md);
see the [credential workflow review](../reviews/2026-09-25-credential-lifecycle-verification.md).

ADR-0079 and ADR-0080 retain accepted/partial status. The
[renewal verification review](../reviews/2026-09-25-integration-renewal-verification.md)
adds recorded generated current-authority and three-replica token-consumption
evidence and captured passing native live membership/attachment withdrawal,
original socket closure without retry and restored fresh requests.

ADR-0059/0119 requirements inherited by ADR-0123 gain generated and three-Marshall retry/history evidence; the [job-history review](../reviews/2026-09-25-job-history-verification.md) records native/full-gate scope separately.

ADR-0077 and ADR-0105 gain private team browser authorization/renewal evidence; the
[private web review](../reviews/2026-09-25-private-web-verification.md) records the
Cedar omission, correction and exact generated/native execution scope.

Administrative account mutation authority adds scoped evidence for inherited ADR-0058/0065 through ADR-0123 and accepted ADR-0066; see the [verification review](../reviews/2026-09-25-admin-account-authority-verification.md). Decision and implementation statuses remain unchanged.

ADR-0070 gains [backup operator verification](../reviews/2026-09-26-backup-operator-verification.md)
through generated local encrypted Restic histories. Its accepted/implemented status
and the original native recovery evidence remain unchanged.

ADR-0061 retains accepted/partial status. Its [maintenance verification review](../reviews/2026-09-25-maintenance-evacuation-verification.md)
records generated histories, control/revocation ordering and the bounded native
browser campaign fixture separately from existing relocation acceptance.

ADR-0083 gains generated real-socket ticket and current-authority evidence in the
[attachment-history review](../reviews/2026-09-26-terminal-attachment-verification.md).
Its decision and implementation status and prior native scope are unchanged.

The [executor-loss verification review](../reviews/2026-09-26-executor-loss-histories.md)
tracks ADR-0100/0101 composed loss/retry evidence without changing either partial status.

ADR-0055 and ADR-0066 gain bounded generated cancellation/current-authority and
three-independent-BEAM ordering evidence in the
[clone verification review](../reviews/2026-09-25-clone-cancellation-verification.md).
Native execution status is recorded separately; ADR-0072 remains partial.
ADR-0092 also records the narrowly repaired retained-disk retry classification;
invalid disk and boot-bundle evidence remain terminal.

ADR-0082 gains scoped explicit-kill credit-retirement evidence in the
[review](../reviews/2026-10-03-terminald-credit-retirement.md); accepted and partial statuses remain unchanged.

Its [actual growth review](../reviews/2026-10-05-terminald-growth-backing.md)
records 51 passing native tests, independent 64 MiB aggregate backing checks and
a 128 MiB original-append counterexample. Simultaneous mixed pressure and
authenticated guest/hosted composition remain open; status remains partial.

Its [mixed growth review](../reviews/2026-10-05-terminald-mixed-growth.md)
adds local default64MiB stalled-viewer/growth/admission contention evidence;
52native tests and Clippy, Marshall1451checks and forced Dialyzer passed.
Authenticated guest/hosted acceptance remains separate; implementation stays partial.

The [native readiness history review](../reviews/2026-10-03-lilly-runtime-readiness.md) records passing 897.72-second native readiness execution for ADR-0017 and ADR-0036; implementation remains partial.

ADR-0050 carries ADR-0010's idempotency requirements; the [lost reply review](../reviews/2026-10-05-admission-lost-reply.md) records generated committed worker/BEAM loss and three-node retry evidence. Native dispatch and pre-commit ambiguity remain separate.
ADR-0017 gains a [submission recovery scenario](../reviews/2026-10-05-lilly-submission-recovery.md) whose native subtest passed337.69seconds with composed-driver static checks; accepted and partial statuses remain unchanged.

| [ADR-0153](0153-official-source-browser-editor.md) | superseded | partial | Official-source personal browser editor |
Native helper custody evidence now includes actual escaped-descendant completion
and failure histories, repaired host-lock/transfer packages and scoped selector
mutations. Source/test identity after integration is distinct from full consumer
and physical storage acceptance. See the
[host-lock review](../reviews/2026-10-05-host-lock-descendant-custody.md) and
[transfer review](../reviews/2026-10-05-transfer-stream-adopted-children.md);
ADR-0015/0037 retain their statuses and accepted rationale.

| [ADR-0201](0201-localized-human-surfaces.md) | accepted | partial | Localized human-facing surfaces |
| [ADR-0207](0207-bundled-multilingual-font-fallback.md) | accepted | partial | Bundled multilingual font fallback |
| [ADR-0220](0220-mila-client-over-porsche-ssh.md) | accepted | partial | Mila, the Overalls client over Porsche SSH |
| [ADR-0221](0221-canonical-app-routes.md) | accepted | partial | Canonical `overalls://` app routes |
| [ADR-0222](0222-porsche-client-commands.md) | accepted | partial | Porsche thread, web, device and watch commands for clients |
| [ADR-0223](0223-porsche-terminal-attach.md) | accepted | partial | Porsche terminal attach through a Marshall gateway stream |
| [ADR-0224](0224-susan-push-relay.md) | accepted | partial | Susan, the push relay at notifications.overalls.dev |
| [ADR-0225](0225-marshall-notifications-domain.md) | accepted | partial | Marshall Notifications domain |
| [ADR-0226](0226-monospace-web-on-flutter.md) | accepted | partial | The Monospace Web on Flutter |
| [ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md) | accepted | partial | Flutter toolchain, patched dartssh2 overlay and Mila checks in Nix |
| [ADR-0228](0228-strict-host-certificates-in-mila.md) | accepted | partial | Strict SSH host-certificate verification in Mila |
| [ADR-0229](0229-scim-managed-identity-and-teams.md) | accepted | partial | SCIM-managed identity and teams |
| [ADR-0230](0230-terminal-image-decoder-webassembly.md) | accepted | partial | WebAssembly compilation for the terminal image decoder |
| [ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) | accepted | partial | Hetzner Cloud fleet hosts and Susan placement |
| [ADR-0232](0232-sops-delivered-public-host-addresses.md) | superseded | partial | SOPS-delivered public host addresses |
| [ADR-0233](0233-fleet-addresses-from-sops.md) | accepted | partial | Fleet addresses from SOPS and the Susan fleet path |
| [ADR-0234](0234-installer-source-administrative-grant.md) | accepted | partial | Installer source grant for administrative SSH |
| [ADR-0235](0235-mila-desktop-clients.md) | accepted | partial | Mila desktop clients for macOS and Windows |
| [ADR-0236](0236-susan-wns-provider.md) | accepted | partial | Susan WNS provider and channel-host egress |
| [ADR-0237](0237-windows-custodian-same-boot-recovery.md) | accepted | partial | Windows custodian same-boot recovery by logon-session quiescence |
| [ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md) | accepted | partial | Panterloons deployment and per-deployment fleet tunnels |
| [ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) | accepted | partial | Salopettes joins the Panterloons tunnel |
| [ADR-0240](0240-account-machine-creation-presets.md) | accepted | partial | Three account machine creation presets |
| [ADR-0241](0241-sops-tailscale-auto-join.md) | accepted | partial | SOPS-delivered automatic Tailscale joining |
| [ADR-0243](0243-native-guest-durability-verification.md) | accepted | partial | Native guest durability across interrupted growth, host power loss and relocation |
| [ADR-0245](0245-underclass-egress-node-tag.md) | accepted | partial | Underclass egress node tag |
| [ADR-0246](0246-panterloons-control-plane-deployment.md) | accepted | partial | Panterloons control-plane deployment |
| [ADR-0247](0247-sops-operator-source-grant.md) | accepted | partial | SOPS-held operator source grant |
| [ADR-0248](0248-fleet-build-scheduling.md) | accepted | partial | Fleet build scheduling through a tribuchet hub and grpc:// stores |
| [ADR-0250](0250-independent-hldd-review-records.md) | superseded | implemented | Independent HLDD review records |
| [ADR-0249](0249-mila-rust-core-native-clients.md) | accepted | partial | Mila Rust core with native platform clients |
| [ADR-0251](0251-thread-owned-durable-attachments.md) | accepted | partial | Thread-owned durable attachments |
| [ADR-0252](0252-profile-boards-and-thread-subscriptions.md) | accepted | partial | Profile boards and authorized thread subscriptions |
| [ADR-0262](0262-inception-development-checkout.md) | accepted | implemented | Inception development checkout |
| [ADR-0263](0263-retire-hldd.md) | accepted | implemented | Retire the HLDD handbook and its review gates |
| [ADR-0253](0253-artifacts-domain.md) | accepted | partial | Artifacts domain for agent-published pages |
| [ADR-0254](0254-isolated-artifact-content-origin.md) | accepted | partial | Isolated artifact content origin |
| [ADR-0255](0255-thread-lifecycle-and-server-tool-dispatch.md) | accepted | partial | Thread lifecycle state machine and Oban server-tool dispatch |
| [ADR-0256](0256-batched-page-authorization-snapshots.md) | accepted | partial | Batched page authorization over one read-only snapshot |
| [ADR-0257](0257-liveview-callback-observability.md) | accepted | partial | Trace every Marshall LiveView callback |
| [ADR-0258](0258-marshall-page-service-levels.md) | accepted | partial | Marshall page interaction service levels |
| [ADR-0259](0259-deployment-revision-telemetry.md) | accepted | partial | Deployment revision in telemetry provenance |
| [ADR-0260](0260-underclass-egress-without-exit-node.md) | accepted | partial | Underclass egress proxy without an exit node |
| [ADR-0261](0261-thread-feed-turn-notifications-and-subscription-revocation.md) | accepted | partial | Thread feed turn notifications and subscription revocation |
| [ADR-0264](0264-hermetic-mila-journey-fixture.md) | accepted | partial | Hermetic Mila journey fixture |
| [ADR-0265](0265-rust-code-quality.md) | accepted | implemented | Rust code quality: module layout, lint policy and Hegel properties |
| [ADR-0266](0266-anonymous-restored-guest-memory.md) | accepted | partial | Restored guest memory is anonymous |
| [ADR-0267](0267-single-dependency-pin-registry.md) | accepted | partial | Single dependency pin registry |
| [ADR-0268](0268-cedar-single-authorization-source.md) | accepted | partial | Cedar is Marshall's single authorization source |
| [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md) | accepted | partial | Buck2 is the build system; Nix supplies toolchains, pins and NixOS assembly |
| [ADR-0270](0270-graph-driven-machine-test-selection.md) | accepted | partial | Select pull-request builds and NixOS machine tests from the Buck2 graph |
| [ADR-0271](0271-buck2-host-self-deployment.md) | accepted | partial | Hosts self-deploy by building their Buck2 deployment target |
| [ADR-0272](0272-nativelink-remote-cache-and-execution.md) | accepted | partial | NativeLink remote cache and execution for Buck2 |
| [ADR-0273](0273-single-rust-workspace-and-toolchain.md) | accepted | partial | One Cargo workspace and one Rust toolchain |

The [Mila native release readiness review](../reviews/2026-10-24-mila-native-release-readiness.md)
updates ADR-0249 implementation evidence without changing its accepted/partial status.
