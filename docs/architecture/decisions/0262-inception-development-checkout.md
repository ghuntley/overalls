# ADR-0262: Inception development checkout

- ID: ADR-0262
- Date: 2026-10-22
- Status: accepted
- Implementation: implemented
- Components: Marshall Compute, Nix Inception guest, NixOS machine verification
- Supersedes: none
- Superseded by: none

## Context

The requested Inception development workflow starts from the Overalls source
repository itself. The prior image-bundled checkout could be stale and did not
prove that a newly admitted workload had a development checkout. The existing
Inception resource and separate sparse data-disk policy remains governed by
ADR-0054 and its successors.
This decision amends only ADR-0054's source-delivery clause; it does not
supersede that profile decision or its later successors.

## Decision

On first boot, the Inception guest clones
`https://github.com/ghuntley/overalls` into `/workspace/overalls` using Git over
the guest's verified TLS trust. The clone is staged in a temporary sibling and
renamed atomically. A valid existing checkout is never replaced, so edits and
uncommitted work survive restart. Failed network attempts retry within the
bounded `inception-source.service` startup window. Marshall does not attach a
`WorkspaceSource` command to Inception; this bootstrap is guest-owned and the
image remains a non-receiver image.

The bootstrap runs after the guest trust bundle has been published and the
Inception host's network-online and Lilly guest-network units are active. It
uses the guest's public DNS route for GitHub while retaining the more specific
private-service DNS route for `.internal` names. Its Git subprocesses
disable system and global Git configuration so the interactive guest's GitHub
broker `insteadOf` rules cannot rewrite the canonical origin or supply
credentials. The published checkout is a shared development workspace: root
and directory entries are mode `0777`, regular executable files `0777`, and
other regular files `0666`. On restart, these modes are repaired without
following symlinks; special permission bits and malformed ownership are still
refused.

The profile's existing resource minima and fixed additional sparse data disk
remain unchanged and are included in reservations and lifecycle operations.

## Alternatives

Bundling a Nix source snapshot was rejected because it is not the requested
development checkout and can drift from the public repository. Marshall's
workspace-source delivery was rejected because Inception is not built with the
ordinary guest receiver and its bootstrap has a separate trust and persistence
boundary.

## Consequences

Initial Inception startup needs guest egress to GitHub and verified public CA
trust. GitHub unavailability delays the workload but does not overwrite an
existing checkout. The checkout is a development input; packaged Marshall,
Lilly and inner guest releases still require their normal build and image
update workflow after source edits.

## Invariants and verification

- A new workload's guest-owned source bootstrap publishes `.git` and the exact
  `origin` URL before the development checkout is used. Stack readiness may
  complete while this independently retrying bootstrap is still converging.
- A restart preserves a developer edit in the checkout.
- A malformed or non-directory existing path fails closed.
- The Inception NixOS machine test checks clone origin, checkout state and edit
  retention across stop/start; focused preparation tests use an isolated local
  Git origin.

## Implementation evidence

[bootstrap clone and network ordering](../../../nix/domains/artifacts/guest/inception/prepare.py),
[machine defaults](../../../marshall/lib/marshall_web/live/machines_live.ex),
and the [native Inception fixture](../../../nix/verification/tests/machines/inception/driver.py)
implement and exercise the decision. The guest-owned `inception-source.service`
retries independently of the boot-bound readiness path. The focused native
checkout check (`.#checks.x86_64-linux.inception-checkout`, passed 2026-10-30)
admits a real workload, verifies the exact GitHub origin and writable checkout,
edits the checkout, stops and starts the workload, and verifies the edit remains.
Native GitHub egress remains dependent on the test environment; the focused
preparation test avoids external services.

## Open questions

None.

## Related decisions

[ADR-0054](0054-inception-development-profile.md),
[ADR-0085](0085-inception-public-ingress.md), and
[ADR-0072](0072-multi-disk-workload-transfer.md).
