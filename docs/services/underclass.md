# Underclass fleet service

Panterloons and Dungarees retain independent
[Underclass](https://github.com/ghuntley/underclass) account databases. Dungarees
Ziggy sends inference to `https://panterloons.lorikeet-bangus.ts.net` using a
dedicated proxy-only encrypted credential bundle
([ADR-0280](../architecture/decisions/0280-remote-underclass-and-safe-agent-retries.md)).
Provider accounts, SQLite state, sticky bindings and administrative credentials
are not replicated. Onboard provider accounts on Panterloons for this route.
Future hosts opt in by declaring a host-specific `NAME-underclass` encrypted
document; generic enrollment and base/recovery configurations remain independent.

## Access

Underclass listens only on `127.0.0.1:8080`. `underclass-tailscale-serve.service`
publishes that origin as HTTPS on the host's MagicDNS name. Tailscale Serve must
be enabled for the tailnet, both hosts must be enrolled, and tailnet ACLs must
grant the intended operators and clients access. Funnel is not used. Serve stays
in the foreground under systemd supervision, so publication-process failure
changes unit health and triggers a restart instead of leaving a stale active unit.

Tailnet identity is a network admission control, not application authorization.
Clients still send the host-specific `UNDERCLASS_PROXY_KEY` to `/v1/*`; the web
UI and `/admin/api/*` require that host's `UNDERCLASS_UI_TOKEN`.

The local encrypted documents are `panterloons-underclass` and
`dungarees-underclass`; `dungarees-underclass-proxy` holds only the Panterloons
proxy key. Rotate the source key and its proxy-only copy together. Recover a
document to a private file outside the checkout
with the ordinary `tools/buck2 run //:secrets -- decrypt ...` workflow in
[fleet-users.md](../operations/fleet-users.md). Never put either value in a command argument,
Nix expression, issue, or diagnostic output.

## Onboarding

1. Open the selected host's Tailscale Serve HTTPS URL.
2. Enter that host's admin token.
3. Add Codex and/or Copilot accounts through the device flow.
4. Repeat on the other host if both independent pools need that account.
5. Configure clients with that host's HTTPS `/v1` URL and proxy key.

The account database is `/var/lib/underclass/pool.db`, mode `0700` under a
systemd dynamic user. It contains plaintext OAuth credentials. Underclass source
is pinned to an immutable revision, and that revision does not emit proxy/admin
tokens during startup.
Durable sticky bindings use the same 24-hour expiry and 10,000-entry cap as the
in-memory pool; pruning runs transactionally at startup, periodically and after
binding persistence.

The pinned upstream revision enables automatic Codex banked-reset redemption by
default. When a live request finds every enabled Codex account unavailable, it
may spend one available reset credit and verify recovery before serving through
that account. The pending attempt is kept in the host-local database for retry
with the same idempotency key. A host configuration can disable redemption with
`systemd.services.underclass.environment.UNDERCLASS_AUTO_CODEX_RESETS = "false";`.

Codex quota errors now prefer the later valid deadline from the upstream error
and `Retry-After`. A verified exhausted-window usage poll can extend a cooling
deadline, while an explicit allowed result readmits the account. When no usable
deadline is available, the configured cooldown remains the fallback.

## Operations and failure behavior

New request and account identifiers use UUIDv7. Underclass preserves one valid
UUIDv7 `x-request-id`, replacing other versions and malformed/duplicate headers.
Search a model-call ID across Marshall, Ziggy and Underclass to trace admission,
provider start and terminal outcome; internal account attempts share that ID.
Local monitor readiness describes the local pool, so Dungarees's empty local
pool does not describe the health of its remote Ziggy provider route.

Marshall retries only Ziggy's positively verified pre-output overload result:
at most three fresh model calls, delayed one then two seconds. Failed attempts
remain in history. Empty pools, quota exhaustion and ambiguous/lost results are
terminal. The proxy-owned retry-safety header certifies only an overload-only
attempt chain; generic HTTP503 is not a retry instruction.

Revision `8c1a38c` retains the existing refresh-token rotation and rotates stored
Codex refresh tokens after 24 hours,
checking at startup and every 15 minutes. Rotation preserves account health and
quota cooldowns, including on failure; failed attempts retry on a later tick.
Copilot tokens are excluded. Opening an older database adds
`accounts.token_refreshed_at` with a zero default, making existing Codex tokens
due on the first pass. Successful refreshes persist the new token and timestamp
together; an older backup can contain an invalidated refresh token.

Upstream HTTP 401 or 403 triggers one forced refresh and same-account retry per
request before authentication failure and failover. An administrator can use
**Enable** to readmit an `auth_error` account or **Re-login** to replace its
credentials. Enable preserves an account's existing quota cooldown.
These changes have source review only in this pin update; tests were skipped
at the user's request, and live provider recovery remains unverified.

Revision `d0cb274` added manual redemption of one banked Codex reset
credit. Use **Use reset** on a Codex account row in the admin page, or run
`underclass reset <label-or-id>` on the host; both call
`POST /admin/api/accounts/{id}/reset` behind the admin token. The command
resolves the admin token like `utop`; with `--url` it requires
`UNDERCLASS_UI_TOKEN` and never sends a database token to a remote host.
Without `--force` the proxy refuses with HTTP 409 when upstream reports the
account is not rate limited or when a reset already redeemed for this outage has
not restored usage; a missing credit or a non-Codex account is never
overridable. Redemption reuses the automatic path's idempotency key and readmits
the account only after upstream confirms. The default catalog adds `gpt-6-sol`,
and usage accounting treats `"stream": true` requests as streaming. These
changes have source review and an offline package build only; tests were not
run for this pin update.

Revision `8c1a38c` records stream outcomes and sanitized upstream error codes for
completed proxy bodies. It exposes long-range request, token, session,
concurrency, outcome, capacity and policy statistics through
`GET /admin/api/stats` and `underclass stats`. The endpoint and event-import
route remain behind the administrator token. Statistics retain raw rows and
daily rollups for 730 days by default; minute and hour queries have bounded
windows, and old rows are pruned by the service. Prompts, cache keys,
credentials and upstream error text are not retained. This pin has source
review and an offline package build only; tests were not run.

Revision `dbaf7b8` retries upstream capacity failures on another account
(upstream ADR 0022). Upstream answers 200, then fails the stream with
`server_is_overloaded` before any output; Codex shows "Selected model is at
capacity". The proxy now holds a streamed response, for at most 60 seconds or
1 MiB, until its first output or terminal event. An overload before any output
is recorded, that account is skipped for the rest of the request without a
health change, and the sticky session moves to the account that serves the
request. If every account overloads, the client receives the original upstream
bytes. Errors after output still pass through. A stream `error` event's nested
code is now recorded, so these failures count as `overloaded` instead of
`upstream_failed`. Response headers now reach clients at the first output
rather than the first upstream byte. A request that retries elsewhere still
produces exactly one SLO outcome. This pin has an offline package build, and
the upstream tests passed on the patched source; live provider behavior is
unverified.

Revision `469aff4` keeps the fail-fast 429 but always selects an account again
after the automatic reset attempt. That attempt can wait behind another
request's usage check, and short upstream throttles (seconds to a minute) can
expire meanwhile; the previous revision then returned a 429 whose deadline had
already passed. Requests skip the reset lock entirely while any Codex account is
healthy. The `request.saturated` journal event now carries the relative
`retry_after_ms` wait plus the absolute `until_ms` deadline; it previously put the
epoch deadline in `retry_after_ms`. The client `Retry-After` header was already
relative and is unchanged. Upstream Rust unit, property and end-to-end tests
passed for this revision, and the Underclass NixOS package, configuration,
service and SLO checks passed on the pin. The race itself has no dedicated
regression test.

Use `systemctl status underclass underclass-tailscale-serve` and
`tailscale serve status` for bounded status checks. Restarting Underclass retains
the local database. Failure of either service is reported by fleet monitoring and
deployment health, but does not stop Marshall, Lilly, guests, or the other host's
pool.

When fleet OpenTelemetry is enabled, `underclass-monitor-probe.service` checks
the read-only local monitor socket every 15 seconds. Its fixed readiness gauge
feeds a private Grafana candidate for both hosts. A failed monitor check is zero;
missing probe or collector samples make the candidate unknown. This probes the
local SQLite and monitor path only. It does not exercise Tailscale, proxy bearer
authorization or a live provider request.

Proxy request accounting is a private SQLite journal,
`/var/lib/underclass/slo-totals.sqlite`, holding one aggregate totals record and
pending admission identities only. Its single duration histogram has fifteen
finite bounds from 10 ms to 24 hours. Restart turns each pending admission into
one failure with unknown duration; no provider request is replayed. A separate
exporter user reads only the group-readable `/run/underclass/slo/slo.json`
snapshot. The retired seven-bound `slo.sqlite` is never read; an operator removes
it in a recorded maintenance window.

The enabled host also has `underclass` and `utop` on its PATH. Local `utop`
reads a limited monitor snapshot through `/run/underclass/monitor.sock` without
an admin token. Any local host user can read account labels, IDs, quotas, model
names and usage through that socket; it exposes no account controls, credentials,
full prompts or cache keys. `utop --url` selects another host's tailnet HTTPS
endpoint and still requires that host's `UNDERCLASS_UI_TOKEN`. The service's
private environment file and database are not exposed to interactive users.

There is no automatic cross-host failover. A client may be configured manually
for the other host, but its account set, quota health and sticky sessions differ.

Production host backups remain disabled. The backup inventory includes
`/var/lib/underclass` for future activation, but until encrypted backups and an
isolated restore are verified, loss of a host database requires provider
re-onboarding and can invalidate rotated refresh tokens. No recovery or
availability claim is made for this state.

## Upstream egress node

[ADR-0185](../architecture/decisions/0185-underclass-tailnet-exit-egress.md)
routes Underclass provider traffic, and nothing else, through a dedicated
tailnet egress node, optionally via an exit node.
[ADR-0260](../architecture/decisions/0260-underclass-egress-without-exit-node.md)
removed the `mac-mini` exit node after it went offline on 2026-10-28. The
enrolled profile sets `egress = { enable = true; route = true; }`, so traffic
keeps the proxy and loopback confinement but leaves from the host's own address.
Each host runs `underclass-egress.service`. This is a
separate, unprivileged, userspace `tailscaled` with its own state and socket.
It has no TUN device and installs no routes. Its HTTP proxy listens only on
`127.0.0.1:1055`. The host's own `tailscaled`, Tailscale Serve and every other
service keep their direct paths.

Rollout has two stages, because Underclass is an update health unit:

1. With `egress.enable` alone, the node runs logged out and Underclass is
   unchanged. Join it once on each host:
   `sudo underclass-egress up --hostname=$(hostname)-underclass-egress`.
   Joining always advertises `tag:underclass` (`services.underclass.egress.tags`,
   ADR-0245), so tailnet policy must let you own that tag. Approve the node in
   the admin console if your tailnet requires that, and make sure tailnet policy
   lets `tag:underclass` use exit nodes. A node joined before the tag existed
   keeps user ownership until you rejoin it with
   `sudo underclass-egress up --force-reauth`. Then
   `sudo underclass-egress set --exit-node=mac-mini` followed by
   `curl -x http://127.0.0.1:1055 https://ipinfo.io/country` should print `AU`.
2. Setting `services.underclass.egress.route = true` (implied by setting
   `exitNode`) gives Underclass `HTTPS_PROXY`, confines its unit to loopback
   with systemd IP filtering, and adds a privileged start gate. Without an exit
   node, the gate clears any stored exit-node preference. With one, it
   re-selects that exit node with LAN access disabled. Either way it refuses to
   start while the node is logged out.

The enrolled profile sets both stages with no exit node. Ship it only after each
host's egress node has been joined. Otherwise Underclass refuses to start, and
the updater rolls the deployment back.

Failure behaviour with an exit node configured: if the exit node, its
connection or the tailnet path is down, provider requests fail. They never fall back to the host's own address,
and Underclass keeps running and recovers by itself when the exit node
returns. Provider DNS is resolved at the exit node. "Allow LAN access" on the
Mac only matters for the Mac's own use of other exit nodes; it does not affect
the traffic it carries.

Diagnose with `systemctl status underclass-egress underclass`,
`sudo underclass-egress status`, and `journalctl -u underclass` for gate
refusals ("cannot select exit node"). Root clearing the exit node through
`underclass-egress set --exit-node=` makes proxied traffic leave directly until
the next Underclass start re-asserts it. Do not do that on a live host.

To stop using an exit node, remove `exitNode` and keep `route = true`; the next
Underclass start clears the stored preference. Setting `route = false` as well
returns Underclass to direct egress without the proxy, and the egress node can
stay logged in.

## Live acceptance

Before relying on either endpoint, verify on both physical hosts:

1. the node is joined to the intended tailnet;
2. MagicDNS and tailnet HTTPS certificates are enabled;
3. no conflicting Tailscale Serve root exists;
4. the HTTPS URL is unreachable outside the tailnet;
5. missing/wrong Underclass bearer tokens are rejected;
6. each host sees only its own onboarded account set;
7. after stage 2, a proxied request from each host shows the Mac Mini's
   Australian address and the host's own address otherwise.

Local NixOS tests use synthetic keys and no public provider accounts. They do not
establish live tailnet policy, provider acceptance, subscription terms, fleet
throughput or host-failure recovery.
