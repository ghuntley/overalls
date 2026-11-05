# ADR-0102: Local Underclass monitor socket

- ID: ADR-0102
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Underclass, NixOS services, host-local authorization
- Supersedes: ADR-0081
- Superseded by: none

## Context

ADR-0081 requires proxy and administration bearer tokens. Its host-local
Underclass service runs as a dynamic user with a private SQLite database and
private runtime credentials. The `utop` command installed on the host cannot
read that database or credential file as an ordinary operator. Upstream revision
`8c4cd02` offers a separate read-only Unix monitor socket for that case. The
user's September 23 request to update the pin and deploy authorizes adopting
this upstream access boundary.

## Decision

Carry forward ADR-0081's independent per-host pools, loopback-only network
listener, Tailscale Serve publication, distinct proxy/admin keys, secret custody,
service isolation, and incomplete backup acceptance. Keep every network proxy
and administration endpoint behind its existing bearer token. In addition,
allow any local host user to read only the bounded monitor snapshot through a
Unix socket at `/run/underclass/monitor.sock`, without a token. The service owns
a searchable runtime directory and creates the socket with mode `0666`.

The socket MUST expose only `GET /monitor`. It does not expose account controls,
full prompts, credentials or cache keys. The snapshot does expose account labels
and IDs, quotas, model names, usage totals, and recent outcomes to local users.
An explicit remote `utop --url` continues to require the admin token. The
service's runtime credential file and SQLite database remain private.

## Alternatives

Requiring each operator to obtain the admin token would retain one access
boundary but grant write-capable administration for a read-only task. Running
`utop` as root would broaden credential and database access. A group-restricted
socket would narrow readership but requires an additional host membership and
group-lifecycle design; upstream currently offers the simple local-user scope.

## Consequences

Every process with a local host user identity can read the monitor snapshot
while Underclass runs, including other local services. Host-user admission and
isolation become part of monitor confidentiality. The socket is not published by
Tailscale Serve or exposed to guests. Local operators can inspect the pool
without obtaining a credential that permits account administration.

## Invariants and verification

- The daemon listens on IPv4 loopback for HTTP and serves only `GET /monitor`
  on the Unix socket. The socket remains under `/run/underclass`, mode `0666`,
  with a searchable runtime directory.
- An unprivileged local user can read the snapshot without a token, but cannot
  reach network administration routes through that socket.
- Network `/admin/api/*` routes still reject missing and proxy-only tokens.
  Proxy routes still reject admin-only tokens.
- The monitor snapshot and ordinary diagnostics contain no credentials, prompt
  bodies or full cache keys. Live provider and tailnet behavior remain separate
  acceptance obligations.

## Implementation evidence

The [pinned source package](../../../nix/domains/artifacts/underclass/default.nix)
contains upstream's separate monitor router and socket binding. The
[NixOS module](../../../nix/domains/system/underclass.nix) supplies the runtime socket
path and directory while retaining the private environment file and loopback
command. The [configuration check](../../../nix/verification/tests/evaluation/underclass.nix)
checks the socket path, directory and address families; the
[service VM check](../../../nix/verification/tests/machines/underclass-service/default.nix)
exercises local unauthenticated monitoring and continued network token checks.
The [operations guide](../../services/underclass.md) distinguishes local and remote use.
Both physical hosts activated revision `882bc34f` and reported healthy. On
each host the running package was `8c4cd02`, the daemon was active, the socket
was mode `0666`, local monitoring succeeded, socket administration returned
404, and unauthenticated network monitoring returned 401. Fleet pin `9244c81`
also uses the later valid upstream quota reset deadline; its usage poll can
extend persisted cooling or readmit an explicitly allowed account. This changes
pool recovery timing within each independent host and does not widen its access
boundary.
Both hosts activated fleet revision `c63313e7` and ran package `9244c81` with
an active daemon, a responsive local monitor socket and a 401 response from the
unauthenticated network monitor route. A live Codex quota deadline was not
exercised.
Implementation remains partial for ADR-0081's provider, tailnet and encrypted-restore
obligations.

The fleet's [Rust readiness probe](../../../nix/domains/system/otel-guest/receiver/src/underclass_probe.rs)
now uses the existing tokenless `GET /monitor` boundary to publish one fixed
local readiness bit through a group-restricted collector socket. It never reads
the private database or proxy/admin credentials. A passing local monitor check
does not establish tailnet publication, bearer authorization or provider
completion; those ADR-0081 obligations remain open.

The pin at `8c1a38c` retains daily Codex refresh-token rotation with an additive
SQLite timestamp migration, bounded recovery from HTTP 403 as well as 401, and
administrator re-enablement of authentication-failed accounts while preserving
quota cooldowns. It retains the existing host-local state and access boundaries.
The [pin review](../reviews/2026-09-26-underclass-pin.md) records source inspection
and hash validation separately from unexecuted tests and provider acceptance.

The current pin also records bounded stream outcomes and long-range statistics
behind the existing administrator token. Those routes do not alter the local
monitor socket, proxy credential, service placement or independent-pool
ownership; prompts, credentials and cache keys remain excluded from stored
statistics. The [current pin review](../reviews/2026-10-15-underclass-pin.md)
records this source inspection separately from unexecuted tests.

The pin at `469aff4` corrects saturation handling inside the proxy: requests
reselect after the automatic reset attempt and skip the reset lock while a Codex
account is healthy. It changes no socket, credential, placement or pool-ownership
boundary. The [saturation pin review](../reviews/2026-10-16-underclass-pin.md)
records upstream test execution and the remaining regression-test gap.

The pin at `d0cb274` adds manual redemption of one banked Codex reset credit
through a new admin-token-gated route, page button and `underclass reset`
command that reuses `top`'s token resolution, plus a `gpt-6-sol` catalog entry
and body-based stream classification for usage accounting. The monitor socket
router and host-local access boundaries are unchanged. The
[pin review](../reviews/2026-10-14-underclass-pin.md) records source inspection,
hash validation and an offline package build separately from unexecuted tests.

## Open questions

Revisit a narrower local group if future host users or services should not see
account labels and usage. Choose and verify production tailnet ACL principals,
measure usage-ledger growth, and test encrypted isolated restoration.

## Related decisions

[ADR-0081](0081-independent-underclass-pools.md) records the original
independent-pool rationale and requirements carried forward here.
[ADR-0042](0042-host-observability.md) governs diagnostics.
[ADR-0075](0075-fleet-overlay-and-source-access.md) governs overlay admission.
[ADR-0185](0185-underclass-tailnet-exit-egress.md) adds opt-in upstream egress
through a dedicated userspace tailnet node and exit node, preserving these
boundaries.
