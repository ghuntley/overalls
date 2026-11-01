# Lilly guidance

Follow [root guidance](../AGENTS.md) and the relevant
[ADRs](../docs/architecture/decisions/README.md), especially execution, lifecycle,
capacity, networking and assurance. Lilly is an independent Elixir release;
Firecracker process lifetime must not depend on the Lilly application lifetime.

- Run `tools/precommit`, which builds `//lilly:check` and `//lilly:test` for a
  Lilly change, inside the pinned `devenv shell`. Both applications use the
  shared runtime and ADR checks.
- Use typespecs on public APIs and validated types at host/protocol boundaries.
  Unknown or unreadable capacity must not become fabricated schedulable capacity.
- Host operations must use fixed executable names and argument lists, never
  concatenate caller input into shell commands. Treat privileged execution,
  device paths, process identity and network isolation as review boundaries.
- Unit/property tests run without root or KVM. Real execution and isolation
  claims require the documented multi-host KVM tests. Never infer them from mocks.
- Keep terminal bytes and credentials out of logs and test failure output.
