# Architecture reviews

- [Cedar single authorization source (2026-10-30)](2026-10-30-cedar-single-authorization-source.md): ADR-0268 cutover to one Cedar-mapped authorizer, service principals, SQL record decisions and list filters from Cedar residuals, with the VM decision table and query budgets; Galileo machine eligibility, benchmarks and machine tests remain open.
- [Rust code quality (2026-10-30)](2026-10-30-rust-quality.md): ADR-0265 adoption across every Rust crate with `--strict` drift checking, pure-move `lib.rs` splits (mila-ffi symbols unchanged), proptest replaced by Hegel plus gap properties, and fatal clippy gates; Lyra/terminald unsafe confinement and three protocol/journey defects remain open.
- [eMudhra distrust backout (2026-10-29)](2026-10-29-emudhra-distrust-backout.md): removal of the temporary fleet blacklist after the `nixos-26.05` distrust, the coordinated nixpkgs/devenv/nix-compact bump, Rust 1.99 lint fixes and the sandbox `openat2` test gap; `fleet-guest-trust` acceptance remains open.
- [Mila Linux GTK parity (2026-10-30)](2026-10-30-mila-linux-gtk-parity.md): deployment list, terminal surface over `HostPtyTransport` with the additive `mila_session_terminal_read` FFI, SSH-key settings view and navigation-only deep-link/share presentation, plus the `mila-linux-journey` fixture driver; GTK live sign-in and a recorded fixture run remain open.
- [Mila Apple host app and build targets (2026-10-29)](2026-10-29-mila-apple-host-app.md): `App` host and `mila-build`/`mila-run` for iOS and macOS under ADR-0235, the unreachable WebKit navigation guard, iOS compile and resource-bundle fixes, and the Darwin rust-overlay toolchain.
- [Underclass egress without an exit node (2026-10-28)](2026-10-28-underclass-egress-without-exit-node.md): route-only egress mode, stale exit-node preference clearing and the `d7a0ccf` pin under ADR-0260.
- [Mila native release readiness (2026-10-24)](2026-10-24-mila-native-release-readiness.md): native release/source-bundle replacement obligations, centralized catalog evidence and incomplete platform acceptance under ADR-0249.

- [Mila Windows authenticated SSH keys (2026-10-22)](2026-10-22-mila-windows-ssh-keys.md): typed Rust FFI list/revoke wiring and stale-response fencing in the WinUI client; live Windows/Porsche execution remains open.

- [Inception development checkout (2026-10-22)](2026-10-22-inception-development-checkout.md): ADR-0262 guest-owned canonical Git checkout, corrected offline image source hierarchy, re-enabled CI and focused evidence; native GitHub egress remains an explicit gap.

- [Mila native Apple custody](2026-10-21-mila-apple-custody.md): deployment-scoped Secure Enclave adapter; signed hardware evidence remains open.

- [Mila native Rust session (2026-10-21)](2026-10-21-mila-native-session.md): actual certificate-pinned SSH machine pagination and atomic refresh, with local scripted-server and Hegel evidence; native adapters and real Porsche journeys remain open.

- [Artifacts and thread tool (2026-10-21)](2026-10-21-artifacts-and-thread-tool.md): ADR-0253–0255: the Artifacts domain, isolated content origin, Thread lifecycle state machine and Oban server-tool dispatch; records executed checks separately from pending machine-test acceptance.
- [Independent HLDD reviews](2026-10-20-hldd-independent-reviews.md): ADR-0250, review isolation, safe migration and merge verification.
- [Thread redaction (2026-10-20)](2026-10-20-thread-redaction.md): bounded inactive-machine text scrubs, profile fencing, and admin audit controls.

- [Mila desktop clients and Susan WNS (2026-10-21)](2026-10-21-mila-desktop.md):
  ADR-0235's macOS and Windows clients, per-platform custody and dev/release
  targets, and ADR-0236's suffix-bounded WNS egress; Windows native and signed
  release evidence pending.
- [Account machine creation presets (2026-10-20)](2026-10-20-account-machine-presets.md): three independent account presets, self-only validated persistence, browser precedence and original-request launch replay; records executed checks separately from native and rollout gaps.

- [Fleet addresses from SOPS (2026-10-20)](2026-10-20-fleet-addresses-from-sops.md): ADR-0233's
  shared address document, runtime firewall chain on both backends, runtime
  WireGuard endpoints, uplink recovery copy and the Susan path over `fleet0`;
  staged rollout with literals removed per host, per-peer port scoping open.
- [Windows editor job custodian (2026-10-18)](2026-10-18-windows-editor-job-custodian.md): ADR-0208 replaces broker-owned job lifetime with an independent SYSTEM custodian, atomic job-list creation and a boot-bound local streaming proxy. Portable/static and bounded SYSTEM library checks pass; same-boot custodian replacement remains incomplete and exact-image browser/recovery acceptance remains pending.

- [Localization completion follow-up (2026-10-19)](2026-10-19-localization-completion-follow-up.md): closes raw-source and strict-gate omissions, preserves authentication and machine contracts, and separates committed regression/journey coverage from pending execution.
- [Localization feature catalogs (2026-10-19)](2026-10-19-localization-feature-catalogs.md): native per-locale/per-feature catalogs and the source-English handbook boundary under ADR-0201; migration and verification evidence remain separately scoped.
- [MFA property fixture isolation (2026-10-19)](2026-10-19-mfa-property-isolation.md): fresh SQL ownership per generated history under ADR-0191, preserving exploration and separating historical timing from current execution.
- [Mila M6: integrated client, relay and verification (2026-10-19)](2026-10-19-mila-m6.md):
  ADR-0220–0228 across the integrated Mila, Porsche, Marshall and Susan
  changes; records which machine and unit runs passed on the integrated tree.
- [Susan push relay (2026-10-19)](2026-10-19-susan-push-relay.md): ADR-0224's
  account-free relay, canonical domain-separated poke signature shared with
  Marshall, append-only audit and per-node limits; real APNs/FCM and hosting open.
- [Mila terminal attach (2026-10-19)](2026-10-19-mila-terminal-attach.md):
  ADR-0223's Porsche attach through the Marshall terminal-gateway stream with an
  unpinned ticket and credit after local send.
- [Mila M2–M4 screens (2026-10-18)](2026-10-18-mila-ui.md): terminal, thread
  and web screens over the client commands and attach channel; payloads only on
  stdin and private endpoints only in the system browser.
- [Mila client commands (2026-10-18)](2026-10-18-mila-commands.md): ADR-0222's
  thread, terminal, web and watch commands, monotonic read markers and
  digest-only stdin payload receipts.
- [Mila notifications (2026-10-18)](2026-10-18-mila-notifications.md): ADR-0225's
  Notifications domain, after-commit producer, fenced delivery worker and
  content-free E2E pokes to the compiled Susan origin.
- [Mila device features (2026-10-18)](2026-10-18-mila-device.md): push
  registration, v1 poke opening, app lock and the offline snapshot cache.
- [Mila M1: client, transport and host trust (2026-10-18)](2026-10-18-mila-m1.md):
  ADR-0220–0228; per-deployment P-256 keys, strict host certificates checked in
  key exchange, the patched dartssh2 overlay and link navigation; native custody
  and the real-Porsche machine test remain unrun.
- [Overview newsletter (2026-10-18)](2026-10-18-overview-newsletter.md): ADR-0205's account-wide durable invitation, self-only dismissal and server-side Ghost subscription boundary; test presence is distinguished from external delivery and packaged browser acceptance.
- [Guest reflection (2026-10-18)](2026-10-18-guest-reflection.md): ADR-0203's secret-free, execution-fenced Peach projection; protocol and credential tests are present while successful HTTP/native guest execution and fleet enablement remain open.
- [GitHub.com owner integration (2026-10-18)](2026-10-18-github-com-integration.md): ADR-0202's owner-bound OAuth custody and managed guest route; source and focused tests are recorded while live provider and native rollout remain open.
- [Fleet dependency convergence (2026-10-18)](2026-10-18-fleet-dependency-convergence.md):
  diagnoses mixed inventory versions and stale Marshall/Porsche dependency
  snapshots; repairs current release inputs without weakening the lock guard,
  hostd authority or current protocol. Live convergence is recorded separately.
- [Memory-preserving suspension and demand wake (2026-10-18)](2026-10-18-memory-suspension.md):
  ADR-0199, durable lifecycle/wake/checkpoint state machines and authenticated
  waiting connections; implementation and native acceptance in progress.

- [One account settings page (2026-10-18)](2026-10-18-account-settings-page.md):
  ADR-0196 merges Profile, Security and SSH keys into `/settings` behind the
  security mount, removes the old routes without redirects and collapses the
  sidebar; LiveView, contract, presentation and probe checks ran, while the
  rewritten NixOS browser tests and Antithesis workload were not executed.
- [Foreign Linux browser editor (2026-10-18)](2026-10-18-foreign-linux-browser-editor.md):
  repairs the missing Alma/Arch editor package, account broker and immutable
  descriptor while preserving exact-release authority; twelve Alma native browser
  subtests and both new production CLI lifecycles passed, while Arch browser
  diagnostic replay passed all twelve stages after an unexplained broker-recovery
  502; all remain separate from
  the frozen seven-family CLI milestone.
- [Cross-platform browser editor status (2026-10-18)](2026-10-18-cross-platform-editor-status.md):
  reconciles current Linux editor evidence with ADR-0153/0158 and records the
  explicit FreeBSD, OmniOS/illumos and Windows editor refusals and their remaining
  implementation and native-browser gaps. Windows runtime/source staging,
  portable broker custody tests and the roster authorizer lock are recorded as
  partial evidence; ADR-0200 accepts a separate manifest-v7/bundle-v4 Windows
  editor candidate without changing selected Windows images. Native pipe/ACL
  library checks are recorded; personal account/task execution and the complete
  Windows browser journey remain unrecorded.
