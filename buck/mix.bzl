# Mix rules (ADR-0269). Contracts: buck/CONTRACTS (the checker does not parse
# .bzl files, so every @cc obligation for these rules lives there).
#
# Every Mix action runs inside a bubblewrap sandbox that mirrors the Nix
# build sandbox: the work directory is /build, /nix/store is a writable
# overlay, there is no network and the user is uid 1000. Mix, Spark and
# Rustler embed absolute build paths, so a fixed layout makes outputs
# location-independent (cacheable across checkouts and hosts) and lets the
# release reproduce beam.mixRelease byte for byte.

load(":assemble.bzl", "RuntimeRefsInfo", "nix_store_import")
load(":nix.bzl", "OwnedSrcsInfo")

# Repository-relative path -> source artifact (a file, or a whole owned
# package directory), merged across path dependencies.
MixSourcesInfo = provider(fields = {"files": dict[str, Artifact]})

# The placeholder store path a release names itself by (see the
# mix-release-self-reference contract); assembly rewrites it to $out.
MixReleaseInfo = provider(fields = {"self_reference": str, "application": str})

# A compiled Mix project: `_build/<env>` and the compiled dependency tree.
MixCompileInfo = provider(fields = {"state": Artifact, "env": str, "project": str})

# Source overlays (contract mix-sources-declared): store trees copied over the
# declared sources, and whether every file loses its execute bits as
# `cp --no-preserve=mode` gives the Nix source.
_SOURCE_ATTRS = {
    "overlays": attrs.list(attrs.string(), default = []),
    "reset_modes": attrs.bool(default = False),
}

_TOOLS = {
    "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
    "_bwrap": attrs.default_only(attrs.exec_dep(default = "toolchains//:bwrap")),
    "_sandbox": attrs.default_only(attrs.source(default = "root//buck:mix_sandbox.sh")),
    "_phases": attrs.default_only(attrs.source(default = "root//buck:mix_phases.sh")),
}

def _mix_sources_impl(ctx: AnalysisContext) -> list[Provider]:
    files = {}
    for dep in ctx.attrs.deps:
        files.update(dep[MixSourcesInfo].files)
    for src in ctx.attrs.srcs:
        files[ctx.label.package + "/" + src.short_path] = src
    for dep in ctx.attrs.owned:
        for package, directory in dep[OwnedSrcsInfo].dirs:
            files[package or "."] = directory
    return [DefaultInfo(), MixSourcesInfo(files = files)]

# Contract mix-sources-declared: see buck/CONTRACTS.
mix_sources = rule(
    impl = _mix_sources_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [MixSourcesInfo]), default = []),
        # Whole owned packages (nix_owned/owned_set), for suites that read the
        # repository itself, such as Marshall's shared validator tests.
        "owned": attrs.list(attrs.dep(providers = [OwnedSrcsInfo]), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

def _source_files(sources: list[Dependency]) -> dict[str, Artifact]:
    files = {}
    for dep in sources:
        files.update(dep[MixSourcesInfo].files)
    return files

def _tree(ctx: AnalysisContext, sources: list[Dependency], name: str) -> cmd_args:
    return _tree_of(ctx, _source_files(sources), name)

def _tree_of(ctx: AnalysisContext, files: dict[str, Artifact], name: str) -> cmd_args:
    """A manifest of `relative-path<TAB>artifact` lines, with its inputs.

    Owned package directories sort first, so files declared by a project
    overwrite nothing they did not already contain."""
    ordered = sorted(files.items(), key = lambda item: (0 if item[1].is_source == False else 1, item[0]))
    # Store trees from the cells (generated sources such as the Cargo
    # workspace overlay) are copied over the root after the declared files.
    directives = [cmd_args("@overlay", path, delimiter = "\t") for path in ctx.attrs.overlays]
    if ctx.attrs.reset_modes:
        directives.append(cmd_args("@reset-modes", "-", delimiter = "\t"))
    manifest = ctx.actions.write(name + ".tsv", [cmd_args(rel, artifact, delimiter = "\t") for rel, artifact in ordered] + directives)
    return cmd_args(manifest, hidden = [artifact for _, artifact in ordered])

def _env_lines(env: dict[str, str]) -> list[str]:
    return ["export {}={}".format(k, shell_quote(v)) for k, v in sorted(env.items())]

def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"

def _var_lines(variables: dict[str, str]) -> list[str]:
    return ["{}={}".format(k, shell_quote(v)) for k, v in sorted(variables.items())]

def _run_sandboxed(ctx: AnalysisContext, category: str, script: Artifact, tree: cmd_args, outputs: cmd_args | list, inputs: list = [], identifier: str | None = None, env: dict[str, str] = {}, weight: int = 1):
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            ctx.attrs._sandbox,
            ctx.attrs._bwrap[RunInfo],
            ctx.attrs.state,
            ctx.attrs._phases,
            script,
            tree,
            outputs,
            hidden = inputs,
        ),
        category = category,
        identifier = identifier,
        env = env,
        weight = weight,
        # The sandbox needs unprivileged user namespaces, which remote
        # workers do not promise yet (ADR-0272).
        local_only = True,
    )

