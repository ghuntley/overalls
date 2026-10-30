# ADR-0097: Enrico Git mirrors

- ID: ADR-0097
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Enrico, Marshall, Overalls, NixOS
- Supersedes: none
- Superseded by: none

## Context

Marshall needs a read-only, cgit-like view of GitHub repositories under
`github/<owner>/<repo>`. The user authorized a 100 GiB cache on Overalls,
administrator registration, signed-in reads, hourly and manual refresh,
structured logging, an audit trail and NixOS machine tests. Public GitHub
repositories are the only accepted source. Marshall already owns account
authorization and PostgreSQL/Oban; Overalls already runs a private fleet
network, SecretSpec, Nix-built services and the automatic updater.

## Decision

Marshall owns the registered repository catalog, administrator authority,
refresh intent, outcome and audit records in PostgreSQL. Its authenticated
browser routes show repository trees, files, history, refs, diffs, blame and
search. Raw single-file downloads require the stored browser login. The
catalog accepts only GitHub owner/repository labels. New registration and
manual refresh require current administrator authority and recent passkey
elevation. The Oban reconciler schedules refreshes hourly; AshStateMachine
records the durable pending, refreshing, ready and failed phases.

Enrico is an independent OTP release on Overalls. Its dedicated TLS listener
binds only the private fleet address, and every request needs a separate
service token. It constructs `https://github.com/<owner>/<repo>.git` from
validated labels, stores bare mirrors in a service-owned ZFS dataset capped at
100 GiB, and serves bounded, read-only Git operations. A failed fetch preserves
the last published refs. Its local Unix readiness endpoint joins the updater's
activation check. Enrico has no account or browser authority: Marshall checks
current registration and login before proxying a read. Enrico logs through a
closed structured event catalog; Marshall records append-only actor and
attempt outcomes. Marshall verifies the Enrico service hostname against a
dedicated private CA and records bounded failure reasons in the audit trail.
The CA and leaf certificate rotate together through SecretSpec; the CA private
key is not retained after issuance. Marshall retries transient attempt-status
failures and resumes an existing Enrico attempt after an interrupted worker.
Manual refresh declines while a repository is already refreshing, and Oban
uniqueness spans the full job limit so a long clone has one Marshall owner.
The production service has an 8 GiB memory limit and bounds Git pack work to
two threads.

This decision is authorized by the user-requested implementation plan.

## Alternatives

Cloning inside Marshall would couple browser release lifecycle, network Git
fetches and local disk cache to the control plane. An external cgit instance
would duplicate login and administrator authority. Storing Git objects in
PostgreSQL would make large repository histories compete with control-plane
transactions. Webhooks alone would miss updates and would require externally
reachable inbound GitHub integration.

## Consequences

Overalls gains a bounded persistent dataset, independent release and private
credential. A public repository may remain stale during an upstream outage;
the previous published mirror remains available. The database keeps metadata
and audit events but not Git objects. The private token and certificate need
rotation through the existing SOPS deployment path. Cache exhaustion must be
reported as a failed refresh without invalidating published content.

## Invariants and verification

- Only a current administrator with recent passkey elevation can mutate the
  catalog; signed-in readers cannot ask Enrico to fetch a new source.
- Neither user input nor Git output may select an arbitrary remote, filesystem
  path, command or protocol. Requests and returned bodies remain bounded.
- A failed or interrupted refresh keeps the last usable Git refs and head.
- The production service binds `10.90.0.1:5445`, reachable through `fleet0`
  only, and its ZFS dataset has a 100 GiB reference quota.
- Enrico's readiness response and systemd unit both gate updater promotion;
  a service-only crash must not advance `lastHealthy`.
- NixOS machine tests must exercise the packaged release with an isolated
  HTTPS Git fixture, authenticated API, refresh, browsing and source outage.

## Implementation evidence

The [Enrico Git runner](../../../enrico/lib/enrico/git.ex) constructs the
GitHub URL and bounds operations. The [Marshall resource](../../../marshall/lib/marshall/enrico/repository.ex)
and [worker](../../../marshall/lib/marshall/enrico/worker.ex) define state and
refresh reconciliation; the [audit resource](../../../marshall/lib/marshall/enrico/audit_event.ex)
records actions and outcomes. The [service module](../../../nix/domains/system/enrico.nix)
and [Overalls declaration](../../../fleet/roles/control-plane/services.nix) define
runtime custody, storage and private listener. The
[machine fixture](../../../nix/verification/tests/machines/enrico-service/default.nix)
exercises a packaged service. The machine, Marshall precommit and fleet build
checks pass. A live Overalls activation recorded revision `3a5ae1a1` healthy;
the mounted `zroot/enrico` dataset has `refquota=100G`, and the Enrico listener
bound `10.90.0.1:5445` rejected an unauthenticated HTTPS request. Implementation
remains partial pending an observed cross-host tunnel request and large-repository
capacity behavior.
The mirror manager also records unique admitted terminal refresh outcomes and
fixed duration buckets for a candidate SLI. Its private Unix health socket
serves a fixed numeric snapshot to a Rust host exporter. The isolated
[service machine test](../../../nix/verification/tests/machines/enrico-service/default.nix)
passed source-to-collector delivery, duplicate-attempt stability and source
outage failure accounting. This evidence does not set an SLO target or prove
live collection.
Internal refs now retain observed default heads across upstream force-pushes;
the browser uses Marshall's durable head SHA until a new refresh commits.
The [client](../../../marshall/lib/marshall/enrico/client.ex) verifies the
private CA and translates transport failures to bounded reasons. The
[failure-reason migration](../../../marshall/priv/repo/migrations/20260923060150_add_enrico_failure_reason.exs)
adds nullable reasons to append-only audit records, and the Git runner permits
a 60-minute initial mirror fetch while Marshall waits up to 65 minutes.
The [Enrico NixOS module](../../../nix/domains/system/enrico.nix) defaults to
an 8 GiB service memory limit after a live Nixpkgs `index-pack` exceeded the
initial 2 GiB limit. The worker resumes in-flight attempts after transient
status failures, and records an abandoned attempt before replacing it.
The first live Nixpkgs mirror completed on Overalls at 06:56 UTC on
2026-09-23. Marshall published commit `0fab6f88ef525e108dcf8645d8fe90a828a3a9d4`;
its production client read the root tree and `README.md` at that commit from
the 4.7 GiB cache. The 8 GiB runtime cgroup prevented another OOM during
the successful clone.

