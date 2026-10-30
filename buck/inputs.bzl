# Owned source groups that NixOS assembly reads besides a suite's own files
# (ADR-0270). Each entry is a leaf filegroup so nix_assemble can copy it.
# Coarse until modules have their own targets (M11).

# The flake, root manifests, modules, fleet inventory and secrets.
NIX_INPUTS = [
    "//:flake",
    "//:workspace_files",
    "//fleet:srcs",
    # Host and platform packages (ADR-0271) own their directories' files.
    "//fleet/hosts/dungarees:srcs",
    "//fleet/hosts/panterloons:srcs",
    "//fleet/hosts/salopettes:srcs",
    "//nix:srcs",
    "//nix/platform:srcs",
    "//nix/domains/artifacts/guest/github:srcs",
    # support/zfs-node.nix installs these suites' probes for every ZFS node.
    "//nix/verification/tests/machines/native-zfs:srcs",
    "//nix/verification/tests/machines/zfs-lifecycle:srcs",
    # support/native-role-node.nix seals the native role prerequisites.
    "//nix/verification/tests/machines/service-roles:srcs",
    # The trace-spool module validates spans against the diagnostics schema.
    "//elixir:trace_schema",
    "//secrets:srcs",
] + [
    # The root Cargo workspace's member manifests (cargo-workspace.nix).
    "//{}:cargo_manifests".format(package)
    for package in ["elixir", "enrico", "lilly", "lyra", "marshall", "mila"]
]

# The application and tool sources behind the package set, read by suites
# that take `packages`, `service` or a package-closing module.
PACKAGE_INPUTS = [
    "//antithesis:srcs",
    "//audi:srcs",
    "//brady:srcs",
    "//elixir:srcs",
    "//enrico:srcs",
    "//galileo:srcs",
    "//lilly:srcs",
    "//lyra:srcs",
    "//marshall:srcs",
    "//marvin:srcs",
    "//mila:srcs",
    "//peach:srcs",
    "//porsche:srcs",
    "//protocol:srcs",
    "//scripts:srcs",
    "//susan:srcs",
    "//vendor:srcs",
    "//ziggy:srcs",
]