def _mix_release_impl(ctx: AnalysisContext) -> list[Provider]:
    name = "overalls-{}-0.1.0".format(ctx.attrs.application)
    self_reference = "/nix/store/{}-{}".format(ctx.attrs.out_hash, name)
    tree = _tree(ctx, ctx.attrs.srcs, "source")
    out = ctx.actions.declare_output(name, dir = True)
    refs = ctx.actions.declare_output("runtime-refs.txt")
    metadata = ctx.actions.write("overalls-release.json", ctx.attrs.release_metadata)
    script = ctx.actions.write("release.sh", [
        "out_hash=" + shell_quote(ctx.attrs.out_hash),
        "random_seed=" + shell_quote(ctx.attrs.random_seed or ctx.attrs.out_hash[:10]),
        "out_name=" + shell_quote(name),
        "declared_refs=" + shell_quote(" ".join(ctx.attrs.runtime_refs)),
    ] + _env_lines(ctx.attrs.env) + _var_lines({
        "name": name,
        "pname": "overalls-" + ctx.attrs.application,
        "version": "0.1.0",
        "sourceRoot": "source/" + ctx.attrs.project,
        "mixFodDeps": ctx.attrs.mix_deps,
        "preConfigure": "\n".join(ctx.attrs.pre_configure),
        "preBuild": "\n".join(ctx.attrs.pre_build),
        "postBuild": "\n".join(ctx.attrs.post_build),
        "postInstall": "\n".join(['cp /arg/2 "$out/overalls-release.json"'] + ctx.attrs.post_install),
    }) + [
        "mixCompileFlags=(--warnings-as-errors)",
        "mix_release",
    ])
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            ctx.attrs._sandbox,
            ctx.attrs._bwrap[RunInfo],
            ctx.attrs.state,
            ctx.attrs._phases,
            script,
            tree,
            cmd_args(out.as_output(), refs.as_output(), metadata),
        ),
        category = "mix_release",
        identifier = ctx.attrs.application,
        local_only = True,
    )
    return [
        DefaultInfo(default_output = out, sub_targets = {"runtime_refs": [DefaultInfo(default_output = refs)]}),
        RuntimeRefsInfo(refs = ctx.attrs.runtime_refs),
        MixReleaseInfo(self_reference = self_reference, application = ctx.attrs.application),
    ]

# Contracts mix-release-parity, mix-release-self-reference and
# mix-release-runtime-refs: see buck/CONTRACTS.
mix_release = rule(
    impl = _mix_release_impl,
    attrs = _SOURCE_ATTRS | {
        "application": attrs.string(),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "release_metadata": attrs.string(),
        "mix_deps": attrs.string(),
        "out_hash": attrs.string(),
        # stdenv's -frandom-seed, normally the output hash prefix. Parity runs
        # set it to the Nix release's so C NIFs compare byte for byte.
        "random_seed": attrs.string(default = ""),
        "post_build": attrs.list(attrs.string(), default = []),
        "post_install": attrs.list(attrs.string(), default = []),
        "pre_build": attrs.list(attrs.string(), default = []),
        "pre_configure": attrs.list(attrs.string(), default = []),
        "project": attrs.string(),
        "runtime_refs": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.dep(providers = [MixSourcesInfo])),
        "state": attrs.string(),
    } | _TOOLS,
)

def _mix_compile_impl(ctx: AnalysisContext) -> list[Provider]:
    tree = _tree(ctx, ctx.attrs.srcs, "source")
    state = ctx.actions.declare_output("mix-" + ctx.attrs.mix_env, dir = True)
    script = ctx.actions.write("compile.sh", [
        "project=" + shell_quote(ctx.attrs.project),
        "mixFodDeps=" + shell_quote(ctx.attrs.mix_deps),
        "preConfigure=" + shell_quote("\n".join(ctx.attrs.pre_configure)),
    ] + _env_lines(ctx.attrs.env | {"MIX_ENV": ctx.attrs.mix_env, "MIX_BUILD_PREFIX": ctx.attrs.mix_env}) + [
        "mix_compile",
    ])
    _run_sandboxed(ctx, "mix_compile", script, tree, [state.as_output()], identifier = ctx.attrs.mix_env)
    return [
        DefaultInfo(default_output = state),
        MixCompileInfo(state = state, env = ctx.attrs.mix_env, project = ctx.attrs.project),
    ]

