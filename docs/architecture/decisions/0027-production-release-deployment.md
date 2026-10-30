# ADR-0027: Production release deployment

- ID: ADR-0027
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Marshall runtime, Lilly services, PostgreSQL transport, deployment tooling
- Supersedes: none
- Superseded by: ADR-0030

## Context

Superseded by [ADR-0030](0030-nixos-deployment-and-tls.md) for source-built NixOS
host deployment and HAProxy TLS termination with verified TLS backends. Runtime,
database, readiness, migration and supervision contracts continue there. The
implemented status and acceptance evidence below belong to this earlier deployment.

The authorized implementation requires at least three deployed Marshall instances,
potentially up to 100, and independently hosted privileged Lilly services. Releases
exist, but the generated production configuration has no PostgreSQL TLS policy,
explicit fleet connection budget or load-balancer readiness probe. Deployment
automation and HA database infrastructure remain open under ADR-0003.

## Decision

Use the independently built Elixir releases on standard Linux/systemd for the
first supported service deployment. This matches Lilly's existing systemd/cgroup
boundary. The user authorized implementation of the full platform; systemd is
the stated default after the optional deployment preference question.

Require explicit instance identity, planned replica count (3–100), and database
connection budget in production configuration. Count one Oban notification
connection per node in addition to its Repo pool, plus ten connections reserved
for operator/migration work. Reject configurations that exceed this declared
budget. Deployment must provision the corresponding database capacity; this
arithmetic does not establish a workload throughput claim or prove replicas exist.

Use verified PostgreSQL TLS by default, including hostname checks and a configured
CA or the bundled CA store. Reject URL query overrides. An explicit loopback-only
development mode may use plaintext to localhost/loopback IPs. Connect only to a
writable primary. Keep credentials out of configuration error messages.

Serving production nodes use direct HTTPS, optionally with an explicit HTTP
redirect port, and bind loopback by default until an operator selects another IP.
Use a TCP/TLS-passthrough load balancer so the existing force-SSL and client TLS
boundaries remain intact. No forwarded-header trust bypass is introduced.

Expose bounded `/health/live` and `/health/ready` probes. Readiness requires a
writable database with the release's required migration; errors return a fixed
unavailable response. Migration is an explicit operator step, serialized by Ecto's
database migration lock. Serving nodes do not migrate at startup.

Run Marshall unprivileged and Lilly as the trusted root host agent. Lilly service
termination must leave independently supervised VM units running in `lilly.slice`.
Its service must not add a private mount namespace that hides guest bind mounts
from systemd's VM units. Install secrets/configuration separately from artifacts.
Restart services to activate a release; preserve Lilly state and physical identity.

## Alternatives

Kubernetes would add an unselected orchestrator and does not remove Lilly's host
privileges. NixOS host modules can follow without changing the release contracts.
TLS termination followed by plaintext backend traffic needs an additional trusted
proxy boundary. Multiplying default database pools by 100 without a budget would
overwhelm the authoritative store. Startup migrations on every serving instance
would mix deployment coordination with request availability.

## Consequences

Production runtime environment requirements become stricter. Existing deployments
must supply the new identity/budget/TLS configuration. Rollout still follows the
compatibility constraints in individual migrations and ADRs. Release packaging
must include native dependencies and the pinned Elixir/OTP runtime or its closure.
Three services on one development host prove process behavior, not production
failure-domain availability. PostgreSQL HA selection and failover remain separate
required work; a readiness endpoint alone cannot provide database availability.

## Invariants and verification

- Invalid budgets, non-loopback plaintext and TLS-verification overrides fail closed.
- Actual TLS tests reject untrusted/wrong-name certificates and plaintext servers.
- Health responses disclose no queries, credentials or errors; missing/read-only
  databases and unapplied migrations are not ready.
- Three production releases share durable state and remain usable when one stops.
- Service restart/stop preserves Lilly guest processes, disks and ownership fences.
- Validate rendered units, real release startup and migration commands, property
  tests for configuration boundaries, and normal compiler/Dialyzer gates.

## Implementation evidence

