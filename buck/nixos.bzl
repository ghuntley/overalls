# NixOS machine tests and script tests as Buck2 test targets (ADR-0270).

load(":artifacts.bzl", "ASSEMBLY_ARTIFACTS")
load(":assemble.bzl", "nix_assemble")
load(":nix.bzl", "owned_set")

# Contract script-tests-run-locally: see buck/CONTRACTS.
_LOCAL = CommandExecutorConfig(local_enabled = True, remote_enabled = False, remote_cache_enabled = False)

def _hidden(ctx: AnalysisContext) -> list:
    files = list(ctx.attrs.srcs)
    for dep in ctx.attrs.deps:
        files.extend(dep[DefaultInfo].default_outputs)
        files.extend(dep[DefaultInfo].other_outputs)
    return files

def _nixos_machine_test_impl(ctx: AnalysisContext) -> list[Provider]:
    assembly = ctx.attrs.assembly[DefaultInfo]
    command = cmd_args(
        ctx.attrs._python[RunInfo],
        ctx.attrs._runner,
        "run",
        "--nix",
        ctx.attrs._nix[RunInfo],
        "--check",
        ctx.attrs.check,
        "--nested-kvm",
        "true" if ctx.attrs.nested_kvm else "false",
        "--suite",
        ctx.attrs.suite,
        "--store-path",
        assembly.default_outputs[0],
        cmd_args([cmd_args("--scenario", s) for s in ctx.attrs.scenarios]),
        hidden = assembly.other_outputs,
    )
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [command],
            labels = ctx.attrs.labels,
            default_executor = _LOCAL,
            run_from_project_root = True,
            use_project_relative_paths = True,
        ),
    ]

_nixos_machine_test = rule(
    impl = _nixos_machine_test_impl,
    attrs = {
        "assembly": attrs.dep(),
        "check": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "nested_kvm": attrs.bool(),
        "params": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "scenarios": attrs.list(attrs.string(), default = []),
        "suite": attrs.string(),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
        "_python": attrs.default_only(attrs.exec_dep(default = "toolchains//:python")),
        "_runner": attrs.default_only(attrs.source(default = "root//buck:machine_tests.py")),
    },
)

_RESERVED_LABELS = ["machine_test", "nested_kvm"]

# Contract nixos-machine-test-labels: see buck/CONTRACTS.
def nixos_machine_test(name: str, check: str, nested_kvm: bool, inputs: list[str], labels: list[str] = [], **kwargs):
    """A NixOS machine test: builds `lib.assemble {}.checks.<check>` over a
    copy of `inputs` only (leaf owned file groups), then checks its labels."""
    for label in labels:
        if label in _RESERVED_LABELS:
            fail("{}: label {} is derived from nested_kvm; do not set it".format(name, label))
    owned_set(name = name + ".inputs", deps = inputs)
    nix_assemble(
        name = name + ".assembly",
        attr = "checks.\"{}\"".format(check),
        srcs = [":" + name + ".inputs"],
        # Every Buck2-built leaf replaces its Nix build in the test, as it
        # will on hosts (ADR-0269).
        artifacts = ASSEMBLY_ARTIFACTS,
        labels = ["machine_test_assembly"],
    )
    _nixos_machine_test(
        name = name,
        check = check,
        assembly = ":" + name + ".assembly",
        nested_kvm = nested_kvm,
        labels = ["machine_test"] + (["nested_kvm"] if nested_kvm else []) + labels,
        visibility = ["PUBLIC"],
        **kwargs
    )

def _script_test_impl(ctx: AnalysisContext) -> list[Provider]:
    env = {"BUCK2_TEST_NIX": cmd_args(ctx.attrs._nix[RunInfo])}
    command = cmd_args(
        ctx.attrs._python[RunInfo],
        ctx.attrs.script,
        ctx.attrs.args,
        hidden = _hidden(ctx),
    )
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [command],
            env = env,
            labels = ctx.attrs.labels,
            default_executor = _LOCAL,
            run_from_project_root = True,
            use_project_relative_paths = True,
        ),
    ]

# A Python script run from the project root as a local test. Declare every
# file it reads in srcs or deps so selection sees it (ADR-0270).
script_test = rule(
    impl = _script_test_impl,
    attrs = {
        "args": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "script": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
        "_python": attrs.default_only(attrs.exec_dep(default = "toolchains//:python")),
    },
)
