# Mila Linux GTK parity: deployments, terminal stream, SSH keys, deep links (2026-10-30)

Scope: the GTK4/libadwaita client in `mila/native/linux` and one additive FFI
entry in `mila/rust`, for the parity-matrix gaps that do not need a live
backend: the deployment list, GTK terminal stream wiring, SSH-key settings
presentation, and deep-link target widgets and share integration. It also adds
the `mila-linux-journey` headless driver for the hermetic journey fixture.

## Changes

- **Deployment list.** `deployments::DeploymentList` holds at most 32 distinct
  canonical hosts and one selection that must be in the list. Forgetting the
  selected host leaves no selection rather than choosing another deployment.
  `DeploymentStore` writes an owner-only file atomically and migrates the
  single-host `deployment.json` in place. The GTK Deployments page renders rows
  with Open and confirmed Remove. A selection change drops all authority:
  session, sign-in generation, machine listing, terminal generation and SSH-key
  rows.
- **Terminal stream.** `TerminalSurface` owns `AuthenticatedPty` over
  `HostPtyTransport<SessionPtyBackend>`. The GTK text view copies only the
  bounded viewport text after a 33 ms main-loop tick, and the tick timer
  removes itself on end of stream, failure, kill or sign-out. PTY bytes are
  decoded in the host backend (`terminal_text::PtyTextDecoder`): escape
  sequences and unsupported controls are dropped, and the result is independent
  of where chunks split. Key presses map through a closed `TerminalKey` table.
  `PtyTransport::send_input` now carries the input bytes, where before it took
  only a length, so the transport can actually deliver input. `read_output`
  returns `PtyRead::{Text, Idle, Eof}`.
- **FFI.** `mila_session_terminal_read_within(handle, wait_ms ≤ 1000, …, event)`
  is additive. It reports the same `TerminalReadEvent` codes (data 0, idle 1,
  closed 2) as the existing `mila_session_terminal_read`, which the Windows
  adapter binds, and refuses an undersized buffer before it consumes any data.
  Both `mila_session_terminal_poll` and `mila_session_terminal_read` wait for
  up to the session timeout, which made them unusable on the GTK main loop.
  Apple, Android and Windows headers are unchanged.
- **SSH keys.** `SshKeysView` projects rows and their states, marks this
  device's key and refuses to revoke it, and reuses a pending request id per key
  until the outcome is known. A retry after an uncertain outcome therefore
  never becomes a second submission (ADR-0222 at-most-once).
- **Deep links and share.** `deep_link::present` maps a decision to a page plus
  pre-filled identifiers. Unknown deployments land on the deployment list with
  only the host filled in. Signed-out links land on sign-in with nothing filled
  in. `route::share_route` produces canonical outbound links for Copy link, and
  `route::share_inbound` bounds pasted or dropped `text/uri-list` text before it
  reaches the same `ActivationBatch`.
- **Fixes found while doing this work.** A thread-input `max_length(65536)`
  exceeded GtkEntry's range and aborted window construction. A Broadway smoke
  run exposed it. The approval-URL validator also rejected explicit ports such
  as the fixture's `https://localhost:8443`; it now compares the canonical
  authority, including the port.

## Architecture impact

These changes stay within ADR-0249: the Rust library decides and GTK binds. They
also stay within ADR-0220 (Porsche-only transport), ADR-0221 (links only
navigate) and ADR-0222 (mutations at most once). The FFI addition is backward
compatible. There is no change to the Marshall API, the Porsche wire format or
persistence outside Mila's local configuration file.

## Verification run

- `cargo test --manifest-path mila/rust/Cargo.toml --workspace`, including a
  real-TCP SSH PTY test of `read_within` and a Hegel FFI refusal property.
- `cargo test --manifest-path mila/native/linux/Cargo.toml --locked`. The GTK
  widget test ran on a local `gtk4-broadwayd` with
  `MILA_GTK_TESTS_REQUIRED=1`, and CI now does the same.
- `cargo fmt --check` for both workspaces, and the shared localization catalog
  checks.

## Follow-up: live GTK sign-in

- **Driver.** `signin_driver::SignInDriver` drives the existing `SignInFlow`
  reducer through the live sequence. It mirrors the Windows
  `MilaSignInCoordinator`: one job per generation and stale results dropped
  with their sessions. Approval links are checked against the target's HTTPS
  authority and opened once per generation. Refusal, expiry and protocol
  failures close the session. Reconnect is bounded and always starts a fresh
  generation. Jobs run on a worker thread in GTK and inline in tests, and GTK
  only applies results on the main loop. A new `SessionProbe` lets the
  heartbeat call `whoami` off the main loop without moving the session out of
  the window's binding.
- **Connector.** `LiveConnector` opens the owner-only device key, reconciles
  trust in Rust from an HTTPS fetch of the deployment's own origin, and
  connects. It uses `HttpsTrustFetcher`: no redirects, an explicit port and an
  optional CA from the connection profile.
