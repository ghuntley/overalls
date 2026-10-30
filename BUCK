load("//buck:nix.bzl", "nix_owned")
load("//nix/buck:bootstrap_attrs.bzl", "BOOTSTRAP_CHECKS", "BOOTSTRAP_PACKAGES")
load("//buck:nix.bzl", "nix_flake_attr", "owned_set")
load("//buck:checks.bzl", "conflict_markers", "contract_check", "repo_check")
load("//buck:python.bzl", "py_static")
load("//nix/verification/tests/machines:suites.bzl", "MACHINE_PACKAGES", "MACHINE_TESTS")

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
] + MACHINE_PACKAGES

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

filegroup(name = "flake", srcs = ["flake.lock", "flake.nix"], visibility = ["PUBLIC"])

# Root manifests that Nix builds read: the Cargo workspace (ADR-0273), its
# clippy.toml, and pyproject.toml for the ruff checks inside machine tests.
filegroup(name = "workspace_files", srcs = ["Cargo.lock", "Cargo.toml", "clippy.toml", "pyproject.toml"], visibility = ["PUBLIC"])

# Machine checks are nixos_machine_test targets (nix/verification/tests/machines).
[nix_flake_attr(name = "check-" + attr, attr = "checks.x86_64-linux." + attr, labels = ["bootstrap", "check"]) for attr in BOOTSTRAP_CHECKS if attr not in MACHINE_TESTS]

# Repository-wide checks (M7). Each is a cached build action; `buck2 test`
# reads its stamp. Sub-targets check single files for precommit (M8).

# ruff format, ruff check and ty over every owned Python file and
# pyproject.toml; `:py-static[ruff/<path>]` checks one file.
py_static(name = "py-static", owned = ALL_OWNED_FILES, labels = ["check", "precommit"])

# Merge-conflict markers in every owned file; `:conflict-markers[<path>]`
# checks one file.
conflict_markers(name = "conflict-markers", owned = ALL_OWNED_FILES, labels = ["check", "precommit"])

# Repository-wide checks that `tools/precommit` (buck/bxl/precommit.bxl) runs
# once each, only when a file matching `include` changes (M8). Each target
# carries the `precommit` label; see the buck2 skill for the convention.
_ELIXIR = "$(exe toolchains//:elixir)/bin/elixir"
_NODE = "$(exe toolchains//:node)/node"
_CONTRACT_ENV = {"OVERALLS_CODE_CONTRACTS_NODE_MODULES": "$(exe toolchains//:code_contracts_node_modules)"}

# devenv.lock must agree with flake.lock on the inputs both carry.
repo_check(
    name = "package-input-lock",
    cmd = [_ELIXIR, "scripts/check_package_input_lock.exs", "flake.lock", "devenv.lock"],
    include = ["flake.lock", "devenv.lock", "scripts/check_package_input_lock.exs"],
    labels = ["check", "precommit"],
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:erlang"],
)

# ADR structure and references. The validator also tests that evidence links
# resolve, so the owned-path inventory is an input and any deletion selects it.
repo_check(
    name = "adrs",
    cmd = [_ELIXIR, "scripts/check_adrs.exs"],
    deletions = ["*"],
    include = ["docs/architecture/*", "scripts/adr_validator.ex", "scripts/check_adrs.exs"],
    inventory = True,
    labels = ["check", "precommit"],
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:erlang"],
)

# Contract syntax and coverage over the repository (`mix contracts.check`
# and the CI gates run the same command); `[contracts/<path>]` checks one
# file with its ancestor CONTRACTS. cc-check comes from the importNpmLock tree
# of tools/code-contracts.
contract_check(name = "contracts", labels = ["check", "precommit"], owned = ALL_OWNED_FILES)

repo_check(
    name = "contracts-tests",
    cmd = [_NODE, "--test", "scripts/test/check_contracts_test.mjs"],
    env = _CONTRACT_ENV,
    include = ["scripts/check_contracts.mjs", "scripts/test/check_contracts_test.mjs", "tools/code-contracts/*"],
    labels = ["check", "precommit"],
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:git", "toolchains//:node"],
)

# Third-party fixed-output hashes come only from the pin registry.
repo_check(
    name = "pins",
    cmd = [_ELIXIR, "scripts/check_pins.exs"],
    include = ["*.nix", "nix/domains/artifacts/dependency-hashes.json", "scripts/pins.ex", "scripts/check_pins.exs"],
    labels = ["check", "precommit"],
    local_only = True,
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:erlang", "toolchains//:git"],
)

# ADR-0265 lint policy for adopted crates.
repo_check(
    name = "rust-lints",
    cmd = [_ELIXIR, "scripts/check_rust_lints.exs", "--strict"],
    include = ["*.rs", "*Cargo.toml", "*clippy.toml", "scripts/rust/*", "scripts/rust_lints.ex", "scripts/check_rust_lints.exs"],
    labels = ["check", "precommit"],
    local_only = True,
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:erlang", "toolchains//:git"],
)

# The cells' Elixir and OTP must be the .tool-versions ones: the toolchain
# check as a configuration assertion. The store paths are in the command, so a
# toolchain change reruns it.
repo_check(
    name = "toolchain-versions",
    cmd = [_ELIXIR, "scripts/check_toolchain.exs"],
    include = [".tool-versions", "scripts/check_toolchain.exs"],
    labels = ["check", "precommit"],
    owned = ALL_OWNED_FILES,
    path = ["toolchains//:erlang"],
)

# The structured-event catalog gate per application (`mix logging.check`).
LOGGING_APPS = ["audi", "brady", "enrico", "galileo", "lilly", "marshall", "peach", "porsche", "susan", "ziggy"]

[repo_check(
    name = "logging-" + app,
    cmd = [_ELIXIR, "scripts/check_logging.exs", app],
    include = [app + "/lib/*.ex", app + "/lib/*.exs", app + "/config/*.ex", app + "/config/*.exs", app + "/mix.exs", "scripts/check_logging.exs"],
    labels = ["check", "precommit"],
    owned = ["//" + app + ":srcs_files", "//scripts:srcs_files"],
    path = ["toolchains//:erlang"],
) for app in LOGGING_APPS]
