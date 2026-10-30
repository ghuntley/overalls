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
6. macOS and Windows runners reach a Linux runner's fixture over a Tailscale
   tailnet (the tunnelled fixture). The `journey-fixture-tailnet` job boots
   the launcher with `--bind` on its tailnet address and serves only the
   descriptor on port 8445. Before serving, it fails fast if its node lacks
   `tag:mila-ci` or its packet filter admits none of the fixture ports. It
   stays up until each Apple and Windows journey job has reported its result
   (`POST /finished/<node>/<outcome>`), left the tailnet, or never joined, or
   until a deadline passes. Only a reported `success` counts as finished. The
   journey jobs join as ephemeral `tag:mila-ci` nodes and resolve the fixture
   from `tailscale status --json`. They print a diagnostic every minute while
   waiting, download the descriptor and forward `127.0.0.1:8443/2222/8444`
   to the fixture. `deployment.host` therefore
   stays `localhost`, which the TLS SAN, trust management host and Porsche
   certificate principal all name. Every tailnet step is skipped when the
   `MILA_TAILSCALE_AUTHKEY` secret is absent.
7. The approver also exposes `POST /fixture/<action>` under the same bearer
   and TLS (`descriptor.approver.fixture_url`). It runs only the closed
   stand-in actions `observe`, `thread-create`, `thread-ready`,
   `thread-question` and `thread-proposal`, with canonical UUID inputs, so
   platform journeys outside the VM can use them. Other input is refused with
   a 4xx status.
8. `checks.x86_64-linux.mila-journey-terminal` runs the same driver on the
   fleet harness, which needs nested KVM. It enrolls a device key through
   the browser approval page, then drives `terminal new`, a named attach,
   output, input, resize, detach, reattach with replay and a server-side kill
   on a real guest PTY. It reaches Porsche at the deployment's public host.
9. The control fixture also has a guest-backed terminal mode, so terminal
   journeys run on every runner that can boot the fixture or reach it over
   the tailnet. It needs no nested KVM. The seed provisions a second machine,
   `seed.terminal_machine_id` (`seed.terminal_machine_name`), and observes it
   running. A terminal stand-in (`mila-fixture-terminal`) connects to
   Marshall's production provisioner stream (`HostStream`) with the synthetic
   host's credential and speaks terminal stream v2. It also serves terminald
   for that one machine: each session is a real PTY running a login shell as
   the unprivileged `mila-guest` user, with a byte ring for replay and
   Marshall's credit window. `terminal new`, named attach, input, output,
   resize, detach, reattach with replay and kill therefore cross Porsche SSH,
   Marshall's terminal authority, relay and ledger, and the Rust core
   unchanged. The guestless refusal stays available on any machine the
   fixture has not observed running: `terminal new` there returns Marshall's
   closed `terminal_unavailable`. The stand-in answers no other machine, and
   lifecycle actions on the terminal machine are outside its contract.

Authorization: the hermetic-fixture and tunnelled-fixture choices in the Mila
journey fixture request (2026-10-30); the Tailscale route was approved by the
user on 2026-10-30.

### Tailnet configuration

Create these in the Tailscale admin console:

- Tag owner and access policy (tailnet policy file):

  ```json
  {
    "tagOwners": { "tag:mila-ci": ["autogroup:admin"] },
    "grants": [
      { "src": ["tag:mila-ci"], "dst": ["tag:mila-ci"],
        "ip": ["tcp:8443", "tcp:2222", "tcp:8444", "tcp:8445"] }
    ]
  }
  ```

  Merge these into the existing policy. No other source or destination
  needs access to `tag:mila-ci`.
- An auth key that is **reusable**, **ephemeral** and **pre-approved**, with
  tag `tag:mila-ci` and the longest expiry policy allows. Rotate it before
  it expires. Store it as the repository secret `MILA_TAILSCALE_AUTHKEY`.
- MagicDNS is not required. Peers are found by their tailnet host names,
  `mila-{fixture,apple,windows}-<run id>-<attempt>`.

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
idempotent receipts, ledger state and browser approval. Its terminal mode
proves the client, Porsche and Marshall halves of the terminal path against a
real PTY. It does not prove guest execution, Lilly's terminal stream or the
in-guest terminald, vsock transport, checkpoint restore, push delivery
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
- The terminal stand-in only reaches Marshall through the host stream with the
  synthetic host's own credential, serves only the seeded terminal machine,
  and logs event names and counters, never terminal bytes or the token
  (`mila-terminal-host-stand-in`).

## Implementation evidence

- Fixture module: [`fixture.nix`](../../../nix/verification/tests/machines/mila-journey/fixture.nix).
  Seed and stand-in actions: [`fixture.exs`](../../../nix/verification/tests/machines/mila-journey/fixture.exs).
  Approver: [`approver.py`](../../../nix/verification/tests/machines/mila-journey/approver.py).
  Terminal stand-in: [`terminal_host.py`](../../../nix/verification/tests/machines/mila-journey/terminal_host.py).
- Machine test: [`default.nix`](../../../nix/verification/tests/machines/mila-journey/default.nix)
  and [`driver.py`](../../../nix/verification/tests/machines/mila-journey/driver.py).
  It was run locally on 2026-10-30 and all subtests passed, including the
  fixture hooks, Marshall's closed `vm_busy` refusal, the guest-backed
  terminal subtest (new, attach, echo, resize, replay, kill confirmed in the
  ledger and the PTY's processes gone) and the guestless `terminal_unavailable`
  refusal:
  `nix build -L .#checks.x86_64-linux.mila-journey`.
- Fleet terminal journey: [`mila-terminal.py`](../../../nix/verification/tests/machines/fleet/scenarios/mila-terminal.py)
  on the [fleet harness](../../../nix/verification/tests/machines/fleet/default.nix)
  (`milaTerminal`). It was run locally on 2026-10-30 with nested KVM and
  passed: browser-approved enrollment, then terminal new, attach, output,
  input, resize, reattach with replay and a kill confirmed in Marshall's
  ledger, on a real guest:
  `nix build -L .#checks.x86_64-linux.mila-journey-terminal`.
- Tailnet route: [`mila-builds.yml`](../../../.github/workflows/mila-builds.yml)
  (`journey-fixture-tailnet`, Apple and Windows tailnet steps) with
  [`mila-tailnet-fixture.sh`](../../../.github/scripts/mila-tailnet-fixture.sh),
  [`mila-tailnet-forward.py`](../../../.github/scripts/mila-tailnet-forward.py) and
  [`mila-tailnet-peers.py`](../../../.github/scripts/mila-tailnet-peers.py).
  The forwarder was smoke-tested locally; the route has not run in CI.
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

- The control fixture's terminal machine has no guest VM. Lilly's stream,
  terminald, vsock and guest boot are covered only by `mila-journey-terminal`
  on the nested-KVM fleet harness. The stand-in does not fence by placement
  epoch and sends no `fenced` close.
- Pause records intent, but the synthetic host stores no checkpoint, so resume
  is asserted only as an admitted wake.
- The tunnel for macOS and Windows has not run until the secret and policy
  above exist.

## Open questions

None. Recorded execution of the tunnel and the fleet terminal journey is tracked
under implementation evidence.

## Related decisions

[ADR-0249](0249-mila-rust-core-native-clients.md),
[ADR-0228](0228-strict-host-certificates-in-mila.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0235](0235-mila-desktop-clients.md).
