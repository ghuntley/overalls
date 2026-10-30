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
            # Reading a stamp never goes remote (script-tests-run-locally).
            default_executor = CommandExecutorConfig(local_enabled = True, remote_enabled = False, remote_cache_enabled = False),
        ),
    ]

# Contract precommit-info-selection: see buck/CONTRACTS.
# How buck/bxl/precommit.bxl selects the work of a `precommit`-labelled check
# for a set of changed files. A check without this provider falls back to its
# default output whenever an owner of a changed file is among its deps.
#   inputs:    repository paths the whole check reads; a changed path outside
#              it never selects the check.
#   per_file:  path -> sub-targets that check that file alone. When every
#              changed input has an entry, precommit builds only those (and
#              `shared`) instead of the default output.
#   shared:    sub-targets built once alongside per-file ones and for matching
#              deletions: the cross-file part of the check (ty, for example).
#   fix:       path -> sub-target whose single output is the fixed file;
#              `tools/precommit --fix` copies it over the source.
#   deletions: patterns (see path_matches) of deleted paths that select the
#              check: per-file checks then build `shared`, others the default.
PrecommitInfo = provider(fields = {
    "deletions": list[str],
    "fix": dict[str, str],
    "inputs": dict[str, bool],
    "per_file": dict[str, list[str]],
    "shared": list[str],
})

# One `*` matches any characters, `/` included; a pattern without `*` is an
# exact path. `docs/architecture/*`, `*.py`, `marshall/lib/*.ex`, `flake.lock`.
def path_matches(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if "*" not in pattern:
            if path == pattern:
                return True
            continue
        head, tail = pattern.split("*", 1)
        if len(path) >= len(head) + len(tail) and path.startswith(head) and path.endswith(tail):
            return True
    return False

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
    # The checker itself is not a per-file input: changing it reruns the whole
    # check. Deleted files cannot hold markers.
    checker = [ctx.attrs.script, ctx.attrs.library]
    return check_providers(ctx, stamp, sub_targets) + [PrecommitInfo(
        deletions = [],
        fix = {},
        inputs = {path: True for path in files},
        per_file = {path: [path] for path in files if path not in checker},
        shared = [],
    )]

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

_REPO_CHECK = [
    "set -euo pipefail",
    "stamp=$1; shift",
    "scratch=$(mkdir -p \"$BUCK_SCRATCH_PATH\" && cd \"$BUCK_SCRATCH_PATH\" && pwd)",
    "export HOME=\"$scratch/home\" TMPDIR=\"$scratch\" XDG_CACHE_HOME=\"$scratch/cache\" LC_ALL=C.UTF-8",
    "mkdir -p \"$HOME\"",
    # A daemon started from a Git hook would otherwise leak the hook's index
    # and directory into the checks' own git calls.
    "for v in $(compgen -e); do case $v in GIT_*) unset \"$v\" ;; esac; done",
    "\"$@\"",
    "touch \"$stamp\"",
]

# Contract repo-check-declared-inputs: see buck/CONTRACTS.
def _repo_check_impl(ctx: AnalysisContext) -> list[Provider]:
    owned = owned_paths(ctx.attrs.owned)
    inputs = {path: f for path, f in owned.items() if path_matches(path, ctx.attrs.include)}
    hidden = list(inputs.values())
    if ctx.attrs.inventory:
        # The owned path set, so adding or deleting any file changes the key of
        # checks that test for a file's existence (ADR evidence links).
        hidden.append(first_artifact(ctx.actions.write("inventory", sorted(owned.keys()))))
    stamp = ctx.actions.declare_output("stamp")
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), ctx.actions.write("check.sh", _REPO_CHECK), stamp.as_output(), ctx.attrs.cmd, hidden = hidden),
        env = dict({"PATH": search_path(ctx.attrs.path + [ctx.attrs._coreutils])}, **ctx.attrs.env),
        category = "repo_check",
        # Checks that list files through git read the checkout's .git.
        local_only = ctx.attrs.local_only,
        allow_cache_upload = not ctx.attrs.local_only,
    )
    return check_providers(ctx, stamp) + [PrecommitInfo(
        deletions = ctx.attrs.deletions if ctx.attrs.deletions != None else ctx.attrs.include,
        fix = {},
        inputs = {path: True for path in inputs},
        per_file = {},
        shared = [],
    )]

