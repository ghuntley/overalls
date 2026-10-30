# ADR-0259: Deployment revision in telemetry provenance

- ID: ADR-0259
- Date: 2026-10-23
- Status: accepted
- Implementation: partial
- Components: NixOS, OpenTelemetry collector, trace spool (Rust), Lyra (Rust), Marshall, Grafana, Tempo, Prometheus
- Supersedes: none
- Superseded by: none

## Context

On 2026-10-23 `/threads` and `/machines` returned 5xx responses while Marshall's
database pool was saturated (see the
[host-row lock convoy review](../reviews/2026-10-23-host-row-lock-convoy.md)).
Correlating the failures with a deployment was guesswork:

- The trace spool replaced every application span resource with exactly
  `service.name`, `host.name` and `overalls.telemetry.origin`.
- No host set `system.configurationRevision`.
- No Prometheus series or Grafana panel named the deployed revision.

The operator asked for spans in the diagnostics library and collectors, including
the Rust components, to carry the deployment version, and for Grafana to show it.

## Decision

1. Every flake host build sets `system.configurationRevision` to the flake
   source revision (`self.rev`, else `self.dirtyRev`, else unset).
   [`deployment-revision.nix`](../../../nix/domains/system/otel-fleet/deployment-revision.nix)
   reads it, falls back to `unknown`, and restricts it to the spool's simple
   identifier alphabet.
2. The trace spool receives the revision from its host-built configuration.
   Its closed resource becomes service, host, application origin, plus
   `service.version` and `overalls.deployment.revision`, both carrying that
   revision. Producers still cannot supply any resource attribute.
3. Guest spans keep their own build identity. Lyra reports its crate version as
   `service.version`. The host collector adds
   `overalls.host.deployment.revision` to guest traces, under a separate key, so
   a guest cannot claim a host deployment revision.
4. Prometheus receives the revision only as one separate per-host
   `overalls_deployment_info` series, from a dedicated collector pipeline. The
   revision never labels any other series, because
   `resource_to_telemetry_conversion` would otherwise change series identity on
   every deploy and break roster and exact-count rules.
5. Grafana shows the deployed revision by host and deployment annotations on the
   operations dashboard. The Marshall pages dashboard shows failed LiveView
   callbacks by closed failure reason and `service.version`.

Authorization: the operator's request in this session (2026-10-23), including
committing to trunk for automatic deployment.

## Alternatives

- **Set the revision in each Elixir SDK resource.** Rejected: the spool discards
  producer resources by design (`trace-schema-closes-provenance`), and a
  producer-supplied revision would weaken that provenance.
- **Stamp the release build or Mix version.** Rejected: every application is at
  `0.1.0`, and baking the revision into release derivations would rebuild every
  release and guest image on every commit.
- **Add the revision to every metric resource.** Rejected because of the
  series-identity break described above.

## Consequences

- Traces can be filtered by revision in Tempo, and a deploy is visible in Grafana.
- The spool configuration and the host toplevel change on every commit. The
  per-producer spool units restart with each deployment, as Marshall already does.
- Guest traces show the receiving host's revision, not the guest image's.

## Invariants and verification

- The spool's resource is exactly the five reviewed attributes. Rust test
  `schema_replaces_origin_and_discards_unreviewed_context` in
  [`spool/src/tests.rs`](../../../elixir/diagnostics/native/spool/src/tests.rs).
- The spool refuses a revision that is empty, longer than 64 bytes or outside the
  simple alphabet: config validation in
  [`spool/src/main.rs`](../../../elixir/diagnostics/native/spool/src/main.rs).
- Lyra spans carry only `service.name` and `service.version`. Test
  `generated_trace_ids_keep_only_fixed_span_data` in
  [`lyra/src/telemetry.rs`](../../../lyra/src/telemetry.rs).
- Exactly one deployment series per host, with no revision label on other series.
  Machine test assertion in
  [`otel-fleet`](../../../nix/verification/tests/machines/otel-fleet/default.nix),
  plus contract `deployment-info-series` in
  [`otel-fleet/default.nix`](../../../nix/domains/system/otel-fleet/default.nix).
- Operations dashboard inventory (panels 23–25) checked by the
  [log-store machine test](../../../nix/verification/tests/machines/log-store/driver.py).

## Implementation evidence

- Partial.
- Implemented in:
  - [`flake.nix`](../../../flake.nix) (`hostSystem`);
  - [`trace-spool.nix`](../../../nix/domains/system/otel-fleet/trace-spool.nix);
  - [`spool/src/schema.rs`](../../../elixir/diagnostics/native/spool/src/schema.rs);
  - [`lyra/src/telemetry.rs`](../../../lyra/src/telemetry.rs);
  - [`otel-fleet/default.nix`](../../../nix/domains/system/otel-fleet/default.nix);
  - [`operations-dashboard.nix`](../../../nix/domains/system/otel-fleet/operations-dashboard.nix);
  - [`marshall-pages-dashboard.nix`](../../../nix/domains/system/otel-fleet/marshall-pages-dashboard.nix).
- Code and Rust unit tests pass locally.
- The collector configuration generated for the production host passes
  `otelcol-contrib validate`.
- The NixOS machine tests above are updated but have not yet run on this change.
- No Tempo assertion yet checks span resource attributes end to end.

## Open questions

- Should guest images also carry their own build revision? That would require a
  build-time input that does not rebuild images on every commit.

## Related decisions

- [ADR-0149](0149-independent-observability.md): independent observability and the trace spool.
- [ADR-0159](0159-remove-legacy-compatibility.md): carries ADR-0149 forward.
- [ADR-0258](0258-marshall-page-service-levels.md): Marshall page service levels and dashboard.
- [Host-row lock convoy review](../reviews/2026-10-23-host-row-lock-convoy.md).