_COMPILE_ATTRS = _SOURCE_ATTRS | {
    "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
    "labels": attrs.list(attrs.string(), default = []),
    "mix_deps": attrs.string(),
    "pre_configure": attrs.list(attrs.string(), default = []),
    "project": attrs.string(),
    "srcs": attrs.list(attrs.dep(providers = [MixSourcesInfo])),
    "state": attrs.string(),
}

# Contract mix-compile-shared-build: see buck/CONTRACTS.
mix_compile = rule(
    impl = _mix_compile_impl,
    attrs = _COMPILE_ATTRS | {"mix_env": attrs.string()} | _TOOLS,
)

def _restored_script(ctx: AnalysisContext, name: str, body: list[str], extra: dict[str, str] = {}) -> Artifact:
    compiled = ctx.attrs.compiled[MixCompileInfo]
    return ctx.actions.write(name, [
        "project=" + shell_quote(compiled.project),
        "mix_env=" + shell_quote(compiled.env),
        "preConfigure=" + shell_quote("\n".join(ctx.attrs.pre_configure)),
    ] + _env_lines(ctx.attrs.env | extra | {"MIX_ENV": compiled.env, "MIX_BUILD_PREFIX": compiled.env}) + body)

def _mix_check_impl(ctx: AnalysisContext) -> list[Provider]:
    compiled = ctx.attrs.compiled[MixCompileInfo]
    tree = _tree(ctx, ctx.attrs.srcs, "source")
    sub_targets = {}
    plt = None
    if ctx.attrs.dialyzer:
        plt = ctx.actions.declare_output("plt", dir = True)
        script = _restored_script(ctx, "plt.sh", ["mix_plt"])
        _run_sandboxed(ctx, "mix_plt", script, tree, cmd_args(compiled.state, plt.as_output()), identifier = "plt")
        sub_targets["plt"] = [DefaultInfo(default_output = plt)]
    for check, command in ctx.attrs.checks.items():
        result = ctx.actions.declare_output(check + ".log")
        script = _restored_script(ctx, check + ".sh", ["mix_check " + shell_quote(command)])
        outputs = cmd_args(compiled.state, result.as_output(), plt if check == "dialyzer" and plt else "-")
        _run_sandboxed(ctx, "mix_check", script, tree, outputs, identifier = check)
        sub_targets[check] = [DefaultInfo(default_output = result)]
    return [DefaultInfo(
        default_outputs = [v[0].default_outputs[0] for k, v in sub_targets.items() if k != "plt"],
        sub_targets = sub_targets,
    )]

# Contract mix-check-subtargets: see buck/CONTRACTS.
mix_check = rule(
    impl = _mix_check_impl,
    attrs = _SOURCE_ATTRS | {
        "checks": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "compiled": attrs.dep(providers = [MixCompileInfo]),
        "dialyzer": attrs.bool(default = False),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "pre_configure": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.dep(providers = [MixSourcesInfo])),
        "state": attrs.string(),
    } | _TOOLS,
)

# The repository-relative test files a project's `mix test` loads by default.
def _is_test_file(project: str, path: str) -> bool:
    return path.startswith(project + "/test/") and path.endswith("_test.exs")

def _stable_hash(text: str) -> int:
    """A hash of `text` that depends only on its bytes (FNV-1a, 31 bits)."""
    value = 2166136261
    for byte in text.elems():
        value = ((value ^ ord(byte)) * 16777619) % 2147483648
    return value

def _assign_shards(paths: list[str], shards: int, weights: dict[str, int]) -> list[list[str]]:
    """Deterministic test-file shards (contract mix-test-sharded).

    Files without a recorded weight go to the shard their path hashes to, so
    adding or editing one changes only that shard. Weighted files (the slow
    modules, in seconds) then go, heaviest first, to the least-loaded shard,
    counting each hashed file as one second."""
    buckets = [[] for _ in range(shards)]
    loads = [0 for _ in range(shards)]
    for path in paths:
        if path not in weights:
            index = _stable_hash(path) % shards
            buckets[index].append(path)
            loads[index] += 1
    for path in sorted([p for p in paths if p in weights], key = lambda p: (-weights[p], p)):
        index = 0
        for candidate in range(shards):
            if loads[candidate] < loads[index]:
                index = candidate
        buckets[index].append(path)
        loads[index] += weights[path]
    return [sorted(b) for b in buckets]

