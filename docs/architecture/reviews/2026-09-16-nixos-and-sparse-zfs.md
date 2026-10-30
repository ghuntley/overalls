# NixOS deployment and sparse ZFS architecture review

## Scope and evidence

This documentation-only review records the user-selected deployment, storage,
secret custody and machine-testing decisions. It uses the architecture-review,
ADR-maintenance and code-contract discovery workflows. The working tree was clean
before the change. No application, Nix expression, service template, contract
implementation or live host configuration is changed by this review.

Inspected the existing ADRs, repository/docs contracts, relevant source contracts,
ext4 pool/enrollment validation, disk materialization, budget arithmetic, jail
configuration, release packaging and systemd/HAProxy templates. Existing Nix files
provide a guest image and release wrapper, not reusable host modules or a NixOS
machine suite. Earlier read-only reference-host inspection reported a mirrored
ZFS/dual-EFI disko test; that external test has not been imported or run here.

## Affected ADRs

- [ADR-0030](../decisions/0030-nixos-deployment-and-tls.md) replaces
  [ADR-0027](../decisions/0027-production-release-deployment.md).
- [ADR-0031](../decisions/0031-sparse-zfs-storage-and-capacity.md) replaces
  [ADR-0013](../decisions/0013-capacity-collection-and-local-receipt.md) and
  [ADR-0015](../decisions/0015-jailed-execution-and-host-networking.md), explicitly
  retaining their non-storage receipt, supervision, confinement and networking.
- [ADR-0032](../decisions/0032-ssh-derived-age-identities.md) and
  [ADR-0033](../decisions/0033-nixos-machine-verification.md) add accepted custody
  and testing requirements. All four new capabilities have implementation planned.
- [ADR-0034](../decisions/0034-mixed-workload-storage-tuning.md) remains proposed;
  it does not turn assistant-suggested tuning into user-approved performance facts.
- Related capacity, assurance, enrollment and recovery records now distinguish
  resolved mechanism choices from pending implementation/provider evidence.

## Findings

### 1. High — storage design replacement is not implemented

[Pool inspection](../../../lilly/lib/lilly/host/pool.ex) and
[enrollment](../../../marshall/lib/marshall/compute/enrollment_request.ex) reject
ZFS. [Disk creation](../../../lilly/lib/lilly/vm/disk.ex) uses non-sparse copying,
fallocate and full-allocation checks. Its source contracts deliberately require
the current ext4 behavior. Merely adding Nix dataset properties or removing one
guard would leave incompatible ownership/accounting rules.

Classification: accepted requirement remains unimplemented after an explicit
design replacement (ADR-0031). Implement backend validation, sparse creation,
GUID ownership, reporting and local contracts together; retain ext4 and upgrade
all Marshall instances before enabling ZFS hosts.

### 2. High — logical commitments are not ZFS reservations

[Admission arithmetic](../../../marshall/lib/marshall/compute/budget.ex) credits
only attributed physical allocation against retained commitments. Reusing apparent
sparse size or compression ratios as that credit would invent capacity. ZFS
available space is constrained by shared pool usage and quotas, and its accounting
can lag writes/deletion. Without filesystem reservations, unrelated writers can
still exhaust shared space.

Classification: new accounting/evidence obligation (ADR-0031), not a demonstrated
bug in the ext4 implementation. Keep logical limits, physical observations and
headroom separate; validate coherent conservative sampling and pressure recovery
with properties plus real machine tests. Treat 20% headroom as proposed only.

### 3. High — guest flush behavior is implicit

[The jail configuration](../../../lilly/lib/lilly/vm/jail.ex) omits `cache_type`.
The [pinned Firecracker documentation](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/docs/api_requests/block-caching.md)
describes the default Unsafe behavior and Writeback support for guest flushes.
ZFS `sync=standard` alone cannot cause the VMM to advertise/forward guest flushes.
Existing stop/start tests do not prove acknowledged-write survival after host loss.

Classification: existing implementation gap against the newly explicit durability
requirement in ADR-0031; not evidence that historical host-loss tests passed.
Set Writeback explicitly and test acknowledged flushes through real guests with
an abrupt-loss simulation that invalidates the relevant caches.

