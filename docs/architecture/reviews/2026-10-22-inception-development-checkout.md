# Inception development checkout review

## Scope and architecture impact

This review reconciles ADR-0262 with the current Inception image, bootstrap,
native fixture and CI catalog. The change preserves Inception's existing
Marshall → Lilly → Firecracker ownership boundary and the fixed resource and
separate-data-disk policy from ADR-0054/ADR-0072. It adds no protocol surface
or parent workspace receiver: the guest-owned bootstrap remains the authority
for the development checkout. The architecture impact is therefore limited to
the guest's first-boot network dependency and its persistent workspace.

## Implementation evidence

`nix/domains/artifacts/guest/inception/prepare.py` validates `/workspace`,
clones the canonical `https://github.com/ghuntley/overalls` origin into a
temporary sibling and publishes it atomically. Existing valid Git checkouts are
left untouched, including uncommitted edits; malformed, symlinked and non-Git
paths fail closed. Clone and subprocess attempts have bounded retry and
timeout handling. `default.nix` supplies the source URL as a public image
setting and keeps the persistent SSH host key required by Inception secret
custody while administrative OpenSSH remains disabled.

The preparation helper orders identity setup after its Git identity writer and
the host's `network-online.target`. The guest-owned
`inception-source.service` additionally requires the published trust bundle,
the validated `lilly-network.service` route and `systemd-resolved.service`
before attempting public egress. It retries the public checkout independently
of boot readiness. A GitHub outage therefore cannot block boot-bound credential
delivery or the packaged Marshall/Lilly stack. It also
keeps public recursive DNS on the global resolver path while the more-specific
`~internal` route remains on Audi, and isolates bootstrap Git from the inherited
interactive broker configuration.
The staged checkout is made writable by all managed guest accounts (directories
and executable files `0777`, regular files `0666`), and an existing checkout is
repaired to that policy on restart without following symlinks. Setuid, setgid
and sticky bits, foreign ownership and malformed Git metadata remain fail-closed.

`image-builder.nix` now preserves the pinned `nix/domains` source hierarchy in
the nested offline recipe. The recipe imports the guest constructor from the
correct source root and retains its Nixpkgs and Lyra inputs. The image build
bound is aligned with Lilly's Inception readiness bound. The native probe checks
the exact GitHub origin and checks that a developer edit survives stop/start.

All Inception checks are enabled in `nix/verification/tests/ci.nix`; the focused
preparation test covers TLS stability, local Git cloning, origin identity,
edit preservation and malformed-path refusal.

## Verification performed

- `inception-image-builder` pure evaluation/build: passed.
- `inception-runtime`, `inception-probe`, `inception-proof-broker` and
  `inception-ssh-host-ca`: passed.
- Focused preparation test: five tests passed with the pinned Nix shell tools.
- Ruff format/check and `ty check` for changed Python files: passed.
- `elixir scripts/check_adrs.exs`: passed.
- Inception check metadata evaluates with `enable = true`, `machine = true` and
  `nestedKvm = true`.
- `nix build --no-link .#checks.x86_64-linux.inception-runtime`: passed after
  the shared-workspace, Git-configuration and network-ordering changes.
- The 2026-10-25 native create subtest passed for both workloads and checked the exact origin, checkout publication, writability and 16-vCPU/32-GiB/64-GiB shape. The focused native checkout check passed on 2026-10-30: it created a real workload through outer Marshall and Lilly, checked the checkout, wrote a developer edit, stopped and started the workload, verified the edit remained, and deleted the workload.

## Remaining native gap

The focused native check now records the complete ADR-0262 lifecycle, including
restart and edit retention. The full Inception fixture still has a separate
public DNS-01/ACME readiness timeout after the checkout assertions; that later
ingress scenario is outside ADR-0262's source-delivery boundary and does not
invalidate the checkout evidence. The focused preparation test continues to use
an isolated local Git origin for deterministic failure-path coverage.

## Follow-up

Keep the focused native checkout check in the catalog and rerun it on builders
with the required nested-KVM feature. If the declared NAT path is unavailable
on a builder, add a test-only HTTPS Git fixture and an explicit source-setting
seam; do not weaken production TLS verification or change the canonical origin
contract.