def _mix_test_impl(ctx: AnalysisContext) -> list[Provider]:
    compiled = ctx.attrs.compiled[MixCompileInfo]
    project = compiled.project
    shards = ctx.attrs.shards
    if shards < 1:
        fail("mix_test shards must be at least 1, got {}".format(shards))
    schedulers = ctx.attrs.schedulers
    files = _source_files(ctx.attrs.srcs)
    for path in ctx.attrs.shard_weights:
        if path not in files:
            fail("mix_test shard_weights names {}, which is not a declared test file".format(path))

    # Each shard is its own cacheable action with its own sandbox and
    # PostgreSQL, and its tree holds only its own test files, so a change to
    # one test file reruns one shard (contract mix-test-sharded). Files under
    # `repository_tests` read the whole repository; they form their own
    # shard, the only one that depends on `repository_srcs`.
    # Whole-module entries move their file into the known_failures shard;
    # `Module: test name` entries leave the file in the ordinary shards,
    # which skip only that test, and the known_failures shard runs only it.
    known_files = []
    known_paths = []
    known_filters = []
    known_excludes = []
    for f, entries in sorted(ctx.attrs.known_failures.items()):
        path = project + "/" + f
        if path not in files or not _is_test_file(project, path):
            fail("mix_test known_failures names {}, which is not a declared test file".format(path))
        known_paths.append(path)
        for entry in entries:
            module, sep, name = entry.partition(": ")
            if sep:
                known_filters += ["--only", "test:" + name]
                known_excludes += ["--exclude", "test:" + name]
            else:
                if path not in known_files:
                    known_files.append(path)
                known_filters += ["--only", "module:Elixir." + module]
    plans = []
    if shards == 1 and not ctx.attrs.repository_tests and not known_paths:
        plans.append(("shard-1", files, None))
    else:
        tests = sorted([p for p in files if _is_test_file(project, p)])
        repository = [p for p in tests if p not in known_files and any([p.startswith(project + "/" + prefix) for prefix in ctx.attrs.repository_tests])]
        ordinary = [p for p in tests if p not in repository and p not in known_files]
        others = {p: a for p, a in files.items() if not _is_test_file(project, p)}
        groups = [("shard-{}".format(i + 1), group, others) for i, group in enumerate(_assign_shards(ordinary, shards, ctx.attrs.shard_weights))]
        if repository:
            extra = dict(others)
            extra.update(_source_files(ctx.attrs.repository_srcs))
            groups.append(("repository", repository, extra))
        if known_paths:
            groups.append(("known_failures", sorted(known_paths), others))
        for name, group, base in groups:
            if not group:
                continue
            tree_files = dict(base)
            for path in group:
                tree_files[path] = files[path]
            plans.append((name, tree_files, [p[len(project) + 1:] for p in group]))

    results = []
    for index, (name, tree_files, selected) in enumerate(plans):
        tree = _tree_of(ctx, tree_files, "source-" + name)
        result = ctx.actions.declare_output("shards", name, dir = True)
        script = _restored_script(ctx, "test-{}.sh".format(name), [
            "postgres_bin=" + shell_quote(ctx.attrs.postgres),
            # Changes the action key only: a new salt reruns every shard with
            # fresh ExUnit and Hegel seeds (contract mix-test-seeds-explicit).
            "test_salt=" + shell_quote(ctx.attrs.seed_salt),
            "test_timeout=" + shell_quote("{}m".format(ctx.attrs.timeout_minutes)),
        ] + (["known_failures=" + shell_quote("\n".join([e for f in sorted(ctx.attrs.known_failures) for e in ctx.attrs.known_failures[f]]))] if name == "known_failures" else []) +
          (["export MIX_TEST_PARTITION={}".format(index + 1)] if selected != None else []) +
          (["export PATH={}:\"$PATH\"".format(shell_quote(":".join(ctx.attrs.path)))] if ctx.attrs.path else []) + [
            "mix_test " + " ".join([shell_quote(a) for a in ctx.attrs.args + (known_filters if name == "known_failures" else known_excludes) + (selected or [])]),
        ], extra = {"ERL_FLAGS": "+S {}:{}".format(schedulers, schedulers)})
        # Suites check TLS configuration against the OS trust store; releases
        # never see one, as in the Nix sandbox.
        _run_sandboxed(
            ctx,
            "mix_test",
            script,
            tree,
            cmd_args(compiled.state, result.as_output()),
            identifier = name,
            env = {"MIX_SANDBOX_CA_BUNDLE": ctx.attrs.ca_bundle} | ({"MIX_SANDBOX_CGROUP": "1"} if ctx.attrs.host_cgroup else {}) | ({"MIX_SANDBOX_HOST_IDENTITY": "1"} if ctx.attrs.host_identity else {}),
            weight = schedulers,
        )
        results.append((name, result))
    tree = _tree_of(ctx, files, "source")
    sub_targets = {name: [DefaultInfo(default_output = result)] for name, result in results}
    # Which shard runs which test file (null: the whole suite in one shard).
    sub_targets["shard_plan"] = [DefaultInfo(default_output = ctx.actions.write_json(
        "shard_plan.json",
        {name: selected for name, _, selected in plans},
    ))]
    # The aggregate: every shard's passing record under one directory. No
    # action runs; it exists only when every shard action succeeded.
    aggregate = ctx.actions.symlinked_dir("test_result", {name: result for name, result in results})
    sub_targets["test_result"] = [DefaultInfo(default_output = aggregate)]
    if ctx.attrs.covenant:
        covenant = ctx.actions.declare_output("covenant.log")
        check = _restored_script(ctx, "covenant.sh", ["mix_covenant {}".format(len(results))])
        _run_sandboxed(ctx, "mix_covenant", check, tree, cmd_args(compiled.state, covenant.as_output(), [result for _, result in results]), identifier = "covenant")
        sub_targets["covenant"] = [DefaultInfo(default_output = covenant)]
    runner = ctx.actions.write("report.sh", [
        "set -e",
        "status=0",
        "for shard in \"$@\"; do",
        "  cat \"$shard/test.log\"",
        "  [ \"$(cat \"$shard/status\")\" = 0 ] || status=1",
        "done",
        "exit \"$status\"",
    ])
    # Each run action fails on a failed shard, so building the target (as
    # tools/precommit does) is the whole check, and only passing shards are
    # cached.
    return [
        DefaultInfo(
            default_outputs = [result for _, result in results] + sub_targets.get("covenant", [DefaultInfo()])[0].default_outputs,
            sub_targets = sub_targets,
        ),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd_args(ctx.attrs._bash[RunInfo], runner, [result for _, result in results])],
            labels = ctx.attrs.labels,
            use_project_relative_paths = True,
        ),
    ]