- [User time zones (2026-10-18)](2026-10-18-user-time-zones.md): ADR-0195's
  per-user display zone, self-only validated writes, saved → browser → UTC
  viewer resolution, UTC-provenance timestamps, people's local time in team,
  access, thread and Control room projections, the offline `tz` dependency and
  its refreshed release hash; Hegel/LiveView/Covenant evidence, no native journey.
- [Machine pins (2026-10-18)](2026-10-18-machine-pins.md): ADR-0193's per-user
  pins, pinned-first lists, the owner-pin deletion guard across every lifecycle
  delete path with the account-deletion exception, pin removal at archival and
  Porsche `pin`/`unpin`; BEAM-level property, LiveView and SSH evidence, no
  native journey.
- [Marshall HTTP security headers, no-index and session cookies (2026-10-18)](2026-10-18-marshall-security-headers.md):
  ADR-0194's endpoint-level header set, strict script policy with a style-only
  inline relaxation for xterm.js and Mermaid, HSTS with subdomains, `__Host-`
  session and remember-me cookies and no-index directives; unit, Covenant and
  Python gates passed, the browser probe recorded no CSP violation but stopped
  on pre-existing thread layout findings, and no machine test was run.
- [Retained launch-bundle capacity (2026-10-18)](2026-10-18-retained-bundle-capacity.md):
  exactly owned storage with an invalid current launch bundle contributes no
  allocation credit while preserving neighboring pool observations. Current
  launch/readiness codecs and all native ownership refusals remain strict.
- [Guest OS matrix evidence (2026-10-18)](2026-10-18-guest-os-matrix.md): seven
  declared families and admitted catalog rows, explicit-image live acceptance,
  and 49 separately recorded successful CLI lifecycle stages. Broader guest
  capabilities and the custom-kernel plan remain partial.
