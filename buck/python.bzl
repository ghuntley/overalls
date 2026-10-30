# The repository Python gate (ADR-0269, M7).
# Contract py-static-prek-parity: see buck/CONTRACTS.
# Contract python-static-repository-root: see nix/verification/tests/evaluation/python-static.nix.

load(":checks.bzl", "PrecommitInfo", "check_providers", "first_artifact", "owned_paths", "search_path", "tool", "tool_attr")

_RUFF = [
    "set -euo pipefail",
    "stamp=$1; shift",
    "status=0",
    "\"$RUFF\" format --check --no-cache --force-exclude \"$@\" || status=1",
    "\"$RUFF\" check --no-cache --force-exclude \"$@\" || status=1",
    "[ \"$status\" = 0 ] && touch \"$stamp\"",
]

_STATIC = [
    "set -euo pipefail",
    "stamp=$1 files=$2",
    "scratch=$(mkdir -p \"$BUCK_SCRATCH_PATH\" && cd \"$BUCK_SCRATCH_PATH\" && pwd)",
    "export HOME=\"$scratch/home\" XDG_CACHE_HOME=\"$scratch/cache\" LC_ALL=C.UTF-8",
    # Run every gate before failing so one run reports all findings, as prek does.
    "status=0",
    "xargs -d '\\n' -a \"$files\" \"$RUFF\" format --check --no-cache --force-exclude || status=1",
    "xargs -d '\\n' -a \"$files\" \"$RUFF\" check --no-cache --force-exclude || status=1",
    "bash antithesis/verification/static-check.sh \"$TY\" \"$PYTHON_STATIC\" \"$PYTHON_HARNESS\" \"$ANTITHESIS_WHEELS\" || status=1",
    "[ \"$status\" = 0 ] && touch \"$stamp\"",
]

# ty alone over every tree: the cross-file part precommit runs beside the
# per-file ruff sub-targets.
_TY = [
    "set -euo pipefail",
    "stamp=$1",
    "scratch=$(mkdir -p \"$BUCK_SCRATCH_PATH\" && cd \"$BUCK_SCRATCH_PATH\" && pwd)",
    "export HOME=\"$scratch/home\" XDG_CACHE_HOME=\"$scratch/cache\" LC_ALL=C.UTF-8",
    "bash antithesis/verification/static-check.sh \"$TY\" \"$PYTHON_STATIC\" \"$PYTHON_HARNESS\" \"$ANTITHESIS_WHEELS\"",
    "touch \"$stamp\"",
]

# The fixed copy of one file: ruff's safe fixes, then ruff format, through
# stdin with the file's repository path so per-path configuration applies.
_FIX = [
    "set -euo pipefail",
    "out=$1 src=$2 path=$3",
    "\"$RUFF\" check --no-cache --force-exclude --fix --exit-zero --quiet --stdin-filename \"$path\" - < \"$src\" > \"$out.fixed\"",
    "\"$RUFF\" format --no-cache --force-exclude --quiet --stdin-filename \"$path\" - < \"$out.fixed\" > \"$out\"",
    "rm \"$out.fixed\"",
]

def _py_static_impl(ctx: AnalysisContext) -> list[Provider]:
    owned = owned_paths(ctx.attrs.owned)
    files = {path: f for path, f in owned.items() if path.endswith(".py")}
    env = {
        "ANTITHESIS_WHEELS": tool(ctx.attrs._antithesis_wheels),
        "PATH": search_path([ctx.attrs._coreutils, ctx.attrs._findutils, ctx.attrs._bash]),
        "PYTHON_HARNESS": tool(ctx.attrs._python_harness),
        "PYTHON_STATIC": tool(ctx.attrs._python_static),
        "RUFF": tool(ctx.attrs._ruff),
        "TY": tool(ctx.attrs._ty),
    }
    config = [owned[ctx.attrs.pyproject]]

    ruff = ctx.actions.write("ruff.sh", _RUFF)
    fix = ctx.actions.write("fix.sh", _FIX)
    sub_targets = {}
    for path, f in sorted(files.items()):
        stamp = ctx.actions.declare_output("ruff/" + path + ".ok")
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), ruff, stamp.as_output(), f, hidden = config),
            env = env,
            category = "ruff",
            identifier = path,
        )
        sub_targets["ruff/" + path] = [DefaultInfo(default_output = stamp)]
        fixed = ctx.actions.declare_output("fix/" + path)
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), fix, fixed.as_output(), f, path, hidden = config),
            env = env,
            category = "ruff_fix",
            identifier = path,
        )
        sub_targets["fix/" + path] = [DefaultInfo(default_output = fixed)]

    static_inputs = config + [owned[ctx.attrs.static_check]] + list(files.values())
    listing = ctx.actions.write("files", [cmd_args(f) for _, f in sorted(files.items())], allow_args = True)
    stamp = ctx.actions.declare_output("stamp")
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._bash),
            ctx.actions.write("static.sh", _STATIC),
            stamp.as_output(),
            first_artifact(listing),
            hidden = static_inputs,
        ),
        env = env,
        category = "py_static",
    )
    ty = ctx.actions.declare_output("ty.ok")
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), ctx.actions.write("ty.sh", _TY), ty.as_output(), hidden = static_inputs),
        env = env,
        category = "ty",
    )
    sub_targets["ty"] = [DefaultInfo(default_output = ty)]

    # Contract precommit-info-selection: see buck/CONTRACTS.
    return check_providers(ctx, stamp, sub_targets) + [PrecommitInfo(
        deletions = ["*.py"],
        fix = {path: "fix/" + path for path in files},
        inputs = {path: True for path in files.keys() + [ctx.attrs.pyproject, ctx.attrs.static_check]},
        per_file = {path: ["ruff/" + path] for path in files},
        shared = ["ty"],
    )]

# ruff format --check, ruff check and ty over every owned Python file from the
# repository root with its pyproject.toml. `[ruff/<path>]` sub-targets check one
# file, so precommit can run only the changed files.
py_static = rule(
    impl = _py_static_impl,
    attrs = {
        "labels": attrs.list(attrs.string(), default = []),
        "owned": attrs.list(attrs.dep()),
        # Repository-relative paths within `owned`.
        "pyproject": attrs.string(default = "pyproject.toml"),
        "static_check": attrs.string(default = "antithesis/verification/static-check.sh"),
        "_antithesis_wheels": tool_attr("antithesis_wheels"),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_findutils": tool_attr("findutils"),
        "_python_harness": tool_attr("python_harness"),
        "_python_static": tool_attr("python_static"),
        "_ruff": tool_attr("ruff"),
        "_ty": tool_attr("ty"),
    },
)