# Contracts mix-test-cacheable-result, mix-test-sharded,
# mix-test-seeds-explicit and mix-test-hermetic-postgres: see buck/CONTRACTS.
mix_test = rule(
    impl = _mix_test_impl,
    attrs = _SOURCE_ATTRS | {
        "args": attrs.list(attrs.string(), default = []),
        # Directories put before the state's PATH, as devenv does for suites
        # that run native helpers.
        "path": attrs.list(attrs.string(), default = []),
        "compiled": attrs.dep(providers = [MixCompileInfo]),
        "covenant": attrs.bool(default = False),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "postgres": attrs.string(),
        "ca_bundle": attrs.string(default = ""),
        "pre_configure": attrs.list(attrs.string(), default = []),
        # BEAM schedulers per shard; also the action's local weight, so
        # Buck2 never runs more shard schedulers than it has job slots.
        "schedulers": attrs.int(default = 4),
        # Hard bound on one shard's `mix test`, in minutes.
        "timeout_minutes": attrs.int(default = 45),
        # Test files (relative to the project) under these prefixes read the
        # whole repository and run in their own `repository` shard.
        "repository_tests": attrs.list(attrs.string(), default = []),
        "repository_srcs": attrs.list(attrs.dep(providers = [MixSourcesInfo]), default = []),
        "seed_salt": attrs.string(default = ""),
        # Bind the host's /sys/fs/cgroup read-only (not part of the key).
        "host_cgroup": attrs.bool(default = False),
        # Bind the host's /etc/machine-id read-only and leave /nix/store the
        # read-only host store (no writable overlay), so root-owned system
        # files keep their host ownership (not part of the key).
        "host_identity": attrs.bool(default = False),
        # Project-relative test file -> its known failures (`Module` or
        # `Module: test name`). Those files run in the `known_failures` shard,
        # where only the listed failures are tolerated and are reported in
        # its known.txt (contract mix-test-known-failures).
        "known_failures": attrs.dict(attrs.string(), attrs.list(attrs.string()), default = {}),
        # Repository-relative test file -> seconds, for balancing slow files.
        "shard_weights": attrs.dict(attrs.string(), attrs.int(), default = {}),
        "shards": attrs.int(default = 1),
        "srcs": attrs.list(attrs.dep(providers = [MixSourcesInfo])),
        "state": attrs.string(),
    } | _TOOLS,
)

def _release_probe_impl(ctx: AnalysisContext) -> list[Provider]:
    release = ctx.attrs.release
    info = release[MixReleaseInfo]
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd_args(
                ctx.attrs._bash[RunInfo],
                ctx.attrs._probe,
                ctx.attrs._bwrap[RunInfo],
                ctx.attrs.state,
                release[DefaultInfo].default_outputs[0],
                info.application,
                info.self_reference,
                ctx.attrs.probe,
                ctx.attrs.tool_versions,
                ctx.attrs.toolchain_check,
                ctx.attrs.elixir_version,
                ctx.attrs.otp_version,
                ctx.attrs.ca_bundle,
            )],
            labels = ctx.attrs.labels,
            use_project_relative_paths = True,
        ),
    ]

