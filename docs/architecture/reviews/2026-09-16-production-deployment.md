# Production release deployment review

## Scope and evidence

The authorized implementation adds [ADR-0027](../decisions/0027-production-release-deployment.md)
and extends ADRs 0002/0003/0017/0024/0025. The stated initial target is standard
Linux/systemd, matching the existing privileged Lilly host boundary. No wire,
Ash resource or database schema change is introduced by this deployment work.

Reviewed [runtime validation](../../../marshall/lib/marshall/operations/runtime_config.ex),
[health](../../../marshall/lib/marshall/operations/health.ex),
[migration entry point](../../../marshall/lib/marshall/operations/migrate.ex),
[release packaging](../../../scripts/package_release.sh),
Nix closure (`nix/domains/artifacts/applications/release-bundle.nix` at overalls revision `4c6fac25c`, file deleted),
Marshall (`scripts/test/fixtures/legacy-deployment/systemd/marshall@.service` at overalls revision `9fe1e493`, repository deleted) and
Lilly (`scripts/test/fixtures/legacy-deployment/systemd/lilly.service` at overalls revision `9fe1e493`, repository deleted) service units, and the
[deployment guide](../../operations/deployment.md).

## Findings and disposition

1. **High — fixed deployment defect: PostgreSQL transport had no explicit TLS
   or primary-only contract.** Production now defaults to verified TLS with
   hostname checking and rejects a read-only target. Query/fragment overrides
   are rejected before Ecto's URL parser can turn arbitrary query keys into atoms.
   Plaintext requires an explicit local-loopback mode. Actual PostgreSQL tests
   accept the trusted certificate and reject an untrusted CA, wrong DNS identity,
   plaintext listener and read-only role. ADRs 0003/0027.
2. **High — fixed runtime integration defect: Bandit rejected top-level TLS
   version options.** The first real service startup failed despite configuration
   unit tests passing. Versions now use Bandit's Thousand Island transport
   options. Three immutable production releases subsequently start with direct
   HTTPS under DynamicUser. Configuration-shape tests alone do not establish
   service startup. ADR-0027.
3. **High — service boundary preserved and physically verified.** Lilly
   cannot use a private mount namespace: guest units started by host PID 1 need
   its bind mounts. Its service has no mount-namespace sandbox and remains in
   `system.slice`, independently of guest units in `lilly.slice`. The extended
   [real KVM harness](../../../marshall/scripts/smoke_execution.exs) now hands
   three running guests to a service rendered from the production template.
   Graceful stop and automatic restart after SIGKILL preserve every VMM PID,
   console, persistent marker and compute/disk reservation. Each new daemon
   establishes a higher authenticated session epoch and a fresh capacity report.
   The service also performs a real retained-guest stop/start, creating its new
   unit and mounts. `/proc` checks establish that its mount namespace equals
   PID 1's and its cgroup is outside the guest slice. A PID that disappears during
   forced restart is retried; a live replacement and new API epoch are required.
   This proves local service behavior, not independent host failure domains.
   ADRs 0017/0027.
4. **Medium — connection budgeting now includes Oban's independent notifier.**
   Each declared serving instance counts its Repo pool plus one PostgreSQL
   LISTEN connection, with ten operator/migration connections reserved. This is
   a local configuration consistency check; actual replica count, concurrent
   operator processes and PostgreSQL capacity are deployment responsibilities.
   Randomized tests cover the arithmetic over replica/pool/budget ranges. No
   100-node throughput claim is made. ADRs 0003/0027.
5. **Medium — load-balancer fixture needed its own resource budget.** The example's
   4,096 connections exceeded the interactive host's descriptor hard limit.
   Acceptance uses 256; the guide explains the production descriptor requirement.
   Node failover waits for HAProxy's explicit backend DOWN state, avoiding an
   assertion during the configured health-check detection window. ADR-0027.
6. **Release portability is explicit.** Copying a Nix-built Mix release alone
   omits native runtime paths. Both artifacts now export their Nix store closure.
   This preserves pinned runtime dependencies; it does not prove a hermetic
   source build, trusted publication or compatibility on another CPU architecture.
   Deployment config/keys remain outside artifacts. ADRs 0002/0027.

## Verification

- Both release bundles and their complete Nix closure exports build with
  Elixir 1.20.4/OTP 29.0.6. Lilly metadata contains canonical, pinned VM launchers
  and host tools. Marshall runs directly from the immutable store bundle.
- [Focused tests](../../../marshall/test/marshall/operations/runtime_config_test.exs)
  and [HTTP tests](../../../marshall/test/marshall_web/health_test.exs) pass nine
  cases (two properties, seven tests): fixed errors, budget bounds, explicit
  listeners, IPv6 options, missing schema and read-only transactions.
- [Deployment acceptance](../../../nix/verification/tests/README.md) passes with
  PostgreSQL 18.6, systemd 255 and HAProxy 3.4.3 on the development host. It uses
  a separate disposable database and freshly generated CA/key material.
- The packaged migration command applies every migration to the empty TLS
  database, and a second invocation succeeds without duplicate migrations.
  With the database stopped, it exits nonzero with a fixed failure message.
- Three actual unprivileged systemd Marshall services share an authenticated v2
  session. The same session remains authoritative through a service stop and
  restart, including requests through the certificate-verified TLS pass-through
  load balancer. No Erlang distribution is enabled.
- Missing migration and database outage return fixed, cookie-free 503 readiness
  while liveness remains 200. Each outage probe completes in under two seconds;
  all three services reconnect and return ready after database restart.
- Rendered Marshall/Lilly units pass `systemd-analyze verify`. Fixture diagnostics
  contain none of the generated environment secrets or provisioner credential.
  Successful runs remove the test cluster, units and temporary secrets.
- Marshall's precommit passes 218 cases (23 properties, 195 tests), including its
  three-node suite, plus six browser-state tests; four environment-specific host
  cases remain opt-in. Compiler/format/runtime checks and Dialyzer pass with the
  one existing upstream typespec exclusion and no new or unused exclusions.
- Lilly's precommit passes 82 cases (18 properties, 64 tests), compiler/runtime
  checks and Dialyzer without exclusions. Ash code generation reports no schema
  drift. The structural validator accepts all 27 ADRs and their local links.
- The real three-guest HTTPS/KVM run includes the immutable Lilly release service,
  retained-guest stop/start, host mount/cgroup checks, graceful service stop,
  forced main-process death, systemd automatic restart,
  stable VMM PIDs, retained reservations, console/data continuity and new-session
  capacity reporting. The service template changes only fixture paths and its
  runtime-directory name; production privilege, slice and termination settings
  remain intact. The complete run also passes host drain/resume, bounded crash
  recovery, credential fencing/rotation, confirmed deletion and empty-host
  retirement, then removes its units, mounts, network, disks and database rows.

## Remaining work

ADR-0027 is **implemented** for the selected release/service contract and local
acceptance. No production deployment or fleet availability claim follows.

The broader platform still requires independent KVM hosts,
PostgreSQL HA/failover and restore, production SMTP inbox delivery, operator key
custody, deployment failure domains and defined workload/100-node acceptance.
Application readiness cannot establish those operational properties.

The normal project gates and structural ADR validation complement these runtime
checks; they do not establish the outstanding infrastructure acceptance.
