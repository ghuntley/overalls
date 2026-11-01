# ADR-0082: Guest terminal multiplexer

- ID: ADR-0082
- Date: 2026-09-19
- Status: accepted
- Implementation: partial
- Components: guest images, terminald, Lilly VM actors, Lilly terminal stream
- Supersedes: ADR-0020
- Superseded by: none

## Context

ADR-0011 and ADR-0020 put the only terminal on the Firecracker serial console
through dtach: one fixed 80x24 stream, one writer, output retained in bounded
windows, and every byte relayed through host fences and encrypted PostgreSQL
mailboxes. The plan now requires many simultaneous terminals per VM (target
fifty), full escape-sequence fidelity, tmux-style persistence and per-terminal
PTYs. Firecracker provides no virtio-console; its supported I/O surfaces are
the serial console, virtio-net and virtio-vsock. vsock is already configured on
every jail (`guest_cid 3`, host UDS `/v.sock`) and the readiness service proves
in-guest vsock listening with host-CID checks.

## Decision

Ship a static Rust `terminald` in both guest images, started by systemd after
`lilly-readiness` whenever the boot identity parameters are present. It listens
on AF_VSOCK port 1075 and accepts connections only from peer CID 2. A
length-prefixed binary control protocol carries hello, create, list, kill,
resize and attach; every data attachment is a raw byte stream on its own
connection. The hello proof is HMAC-SHA256 over a fresh nonce, placement and
execution epoch under a key derived from the per-boot `lilly.boot_challenge`,
so only the host that launched the current boot can drive the daemon.

Each terminal is a fork/exec login shell on a fresh PTY with resolved passwd
identity (uid, gid, supplementary groups applied before exec; TERM from the
creating client, `COLORTERM=truecolor`, UTF-8 locale, home directory). Sessions
persist until killed, child exit, daemon stop or the idle deadline; viewer
disconnects never terminate them. Scrollback is a raw-byte ring per session
(default 1 MiB, growing to 8 MiB within a 64 MiB VM-wide budget) with absolute
cursors, so reattach replays bytes without reinterpreting them and reports any
truncated prefix explicitly. Backpressure pauses the PTY pump behind a viewer
high-water mark instead of dropping bytes. Sessions are capped at 64 per VM.

Lilly's VM actor authorizes terminal dials: only the assigned terminal stream
process, the current durable running placement/epoch/generation, and the
persisted current boot challenge yield the jailed vsock path. The Firecracker
unit appends stdio to a bounded per-VM boot log instead of owning a dtach
console, both guests stop autologining root on ttyS0, and terminal bytes never
enter logs or journals.

## Alternatives

virtio-net with an SSH or TCP server in the guest would require host-to-guest
ingress through the TAP isolation boundary and a guest network service. A
tmux/abduco server in the guest would carry another master process and a less
auditable protocol. Keeping the serial console cannot provide multiple PTYs or
resize. Firecracker has no virtio-console device.

## Consequences

Terminal capacity and fidelity become guest-local and independent of the
control plane's write throughput. Session lifetime is bounded by guest uptime:
a reboot or daemon restart ends sessions, which the workspace surfaces. The
daemon is a new security-sensitive surface, confined to vsock-from-host with
boot-bound HMAC authority, hardened service limits and no terminal bytes in
diagnostics. Scrollback memory is bounded but comes out of the guest's RAM.

## Invariants and verification

- Only vsock peer CID 2 with a valid boot-bound hello proof reaches any
  operation; attach requires the per-session random token.
- Passwd identities are fully applied before exec; no session runs with the
  daemon's credentials by accident.
- Raw replay, input order and viewer fan-out preserve arbitrary binary bytes;
  pause-not-drop backpressure bounds memory without loss.
- Kill, child exit and idle deadlines are the only session endings besides VM
  stop; reattach replays retained bytes and reports truncation.
- Rust unit and property tests (crypto vectors, framing bounds, ring model,
  PTY execution, vsock loopback) run in the nix check derivation, and the
  guest images build offline with the daemon installed.