- **Window.** The Sign in page renders the reducer's phase, the approval
  fingerprint and the account from the shared catalog. Its controls are Sign
  in, Open approval page, Reconnect and Sign out. The earlier state-only
  approval entries were removed. "Refresh machines" now reads the deployment's
  list; it previously re-read the cached FFI listing, so it never fetched.
- **GTK journey.** The `gtk-journey` feature drives the real window. The fixture
  approver stands in for the browser, the bound session is severed to test
  reconnect, and the report contains only step codes. CI always runs this
  journey against an unreachable deployment, which must fail as
  `host_untrusted`, and runs it against the fixture once the fixture exists.

Architecture impact: this stays within ADR-0249. Rust decides, the GTK
process holds the key custody and the I/O traits, and the connection profile
holds only ports and a CA path. Neither the FFI nor the protocol changed.

Verification: 127 library and 6 binary tests, including driver generation,
expiry, reconnect-bound and operation-sequence tests, device-key and profile
refusal tests, and a Broadway GTK test. In that test the Sign in button runs
the real connector to a typed `HostUntrusted` failure and creates an
owner-only key. A local Broadway run of `--gtk-journey` against an unreachable
descriptor reported `host_untrusted`.

## Follow-up: page controls, localization and loss detection

- **Pages.** The Machines page covers list, detail (`show`), the lifecycle with
  a confirmed delete, create and resize, sharing (`share show`, add, confirmed
  remove) and web (show, public/private at the loaded revision, open). The
  Threads page covers list, detail, events, prompt, answer and plan approve or
  revise. They live in `src/pages.rs`, and every visible string comes from the
  shared catalogs. Three new messages (`machineName`, `machinesFailed`,
  `signInRequired`) cover all 30 locales; the rest reuse existing keys.
  Decoders for Porsche's version-1 result envelope live in `porsche_results`.
  A refresh projects the FFI snapshot through `machine_view::project_snapshot`.
- **Loss detection.** `NativeState::with_live` runs every page action. A
  transport or stale-handle error calls `report_loss`, which releases the
  session and starts the next generation before the action returns; the
  terminal frame timer does the same. `RequestLedger` keeps a mutation's
  request id only while its outcome is unknown, so a retry after reconnect is
  idempotent.
- **Rust core.** `LiveSession::machine_show`, `share_show` and `request_show`
  are new. The terminal now opens the account's session with `terminal new`
  and attaches by name (`mila_session_terminal_attach_session`), because
  Porsche refuses an unnamed attach. `last_refusal` exposes the closed refusal
  code.
- **Fixes found against the real fixture.** `whoami` now accepts Porsche's
  `succeeded`/`result.email` and `approval_url` shape. A refresh was decoded
  as a raw `ls` envelope instead of the FFI snapshot. SSH keys were not
  unwrapped from the result envelope. `copy_output` probed the size and then
  read, which ran every executing FFI command twice and sent thread mutations
  twice. It now makes one call into a maximum-size buffer.
- **Journeys.** Both journeys run the same steps and poll the same
  `journey_checks`. The steps are sharing add/remove, web show/public/private,
  and create, stop, resize, start, pause, resume and delete of a
  `mila-journey-<hex>` machine. Then come threads list, prompt, answer and plan
  approval, the terminal, and (GTK only) loss on a page action. The fixture's
  provisioner and model stand-ins are requested from
  `<approver>/fixture/<action>`, or `approver.fixture_url`.

Architecture impact: this stays within ADR-0249. The FFI gains no new entry
points beyond the `show`/`share show` reads; the rest already existed upstream.
GTK still decides nothing: decoding, request ids, refusal codes and checks are
library code that the headless journey shares.

Verification: 136 library and 6 binary tests, with and without `gtk-journey`,
on Broadway. Both journeys ran locally against `nix run .#mila-journey-fixture`
(KVM). Sign-in, machines, sharing, web, create/stop/start/delete, the
`terminal_unavailable` refusal, SSH keys and revoke passed in both, plus
immediate loss detection and reconnect in the GTK journey. Resize
(`temporarily_unavailable`) and pause (`workload_not_stable`) are refused
until the fixture can observe the machine. Threads report `no_thread` until
the action hook exists.

## Remaining gaps

- Resize, pause and the thread steps need the fixture's host-reachable action
  hook (`observe`, `thread-create`, `thread-ready`, `thread-question`,
  `thread-proposal`). Without it they record `fixture_hook_unavailable`,
  `temporarily_unavailable`, `workload_not_stable` or `no_thread`. No CI run
  has passed yet.
- The fixture runs no guest, so the terminal step passes on Porsche's closed
  `terminal_unavailable` refusal. A live PTY echo is unverified.
- Resume against a running machine is admitted as a wake request, and the
  step passes on that receipt.
- The GTK journey replaces the browser with the fixture approver, so the
  `gio::AppInfo::launch_default_for_uri` call itself is not exercised.
- The new catalog messages were translated without native-speaker review.
