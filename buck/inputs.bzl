# Owned source groups that NixOS assembly reads besides a suite's own files
# (ADR-0270). Each entry is a leaf filegroup so nix_assemble can copy it.
# Coarse until modules have their own targets (M11).

# The flake, modules, fleet inventory and secrets.
NIX_INPUTS = [
    "//:flake",
    "//fleet:srcs",
    "//nix:srcs",
    "//secrets:srcs",
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