### 4. High — deployment and TLS changes require implementation

[Packaging](../../../scripts/package_release.sh) builds outside Nix and then uses
the closure wrapper (`nix/domains/artifacts/applications/release-bundle.nix` at overalls revision `4c6fac25c`, file deleted). The
HAProxy example (`scripts/test/fixtures/legacy-deployment/haproxy.cfg.example` at overalls revision `9fe1e493`, repository deleted) and
deployment contract (`scripts/test/fixtures/legacy-deployment/CONTRACTS` at overalls revision `9fe1e493`, repository deleted) require passthrough. They do not
implement ADR-0030's source-built packages, host modules or TLS bridge.

Classification: selected replacement remains unimplemented. Keep the existing
example/contract visibly historical; update rendering, service configuration,
contracts and actual TLS/WebSocket tests together during implementation. Preserve
database budgets, migrations, readiness and independent guest supervision.

### 5. High — secret custody has a bootstrap and privilege boundary

[Private-file readers](../../../lilly/lib/lilly/control/credential_file.ex) and
Marshall's TLS credentials (`scripts/test/fixtures/legacy-deployment/systemd/marshall@.service` at overalls revision `9fe1e493`, repository deleted) support
existing delivery only. There is no host SSH-to-age/SecretSpec preparation service.
An image containing a reusable host key or a Marshall service holding the host
age identity would violate ADR-0032's intended boundary.

Classification: accepted deployment requirement remains unimplemented. Pin the
supplied public key, generate/preserve unique host identities, validate recipient
conversion and recovery, and test private runtime delivery with synthetic keys.

### 6. Medium — machine tests and tuning evidence are absent

The [deployment harness](../../../nix/verification/tests/README.md) and
[execution harness](../../../marshall/scripts/smoke_execution.exs) do not provide
the required `runNixOSTest` host suite. Nested KVM availability has not been
established for a test builder. No measurements establish 16K records, 20%
headroom or cache candidates as optimal for the reference workload.

Classification: planned verification (ADR-0033) and proposed tuning (ADR-0034).
Require real nested guests, separate machine roles, firmware boot and mirrored
failure tests; an unavailable runner is an unmet check. Keep physical performance,
100-instance load, live providers and independent failure domains separate.

## Decisions and open questions

Record NixOS roles/images, external AWS PostgreSQL, TLS bridging/Route 53 ACME,
SecretSpec/SOPS with SSH-derived identities, sparse LZ4 datasets with a logical
cap, and NixOS machine testing as accepted. Preserve all superseded rationale
and historical implementation status. Record tuning candidates as proposed.

Actual host recipients, deployment DNS/certificates/database values and a capable
test builder remain environment inputs. ZFS sampling, headroom and performance
need implementation evidence. No application is claimed compatible with the new
backend or custody scheme merely because its historical source is linked.

## Verification performed

- Baseline: `elixir scripts/check_adrs.exs` passed for the original 29 decisions.
- `devenv shell -- elixir scripts/check_adrs.exs` passed for all 34 decisions,
  including reciprocal supersession, index consistency and local links.
- `git diff --check` passed; an additional whitespace/scope check included all
  six new files and confirmed that every changed file is architecture Markdown.
- Compared superseded records against HEAD: their Decision, Alternatives,
  Consequences, Invariants and verification, Implementation evidence and Open
  questions sections are unchanged. Only metadata, explanatory context and
  successor links were added to those records.
- Independently calculated the supplied public key's SHA256 fingerprint and
  verified it matches ADR-0032. No private key was accessed.
- Manually compared implementation evidence and source contracts with the new
  decisions. No runtime or source contract was weakened to conceal a gap.

No compiler/Dialyzer, application, NixOS, KVM, provider or benchmark acceptance
was run for this documentation-only change. The shared validator is unchanged.

## Follow-up work

Implement and verify ADRs 0030–0033, reconciling source contracts in the same
behavioral changes. Measure and review ADR-0034 before promoting tuning defaults.
Supply deployment inputs and perform the separate live rollout and production
acceptance. Link actual code and executed results before advancing implementation
statuses. The documentation review is not deployment completion.
