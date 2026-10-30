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

## Remaining gaps

- The GTK sign-in button still drives only the reducer. Without a live session
  the window's terminal and SSH-key pages show signed-out states, and the device
  fingerprint is not yet supplied to the SSH-key view.
- `mila-linux-journey` has no recorded passing run against the fixture. The
  live PTY behaviour of `terminal attach --json` (prompt, echo) is unverified.
- The ten new catalog messages were translated without native-speaker review.
  Five of them reuse reviewed translations of identical English verbs.