[Runtime validation](../../../marshall/lib/marshall/operations/runtime_config.ex)
and [production configuration](../../../marshall/config/runtime.exs) enforce the
identity/budget, primary database, TLS and listener boundary.
[Properties and configuration tests](../../../marshall/test/marshall/operations/runtime_config_test.exs)
cover malformed input and randomized budgets. [Health](../../../marshall/lib/marshall/operations/health.ex),
its [HTTP plug](../../../marshall/lib/marshall_web/health.ex) and
[tests](../../../marshall/test/marshall_web/health_test.exs) distinguish process
liveness from a writable, migrated database. The explicit
[migration entry point](../../../marshall/lib/marshall/operations/migrate.ex)
runs independently of the serving application.

[Packaging](../../../scripts/package_release.sh) and its
Nix closure (`nix/domains/artifacts/applications/release-bundle.nix` at overalls revision `4c6fac25c`, file deleted) produce immutable releases with
runtime dependencies and Lilly's canonical launcher paths. The
Marshall service (`scripts/test/fixtures/legacy-deployment/systemd/marshall@.service` at overalls revision `9fe1e493`, repository deleted),
Lilly service (`scripts/test/fixtures/legacy-deployment/systemd/lilly.service` at overalls revision `9fe1e493`, repository deleted),
guest slice (`scripts/test/fixtures/legacy-deployment/systemd/lilly.slice` at overalls revision `9fe1e493`, repository deleted),
HAProxy example (`scripts/test/fixtures/legacy-deployment/haproxy.cfg.example` at overalls revision `9fe1e493`, repository deleted) and
historical harness guide (`scripts/test/fixtures/legacy-deployment/README.md` at overalls revision `9fe1e493`, repository deleted)
record the earlier topology. These four definitions are retained only as test
fixtures after removal of the manual deployment examples. Current installation
and rollout use the NixOS modules under ADR-0030.
The [NixOS deployment checks](../../../nix/verification/tests/README.md) exercises
actual releases, PostgreSQL TLS and multi-process deployment failure behavior;
see the [review](../reviews/2026-09-16-production-deployment.md) for checks completed
and remaining infrastructure obligations. The three-node production service,
TLS rejection, authenticated node failover and database recovery checks pass.
The [real KVM harness](../../../marshall/scripts/smoke_execution.exs), with
`--lilly-release`, also passes graceful service stop and automatic restart after
forced daemon death using the immutable Lilly bundle. It starts a retained guest
through that service and verifies the daemon's shared host mount namespace and
separate cgroup. All three VMM PIDs,
reservations, console access and guest data survive; each daemon establishes a
new authenticated session and fresh capacity report. The full drain/recovery/
retirement run cleans its fixture resources. This is single-host acceptance;
the production infrastructure and cross-host obligations below remain open.

The [production terminal harness](../../../nix/verification/tests/README.md)
also provisions a fresh guest through the packaged Lilly service, with three
Marshall services and Chromium. Lost acknowledgments and serving-node death do
not replay accepted or queued input; guest process identity survives, and writer
handoff plus grant/login revocation reach connected browsers across nodes. Its
[review](../reviews/2026-09-16-terminal-failover.md) records the startup pool-path
validation fix and actual acceptance. This extends the retained-guest service
check above without changing the single-host evidence boundary.

[ADR-0029](0029-database-durability-and-recovery.md) adds explicit durable Repo
commits and [local database recovery acceptance](../../../nix/verification/tests/README.md).
It proves synchronous waiting, fenced promotion and isolated backup restoration
through actual PostgreSQL instances. It does not provide a production HA controller
or authorize connecting historical backups to surviving guests.

## Open questions

Select and exercise PostgreSQL HA/failover, production failure domains and backup
recovery. Confirm actual workload and connection budgets before 100-node claims.
Deployment SMTP, key custody and second-host execution acceptance remain required.

## Related decisions

[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0002](0002-elixir-ash-and-types.md), [ADR-0003](0003-control-plane-coordination.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0024](0024-durable-magic-link-email.md),
[ADR-0025](0025-protected-provisioner-enrollment.md),
[ADR-0026](0026-host-maintenance-and-retirement.md),
[ADR-0029](0029-database-durability-and-recovery.md).