## Implementation evidence

The [daemon](../../../nix/domains/artifacts/terminald/src/session.rs),
[frame codec](../../../nix/domains/artifacts/terminald/src/frame.rs),
[ring](../../../nix/domains/artifacts/terminald/src/ring.rs),
[PTY execution](../../../nix/domains/artifacts/terminald/src/pty.rs) and
[vsock listener](../../../nix/domains/artifacts/terminald/src/vsock.rs) implement the
multiplexer with tests run by the Buck2
[native check gate](../../../nix/BUCK) (`//nix:lilly-terminald-bin-unittest`,
`-clippy` and `-rustfmt`; correction 2026-11-01: the Nix
`terminald-checks.nix` gate was replaced by these targets). Since 2026-11-01
the unsafe FFI, including the post-fork child sequence in
[`sys/pty.rs`](../../../nix/domains/artifacts/terminald/src/sys/pty.rs), lives in
the `sys` shims under a crate-level `deny(unsafe_code)` (ADR-0265), and
`-clippy-freebsd` and `-clippy-illumos` lint the native guests' `cfg` code. Both guest
images install the daemon and unit
([NixOS](../../../nix/domains/artifacts/guest/terminald.nix),
[Ubuntu](../../../nix/domains/artifacts/guest/ubuntu/units/lilly-terminals.service)).
The daemon logger exposes only a closed typed event enum: event names, levels,
messages and keys cannot be supplied by call sites, numeric values remain JSON
numbers, and session events include placement/execution correlation without
terminal bytes or command data.
Lilly binds dials to the current running boot through
[terminal options](../../../lilly/lib/lilly/vm/executor.ex) and the
[VM actor](../../../lilly/lib/lilly/vm/actor.ex). Boot log capture replaced
dtach in the [unit](../../../lilly/lib/lilly/vm/unit.ex); the packaged
[byte-oriented writer](../../../lilly/native/boot-log/src/lib.rs) drains Firecracker output
while bounding each boot's persisted log to 1 MiB.

The authenticated control connection also supports recovering a live session's
attachment token after a Lilly process restart. Tokens remain host-local memory;
they are neither listed to Marshall nor persisted. Attachment admission is
bounded to eight viewers per session and 128 per daemon, and scrollback growth
uses atomic budget reservations. See the
[integration follow-up](../reviews/2026-09-20-terminal-integration-follow-up.md)
for verification and remaining delivery/lifecycle gaps; native tests alone do
not establish completion of the full browser-to-guest path.

The recovery implementation adds boot-authenticated
create-once, creation-status and cancellation controls. Request receipts bind
the original user/TERM/geometry in guest memory, retain cancellation tombstones,
and are bounded to 4096 entries with at least 24-hour or live-PTY retention.
Session IDs now use independent random entropy instead of restarting a counter
on daemon restart; IDs reveal no attachment-token bits. These additions have
subsequently been validated to the component and native scope recorded below.

The bounded guest-control payload ceiling is now 8192 bytes, accommodating all
64 listing entries with maximum-length usernames. Lilly validates listing
metadata, closes unsuccessful negotiation sockets and keys manager reuse to the
current boot challenge as well as placement/epoch. An unsupported recovery query
is reported distinctly from an unknown creation request, allowing Marshall to
withhold new creation until the guest service supports recovery. Native
older-guest/downgrade acceptance remains separate from the current-image fleet
result below.

Native fleet testing exposed service restrictions inherited by every login
shell: the address-family filter prevented IPv4 sockets, while protected kernel
and device mounts curtailed guest-root operations. Both guest units now preserve
the selected guest user's ordinary capabilities, retaining process/memory limits
and restart policy. The VM and host network rules remain the isolation boundary;
terminald still listens only on vsock and requires host CID and boot-bound HMAC.
The corrected full-fleet run passed profile egress, cross-guest denial, spoofing
checks and those checks again after a Lilly upgrade. The complete fleet check
subsequently passed in 1089.57 seconds. A queue/drain lock inversion found during investigation was
also corrected; Rust's 35 tests and Clippy pass.