# Contract mix-release-probe: see buck/CONTRACTS.
mix_release_probe = rule(
    impl = _release_probe_impl,
    attrs = {
        "ca_bundle": attrs.string(),
        "elixir_version": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "otp_version": attrs.string(),
        "probe": attrs.source(),
        "release": attrs.dep(providers = [MixReleaseInfo]),
        "state": attrs.string(),
        "tool_versions": attrs.source(),
        "toolchain_check": attrs.source(),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_bwrap": attrs.default_only(attrs.exec_dep(default = "toolchains//:bwrap")),
        "_probe": attrs.default_only(attrs.source(default = "root//buck:mix_release_probe.sh")),
    },
)

# ---------------------------------------------------------------------------
# Per-project macro. Configuration is read here, at load time, so every store
# path enters the target hash (contract nix-toolchain-paths-in-action-keys).

_ZERO_HASH = "00000000000000000000000000000000"

def mix_available() -> bool:
    """Whether the cells carry the [mix] section.

    Host-tool-only cells (Windows `--no-nix`, aarch64-darwin) omit it; there
    a package that declares a Mix project still loads, without its Mix
    targets, so non-Mix targets in it (or depending on it) keep working."""
    return bool(read_root_config("mix", "state_plain"))

def _mix_config(key: str) -> str:
    value = read_root_config("mix", key)
    if not value:
        fail("[mix] {} is missing; run tools/buck2 so .buck-cells is current".format(key))
    return value

_ENCRYPTED = "root//buck:encrypted_crash_dumps"
_HARNESS = "root//buck:antithesis_harness"
_GUEST = "root//buck:antithesis_guest"
_INTEGRATED = "root//buck:antithesis_integrated_host"

def _crash_dumps(encrypted, plain):
    return select({_ENCRYPTED: encrypted, "DEFAULT": plain})

def _json(value) -> str:
    """Nix builtins.toJSON: compact, object keys sorted."""
    if type(value) == "dict":
        return "{" + ",".join([json.encode(k) + ":" + _json(value[k]) for k in sorted(value.keys())]) + "}"
    return json.encode(value)

def _metadata(application: str, encrypted: bool, antithesis: str | None) -> str:
    data = {
        "application": application,
        "build": "nix-source",
        "elixir": _mix_config("elixir_version"),
        "encrypted_crash_dumps": encrypted,
        "format": 1,
        "otp": _mix_config("otp_version"),
        "platform": "x86_64-linux",
    }
    if antithesis != None:
        data["antithesis_sdk"] = True
        data["antithesis_guest"] = antithesis in ["guest", "integrated_host"] and application == "lilly"
        data["antithesis_integrated_host"] = antithesis == "integrated_host" and application == "lilly"
    if application == "lilly":
        vmm = _mix_config("vmm")
        data["host_tools"] = _mix_config("host_tools")
        data["firecracker"] = vmm + "/bin/firecracker"
        data["jailer"] = vmm + "/bin/jailer"
        data["unshare"] = _mix_config("util_linux_bin") + "/bin/unshare"
    return _json(data)

def _variant(application: str, f):
    """select() over the crash-dump and Antithesis selectors (ADR-0269)."""
    return select({
        _HARNESS: _crash_dumps(f(True, "harness"), f(False, "harness")),
        _GUEST: _crash_dumps(f(True, "guest"), f(False, "guest")),
        _INTEGRATED: _crash_dumps(f(True, "integrated_host"), f(False, "integrated_host")),
        "DEFAULT": _crash_dumps(f(True, None), f(False, None)),
    })

def _antithesis_env(application: str, antithesis: str | None) -> dict[str, str]:
    env = {}
    if antithesis != None:
        env["ANTITHESIS_HARNESS"] = "1"
        env["MIX_ENV"] = "prod"
        if application == "lilly" and antithesis in ["guest", "integrated_host"]:
            env["ANTITHESIS_GUEST"] = "1"
        if application == "lilly" and antithesis == "integrated_host":
            env["ANTITHESIS_INTEGRATED_HOST"] = "1"
    return env

def _release_env(application: str, encrypted: bool, antithesis: str | None, extra: dict[str, str]) -> dict[str, str]:
    env = {
        "ERL_CRASH_DUMP_PUBLIC_KEY": _mix_config("crash_dump_public_key") if encrypted else "",
        "ERL_FLAGS": "+S 4:4",
        "NIX_MAIN_PROGRAM": application,
    } | _antithesis_env(application, antithesis) | extra
    return env

