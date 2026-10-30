# Mila native Linux scaffold

This directory is a standalone GTK4/libadwaita presentation seam for Mila. It is intentionally
outside `mila/rust`'s workspace so a host can integrate generated Rust bindings after the native
surface has a stable shape. The GTK shell uses the shared Rust session adapter.

`dev.overalls.Mila.Linux` is a stable `GApplication` id and the application opts into
`HANDLES_OPEN`. GTK/GIO therefore forwards a second launch to the existing process. The desktop
entry registers `overalls://` as a URI scheme; incoming URIs arrive through `connect_open`, pass
through the bounded typed route parser, and select navigation text in the existing window.

`src/adapter.rs` defines the typed `RuntimeAdapter` seam. `InProcessRuntimeAdapter` routes
bootstrap and snapshot refresh through the shared Rust FFI validation contracts. Requests and
responses contain owned byte buffers behind typed operation values; no raw pointers or credentials
cross this seam. Unsupported input fails closed.

## Pages and library modules

The window is a `gtk::Stack` of Machines, Threads, Terminals, Deployments, Sign in and Settings
pages. GTK code (`src/main.rs`, `src/views.rs`) only builds widgets and forwards actions; the
decisions live in GTK-independent library modules that the headless journey driver also uses:

| Module | Responsibility |
| --- | --- |
| `deployments` | Bounded, owner-only deployment list (add, select, forget) with in-place migration of the single-host `deployment.json`. |
| `terminal_surface` | Terminal lifecycle over `AuthenticatedPty`/`HostPtyTransport`: attach, frame ticks, input, keys, resize, reconnect, kill and sign-out fencing. |
| `terminal_text` | Host-side PTY byte decoding to renderer-safe text and the closed key-to-bytes table. |
| `session::SessionPtyBackend` | `HostPtyBackend` over the authenticated FFI PTY, using the bounded-wait `mila_session_terminal_read_within`. |
| `ssh_keys_view` | SSH-key settings rows, states, this-device protection and at-most-once revocation. |
| `deep_link`, `route` | Navigation-only link presentation (page plus pre-filled identifiers), canonical share links and bounded `text/uri-list` intake for paste and drag-and-drop. |
| `signin_driver` | Live sign-in: `LiveConnector` (device key, HTTPS trust, SSH connect), approval browser launch once per generation, `whoami` polling, heartbeat, and bounded reconnect with a fresh generation. Blocking work runs on a worker thread; GTK polls results on the main loop. |
| `device_key` | Owner-only P-256 device key (`$XDG_DATA_HOME/mila/device-key`), created once; only the OpenSSH public line and `SHA256:` fingerprint leave it. |
| `connection_profile` | Optional owner-only `$XDG_CONFIG_HOME/mila/connections.json` overriding a deployment's SSH port (default 22), HTTPS port (default 443) and CA bundle. |
| `journey` | Headless live-journey driver behind `mila-linux-journey`; it signs in through the same `SignInDriver`. |

Every inbound link (desktop `open`, the link entry, or text dropped on the window) goes through
`ActivationBatch` and `deep_link::present`. "Copy link" buttons place only a `route::share_route`
canonical link on the clipboard; Linux has no system share sheet.

## Live journey

`mila-linux-journey --descriptor <path> [--workdir <new-private-dir>]` reads the hermetic
fixture descriptor (v1: `deployment.{host,ssh_port,https_port}`, `tls.{ca_pem,server_name}`,
`approver.{url,bearer_token}`, `seed.{machine_name,share_principal}`; unknown fields ignored),
fetches `https://<server_name>:<https_port>/bin/ssh-trust.json` with the fixture CA, signs in
with fresh owner-only device keys through the approver hook, and exercises the deployment list,
deep links, machine listing, share link, machine sharing, the terminal stream, and SSH-key
listing/protection/revocation. It prints a JSON report of step names and fixed outcome codes
only, and exits 0 only when every step passed. The approver token reaches curl through an
owner-only config file, never a process argument.

### GTK sign-in and the GTK journey

The Sign in button starts the window's `SignInDriver` for the selected deployment. The window
binds only the session the driver establishes, so every page uses the session the user signed
in with. A heartbeat checks the bound session's identity every 15 seconds off the main loop; a
loss releases the session and every projection derived from it, then reconnects with a fresh
generation (three attempts). A refusal ends the session without retrying.

Built with `--features gtk-journey`, `mila-native-linux --gtk-journey <descriptor> [--workdir
<new-dir>]` drives the real window against the fixture. It confines `XDG_CONFIG_HOME` and
`XDG_DATA_HOME` to a private work directory, writes the fixture CA and connection profile there,
and replaces the browser with the fixture approver. It then presses Sign in, Refresh machines, the
SSH-key Refresh, Attach terminal and Send. It severs the bound session to exercise loss detection
and reconnect, and finally presses Sign out. It prints the same redacted report shape. Release
builds leave the feature off.

## Build and test

From a machine with Rust, GTK4 development files, and libadwaita development files:

```sh
cargo test --manifest-path mila/native/linux/Cargo.toml --locked
cargo check --manifest-path mila/native/linux/Cargo.toml
```

The GTK widget-lifecycle test (`gtk_tests` in `src/main.rs`) needs a display. It skips without
one unless `MILA_GTK_TESTS_REQUIRED=1`; CI runs it against a headless Broadway server:

```sh
gtk4-broadwayd :5 &
GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 GSETTINGS_BACKEND=memory MILA_GTK_TESTS_REQUIRED=1 \
  cargo test --manifest-path mila/native/linux/Cargo.toml --locked
```

Install `data/dev.overalls.Mila.desktop` with the executable on the desktop search path to enable
system URI activation. Neither journey has a recorded passing run against the hermetic fixture yet;
CI runs them once the flake exposes `mila-journey-fixture`, and always runs a GTK journey wiring
smoke against an unreachable deployment.
