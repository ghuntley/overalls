# Bootstrap setup complete is single-owner and live

**Property:** For every selected profile, bootstrap emits `setup_complete` exactly once and only after all required independent probes succeed; it remains alive afterward. A timeout, crash, or signal before readiness must leave the profile incomplete and nonzero, without Compose restarting the bootstrap owner.

**Assertion type:** `Always` for the one-marker/ordering invariant, with `Reachable` for a successful setup marker and `Sometimes` for post-marker liveness after a fault. The marker and process lifetime are observable across timeline faults and are stronger than a readiness log alone.

**Source evidence:** `antithesis/workload/core/bootstrap.py:94-105` documents and implements the single-owner contract. Profile readiness is assembled by `probe()` and the compose definitions use the bootstrap owner as a non-restarted gate. Existing tests cover individual probe branches but no catalog property joins marker cardinality, ordering, and owner lifetime.

**Workload/oracle:** Start each supported profile with one bootstrap owner; inject endpoint/SQL failure before readiness, then restart or signal the owner after readiness. Independently collect setup markers, process exit/restart events, and required probe observations. Fail if a marker precedes its probes, appears more than once, appears after a failed pre-ready exit, or the owner exits/restarts after the marker without an explicit scenario boundary.

**Open Questions:**

- Can the hosted harness observe Compose restart policy and process identity without turning an intentional scenario restart into a duplicate marker? `(partial: source and compose paths inspected; hosted process-lifetime witness is unrun)`
- Which profiles should require a post-marker fault window, and what quiet interval distinguishes normal shutdown from an owner liveness failure? `(partial: profile-specific intervals are not yet standardized)`

**Investigation Log:**

- 2026-11-02: Inspected bootstrap's `run/2`, profile probe dispatch, and current catalog. Found the contract in source and no existing catalog slug covering marker cardinality plus post-marker ownership. Existing per-profile readiness properties do not assert this process-level join.