def mix_cargo_vendor() -> list[str]:
    """preConfigure lines that point Cargo at the root workspace's vendored crates."""
    if not mix_available():
        return []
    vendor = _mix_config("cedar_vendor")
    return [
        'export CARGO_HOME="$TMPDIR/cargo-home"',
        "# Keep Rustler's build output beside the crate, not in the workspace root.",
        'export CARGO_TARGET_DIR="$PWD/native/marshall_cedar/target"',
        "# Panic locations name each vendored crate's source path. Remap the",
        "# vendor so the NIF does not retain the whole crate set at runtime.",
        'export RUSTFLAGS="--remap-path-prefix={}=/vendor"'.format(vendor),
        'mkdir -p "$CARGO_HOME"',
        'substitute {}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "{}"'.format(vendor, vendor),
    ]

def mix_esbuild_config() -> list[str]:
    """preConfigure lines that select the one Nix esbuild for asset builds."""
    if not mix_available():
        return []
    return [
        "cat >> config/prod.exs <<'CONFIG'",
        'config :esbuild, path: "{}", version: "{}"'.format(_mix_config("esbuild"), _mix_config("esbuild_version")),
        "CONFIG",
    ]

# Shared files that suites read from sibling projects: the scripts helpers,
# Marshall's TLS fixtures and the protocol's test support and vectors.
_TEST_SUPPORT = ["root//scripts:mix_support", "root//marshall:tls_fixtures", "root//protocol:test_fixtures"]