The [campaign verification review](../reviews/2026-09-25-git-mirror-verification.md)
records two reproduced consistency repairs: current administrator authority now
shares the catalog mutation transaction, and worker outcomes require the current
locked attempt. [Generated public histories](../../../marshall/test/marshall/enrico/history_test.exs)
and [three-process ordering tests](../../../marshall/test/marshall/enrico/history_distributed_test.exs)
pass for retained publication, removal/re-registration and stale/duplicate outcomes.
The [ordinary browser fixture](../../../nix/verification/tests/machines/git-mirrors/default.nix)
passed the complete packaged Marshall/Enrico native journey in 53.43 seconds on
captured `f4de549a`-based tree `89e03703`. Earlier packaged-service machine results
retain their original scope; these additions do not establish physical tunnel or
cache-pressure acceptance.

The [runtime loader](../../../enrico/lib/enrico/config.ex) validates the JSON
bind type before address conversion, returning fixed configuration refusal
instead of raising on non-string values. The [generated startup properties](../../../enrico/test/invalid_boot_property_test.exs)
exercise local test-build OTP refusal and absence of serving startup calls;
the [property review](../reviews/2026-09-29-antithesis-property-audit.md) records
their scope. They do not establish packaged TLS startup or cache isolation.

The [attempt generation review](../reviews/2026-10-03-enrico-attempt-generation-histories.md)
records repairs to local receipt removal and task-generation ownership. Its
[generated histories](../../../enrico/test/manager_history_property_test.exs)
passed with real supervised workers and controlled Git replies across the
1,024-receipt cap. This is bounded local evidence; aggregate active admission,
real remote/cache pressure and packaged interruption remain open.

## Open questions

Production cache utilization near the 100 GiB quota and worst-case refresh
duration across large repositories need measurement. A 100 GiB quota can reject new
objects when the cache fills; a documented pruning or administrative eviction
policy should follow observed usage.

The Manager now caps aggregate active repository refreshes at eight. New work
at saturation refuses before task or measurement admission; existing active and
retained receipt replays remain available. HTTP preserves unavailable admission
as 503. The [admission review](../reviews/2026-10-03-enrico-refresh-admission.md)
records real supervised-worker success/death slot release and same-attempt retry
with controlled Git, plus exact refusal state and outcome accounting. Manager and task ownership now share a
[one-for-all lifetime](../../../enrico/lib/enrico/refresh_supervisor.ex).
A native PID probe additionally exposed a Git shell surviving BEAM death.
The [native owner](../../../enrico/native/git-owner/src/main.rs) and
[generated native histories](../../../enrico/native/git-owner/tests/histories.rs)
introduce stable eight-slot command admission and conflicting-writer locks,
caller EOF/group termination and parent-death fencing. Cleanup, publication and
administrative removal use the same native writer authority. Published reads do
not conflict with fetch writer locks when command capacity remains; eight held
native commands refuse further reads as well as writes. Ten local native
properties and the source-built helper package passed, including configured
large-output boundaries, descendant reaping and helper SIGKILL with retained
descendant locks. Complete fourteen-check component precommit and forced Dialyzer
passed. Packaged saturated service-cgroup recovery,
packaged escaping-descendant and durable Marshall retry proof remain open. The existing
packaged service machine check passed with the changed helper, isolated HTTPS
clone/read/refresh, source-outage preservation and recovery. The decision
remains partial.

The [escaped-session review](../reviews/2026-10-05-enrico-escaped-session-ownership.md)
records a separate-session deadline counterexample and repair of the native
all-adopted-child wait selector. Eleven native properties and the source-built
package passed; the original two-second cleanup bound and inherited-lock refusal
remain unchanged. Local escaped-session ownership has recorded evidence;
packaged saturated cgroup recovery, quota and durable Marshall retry remain open.
This repair's integrated fourteen-check component gate and zero-error forced
Dialyzer passed; all-file hooks and evaluated HLDD also passed. Broader packaged
and physical acceptance remain open.

A loaded-host counterexample showed a refresh admitted by a replacement
Manager failing before Git ran: the killed worker's native owner still held
the repository writer lock while it reaped its process group, and the
successor's `.git.new` cleanup took the owner's immediate lock refusal (exit
75) as a Git failure. The native refusal is unchanged. Manager-owned refreshes
now retry only that pre-execution refusal with bounded backoff, up to ten
seconds per step, before failing the attempt; direct Git callers,
administrative removal and reads still refuse at once. The
[generated histories](../../../enrico/test/manager_history_property_test.exs)
add a retiring-writer refresh property, and the replacement-admission property
passed repeatedly under 80 competing CPU-bound processes. This is local BEAM and
native-process evidence only; packaged cgroup recovery remains open.

## Related decisions

[ADR-0036](0036-automatic-host-updates.md),
[ADR-0042](0042-host-observability.md),
[ADR-0074](0074-durable-lifecycle-state-machines.md),
[ADR-0075](0075-fleet-overlay-and-source-access.md), and
[ADR-0091](0091-fleet-perimeter-public-listeners.md).
