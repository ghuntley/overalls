load("//buck:nix.bzl", "nix_owned")
load("//nix/buck:bootstrap_attrs.bzl", "BOOTSTRAP_CHECKS", "BOOTSTRAP_PACKAGES")
load("//buck:nix.bzl", "nix_flake_attr", "owned_set")
load("//buck:checks.bzl", "conflict_markers", "script_check")
load("//buck:python.bzl", "py_static")

# Repository-root files: flake, lock files, configuration.
nix_owned()

# Packages with nix_owned files besides the root. The flake reads all of them;
# the repository-wide checks below cover them and the toolchains cell.
OWNED_PACKAGES = [
    "//.agents",
    "//antithesis",
    "//audi",
    "//brady",
    "//.claude",
    "//docs",
    "//elixir",
    "//enrico",
    "//fleet",
    "//galileo",
    "//.github",
    "//lilly",
    "//lyra",
    "//marshall",
    "//marvin",
    "//mila",
    "//nix",
    "//.oss-scanner",
    "//peach",
    "//porsche",
    "//protocol",
    "//scripts",
    "//secrets",
    "//susan",
    "//tools",
    "//vendor",
    "//ziggy",
    "//buck",
    "//nix/domains/artifacts/guest/github",
    "//buck/probes",
]

ALL_OWNED_FILES = [":srcs_files", "toolchains//:srcs_files"] + [p + ":srcs_files" for p in OWNED_PACKAGES]

# Owned sources that the flake reads. Bootstrap targets depend on all of them
# until per-component rules replace them (ADR-0269).
owned_set(
    name = "flake_srcs",
    deps = [":srcs"] + [p + ":srcs" for p in OWNED_PACKAGES],
    visibility = ["PUBLIC"],
)

# Runnable wrappers elsewhere (//mila:journey-fixture) consume these until
# their outputs move to Buck2 rules.
[nix_flake_attr(
    name = "package-" + attr,
    attr = "packages.x86_64-linux." + attr,
    labels = ["bootstrap"],
    visibility = ["//mila:"] if attr == "mila-journey-fixture" else [],
) for attr in BOOTSTRAP_PACKAGES]

[nix_flake_attr(name = "check-" + attr, attr = "checks.x86_64-linux." + attr, labels = ["bootstrap", "check"]) for attr in BOOTSTRAP_CHECKS]

# Repository-wide checks (M7). Each is a cached build action; `buck2 test`
# reads its stamp. Sub-targets check single files for precommit (M8).

# ruff format, ruff check and ty over every owned Python file and
# pyproject.toml; `:py-static[ruff/<path>]` checks one file.
py_static(name = "py-static", owned = ALL_OWNED_FILES, labels = ["check"])

# Merge-conflict markers in every owned file; `:conflict-markers[<path>]`
# checks one file.
conflict_markers(name = "conflict-markers", owned = ALL_OWNED_FILES, labels = ["check"])

# devenv.lock must agree with flake.lock on the inputs both carry.
script_check(
    name = "package-input-lock",
    cmd = ["$(exe toolchains//:elixir)/bin/elixir", "scripts/check_package_input_lock.exs", "flake.lock", "devenv.lock"],
    labels = ["check"],
    path = ["toolchains//:erlang"],
    srcs = ["flake.lock", "devenv.lock", "//scripts:check_package_input_lock.exs"],
)