def overalls_mix_project(
        name: str,
        project: str,
        release_srcs: list[str],
        test_srcs: list[str],
        prefix: str = "",
        release: bool = True,
        antithesis_srcs: list[str] = [],
        release_env: dict[str, str] = {},
        pre_configure: list[str] = [],
        release_pre_configure: list[str] = [],
        post_build: list[str] = [],
        post_install: list[str] = [],
        test_env: dict[str, str] = {},
        test_support: list[str] = _TEST_SUPPORT,
        release_variants: dict[str, dict] = {},
        # Store trees copied over the compile and release sources only: test
        # and check actions restore the compiled build and read declared files.
        source_overlays: list[str] = [],
        test_path: list[str] | None = None,
        test_precommit: bool = True,
        release_reset_modes: bool = False,
        test_args: list[str] = ["--warnings-as-errors"],
        # Separately cached `mix test --partitions` actions, and BEAM
        # schedulers in each (contract mix-test-sharded).
        test_shards: int = 1,
        test_schedulers: int = 4,
        test_timeout_minutes: int = 45,
        test_shard_weights: dict[str, int] = {},
        test_known_failures: dict[str, list[str]] = {},
        test_host_cgroup: bool = False,
        test_host_identity: bool = False,
        test_labels: list[str] = [],
        repository_tests: list[str] = [],
        repository_support: list[str] = [],
        postgres: bool = False,
        checks: dict[str, str] = {},
        dialyzer: bool = True,
        covenant: bool = True):
    """Release, compile, check and test targets for one Mix project.

    `release_srcs` and `test_srcs` are mix_sources targets: the first mirrors
    the Nix release source allowlist, the second adds tests and checks.
    Without the cells' [mix] section it defines nothing (mix_available).
    """
    if not mix_available():
        return
    # Suites run openssl, ssh-keygen and python3, which devenv takes from PATH.
    if test_path == None:
        test_path = [_mix_config("test_tools")]
    state_plain = _mix_config("state_plain")
    state = _crash_dumps(_mix_config("state_encrypted"), state_plain)
    compile_env = {
        "HEGEL_NIF_PATH": _mix_config("hegel_nif"),
        "OVERALLS_GIT_BIN": _mix_config("git"),
        "ERL_FLAGS": "+S 4:4",
    } | test_env

    mix_compile(
        overlays = source_overlays,
        name = prefix + "compile_test",
        project = project,
        mix_env = "test",
        mix_deps = _mix_config("deps_{}_test".format(name)),
        srcs = test_srcs + _TEST_SUPPORT,
        state = state_plain,
        env = compile_env,
        pre_configure = pre_configure,
        visibility = ["PUBLIC"],
    )
    mix_test(
        # The Cedar NIF's Rustler checks run `cargo metadata`, which needs the
        # root Cargo workspace overlay in every shard, not only the
        # repository shard.
        overlays = source_overlays,
        name = prefix + "test",
        compiled = ":" + prefix + "compile_test",
        srcs = test_srcs + test_support,
        state = state_plain,
        env = compile_env,
        pre_configure = pre_configure,
        args = test_args,
        shards = test_shards,
        schedulers = test_schedulers,
        timeout_minutes = test_timeout_minutes,
        shard_weights = test_shard_weights,
        known_failures = test_known_failures,
        host_cgroup = test_host_cgroup,
        host_identity = test_host_identity,
        repository_tests = repository_tests,
        repository_srcs = repository_support,
        seed_salt = read_root_config("mix", "test_salt", ""),
        path = test_path,
        postgres = _mix_config("postgres") if postgres else "",
        ca_bundle = _mix_config("ca_bundle"),
        covenant = covenant,
        # tools/precommit selects the "precommit" label (buck/bxl/precommit.bxl).
        labels = ["mix", "check", "expensive"] + (["precommit"] if test_precommit else []) + test_labels,
        visibility = ["PUBLIC"],
    )
    mix_check(
        # `gettext.extract` recompiles the project, Rustler NIFs included,
        # so checks see the same overlays as the compile.
        overlays = source_overlays,
        name = prefix + "check",
        compiled = ":" + prefix + "compile_test",
        srcs = test_srcs + test_support,
        state = state_plain,
        env = compile_env,
        pre_configure = pre_configure,
        dialyzer = dialyzer,
        checks = {"format": "format --check-formatted"} |
                 ({"logging": "logging.check"} if release else {}) | ({"dialyzer": "dialyzer --force-check --no-compile"} if dialyzer else {}) | checks,
        labels = ["mix", "check", "precommit"],
        visibility = ["PUBLIC"],
    )
    if not release:
        return

    mix_compile(
        overlays = source_overlays,
        name = prefix + "compile",
        project = project,
        mix_env = "prod",
        mix_deps = _mix_config("deps_{}_prod".format(name)),
        srcs = release_srcs,
        state = state_plain,
        env = {"ERL_FLAGS": "+S 4:4"},
        pre_configure = pre_configure,
        visibility = ["PUBLIC"],
    )
    deps = _mix_config("deps_{}_prod".format(name))
    # Fixture variants (fleet update and instrumentation tests) patch sources
    # before compilation or add files after `mix release`, replacing the Nix
    # `overrideAttrs` preBuild/postInstall hooks (contract mix-release-variants).
    for variant, patch in ({"": {}} | release_variants).items():
        mix_release(
            overlays = source_overlays,
            reset_modes = release_reset_modes,
            name = prefix + "release" + ("_" + variant if variant else ""),
            application = name,
            project = project,
            srcs = release_srcs + patch.get("srcs", []) + select({
                _HARNESS: antithesis_srcs,
                _GUEST: antithesis_srcs,
                _INTEGRATED: antithesis_srcs,
                "DEFAULT": [],
            }),
            mix_deps = deps,
            state = state,
            out_hash = _ZERO_HASH,
            random_seed = read_root_config("mix", "random_seed_" + name, ""),
            env = _variant(name, lambda encrypted, antithesis: _release_env(name, encrypted, antithesis, release_env)),
            release_metadata = _variant(name, lambda encrypted, antithesis: _metadata(name, encrypted, antithesis)),
            pre_configure = [
                "# A fixed-output fetch can be reused from cache after inputs change.",
                "# Reject a stale hash rather than compiling old deps against a new lock.",
                'cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"',
            ] + pre_configure + release_pre_configure,
            pre_build = patch.get("pre_build", []),
            post_build = post_build,
            post_install = post_install + patch.get("post_install", []),
            runtime_refs = _mix_config("runtime_refs").split(),
            labels = ["mix", "release"] + (["fixture"] if variant else []),
            visibility = ["PUBLIC"],
        )
        # The release as a store path for nix_assemble's `artifacts`; assembly
        # rewrites the placeholder to the imported path (contract
        # mix-release-self-reference).
        nix_store_import(
            name = prefix + name + "_import" + ("_" + variant if variant else ""),
            src = ":" + prefix + "release" + ("_" + variant if variant else ""),
            self_reference = "/nix/store/{}-overalls-{}-0.1.0".format(_ZERO_HASH, name),
            visibility = ["PUBLIC"],
        )
    mix_release_probe(
        name = prefix + "release_probe",
        release = ":" + prefix + "release",
        state = state,
        probe = "root//nix:release_probe.exs",
        tool_versions = "root//:.tool-versions",
        toolchain_check = "root//scripts:check_toolchain.exs",
        elixir_version = _mix_config("elixir_version"),
        otp_version = _mix_config("otp_version"),
        ca_bundle = _mix_config("ca_bundle"),
        labels = ["mix", "release_probe"],
        visibility = ["PUBLIC"],
    )

def mix_tree(dirs: list[str] = [], files: list[str] = [], exclude: list[str] = []) -> list[str]:
    """Files under `dirs` (dotfiles included) plus `files`, minus `exclude`."""
    include = files + [p for d in dirs for p in [d + "/**", d + "/**/.*", d + "/**/.*/**"]]
    return native.glob(include, exclude = exclude + ["**/BUCK"])

def mix_host_tools_link() -> list[str]:
    """postInstall line that links Lilly's host tools into its release."""
    if not mix_available():
        return []
    return ['ln -s {} "$out/host-tools"'.format(_mix_config("host_tools"))]
