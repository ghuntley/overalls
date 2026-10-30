# Nix layout

The root flake is the public interface. Its package, module, machine, release and
check names are explicit; implementation files live below the domain and platform
areas described here.

| Directory | Responsibility |
| --- | --- |
| `policy/` | Reviewed public user, network-source and encrypted-document registries, and the fleet host, service and port roster (`policy/fleet`). |
| `platform/` | Host inventory/profile, shared Nix helpers, build foundations and patches. |
| `domains/` | Domain-owned packages and NixOS modules for control-plane, provisioner, guest, ingress, observability, security and tooling behavior. |
| `verification/` | Evaluation checks, NixOS machine suites, fixtures, support code and Hegel property testing. |
| `catalog/` | Explicit package, module and check assembly entrypoints consumed by the flake. |

The flake keeps application builds on the development package input and host modules
and machine tests on the separately pinned stable NixOS input. Public output leaves
are domain-qualified (`service-*`, `guest-*`, `tool-*`, and `security-*` packages;
service, platform, network, security, storage and observability modules). The
conventional `default` package and module remain the canonical Marshall/default
profiles.

Read the applicable `CONTRACTS` file before changing a domain. The architecture
and implementation evidence remain in the [ADRs](../docs/architecture/decisions/README.md).
