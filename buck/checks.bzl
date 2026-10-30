# Shared helpers for M7 language rules and script checks (ADR-0269).

load("@toolchains//:nix.bzl", "NixToolInfo")

def tool(dep: Dependency) -> str:
    return dep[NixToolInfo].path

# The bin directory of a nix_tool: the path itself when it is a bin directory,
# <store path>/bin for a package root, otherwise the executable's directory.
def bin_dir(dep: Dependency) -> str:
    path = tool(dep)
    if path.endswith("/bin"):
        return path
    if len(path.split("/")) == 4:
        return path + "/bin"
    return path.rsplit("/", 1)[0]

def search_path(deps: list[Dependency]) -> str:
    return ":".join([bin_dir(d) for d in deps])

def tool_attr(name: str) -> Attr:
    return attrs.default_only(attrs.exec_dep(default = "toolchains//:" + name))

# A check is a cacheable build action whose output is a stamp. `buck2 build`
# runs it once per input hash; `buck2 test` only reads the stamp, so a passing
# result is reused from the action cache instead of rerun.
def check_providers(ctx: AnalysisContext, stamp: Artifact, sub_targets: dict = {}) -> list[Provider]:
    return [
        DefaultInfo(default_output = stamp, sub_targets = sub_targets),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd_args(tool(ctx.attrs._coreutils) + "/cat"), stamp],
            labels = ctx.attrs.labels,
        ),
    ]

# Every file of a nix_owned package as individual source artifacts keyed by
# repository-relative path, so checks can address one file (precommit) or all
# of them (CI).
OwnedFilesInfo = provider(fields = {"files": dict[str, Artifact]})

def _owned_files_impl(ctx: AnalysisContext) -> list[Provider]:
    prefix = ctx.attrs.prefix + "/" if ctx.attrs.prefix else ""
    files = {prefix + f.short_path: f for f in ctx.attrs.srcs}
    return [DefaultInfo(other_outputs = ctx.attrs.srcs), OwnedFilesInfo(files = files)]

owned_files = rule(impl = _owned_files_impl, attrs = {
    "prefix": attrs.string(),
    "srcs": attrs.list(attrs.source()),
})

# Repository-relative path -> artifact over several owned_files targets.
def owned_paths(deps: list[Dependency]) -> dict[str, Artifact]:
    files = {}
    for d in deps:
        files.update(d[OwnedFilesInfo].files)
    return files

def _script_check_impl(ctx: AnalysisContext) -> list[Provider]:
    stamp = ctx.actions.declare_output("stamp")
    script = ctx.actions.write("check.sh", [
        "set -euo pipefail",
        "stamp=$1; shift",
        "scratch=$(mkdir -p \"$BUCK_SCRATCH_PATH\" && cd \"$BUCK_SCRATCH_PATH\" && pwd)",
        "export HOME=\"$scratch/home\" TMPDIR=\"$scratch\" LC_ALL=C.UTF-8",
        "mkdir -p \"$HOME\"",
        "\"$@\"",
        "touch \"$stamp\"",
    ])
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._bash),
            script,
            stamp.as_output(),
            ctx.attrs.cmd,
            hidden = ctx.attrs.srcs,
        ),
        env = {"PATH": search_path(ctx.attrs.path + [ctx.attrs._coreutils])},
        category = "script_check",
    )
    return check_providers(ctx, stamp)

# Runs one command over declared inputs from the project root; the stamp is the
# cached pass result.
script_check = rule(
    impl = _script_check_impl,
    attrs = {
        "cmd": attrs.list(attrs.arg()),
        "labels": attrs.list(attrs.string(), default = []),
        "path": attrs.list(attrs.exec_dep(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
    },
)

# Contract conflict-markers-per-file: see buck/CONTRACTS.
def _conflict_markers_impl(ctx: AnalysisContext) -> list[Provider]:
    files = owned_paths(ctx.attrs.owned)
    env = {
        "LC_ALL": "C.UTF-8",
        "PATH": search_path([ctx.attrs._erlang, ctx.attrs._coreutils, ctx.attrs._findutils]),
    }
    elixir = tool(ctx.attrs._elixir) + "/bin/elixir"
    run = ctx.actions.write("markers.sh", [
        "set -euo pipefail",
        "stamp=$1 elixir=$2 script=$3 files=$4",
        "export HOME=$(mkdir -p \"$BUCK_SCRATCH_PATH/home\" && cd \"$BUCK_SCRATCH_PATH/home\" && pwd)",
        "xargs -d '\\n' -a \"$files\" \"$elixir\" \"$script\"",
        "touch \"$stamp\"",
    ])
    script = files[ctx.attrs.script]
    hidden = [files[ctx.attrs.library]]
    sub_targets = {}
    for path, f in sorted(files.items()):
        stamp = ctx.actions.declare_output("markers/" + path + ".ok")
        listing = ctx.actions.write("markers/" + path + ".list", [cmd_args(f)], allow_args = True)
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), run, stamp.as_output(), elixir, script, first_artifact(listing), hidden = hidden + [f]),
            env = env,
            category = "conflict_markers",
            identifier = path,
        )
        sub_targets[path] = [DefaultInfo(default_output = stamp)]
    stamp = ctx.actions.declare_output("stamp")
    listing = ctx.actions.write("files", [cmd_args(f) for _, f in sorted(files.items())], allow_args = True)
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), run, stamp.as_output(), elixir, script, first_artifact(listing), hidden = hidden + list(files.values())),
        env = env,
        category = "conflict_markers",
        identifier = "all",
    )
    return check_providers(ctx, stamp, sub_targets)

def first_artifact(written) -> Artifact:
    return written[0] if type(written) == "tuple" else written

# scripts/check_conflict_markers.exs over every owned file; `[<path>]`
# sub-targets check one file each.
conflict_markers = rule(
    impl = _conflict_markers_impl,
    attrs = {
        "labels": attrs.list(attrs.string(), default = []),
        # Repository-relative paths within `owned`.
        "library": attrs.string(default = "scripts/conflict_markers.ex"),
        "owned": attrs.list(attrs.dep()),
        "script": attrs.string(default = "scripts/check_conflict_markers.exs"),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_elixir": tool_attr("elixir"),
        "_erlang": tool_attr("erlang"),
        "_findutils": tool_attr("findutils"),
    },
)
