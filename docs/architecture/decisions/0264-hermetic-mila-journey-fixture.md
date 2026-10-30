# ADR-0264: Hermetic Mila journey fixture

- ID: ADR-0264
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Mila, Marshall, Porsche, verification
- Supersedes: none
- Superseded by: none

## Context

The native parity matrix (`mila/native/PARITY_MATRIX.md`) gates Mila's native
platform builds. Rows close only when a platform journey drives the real Rust
core (ADR-0249) against a real deployment. Unit tests with scripted SSH servers
cannot show what Marshall and Porsche actually accept. Journeys against a live
deployment would need secrets, an external host and shared state. GitHub
runners give Linux KVM, but they cannot nest the L3 guests that the fleet
harness uses for real guest execution.

## Decision

1. A hermetic fixture runs the source-built backend on one NixOS machine:
   Marshall, PostgreSQL and Porsche, plus a bearer-protected browser
   approver. It needs no secrets and no external hosts. Marshall's public host
   is `localhost`. The trust document's management host, the descriptor's
   deployment host and the Porsche certificate principal are therefore one
   name. Ports are unprivileged: HTTPS 8443, Porsche SSH 2222, approver 8444.
2. The fixture seeds only disposable users, a synthetic image and a synthetic
   host. The host opens a real control session and reports headroom every
   second through `HostReports`. The journey invokes an explicit `observe` step
   after an accepted physical mutation. That step stands in for the absent
   provisioner: it completes the machine's open operations and records its
   desired state. Model question and plan tool calls are stood in through the
   Planning domain. Every Mila operation still enters through Porsche SSH and
   Marshall's production authority.
3. Device approval is real. The approver accepts
   `POST {"approval_url","fingerprint"}` with a bearer token. It signs the owner
   in with a Marshall magic link, opens the approval page in Chromium, checks
   the displayed fingerprint and submits the form. It never writes Marshall
   state directly.
4. The fixture publishes descriptor v1: deployment host and ports, inline CA
   PEM and TLS server name, approver URL and bearer, and seed machine and share
   principal. The descriptor is written owner-only.
5. `checks.x86_64-linux.mila-journey` is a CI machine test. It drives the
   headless `mila-journey` driver over the same C ABI the native shells use and
   asserts the effect of each step in Marshall's ledger.
   `nix run .#mila-journey-fixture` boots the same module as a KVM QEMU VM. It
   forwards the ports to `--bind` (default loopback) and prints the
   descriptor, so Android (`adb reverse`), Linux and local runs can reach it.
6. macOS and Windows runners cannot reach a Linux runner's fixture without a
   relay. The accepted route is a tunnelled fixture. Its implementation is
   deferred until a tunnel credential (for example an ephemeral tagged
   Tailscale key) is provisioned. No secret-free cross-runner route exists.

Authorization: the hermetic-fixture and tunnelled-fixture choices in the Mila
journey fixture request (2026-10-30).

## Alternatives

- **Live staging deployment.** Rejected: it needs secrets, shares state across
  runs, and fails for reasons unrelated to the client.
- **Scripted SSH servers only.** Rejected: they test the client against its own
  assumptions, not against Porsche and Marshall.
- **Fleet harness with real guests on every platform job.** Rejected for CI:
  it needs nested KVM, which hosted runners lack. It remains the evidence for
  guest execution and the PTY.

## Consequences

Platform agents can close parity rows with execution evidence that shows a real
backend accepting each command. The fixture proves admission, authorization,
idempotent receipts, ledger state and browser approval. It does not prove guest
execution, the terminal PTY data path, checkpoint restore, push delivery
(APNs, FCM or WNS), or physical-device biometrics. Those stay with the fleet
scenarios, device tests and release evidence. Synthetic operation completion
must never be cited as evidence that the provisioner works.

## Invariants and verification

- Every journey step reaches the deployment only through Porsche SSH and the
  HTTPS trust document. The fixture's direct ledger writes are limited to the
  documented synthetic-host and planning stand-ins (`mila-journey-fixture-authority`,
  `mila-fixture-synthetic-host-scope`).
- Approval happens through the authenticated browser page on the same live
  session (`mila-approver-real-browser`).
- The descriptor and the driver's state, including the device key, are
  owner-only. Tokens are never placed in argv or logs
  (`mila-fixture-descriptor-private`, `mila-journey-owner-only-state`).
- Each subtest in the machine test asserts the backend effect in PostgreSQL:
  key rows, operations, resize and wake requests, grants, endpoint revisions,
  turns, plan implementation, device state and key archival.

## Implementation evidence

- Fixture module: [`fixture.nix`](../../../nix/verification/tests/machines/mila-journey/fixture.nix).
  Seed and stand-in actions: [`fixture.exs`](../../../nix/verification/tests/machines/mila-journey/fixture.exs).
  Approver: [`approver.py`](../../../nix/verification/tests/machines/mila-journey/approver.py).
- Machine test: [`default.nix`](../../../nix/verification/tests/machines/mila-journey/default.nix)
  and [`driver.py`](../../../nix/verification/tests/machines/mila-journey/driver.py).
  It was run locally on 2026-10-30 and all 16 subtests passed:
  `nix build -L .#checks.x86_64-linux.mila-journey`.
- Launcher: [`launcher.nix`](../../../nix/verification/tests/machines/mila-journey/launcher.nix)
  (`apps.x86_64-linux.mila-journey-fixture`). It was booted locally with
  `--detach`. The host-side `mila-journey` then completed browser-approved
  enrollment, whoami, ls, ssh-key list and device list against the forwarded
  ports.
- Driver: [`mila-journey`](../../../mila/rust/mila-journey/src/main.rs), which
  uses the C ABI in [`session.rs`](../../../mila/rust/mila-ffi/src/session.rs).
  The core gaps the journey exposed were fixed in
  [`mila-session`](../../../mila/rust/mila-session/src/lib.rs),
  [`mila-protocol`](../../../mila/rust/mila-protocol/src/lib.rs) and
  [`ssh.rs`](../../../mila/rust/mila-transport/src/ssh.rs): v1 SSH key envelopes,
  `porsche-` request ids, `--no-wait` with `request show`, device
  register/ls/rm/prefs grammar, named `terminal attach` and closed refusal codes.

Remaining gaps:

- With no guest, `terminal new` returns Marshall's closed `terminal_unavailable`
  refusal. Attach, output, input, resize, reconnect and kill over the PTY are
  not exercised here.
- Pause records intent, but the synthetic host stores no checkpoint, so resume
  is asserted only as an admitted wake.
- The tunnel for macOS and Windows is not implemented.

## Open questions

- Which tunnel credential to provision for the macOS and Windows jobs.
- Whether a fleet-harness variant should drive `mila-journey` terminal steps
  against a real guest PTY (nested KVM, so not on hosted runners).

## Related decisions

[ADR-0249](0249-mila-rust-core-native-clients.md),
[ADR-0228](0228-strict-host-certificates-in-mila.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0235](0235-mila-desktop-clients.md).