# A repository-wide check: one command from the project root over the owned
# files matching `include` (path_matches patterns). precommit runs it once,
# and only when one of those files changes or a `deletions` path is deleted.
repo_check = rule(
    impl = _repo_check_impl,
    attrs = {
        "cmd": attrs.list(attrs.arg()),
        # Deleted-path patterns; defaults to `include`.
        "deletions": attrs.option(attrs.list(attrs.string()), default = None),
        "env": attrs.dict(attrs.string(), attrs.arg(), default = {}),
        "include": attrs.list(attrs.string()),
        "inventory": attrs.bool(default = False),
        "labels": attrs.list(attrs.string(), default = []),
        "local_only": attrs.bool(default = False),
        "owned": attrs.list(attrs.dep()),
        "path": attrs.list(attrs.exec_dep(), default = []),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
    },
)

# Contract contract-check-per-file: see buck/CONTRACTS.
def _contract_check_impl(ctx: AnalysisContext) -> list[Provider]:
    owned = owned_paths(ctx.attrs.owned)
    env = {
        "LC_ALL": "C.UTF-8",
        "NODE": tool(ctx.attrs._node) + "/node",
        "OVERALLS_CODE_CONTRACTS_NODE_MODULES": tool(ctx.attrs._node_modules),
        "PATH": search_path([ctx.attrs._node, ctx.attrs._git, ctx.attrs._coreutils]),
    }
    script = ctx.actions.write("contracts.sh", _REPO_CHECK)
    checker = [owned[p] for p in ctx.attrs.checker]
    sub_targets = {}
    per_file = {}
    for path, f in sorted(owned.items()):
        if path.rsplit("/", 1)[-1] == "CONTRACTS" or path in ctx.attrs.checker:
            continue
        # The file's ancestor CONTRACTS are its only other inputs.
        parts = path.split("/")
        ancestors = [owned[c] for c in ["/".join(parts[:i] + ["CONTRACTS"]) for i in range(len(parts))] if c in owned]
        stamp = ctx.actions.declare_output("contracts/" + path + ".ok")
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), env["NODE"], ctx.attrs.checker[0], "files", path, hidden = checker + ancestors + [f]),
            env = env,
            category = "contracts",
            identifier = path,
        )
        sub_targets["contracts/" + path] = [DefaultInfo(default_output = stamp)]
        per_file[path] = ["contracts/" + path]
    stamp = ctx.actions.declare_output("stamp")
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), env["NODE"], ctx.attrs.checker[0], "format", hidden = list(owned.values())),
        env = env,
        category = "contracts",
        identifier = "all",
        # The repository inventory comes from git ls-files in the checkout.
        local_only = True,
        allow_cache_upload = False,
    )
    return check_providers(ctx, stamp, sub_targets) + [PrecommitInfo(
        deletions = ["*CONTRACTS"],
        fix = {},
        inputs = {path: True for path in owned},
        per_file = per_file,
        shared = [],
    )]

# scripts/check_contracts.mjs over the repository: `format` (syntax, ID
# uniqueness and coverage) as the default output, and `[contracts/<path>]`
# checking one file with its ancestor CONTRACTS (`files <path>`). Changing a
# CONTRACTS file or the checker reruns the whole check.
contract_check = rule(
    impl = _contract_check_impl,
    attrs = {
        # Repository-relative paths within `owned`; the first is the checker.
        "checker": attrs.list(attrs.string(), default = ["scripts/check_contracts.mjs", "tools/code-contracts/package.json", "tools/code-contracts/package-lock.json"]),
        "labels": attrs.list(attrs.string(), default = []),
        "owned": attrs.list(attrs.dep()),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_git": tool_attr("git"),
        "_node": tool_attr("node"),
        "_node_modules": tool_attr("code_contracts_node_modules"),
    },
)