The [generated byte histories](../../../nix/domains/artifacts/terminald/src/property_tests.rs)
add independent append/resize/cursor retention, configured 1 MiB/8 MiB boundaries,
fixed shrink/grow/append, concatenated frame chunking and invalid-header refusals.
The final sandboxed native gate passed Clippy and all 43 tests, including five
properties; see the [byte-history review](../reviews/2026-10-03-terminald-byte-histories.md)
for recorded execution and pure-proof boundaries. These checks do not establish
vsock authentication, PTY backpressure or shared memory admission.

The [credit-retirement review](../reviews/2026-10-03-terminald-credit-retirement.md)
records native withheld-credit and quiet-slave cancellation findings. Explicit
kill aborts registered viewers and owned process-group execution; the pump uses
bounded readiness waits so cancellation does not depend on slave EOF. Generated
local PTY/socket histories verify returned ring and viewer permits while the peer
is still connected. Natural EOF retains queued-output draining. Authenticated
vsock/Firecracker composition, aggregate admission and escaped descendant cleanup
remain separate; implementation stays partial.

The [shared-ring admission review](../reviews/2026-10-03-terminald-shared-ring-budget.md)
records generated actual PTY admission and retirement at64MiB with independent
inventories and competing final reservations. The native47-test/Clippy gate
passed. This adds local aggregate admission evidence; simultaneous growth,
authenticated guest/browser composition and hosted faults remain open.

The [neighbor-pressure review](../reviews/2026-10-03-terminald-neighbor-pressure.md)
adds real Linux PTY/socket pressure with successive echo-independent executed
output in a distinct session and preserved identity/permits through owned kill.
The final native47-test/Clippy gate passed4.66seconds with zero/configured/read
boundary witnesses; integrated checks remain pending. Guest authentication, complete byte fidelity
and hosted reach remain separate requirements.

## Open questions

The [actual growth review](../reviews/2026-10-05-terminald-growth-backing.md)
records real Linux PTY two-phase output reaching full 64 MiB reservations with
independent actual backing and retained-byte snapshots. All 51 native tests and
Clippy passed; the original append mutation produced 128 MiB backing against
64 MiB reserved. Refusal, exact retirement and grown replacement are covered
locally. Simultaneous mixed stalls/growth/admission, authenticated guest and
hosted fault evidence remain separate; implementation remains partial.

The [mixed growth review](../reviews/2026-10-05-terminald-mixed-growth.md)
records stalled real viewers while healthy PTY growth races creates, including
the default64MiB reservation and1MiB watermark. Independent allowed outcomes,
backing, survivors and replacement accounting passed in52native tests and
Clippy. Full Marshall1451-check and zero-error forced-Dialyzer gates passed. Local native races do not establish authenticated guest/browser or
hosted faults; implementation remains partial.

Sustained throughput and sixel-heavy workloads under many viewers need
measurement on real hardware. Unprivileged guest users require a guest user
provisioning story.

## Related decisions

[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0083](0083-terminal-host-stream-and-registry.md),
[ADR-0015](0015-jailed-execution-and-host-networking.md),
[ADR-0016](0016-executable-generations-and-lifecycle.md),
[ADR-0093](0093-audi-mediated-guest-ssh.md).

ADR-0093 adds Audi-mediated guest SSH as an independent access path. It does not
carry terminal-v2 bytes, reuse its leases or weaken its boot-bound vsock gate.

The [retired-ring review](../reviews/2026-10-05-terminald-retired-ring.md) records a native allocation counterexample and repair: natural EOF drops retired scrollback backing before returning quota while independent queued output drains. Generated1/8MiB histories and the static factory passed; aggregate dynamic growth and authenticated VM composition remain separate.

The [overwrite allocation review](../reviews/2026-10-05-terminald-ring-overwrite.md) records backing growth after append-before-truncate and the pre-append eviction repair. A generated fresh fixed-ring model passed configured1/8MiB and chunk boundaries. Resize/growth and aggregate native backing acceptance remain separate.