- [Staged detached ingress (2026-10-17)](2026-10-17-staged-detached-ingress.md): ADR-0192 finds that the editor and nested HTTPS needed the BEAM only for setup (a Lilly-derived preface and the editor's ready frame), not TLS, HTTP inspection, per-request authorization or multiplexing, and moves them onto ADR-0187's detached bridges with a hostd-executed stage. Rust and Elixir tests passed; the editor-fleet restart subtest has not run.
- [Hegel NixOS property migration (2026-10-17)](2026-10-17-hegel-nixos-migration.md): selected live machine drivers use Hegel for generated histories and stateful schedules; evaluation, guest-side and exact acceptance checks retain their evidence boundaries.

- [Detached ingress bridges (2026-10-17)](2026-10-17-detached-ingress-bridges.md): ADR-0187 moves guest SSH and plain web bridges out of lilly-hostd and the BEAM relay into per-connection `lilly-ingress-<key>.scope` units that survive hostd and Lilly restarts; Lilly records each binding and keeps the execution fence through keepers and re-adoption. Unit and property tests passed; the user-SSH journey machine run is pending.
- [Underclass tailnet exit-node egress (2026-10-17)](2026-10-17-underclass-tailnet-egress.md): ADR-0185 routes only Underclass provider traffic through a dedicated userspace tailnet node and the Australian exit node, confines the unit to loopback and gates start on exit-node selection. Configuration and headscale machine checks passed; live login and stage 2 pending.
- [Lilly owns every socket it uses (2026-10-17)](2026-10-17-lilly-owns-every-socket.md): ADR-0184 removes hostd descriptor passing (the BEAM never closes a descriptor it did not create), adding connect-on-behalf, a privilege-dropped ingress bridge and Lilly socket custody. Machine runs pending.
- [Guest dataset streams in lilly-hostd (2026-10-16)](2026-10-16-guest-dataset-streams-in-hostd.md): ADR-0183 replaces ADR-0182 step 3's ZFS delegation with typed hostd streams; fixed Lilly uid 977 (which collided on dungarees) to 377; repaired main's broken Nix layout paths. Native machine runs pending.
- [Browser extension presence (2026-10-16)](2026-10-16-browser-extension-presence.md): exact-origin optional permission and presentation-only installed marker; runtime Chrome/Firefox setup-visibility evidence remains pending.

- [Underclass saturation reselect pin (2026-10-16)](2026-10-16-underclass-pin.md): fleet package `8c1a38c` to `469aff4` reselects after the saturation reset attempt instead of returning stale 429s, skips the reset lock while a Codex account is healthy and logs relative `retry_after_ms` with absolute `until_ms`. ADR-0102 unchanged; upstream Rust tests passed and the package built offline.
- [lilly-hostd core review (2026-10-16)](2026-10-16-lilly-hostd-core.md): ADR-0176 decision 4, first stage. One `lilly-hostd` daemon replaces a `lilly-host-lock` process per held lock: FIFO leases on the same inodes, a closed utility table, per-command cgroup custody released only after a confirmed empty cgroup, root-only peers in `lilly.service`, and Lilly bound to the unit.
- [Agent context and planning (2026-10-16)](2026-10-16-agent-context-and-planning.md):
  ADR-0178/0179's checkpoint coverage, instruction trust, durable question/proposal
  flow and guest skill custody. Initial architecture assessment; final source,
  native execution and deployment verification remain pending.

- [Host concurrency review (2026-10-16)](2026-10-16-host-concurrency.md): ADR-0176. Lilly has no host-wide lock. Production create latency on dungarees (p95 149 s) comes from bursts of creates serialized through pool-locked preparation that polls instead of queueing, and from per-second re-adoption through the mutation path, not from copies, which are block-cloned in about 0.1 s. Records six decisions: pool single writer with group commit, reconciler actors, native template digests, a `lilly-hostd` effects engine, durable jobs and evidence-gated standbys; ADR-0173 decision 10 corrected.

- [Multi-OS guest images (2026-10-16)](2026-10-16-multi-os-guest-images.md): ADR-0180's
  Arch/Alma Linux reuse of the version-4 contract, explicit FreeBSD/illumos
  version-6 and bundle-v3 metadata, and Lilly's conditional initrd/vsock/CPU
  mapping. Builder evaluation and focused unit evidence are recorded; native
  FreeBSD/OmniOS boot, agents, supervised daemon recovery, isolation and fleet
  claims remain open; scoped OmniOS service, growth and process-crash receipts
  are recorded separately.

- [Exact native image admission (2026-10-17)](2026-10-17-native-image-admission.md):
  qualifies only the reviewed FreeBSD image by complete immutable identity,
  verifies promotion artifacts and five native evidence sets, and preserves
  OmniOS, physical recovery and fleet gaps.
- [Native kernel provenance and attestation (2026-10-17)](2026-10-17-native-kernel-attestation.md):
  ADR-0190 replaces ADR-0180 with a kernel provenance descriptor, fail-closed native-kernel receipts,
  jail-local boot-bound attestation and guest daemon packaging. Source and
  focused tests are joined by a complete FreeBSD candidate, native userland
  linkage, native illumos module assembly, two-boot FreeBSD candidate assembly
  and recorded FreeBSD service/growth/policy/daemon-recovery/process-crash,
  ordinary-transport and reset-event gates. Corrected OmniOS native assembly
  and paired direct-only QEMU boot pass; the first corrected-image Firecracker
  service run misses its boot deadline. OmniOS supervised daemon recovery, native
  peer-VM isolation, physical recovery and fleet acceptance remain open. Scoped
  service, growth and process-crash receipts are recorded separately. OmniOS and
  changed native candidates stay closed; the exact reviewed FreeBSD promotion
  has its separate admission record.

- [Host boot-log authorization (2026-10-17)](2026-10-17-host-boot-log-authorization.md):
  read-only host diagnostics have independent Cedar, host-stream and current
  execution authority while guest terminal capability remains disabled.
  The review tracks boot/log incarnation fencing and focused verification
  separately from deployed browser and native-image acceptance.

- [Thread sharing review (2026-10-16)](2026-10-16-thread-sharing.md): ADR-0175's
  durable thread grants, current bound-machine authority, additive VM/team roles,
  replay and revocation boundaries. The focused 111-case suite and synthetic
  browser matrix passed; native transport and cross-node recovery remain separate.

- [User threads architecture review (2026-10-15)](2026-10-15-user-threads.md): ADR-0174's Threads boundary, running-VM readiness, idempotent initial objective, archive deletion confirmation, reopen machine keys, retained-generation transcript selection and retained-transcript authority. The working integration snapshot passed 31 focused tests and presentation checks; native recovery and cross-node replay remain gaps.

- [Underclass manual reset redemption pin (2026-10-14)](2026-10-14-underclass-pin.md): fleet package `3e35c3b` to `d0cb274` adds an admin-token-gated manual Codex reset endpoint, CLI and page button, a `gpt-6-sol` catalog entry and body-based stream classification. ADR-0102 keeps its accepted decision and partial status; hashes and an offline package build were validated, tests were not run.
- [Underclass stream statistics pin (2026-10-15)](2026-10-15-underclass-pin.md): fleet package `d0cb274` to `8c1a38c` adds bounded stream outcomes and admin-token-gated long-range capacity statistics while preserving the independent pool and monitor boundaries. Hashes and an offline package build were validated; tests were not run.
- [Native guest coding CLIs (2026-10-13)](2026-10-13-native-guest-coding-clis.md): ADR-0167 adds pinned Codex and Claude Code with native Ziggy settings in both images, an offline Ubuntu closure exception and exact Anthropic beta Messages/token-counting query support. Execution and deployment evidence are recorded as they complete; production Anthropic remains disabled.
- [Resize hardening (2026-10-13)](2026-10-13-resize-hardening.md): ADR-0166 adds the Porsche `resize` command with durable receipts, logs every refusal with its reason, records a stop confirmed without its disk for retry instead of aborting the host exchange, and allows cancellation while the machine is still stopping. Coordinator, SSH, page and parser tests pass; full gates and the Porsche acceptance are recorded as they happen.
- [Storage churn and capacity damping (2026-10-13)](2026-10-13-storage-churn-and-capacity-damping.md): ADR-0163, ADR-0164 and ADR-0165 after a production image rebuild retired and filled about 260 standby disks under the pool lock and capacity snapshots were withheld hundreds of times an hour. Standby refill becomes a planned, budgeted pass that yields to pool-lock waiters with at most 32 standbys per image and 64 per pool, usage-counter drift is resampled instead of withholding, and a busy pool entry extends a recent measurement's freshness for at most fifteen seconds. Unit and property gates recorded; native reruns and fleet activation are recorded as they happen.
- [Windows Lilly launch (2026-10-14)](2026-10-14-windows-lilly-launch.md): ADR-0170 admits manifest v5 and bundle v2, routes firmware bundles through Lilly's jail with MMDS identity and `--enable-pci`, records agentless guests as `unattested` running without `guest_ready`, adds the MMDS bootstrap task to the Windows image and Marshall's guest-agents gating. Records the merge of origin/main (ADR renumbered to 0168), the first recorded execution of the `windows-guest` machine test, Linux guest regressions on the patched VMM with a pre-existing post-import fixture failure reproduced on untouched main, the unit and property suites, and the Lilly-mode `windows-lilly-guest` machine test.
- [Windows Firecracker spike (2026-10-13)](2026-10-13-windows-firecracker-spike.md): ADR-0169 bootable Windows Server 2025 guest under the patched static Firecracker 1.16.1 with edk2 CloudHv UEFI as the PVH payload and the opt-in virtio-pci transport. Records the four platform-contract fixes, the offline KVM image build from Microsoft's pinned evaluation ISO, which builds and checks ran, and the serial-console boot result; manifest v5 admission, Lilly launch and guest agents remain gaps.
- [Clone cleanup liveness (2026-10-13)](2026-10-13-clone-cleanup-liveness.md): ADR-0162 after a production clone held its host's transfer slot for ninety minutes with a silently failing prune. Unconfirmed clone effects carry a closed reason on both sides (clone protocol v5), slots release at stream quiescence, a published copy completes at a cleanup deadline while the source snapshot hold, exclusion and prune offer are retained, transient refusals defer in the queue, and a failed source stop is recorded. Generated histories passed; native clone reruns and production acceptance are recorded as they happen.
- [Monospace Web presentation (2026-10-13)](2026-10-13-monospace-web-presentation.md): ADR-0161 replaces the Nekomo presentation with The Monospace Web: character grid, four colour tokens per theme, vendored JetBrains Mono, text glyphs, no external resources, Tailwind/daisyUI/Mishka/Cinder removed. Structural gate and Playwright probe in both themes recorded; synthetic fixture and no assistive-technology audit remain explicit gaps.
- [Antithesis harness foundation (2026-10-13)](2026-10-13-antithesis-harness-foundation.md): optional SDK and controlled/integrated variants, disposable control graph, local TCG guest/router and measured-host evidence, and static property roster; no composed or hosted baseline or native guest acceptance is claimed.
- [Antithesis integration architecture review (2026-10-13)](2026-10-13-antithesis-integration-review.md): source-level ownership, enrollment, readiness and operator boundaries, with composed execution still pending.
- [Antithesis current-main integration (2026-10-13)](2026-10-13-antithesis-main-integration.md): nine merge conflicts resolved around strict pool shape, controlled decoding, separate capacity and I/O verification, replay fixture revisions and five-second ingress; fresh image and hosted evidence remain pending.

- [Antithesis native prerequisites (2026-10-13)](2026-10-13-antithesis-prerequisites.md): captured Galileo/Enrico release and ZFS I/O passes, two failed service-role attempts (cookie pipeline, then Lilly startup), fixture-only custody/replay changes and five-second catalog decoder correction; current hosted harness and remaining native/consumer gates stay separate.

- [Antithesis harness reset (2026-10-13)](2026-10-13-antithesis-reset.md): retires the old tree before a fresh whole-repository rebuild, preserves baseline-pinned historical evidence and ordinary Lilly generated tests, and leaves fresh hosted/mutation/native coverage pending. ADR-0017's accepted decision and partial implementation status remain unchanged.

- [Privileged administrator step-up (2026-10-11)](2026-10-11-privileged-administrator-step-up.md): ADR-0160 replaces inherited five-minute/redirect step-up with fixed fifteen-minute elevation, exact inline pending-action continuation and no-key Security setup followed by explicit retry. Final merged packaged browser checks passed ordinary access, no-key return/retry, inline continuation/cancellation and colocated replica revocation. Native timed expiry, machine-page recovery and physical-host/hardware acceptance remain separate gaps.
- [Legacy compatibility removal (2026-10-11)](2026-10-11-legacy-compatibility-removal.md): ADR-0159 inventory-driven removal of every backward-compatibility path in ordered converged pushes; read-only host and database preflight facts, exports and per-push results.
- [Durable guest identities (2026-10-10)](2026-10-10-durable-guest-identities.md): ADR-0158 replaces email-based allocation and editor checks with immutable generated logins/homes and permanent retired reservations. Original feature and incoming `d4499c4c` merged captures remain distinct: merged Protocol259/Lilly555/Marshall1429 gates and both eight-subtest lifecycles passed. Native inventory passed8.22s within a complete native-zfs run failing unrelated resource receipts. Complete Ubuntu SSH/native editor and later incoming integration remain separate scopes. Authorized live guest deletion does not establish migration/deployment.
- [Stopped-only relocation (2026-10-10)](2026-10-10-stopped-only-relocation.md): ADR-0155 deletes live pre-copy; stopped path traced end to end, production history (18 complete pre-copy moves) validated against the new codecs after the migration transform. Incoming native relocation passed 20 subtests in 4018 seconds; the journal enumeration bound remains a documented contract gap and current merged execution is separate.
- [Shared request-accounting library (2026-10-10)](2026-10-10-request-accounting-library.md): breaking internal rename to `Overalls.RequestAccounting`, shared aggregate arithmetic, preserved recorder boundaries and explicit separation from diagnostics.

- [Shared Elixir observability library (2026-10-10)](2026-10-10-observability-library.md): shared canonical logging, privacy and bounded metrics review.

- [Browser launcher and source2 (2026-10-10)](2026-10-10-browser-launcher.md): Weaver browser comparison, unsigned Nix packages/public downloads, source2/manifest4 cutover and signed-cookie authentication resume under ADR-0157/0156; focused evidence and current native/production gaps.

- [Existing-state profile migration custody (2026-10-10)](2026-10-10-profile-migration-custody.md): incoming raw lifecycle rewrite conflicts with exact legacy archives; reviewed correction passes scoped custody/database regressions, while proposed ADR-0151 preserves the accepted fresh-only decision and retained-state native acceptance remains pending.

- [Guest boot profile (2026-10-10)](2026-10-10-guest-boot-profile.md): ADR-0154 host line offsets and boot report, measured NixOS build-time Nix registration, Ubuntu verified-current trust, lean initrd and quiet console; rejected reorderings and remaining fleet/no-initrd gaps.

- [Default guest Starship (2026-10-10)](2026-10-10-guest-starship.md): ADR-0150 stock Bash/Starship defaults, passing merged NixOS/Ubuntu personal SSH/browser journeys, historical root-image results and explicit property/custom-configuration gaps.

- [Independent observability (2026-10-09)](2026-10-09-observability-decoupling.md): ADR-0149 removes diagnostic authority and transport from the application protocol; independent SDK, durable trace custody, fleet exporter and provisioned Grafana evidence, with deployment acceptance boundaries.
- [Elixir and Rust observability source review (2026-10-09)](2026-10-09-observability-source-review.md): source inventory, emitter searches and semantic review of production boundaries; retained native authority protocols and payload privacy.

- [2026-10-10: Official-source browser editor](2026-10-10-browser-editor.md) - official Code OSS patch/package, personal Editor authority, immutable guest capability and scoped component/native gaps under ADR-0153.

- [2026-10-09: Standard branding and open-domain eligibility](2026-10-09-standard-branding.md) - fresh-install profile naming, preserved testing integration and safe cross-domain identity.

- [Terminal peer silence scheduling (2026-10-06)](2026-10-06-terminal-peer-silence.md): incoming timer drift reproduced and callback repair/mutation checks passed; generated TLS silence history is under fixture review, integration and full gates remain pending.

- [Opening socket custody (2026-10-06)](2026-10-06-opening-socket-custody.md): post-handoff worker death reproduced an untracked socket; provisional custody repairs and scoped properties passed, both cleanup mutants caught; current full Protocol/consumer gates pending.

- [Launch-guard waiting intent](2026-10-05-launch-guard-waiting-intent.md): preserved kernel-witnessed property,99-second native package and ordering mutant; fresh combined verification pending.
- [Source-export adopted children](2026-10-05-source-export-adopted-children.md): preserved all-child custody repair, completion/failure properties and scoped selector mutants; fresh combined verification pending.

- [transfer-stream-adopted-child-custody (2026-10-05)](2026-10-05-transfer-stream-adopted-children.md): scoped native baseline and selector mutation evidence; source/test identity verified after integration, exact-helper consumer and publication gates pending.

- [host-lock-descendant-completion-custody (2026-10-05)](2026-10-05-host-lock-descendant-custody.md): scoped native baseline and selector mutation evidence; source/test identity verified after integration, exact-helper consumer and publication gates pending.

- [Audi pending version close (2026-10-05)](2026-10-05-audi-pending-version-close.md): actual close4001 reproduced permanent-class loss for pending reads; repair and real upgrade/body/DNS expiry properties passed focused checks; full typing/mutation/integration remain open.
- [Control transport properties (2026-10-05)](2026-10-05-control-first-envelope.md): reproduced first-hello, terminal-retry and heartbeat ownership bugs repaired; Protocol249, Lilly503, Marshall1466 and Galileo31-check gates passed, scoped mutants caught; incoming-main and native integration remain open.
- [Auth mail post-acknowledgement design (2026-10-05)](2026-10-05-auth-mail-post-ack-design.md): typed three-peer draft parks the real delivery action after SMTP success and before commit, then checks owner death, identical retry and terminal replay; syntax/format only, runtime pending.
- [Protocol transport boundary (2026-10-05)](2026-10-05-protocol-transport-boundary.md): reconciles stale blanket no-I/O guidance with accepted ADR-0142 named transport modules; pure codecs/state and domain/storage boundaries retained, full component integration gates passed.
- [Auth mail post-ACK loss and sender rotation (2026-10-05)](2026-10-05-auth-mail-post-ack-runtime.md): committed three-peer crash evidence, payload-retirement mutation and reproduced sender-derived Message-ID instability; combined19check execution and rotation mutation/restored selection passed; full typing/integration gates pending.

- [Native recorder commit/reply loss design (2026-10-05)](2026-10-05-recorder-commit-reply-loss.md): accepted commit and preserved Unix identity with Client timeout/gap; native verification pending.

- [Enrico escaped-session ownership (2026-10-05)](2026-10-05-enrico-escaped-session-ownership.md): actual separate-session cleanup counterexample, corrected all-child wait selector and eleven-property native package passed; local reversion mutant caught, integrated gates pending.

- [Producer acknowledgment uncertainty (2026-10-05)](2026-10-05-producer-uncertain-ack.md): two local generated Client/marker/Unix-RPC histories,11check component gate, dedicated source typing, mutant control and reviewed hooks/HLDD passed; native uncertainty remains open.
- [Generated native producer and recorder histories (2026-10-05)](2026-10-05-producer-recorder-histories.md): production Elixir client and authenticated durable Rust recorder; pending admission conservation through reopens and generated completion/death mixtures. Native subtest passed10.77seconds within74.87-second full script, with composed driver lint and typing; final publication gates pending.

- [Terminald actual growth backing (2026-10-05)](2026-10-05-terminald-growth-backing.md): real PTY two-phase growth and full64MiB backing accounting; native51tests and Clippy passed; original-append control caught128MiB backing against64MiB reserved. Marshall1451checks, zero-error forced Dialyzer, hooks and evaluated HLDD passed. Simultaneous mixed-pressure and authenticated composition remain separate.

- [Terminald mixed growth and admission (2026-10-05)](2026-10-05-terminald-mixed-growth.md): stalled real viewer, healthy output/growth and competing creates preserve exact backing/inventory and replacement capacity, including default64MiB; combined native52tests and Clippy passed22.00s. Expanded control caught the smaller-family growth violation; Marshall1451checks and zero-error forced Dialyzer passed.

- [Terminald shared ring admission (2026-10-03)](2026-10-03-terminald-shared-ring-budget.md): real PTY64MiB admission, contending final reservations and exact retirement/replacement; native47tests and Clippy passed; quota mutant caught; reviewed hooks and HLDD22s passed; Marshall integration pending.
- [Terminald neighboring session pressure (2026-10-03)](2026-10-03-terminald-neighbor-pressure.md): actual PTY/socket pressure and fresh executed neighbor output before/after owned retirement; refined zero/configured/read-boundary native47tests and Clippy passed4.66s; integration pending.

- [Create, clone and delete latency (2026-10-05)](2026-10-05-create-clone-delete-latency.md): production timings plus live Porsche cycle; create spent 25.4s of 33.8s in a userspace copy (FICLONE EXDEV across mounts), same-host clone 46.9s in a throttled uncompressed send, delete p90 679s from usage-exact whole-pool observation; image-copy 11 tests and 257 focused Lilly checks passed; native and post-deploy evidence pending.
- [Private burn notification delivery (2026-10-03)](2026-10-03-private-burn-delivery.md): actual upstream TLS delivery, eighty generated route histories and final native check with build validation passed in97.55s; handbook browser61.88s; production destination acceptance pending.
- [Waiting mail token authority (2026-10-03)](2026-10-03-mail-waiting-token-authority.md): three-peer committed token removal/expiry while a worker actually waits on the outbox lock; combined four-property run passed80.8s; full precommit passed1434checks,seed559168,1724.4s; forced Dialyzer60.57s passed with zero errors or skips.
- [Pending audit roster oracle (2026-10-03)](2026-10-03-audit-pending-roster-oracle.md): corrects a local dirty-sender test that demanded offers from completely acknowledged journals; fixed small witness and focused property passed25.1s, final Lilly precommit passed475checks,seed279043,98.0s; forced Dialyzer12.83s and standalone test-module typing passed with zero warnings.
- [Native worker BEAM recovery (2026-10-03)](2026-10-03-lilly-native-beam-recovery.md): generated completed-effect/before-record abrupt whole-worker loss, independent Store/lock reopens and exact Firecracker/outcome replay; native check passed1037s; pending-journal oracle correction integrated; merged Lilly475checks and zero-error Dialyzer passed; Marshall gate pending, production daemon and authenticated exchange remain separate.

- [Committed mail worker histories (2026-10-03)](2026-10-03-mail-committed-worker-histories.md): independent PostgreSQL contention and abrupt post-DATA peer death; final focused two-property run passed63.7s with replacement-peer verification; forced Dialyzer passed74.84s; full precommit passed1,432checks,seed612345,1525.2s; forced Dialyzer passed50.9s with zero errors or skips.

- [SMTP post-DATA timeout histories (2026-10-03)](2026-10-03-mail-smtp-timeout-histories.md): generated verified-TLS owner timeout, connection retirement, stable payload and terminal replay; focused postmerge execution passed eight checks in 114.6 seconds.

- [Uploaded backup publication histories (2026-10-03)](2026-10-03-backup-upload-publication-histories.md): generated real-Restic manifest interruption, exact restore and retention reference survival; full13-test suite1418s passed.

- [Backup reader group retirement (2026-10-03)](2026-10-03-backup-reader-group-retirement.md): actual leader-exit leak, thread death proof and production repair; pinned runtime8s and packaged121s passed; inherited termination-bound gap explicit.

- [Interrupted publishing recovery (2026-10-03)](2026-10-03-backup-publication-recovery.md): installed cleanup preserves seeded journal references and last success; combined native execution passed in 155 seconds.

- [Packaged backup cleanup recovery (2026-10-03)](2026-10-03-backup-packaged-cleanup.md): installed unit/operator ownership refusal, interrupted-run reconciliation and terminal replay; native execution passed in 138 seconds, exit 0.

- [Native backup identity replacement and pre-GUID intent (2026-10-03)](2026-10-03-backup-native-identity-intent.md): actual replacement-object refusal and native precreation cleanup; combined thirty-seven-history native check passed in 169 seconds; mutation during cleanup and full orchestration remain open.

- [Native host cleanup worker death (2026-10-03)](2026-10-03-backup-cleanup-worker-death.md): real worker/helper SIGKILL around native destroy; combined native execution passed in 134 seconds; full packaged orchestration and power loss remain open.

- [Native host snapshot cleanup ownership (2026-10-03)](2026-10-03-native-backup-cleanup.md): real ZFS/mount proof refusals and post-destroy inspection outage; native execution passed in 98 seconds; process/power-loss and concurrent replacement remain open.

- [Native Lilly completed effect recovery (2026-10-03)](2026-10-03-lilly-native-actor-recovery.md): real Executor/Firecracker completion before actor outcome recording; combined contention/completion native check passed in 671 seconds; full daemon/start/submission and hosted boundaries remain open.

- [Enrico aggregate refresh admission (2026-10-03)](2026-10-03-enrico-refresh-admission.md): bounded admission, real controlled-worker saturation, success/death release and same-attempt retry; ten native histories, complete component and packaged HTTPS machine gates passed; saturated native recovery remains open.

- [Terminald byte histories (2026-10-03)](2026-10-03-terminald-byte-histories.md): five generated ring/stream/refusal properties; full native Clippy and 43 tests passed, static production factory also passed.

- [Backup owned cleanup histories (2026-10-03)](2026-10-03-backup-owned-cleanup-histories.md): generated exact refusal inventories, pre-GUID intent and uncertain cleanup retries; pinned Python 3.13 Nix check passed, publication checks pending.
- [Telemetry retention and diagnostics (2026-10-03)](2026-10-03-telemetry-retention-and-diagnostics.md) records ninety-day retention, prioritized missing-data states and additive Underclass latency migration under ADR-0138.
- [Lilly completed launch recovery (2026-10-03)](2026-10-03-lilly-completed-launch-recovery.md): completed executor result held before outcome recording; actor replacement and exact replay passed, native boundaries remain open.

- [Enrico attempt generation histories (2026-10-03)](2026-10-03-enrico-attempt-generation-histories.md): real supervised refresh reuse across bounded receipt retention; focused properties passed, component and integrated gates pending.

- [Producer worker completion histories (2026-10-03)](2026-10-03-producer-worker-completion-histories.md): live-worker ticket custody and once-only actual death/completion races; component and handbook checks passed, integrated publication gates pending.

- [Public Grafana access (2026-10-03)](2026-10-03-public-grafana.md) reviews authenticated HTTPS, certificate reuse, and destination-scoped firewall access under ADR-0137.

- [Durable request SLO accounting (2026-10-02)](2026-10-02-durable-request-slos.md) records ADR-0136's Rust recorder, producer hooks, declared fleet bindings, native Marshall recovery and remaining source/deployment acceptance.

- [Distributed host-lock reach (2026-10-03)](2026-10-03-distributed-host-lock-reach.md): three independent peers reach held host-lock chains before release; focused, complete-file and full pre-integration gates passed; merged checks remain required.

- [Ziggy reporter receipt histories (2026-10-03)](2026-10-03-ziggy-reporter-histories.md): exact controlled batch attempts, immutable refusals, neighbor drain and restart totals; focused, full Ziggy and publication gates passed.

- [Distributed race error oracles (2026-10-03)](2026-10-03-distributed-race-error-oracles.md) records stricter clone error acceptance and passing focused three-node histories; full gates passed; additional lock schedules remain open.

- [Competing relocation and workflow backlog histories (2026-10-02)](2026-10-02-relocation-and-workflow-backlog-histories.md) records passing focused actual admission and workflow publication properties; full batch gates remain pending.

- [Clone competing activation histories (2026-10-02)](2026-10-02-clone-competing-activation.md) records queued acceptance, allocation-free activation refusal, recovery after release and first-release timestamp preservation.

- [Namespace sweep planner properties (2026-10-02)](2026-10-02-namespace-plan-properties.md) records exact target conservation, configured cap boundaries and isolated mutant detection without native unmount claims.

- [Database client-loss histories (2026-10-02)](2026-10-02-database-loss-histories.md) records active-holder execution, generated submission orders and pending silent/asymmetric recovery verification under ADR-0126.

- [Large-file streaming cache (2026-10-02)](2026-10-02-large-egress-cache.md) records ADR-0135, native/property execution and live pinned archive acceptance separately.

- [2026-10-02: Durable physical SLO accounting](2026-10-02-durable-physical-slos.md)
- [HTTPS egress production acceptance (2026-10-02)](2026-10-02-https-egress-production.md) records live NixOS/Ubuntu interception, caching and restart, Customer refusal, native HTTPS/ZFS recovery, and descriptor-pinned namespace cleanup repair.
- [Galileo production acceptance (2026-10-02)](2026-10-02-galileo-production.md) records live management failures, repairs, generated evidence and remaining production acceptance.

- [Underclass durable proxy SLO (2026-10-02)](2026-10-02-underclass-proxy-slo.md) reviews durable Rust admission, terminal-stream accounting, independent exporter custody and native/deployment gaps.

- [Ziggy durable SLO accounting (2026-10-02)](2026-10-02-ziggy-durable-slo.md) records private checkpoints, crash accounting, reader-first rollout and verified two-host producer activation.

- [Provisional seven-day fleet objectives (2026-10-02)](2026-10-02-provisional-seven-day-slos.md) reviews ADR-0132's source, coverage, read-authority and alert-delivery boundaries, seven-day burn arithmetic and actual rule-state projection.
- [Automatic magic-link browser sign-in (2026-10-02)](2026-10-02-automatic-magic-link.md) records the one-step browser handoff, preserved GET boundary, remembered credential and current verification limits.

- [Satellite version refusal recovery (2026-09-29)](2026-09-29-satellite-version-refusal.md) records Ziggy and Galileo terminal 426 classification, stopped Ziggy loops, local TLS evidence and remaining restart/Audi/WebSocket gaps.

- [Antithesis property test audit (2026-09-29)](2026-09-29-antithesis-property-audit.md) tracks the 63-candidate source review and records generated actor and host report evidence.

- [2026-09-28: Local Antithesis actor harness](2026-09-28-antithesis-local-harness.md) — durable Store/actor/journal replay test seam, explicit fake-effect and native-execution boundaries.

- [2026-09-26: Lifecycle operation histories](2026-09-26-lifecycle-histories.md) — generated durable transition-oracle histories and bounded restart-limit mutant evidence; native lifecycle recording blocked by a reproduced terminal-stage failure in the composed fleet check.
- [2026-09-26: Customer owner controls and entry refusals](2026-09-26-customer-controls.md)

- [2026-09-26: Cross-replica revocation propagation](2026-09-26-cross-replica-revocation.md) — generated three-BEAM schedules proving committed session revocation refuses non-login read surfaces on every replica; commit boundary, partition fail-closed and rejoin enforcement.
- [2026-09-26: Legacy browser typing sweep](2026-09-26-browser-typing-sweep.md) — remaining raw browser helpers typed through pinned artifacts; the fleet composed-driver exclusion closed; executor-loss evaluation repaired.
- [2026-09-26: Installer revocation and upgrade trust preservation](2026-09-26-installer-revocation.md) — late account-key revocation refusal, appended-byte upgrade digest agreement, served-digest mismatch, platform/checksum selection refusals, and the fleet revoke→probe→re-register cycle.
- [2026-09-26: Handbook scenario close-out](2026-09-26-handbook-closeout.md) — review-only reconciliation of the handbook scenario row with merged 005/007/015/033 records.
- [2026-09-26: Enrico git-mirror native service refresh](2026-09-26-git-mirror-refresh.md)
- [2026-09-26: Custody backup key ceremony and turnover](2026-09-26-custody-backup-key.md) — Restic key ceremony, exact wedge label/recovery, restore-decrypt composition and recipient turnover histories.
- [2026-09-26: Guest roster name/UID binding and bounds](2026-09-26-roster-identities.md)
- [2026-09-26: Composed sharing matrix verification](2026-09-26-sharing-matrix.md)
- [2026-09-26: Credential management histories](2026-09-26-credential-management-histories.md) — generated passkey/SSH-key histories against a raw-SQL oracle, bounds and session effects; both defect candidates adjudicated as accepted behavior without production change.
- [2026-09-26: Historical-authority characterization](2026-09-26-historical-authority-characterization.md)
- [2026-09-26: Credential self-service lifecycle verification](2026-09-26-credential-self-service.md)

- [2026-09-27: Capacity admission race verification](2026-09-27-capacity-races.md) — generated three-peer admission/outcome mixes with a committed-ledger accounting oracle and a bounded generated native race stage.
- [2026-09-27: Host enrollment and replacement authority](2026-09-27-host-replacement.md): generated enrollment/credential/retirement histories with a shared readiness oracle, three-BEAM races, seeded lock/fence mutants and the native SSH/SOPS replacement journey.

- [2026-09-26: Combined sharing authority across terminal, SSH and web renewal surfaces](2026-09-26-sharing-surfaces.md)
- [2026-09-26: Updater compatibility histories](2026-09-26-updater-compatibility-histories.md)
- [2026-09-26: Updater custody recovery histories](2026-09-26-custody-updater.md)
- [2026-09-26: Executor loss and explicit user retry](2026-09-26-executor-loss-histories.md)
- [2026-09-26: Clone matrix — image/profile/shape coverage, native permutations](2026-09-26-clone-matrix.md)

- [2026-09-26: SSH roster migration verification](2026-09-26-ssh-roster-migration.md)

- [Committed test fixture history](2026-09-26-committed-fixture-history.md) — scoped history teardown and complete-row preservation controls.
- [Authority fixture history teardown](2026-09-26-authority-fixture-history.md) — exact owned job history disposal in catalog and retirement fixtures with unrelated-history controls.

- [2026-09-26: Operator secret recipient histories](2026-09-26-secret-recipient-histories.md)

- [Configured Hegel evidence recognition](2026-09-26-hldd-hegel-attributes.md) — exact runner attributes and retained structural evidence limits.
- [2026-09-26: Guest CLI supervisor recovery](2026-09-26-guest-cli-recovery.md)
- [2026-09-26: Provisioning performance implementation](2026-09-26-provisioning-fastpath.md)
- [2026-09-26: Porsche provisioning baseline investigation](2026-09-26-porsche-provisioning-performance.md)

- [2026-09-26: CLI lifetime history generator repair](2026-09-26-cli-history-generator.md)
- [2026-09-26: Shared download cache histories](2026-09-26-cache-history-verification.md)
- [2026-09-26: Terminal attachment authority histories](2026-09-26-terminal-attachment-verification.md)

- [2026-09-26: Underclass token rotation and recovery pin](2026-09-26-underclass-pin.md)
- [Browser-approved agent CLI verification](2026-09-25-agent-cli-verification.md): generated authority histories and ordinary browser consent joined to packaged CLI and real guest work; execution scope recorded in the review.

- [2026-09-26: Clone restart recovery](2026-09-26-clone-restart-recovery.md)
- [2026-09-26: Guest trust evidence verification](2026-09-26-guest-trust-evidence.md): recorded lifecycle/digest property executions and native wrong/forged/expired trust-failure exhaustion with a caught accept-expired mutant.

- [2026-09-25: Production clone and relocation acceptance](2026-09-25-production-clone-relocation.md)

- [2026-09-25: Terminal startup recovery](2026-09-25-terminal-startup-recovery.md)
- [2026-09-25: Private guest browser authority verification](2026-09-25-private-web-verification.md)
- [2026-09-25: Clone cancellation and current authority](2026-09-25-clone-cancellation-verification.md)

- [2026-09-25: Integration renewal and peer-consumption verification](2026-09-25-integration-renewal-verification.md)
- [2026-09-25: Git mirror user-operation verification](2026-09-25-git-mirror-verification.md)

- [2026-09-25: Team shared resources and distributed retirement](2026-09-25-team-resource-verification.md)
- [2026-09-25: Standalone browser type gates](2026-09-25-browser-type-gates.md)
- [2026-09-25: Fresh guest identity verification](2026-09-25-fresh-guest-identity-verification.md)

- [2026-09-25: Credential registration and retirement verification](2026-09-25-credential-lifecycle-verification.md)
- [2026-09-25: Resize user-journey verification](2026-09-25-resize-verification.md)
- [Fleet guest trust verification](2026-09-25-fleet-guest-trust-verification.md): shared fixture compatibility and bounded NixOS/Ubuntu native trust evidence.

- [2026-09-25: Teams SSH verification](2026-09-25-team-ssh-verification.md)

- [2026-09-25: Default OSS creation verification](2026-09-25-default-oss-verification.md)
- [2026-09-25: Handbook reader authority verification](2026-09-25-handbook-reader-verification.md)
- [2026-09-25: Team creation verification](2026-09-25-team-creation-verification.md)

- [2026-09-25: Team authority verification](2026-09-25-team-authority-verification.md)
- [2026-09-25: Installer verification improvement 002](2026-09-25-installer-verification.md)

- [2026-09-25: Default OSS machine creation](2026-09-25-default-oss-creation.md)

- [2026-09-25: Handbook section pages](2026-09-25-hldd-sections.md)

- [SSH onboarding guidance](2026-09-25-ssh-onboarding-guidance.md)
- [2026-09-25: Authenticated handbook](2026-09-25-hldd.md)
- [2026-09-25: Mandatory Ash domain and deployment views](2026-09-25-hldd-views.md)

- [2026-09-25: SSH configuration download retirement](2026-09-25-ssh-config-download-retirement.md)

- [2026-09-25: Control room read access](2026-09-25-control-room-read-access.md)

- [2026-09-25: Installer management SSH trust](2026-09-25-installer-management-ssh-trust.md)

- [2026-09-25: Personal terminal workspace](2026-09-25-personal-terminal-workspace.md)

- [2026-09-25: Magic-link request regression](2026-09-25-magic-link-request.md)

- [2026-09-25: Public CLI delivery routes](2026-09-25-public-cli-bin-routes.md)

- [2026-09-24: Relocation readiness contention](2026-09-24-relocation-readiness-contention.md)

- [2026-09-24: SSH roster bootstrap](2026-09-24-ssh-roster-bootstrap.md)

- [2026-09-24: Overalls Nekomo redesign](2026-09-24-overalls-nekomo-redesign.md)
- [2026-09-24: Guest trust bootstrap](2026-09-24-guest-trust-bootstrap.md)
- [2026-09-24: Fenced ZFS namespace deletion](2026-09-24-zfs-namespace-delete.md)
- [2026-09-24: macOS agent-backed guest SSH](2026-09-24-macos-agent-ssh.md)
- [2026-09-24: Private SSH TLS verification](2026-09-24-private-ssh-tls.md)
- [2026-09-24: Running VM adoption retry](2026-09-24-running-vm-adoption-retry.md)
- [2026-09-23: Lilly audit backlog recovery](2026-09-23-lilly-audit-backlog-recovery.md)
- [2026-09-23: Cedar guest SSH integration](2026-09-23-cedar-guest-ssh-integration.md)
- [2026-09-23: Cedar guest SSH foundation](2026-09-23-cedar-guest-ssh-foundation.md)
- [2026-09-23: Guest web fetch and fleet Brady CA](2026-09-23-guest-fetch-brady-ca.md)
- [2026-09-23: Marshall agent web search](2026-09-23-marshall-web-search.md)
- [2026-09-23: Private guest CLI updates](2026-09-23-private-guest-cli-updates.md)
- [2026-09-23: Agent capabilities](2026-09-23-agent-capabilities.md)
- [2026-09-23: Underclass quota deadline pin](2026-09-23-underclass-quota-deadline-pin.md)
- [2026-09-23: Underclass local monitor socket pin](2026-09-23-underclass-monitor-socket-pin.md)
- [2026-09-23: Underclass utop pin](2026-09-23-underclass-utop-pin.md)
- [2026-09-23: Underclass usage and monitor pin](2026-09-23-underclass-usage-pin.md)
- [2026-09-23: Ziggy Underclass Responses](2026-09-23-ziggy-underclass-responses.md)
- [2026-09-23: Automatic update identical-system recovery](2026-09-23-auto-update-identical-system.md)
- [2026-09-23: Automatic update dependent-stop recovery](2026-09-23-auto-update-dependent-stop.md)
- [2026-09-23: Underclass banked-reset pin](2026-09-23-underclass-banked-reset-pin.md)
- [2026-09-23: Enrico Git mirrors](2026-09-23-enrico-git-mirrors.md)

- [2026-09-23: Lyra developer SSH](2026-09-23-lyra-developer-ssh.md)

- [2026-09-22: DNS-resolved fleet control and production Audi certificates](2026-09-22-dns-resolved-fleet-control.md)

- [2026-09-22: Structured logging and audit hardening](2026-09-22-structured-logging-audit-hardening.md)

- [2026-09-22: Audi-mediated guest SSH](2026-09-22-guest-ssh.md)

- [2026-09-22: Default development environments](2026-09-22-default-development-environments.md)

- [2026-09-22: Inception completion audit](2026-09-22-inception-completion-audit.md)

- [2026-09-22: Underclass pin advancement](2026-09-22-underclass-pin.md)

- [2026-09-22: Overalls fresh installation](2026-09-22-overalls-rebuild.md)

- [2026-09-22: Portable workload relocation](2026-09-22-portable-workload-relocation.md)

- [2026-09-22: Serial-console rendering](2026-09-22-serial-console-rendering.md)
- [2026-09-22: Audi fleet enablement](2026-09-22-audi-fleet-enablement.md)

- [2026-09-21: Porsche user relocation](2026-09-21-porsche-user-relocation.md)
- [2026-09-21: Standalone nix-compact extraction](2026-09-21-standalone-nix-compact.md)

- [2026-09-21: Compact Nix build logs](2026-09-21-compact-nix-build-logs.md)
- [2026-09-21: Fleet firewall composition recovery](2026-09-21-fleet-firewall-composition.md)

- [2026-09-21: Legacy VM journal import](2026-09-21-legacy-vm-journal-import.md)
- [2026-09-21: Private-services PKI rotation](2026-09-21-private-services-pki-rotation.md)
- [2026-09-21: Terminal original-plan reconciliation](2026-09-21-terminal-original-plan.md)

- [2026-09-20: Terminal integration follow-up](2026-09-20-terminal-integration-follow-up.md)

- [2026-09-20: Terminal host audit remediation](2026-09-20-terminal-host-audit.md)
- [2026-09-20: Browser terminal audit remediation](2026-09-20-browser-terminal-audit.md)
- [2026-09-19: Terminal v2](2026-09-19-terminal-v2.md)
- [2026-09-20: Independent Underclass fleet rollout](2026-09-20-underclass-fleet-rollout.md)
- [2026-09-20: Fleet overlay and firewall perimeter](2026-09-20-fleet-overlay-firewall.md)
- [2026-09-20: Galileo milestone](2026-09-20-galileo.md)
- [2026-09-19: Default guest toolset](2026-09-19-guest-toolset.md)

- [2026-09-19: Fleet structured logging](2026-09-19-structured-logging-fleet.md)
- [2026-09-19: Bounded Nix store garbage collection](2026-09-19-nix-store-gc.md)
- [2026-09-19: Python typing and static-analysis gate](2026-09-19-python-toolchain.md)
- [2026-09-19: Multi-disk workload transfer](2026-09-19-multi-disk-transfer.md)

- [2026-09-18: Required Lilly transfer](2026-09-18-required-lilly-transfer.md)

- [2026-09-18: Porsche interactive input](2026-09-18-porsche-interactive-input.md)

- [2026-09-18: Nix-built Ubuntu guests](2026-09-18-ubuntu-guests.md)
- [2026-09-18: Reciprocal Nix builders](2026-09-18-remote-builders.md)

- [2026-09-18: Dungarees worker provisioning](2026-09-18-dungarees-provisioning.md)

- [2026-09-18: Ziggy private services](2026-09-18-ziggy-private-services.md)
- [2026-09-18: Passkey administration and account retirement](2026-09-18-passkey-administration.md)

- [2026-09-18: Administrator operational status](2026-09-18-admin-operations.md)

- [2026-09-18: Administrator workload console](2026-09-18-admin-workloads.md)

- [2026-09-18: Maintenance console and re-planning](2026-09-18-maintenance-console.md)

- [2026-09-18: Evacuation foundation](2026-09-18-evacuation-foundation.md)

- [2026-09-18: Fleet dashboard foundation](2026-09-18-fleet-dashboards.md)

- [2026-09-18: Fleet ingestion and history](2026-09-18-fleet-ingestion.md)

- [2026-09-18: Detailed fleet collector](2026-09-18-fleet-collector.md)

- [2026-09-18: Administrative jobs](2026-09-18-admin-jobs.md)

- [2026-09-18: Administrative authority foundation](2026-09-18-admin-foundation.md)

- [2026-09-18: Queued machine cloning](2026-09-18-machine-cloning.md)

- [2026-09-18: VM directory cleanup](2026-09-18-vm-directory-cleanup.md)

- [2026-09-18: Porsche live acceptance](2026-09-18-porsche-live-acceptance.md)

- [2026-09-17: Overalls web redesign](2026-09-17-web-redesign.md)
- [Usage-based overcommit](2026-09-17-usage-based-overcommit.md): ADR-0050 resource-update and admission implementation evidence.

- [2026-09-17: Email registration](2026-09-17-email-registration.md)

- [2026-09-17: Audi ingress implementation](2026-09-17-audi-ingress.md)

- [2026-09-17: Porsche SSH management](2026-09-17-porsche-ssh-management.md)

- [2026-09-17: fleet users and recipient reconciliation](2026-09-17-fleet-users.md)

- [2026-09-17: host-local SMTP relay](2026-09-17-smtp-relay.md)

- [2026-09-17: opt-in host TCP profile](2026-09-17-host-tcp-profile.md)

- [2026-09-17: HTTP-01 validation and three-frontend routing](2026-09-17-http01-validation.md)

- [2026-09-16: automatic host updates](2026-09-16-automatic-host-updates.md)

- [2026-09-16: workload relocation feasibility](2026-09-16-workload-relocation.md)

- [2026-09-16: Nix layout and test refactor](2026-09-16-nix-layout-and-test-refactor.md)

- [2026-09-16: plan completion audit](2026-09-16-plan-completion-audit.md)

- [2026-09-16: coordinated Marshall credential rotation](2026-09-16-fleet-credential-rotation.md)

- [2026-09-16: SSH host identity rotation and replacement recovery](2026-09-16-secret-host-rotation.md)

- [2026-09-16: NixOS fleet coordination and independent execution](2026-09-16-nixos-fleet.md)

- [2026-09-16: mirrored ZFS installation and UEFI](2026-09-16-mirrored-installation.md)

- [2026-09-16: native ZFS I/O observations](2026-09-16-native-zfs-io.md)

- [2026-09-16: owned sparse ZFS lifecycle](2026-09-16-owned-zfs-lifecycle.md)
- [2026-09-16: native ZFS observations and lock release](2026-09-16-native-zfs-observations.md)

- [2026-09-16: ZFS identity and capacity contract](2026-09-16-zfs-capacity-contract.md)

- [2026-09-16: ACME issuance and persistent certificate publication](2026-09-16-acme-publication.md)

- [2026-09-16: NixOS releases, roles, TLS and secret custody](2026-09-16-nixos-releases-and-roles.md)

- [2026-09-16: NixOS deployment and sparse ZFS decisions](2026-09-16-nixos-and-sparse-zfs.md)

- [2026-09-16: colocated code contracts and structural gates](2026-09-16-code-contracts.md)

Persist reviews for substantive architectural changes and milestone audits.
Ordinary changes still need an impact assessment in the task/PR summary; do not
create empty review files for changes with no architecture impact.

- [2026-09-15: governance milestone and platform baseline](2026-09-15-governance-baseline.md)
- [2026-09-15: runtime and type-analysis implementation](2026-09-15-toolchain.md)

- [2026-09-15: capacity admission and Cedar](2026-09-15-capacity-admission.md)

- [2026-09-15: NixOS guest and local console](2026-09-15-guest-console.md)

- [2026-09-15: authenticated provisioner transport](2026-09-15-provisioner-transport.md)

- [2026-09-15: continuous capacity and durable Lilly receipt](2026-09-15-capacity-loop.md)
- [2026-09-15: immutable image and profile address admission](2026-09-15-image-address.md)

- [2026-09-15: jailed execution and host networking](2026-09-15-jailed-execution.md)
- [2026-09-15: executable generations and lifecycle outcomes](2026-09-15-execution-lifecycle.md)

- [2026-09-15: durable VM actors and physical host ownership](2026-09-15-durable-vm-actors.md)

- [2026-09-15: persisted sharing and machine pages](2026-09-15-sharing-and-machine-pages.md)
- [2026-09-15: terminal session and writer authority](2026-09-15-terminal-authority.md)
- [2026-09-15: local console fences and bounded streams](2026-09-15-local-console-gate.md)
- [2026-09-15: console relay connections and encrypted mailboxes](2026-09-15-console-relay.md)
- [2026-09-16: browser terminal and fresh login checks](2026-09-16-browser-terminal.md)
- [2026-09-16: retained capacity telemetry](2026-09-16-retained-telemetry.md)
- [2026-09-16: production authentication email](2026-09-16-production-email.md)
- [2026-09-16: protected provisioner enrollment](2026-09-16-provisioner-enrollment.md)

- [2026-09-16: host maintenance and retirement](2026-09-16-host-maintenance.md)
- [2026-09-16: production release deployment](2026-09-16-production-deployment.md)
- [2026-09-16: three-node production terminal failover](2026-09-16-terminal-failover.md)
- [2026-09-16: database durability and isolated recovery](2026-09-16-database-recovery.md)

- [2026-09-16: ZFS-only provisioning and provisioner v2](2026-09-16-zfs-only-provisioning.md)

- [2026-09-17: host observability](2026-09-17-host-observability.md)

Use `YYYY-MM-DD-topic.md` with: scope and evidence, affected ADRs, findings
(severity, evidence, consequence, recommendation), decisions/open questions,
verification performed and follow-up work. Say whether each discrepancy is an
implementation defect, a documented unimplemented requirement, or a design that
needs replacement. Keep checks that were run separate from future test plans.

- [Agent threads foundation](2026-09-23-agent-threads-foundation.md): ADR-0100 boundaries, passing fleet acceptance and remaining gaps.

- [Declarative host provisioning](2026-09-17-host-provisioning.md): ADR-0043, installation/enrollment boundaries and acceptance evidence.

- [2026-09-17: recovery-only secret inventory](2026-09-17-recovery-secret-inventory.md)

- [Declarative enrollment](2026-09-17-declarative-enrollment.md): durable operator retries, host bindings and five-year credential policy.

- [2026-09-17: overalls physical Hetzner provisioning](2026-09-17-overalls-provisioning.md)

- [2026-09-17: overalls service deployment](2026-09-17-overalls-services.md)

- [2026-09-18: Porsche on overalls](2026-09-18-porsche-overalls.md)
- [2026-09-22: empty Lilly authority rebind](2026-09-22-empty-lilly-rebind.md): bounded explicit recovery after control-plane database replacement.
- [VM resizing](2026-09-17-vm-resizing.md): durable resource transitions and validation.

- [2026-09-18: Main branch integration](2026-09-18-main-integration.md): preserved branch work, ADR identities and validation limits.

- [VM disk limit](2026-09-18-vm-disk-limit.md): 500 GiB shared boundary, UI, API and Porsche enforcement.

- [Fleet Mosh and lingering](2026-09-18-fleet-mosh.md): host terminal transport, named-user lifecycle and verification.
- [Inception development profile (in progress)](2026-09-18-inception-profile.md)

- [Interactive monitoring dashboards](2026-09-18-interactive-dashboards.md): graphical monitoring, bounded projections, chart lifecycle and authorization.

- [Lifecycle state machines and audit](2026-09-18-lifecycle-state-machines.md): named transitions, durable local/central audit, retention and recovery verification.
- [Customer isolation](2026-09-18-customer-isolation.md): owner-only access, blocked egress, layered web denial and native verification.
- [IPv4 separation and public Inception (in progress)](2026-09-18-inception-public-ingress.md)
- [Brady egress cache (in progress)](2026-09-18-brady-egress-cache.md): transparent proxy, cache and logging boundaries with remaining native acceptance.

- [Host recovery backups (in progress)](2026-09-18-host-recovery-backups.md): short retention, snapshot ownership, flush-only guests, database recovery and admin status.
- [Public Audi wildcard custody (in progress)](2026-09-23-audi-wildcard-custody.md): encrypted database custody, gateway delivery, recovery and nested-name gaps.

- [2026-09-25: Control room verification](2026-09-25-control-room-verification.md): generated current-authority histories and focused packaged browser acceptance.

- [2026-09-25: Subsequent MFA login and cross-replica revocation](2026-09-25-mfa-login-verification.md)

- [Account lifecycle verification](2026-09-25-account-lifecycle-verification.md): repeated identity generations, invitations, retired authority and real physical cleanup; exact execution scope recorded separately.

- [Unified SSH host CA](2026-09-25-unified-ssh-host-ca.md): issuance, custody, native certificates and installer verification.
- [Administrative job history verification](2026-09-25-job-history-verification.md) — generated retained histories, retry/authority ordering and packaged worker/browser acceptance scope.
- [Terminal workspace verification](2026-09-25-terminal-workspace-verification.md): delayed-ticket attachment, accessibility layout and bounded database client recovery corrections; both complete integrated NixOS and Ubuntu terminal journeys passed with scoped application and native evidence.

- [Administrative account authority verification](2026-09-25-admin-account-authority-verification.md): current mutation authority through audit commit, ordered participants and scoped generated/distributed/browser evidence.

- [Backup operator verification](2026-09-26-backup-operator-verification.md): generated complete manifests, real local Restic retention, host-lock refusals and explicit partial-output recovery.

- [Maintenance evacuation verification](2026-09-25-maintenance-evacuation-verification.md): generated consent/readiness histories, actor control ordering and bounded browser/two-Lilly evidence.

- [Installer SSH configuration verification](2026-09-26-installer-ssh-config.md): generated pre-existing local SSH configuration preservation/refusal properties with an independent byte-level inventory oracle; marker-count and glue-promotion defect repairs; native macOS remains outside.
- [2026-09-29: Open problem resolution](2026-09-29-open-problem-resolution.md) — Lilly startup off image hashing (Brady restart attribution), conflict-marker guard, Brady resolver-disagreement and clone coverage, fleet monitor fixture port, test oracle fixes.
- [2026-09-28: Repository launch links](2026-09-28-repository-launch.md) — ADR-0128 protocol, persistence, vsock delivery and guest-clone review with gate evidence.
- [2026-09-28: Browser probe failure diagnostics](2026-09-28-browser-probe-diagnostics.md) — rendezvous-published bounded diagnostics; triage evidence for the recorded fleet browser acceptance defect.
- [2026-09-28: Fleet OpenTelemetry baseline](2026-09-28-fleet-otel-baseline.md) — guest intake, collector/store placement, NixOS evidence and remaining SLO gaps.
- [2026-09-26: Update failure matrix verification](2026-09-26-update-failure-matrix.md) — update authorization/artifact refusal semantics plus native drift-reconvergence, interrupted-fetch and failed-activation legs.
- [Login race verification](2026-09-26-login-races.md): fenced magic-link issuance and raced callback refusal repairs, committed three-node sign-in/revocation and sign-out/exchange schedules, challenge retention bounds, and the native expired-ceremony refusal with cross-replica fresh retry.

- [Native namespace descriptor histories](2026-10-02-namespace-descriptor-histories.md): generated retained namespaces, duplicate/original-descriptor lifecycle and independent real mount inventory; native focused postmerge execution passed eight checks in 114.6 seconds.

- [Retry measurement window histories](2026-10-02-retry-measurement-window-histories.md): authenticated retry fixture, two-proof boundary composition and exact immutable accounting inventories; focused and full precommit execution recorded.

- [Retry proof binding histories](2026-10-02-retry-proof-binding-histories.md): exact refused inventories, valid delayed historical receipts and unchanged-window crossing; reviewed focused execution recorded, full gates pending.

- [Explicit Galileo attachments and fault validation](2026-10-03-galileo-attachments-and-faults.md)
- [Multi-GiB cache acceptance (2026-10-03)](2026-10-03-multi-gib-egress-cache.md) records 4 GiB boundary coverage and separate live checkpoint reuse.

- [Audi terminal version refusal (2026-10-03)](2026-10-03-audi-terminal-version-refusal.md) records stopped DNS, SSH and certificate work, suspended scheduler retirement, packaged DNS expiry and operator recovery.
- [Terminald credit retirement (2026-10-03)](2026-10-03-terminald-credit-retirement.md) records native PTY/socket explicit cancellation, returned ring/viewer permits and preserved natural EOF draining.
- [Integrated property gate stability (2026-10-03)](2026-10-03-integrated-property-gate-stability.md) records failed full-suite budgets, healthy host/pool positive restart fixtures and scoped same-seed repair evidence.

- [Lilly runtime readiness (2026-10-03)](2026-10-03-lilly-runtime-readiness.md) records passing native incarnation histories, the corrected complete-reply oracle and remaining physical/updater/hosted gaps.

- [Terminald retired ring release](2026-10-05-terminald-retired-ring.md): native retained-allocation counterexample, bounded repair and exact stalled tail drain.

- [Terminald overwrite backing allocation](2026-10-05-terminald-ring-overwrite.md): full-ring allocation counterexample, pre-append eviction and independent newest-byte/cursor model.

- [Committed admission reply loss](2026-10-05-admission-lost-reply.md): observed worker and whole-BEAM loss, three-node retries and unchanged committed allocation inventory.
- [Lilly submission recovery](2026-10-05-lilly-submission-recovery.md): generated native submission/daemon-loss and authenticated settlement passed337.69seconds within the1036.30-second machine script; static driver checks passed. Mutation sensitivity and final gates pending.

- [2026-10-05 audit scan-boundary fairness](2026-10-05-audit-scan-fairness.md) — local generated real-journal scan geometry; focused properties passed, full gates pending.

- [Terminal peer budget incarnation](2026-10-06-terminal-peer-budget-incarnation.md): generated authenticated TLS peer-pair restart and exact successor admission; synthetic host/native gap and mutation validation are explicit.
- [Transient pool contention and capacity freshness](2026-10-09-transient-pool-contention.md): withheld-pool diagnostics, `busy` report entry keeping the previous observation, server-first rollout.

- [2026-09-26: Fleet diagnostic log store and Control room viewer](2026-09-26-fleet-log-viewer.md): ADR-0127's WG-scoped VictoriaLogs destination, reviewed Fluent Bit sources, read-only Control-room viewer and deployment evidence; long-horizon retention and CA rotation remain open.
- [2026-09-26: Hegel property-based testing for NixOS machine checks](2026-09-26-hegel-machine-property-testing.md): verification-only Hegel framework and migrated machine suites; contracts, HLDD and Python gates passed, with composed property execution bounded by existing failures.
- [Backup interruptions and custody symmetry (2026-09-27)](2026-09-27-backup-interruptions.md): backup command custody gates, interruption/publication-window histories and cleanup mutants preserve terminal recovery semantics; native and production gaps remain.
- [Agent revocation histories (2026-09-28)](2026-09-28-agent-revocation.md): owner-authority fencing, revocation-aware CLI authorization and orphaned-command retirement, with focused and three-BEAM histories passing.
- [Ingress renewal and refusal-matrix verification (2026-09-28)](2026-09-28-ingress-refusals.md): generated publication/lease/withdrawal histories, distributed renewal races and Audi refusal coverage; focused and component gates passed, native fleet execution remains queued.
- [Integration name-custody fencing (2026-09-28)](2026-09-28-integration-faults.md): archived integration names now refuse replay and team liveness binds authority to membership; focused histories and contract annotations passed.
- [Windows guest agents (2026-10-14)](2026-10-14-windows-guest-agents.md): ADR-0171's `windows-v1` capability table, vsock endpoint, readiness and Rust guest agents; unit, image and fleet validation are recorded with native workstation and scheduler gaps.
- [Windows images with pinned winget packages (2026-10-15)](2026-10-15-windows-images-winget.md): ADR-0173's Desktop Experience image installs pinned winget packages and WSL features through an offline file server; image and fleet checks passed, with interactive winget registration and nested virtualization gaps recorded.
- [Windows workstation client (2026-10-15)](2026-10-15-windows-workstation-client.md): ADR-0172's cross-platform Overalls CLI adds Windows packaging, SSH and update paths; Linux checks, Windows cross-build and fleet guest-agent validation passed, with real Windows workstation use remaining.
- [Antithesis five-attempt bootstrap admission (2026-10-16)](2026-10-16-antithesis-five-attempt-admission.md): verification campaign ledger admits five concurrent hosted attempts and refuses a sixth; no production architecture boundary changes.
- [Antithesis guest-lifecycle profile (2026-10-17)](2026-10-17-antithesis-guest-lifecycle-profile.md): launchable QEMU TCG guest-lifecycle selection with a labelled stub-storage container Lilly; harness-only, no ADR change and no recorded run.
- [2026 10 16 Nix Domain Layout](2026-10-16-nix-domain-layout.md)

- [Git attribution and guest identity (2026-10-18)](2026-10-18-git-attribution.md): ADR-0198 settings, immutable snapshots and guest configuration verification.
- [Underclass package pin (2026-10-18)](2026-10-18-underclass-pin.md): advances the immutable package to upstream `7169223`; the source hash changed, Cargo.lock and architecture boundaries remain unchanged. Tests and builds were not run.
- [Fleet build scheduling (2026-10-20)](2026-10-20-fleet-build-scheduling.md): pins tribuchet and nix-grpc-store, makes Panterloons the single tribuchet scheduler for itself and Dungarees over mTLS `grpc://` (ADR-0248, superseding ADR-0086 for the pair); fixes a build-machine URI lock-file overflow; records the trusted pool and experimental Nix feature risks. Evaluation and two-VM machine checks; no deployment receipt yet.
- [Underclass package pin (2026-10-20)](2026-10-20-underclass-pin.md): advances the immutable package to upstream `dbaf7b8` (overload failover before output); the source hash changed, Cargo.lock and architecture boundaries remain unchanged. Package build and patched upstream tests passed; machine tests were not run.
- [LiveView load performance (2026-10-22)](2026-10-22-liveview-load-performance.md): ADR-0256 batches machine-page authorization over one read-only repeatable-read snapshot with unchanged decisions (Hegel equivalence property), schedules refreshes after completion, adds list/catalog indexes and `overalls_diagnostics` refresh spans, metrics and dashboard panels. Measured 724 → 37 queries for a 24-machine owner page in the test sandbox; list-query `EXPLAIN` on fleet data remains open.
- [LiveView callback observability (2026-10-22)](2026-10-22-liveview-callback-observability.md): ADR-0257 traces every Marshall LiveView mount, params, event and message as one `marshall.live.callback` span and measurement labelled only by a registered view label and phase, adds fail-open `Tracing.start/2`/`finish/3`, per-phase runtime gauges and two operations panels.
- [Marshall page service levels (2026-10-22)](2026-10-22-marshall-page-service-levels.md): ADR-0258 admits every LiveView callback to an independent `marshall_live` request recorder, adds a guarded `latency` objective kind, two provisional 99% objectives (completion, within 1 s) with burn rules, and the `overalls-marshall-pages` Grafana dashboard.
- [Host-row lock convoy (2026-10-23)](2026-10-23-host-row-lock-convoy.md): /threads and /machines 5xx from a `compute_hosts` FOR UPDATE convoy and FK deadlocks; host rows now lock FOR NO KEY UPDATE, LiveView refresh fails closed, failed callback spans carry a closed reason, the production pool doubles, and ADR-0259 adds deployment revision telemetry.
- [Restored guest memory accounting (2026-10-30)](2026-10-30-restored-guest-memory-accounting.md): a restored guest's private file mapping of its checkpoint double-charged the VM cgroup and the next checkpoint panicked the host on a cgroup OOM; ADR-0266 copies restored RAM into anonymous memory in the patched VMM without raising `MemoryMax`.
- [Fenced capacity snapshots (2026-10-31)](2026-10-31-fenced-capacity-snapshots.md): capacity reads held the pool lock for 1.7-4.7 s on CI, and transfer and clone sections went `storage_busy` behind them; ADR-0274 holds the lock only for the bind and a generation token and withholds straddled reads. BEAM evidence; native rerun pending.
- [Pool observer off the report path (2026-10-30)](2026-10-30-pool-observer.md): inline pool snapshots (p50 1.5 s lock hold on CI) delayed every host report past the 5 s enrollment check; ADR-0140 gains a background per-pool observer and an optional wire `observed_at` bounded by ADR-0163's busy grace. BEAM evidence; native fleet run pending.
