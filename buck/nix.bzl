# Nix boundary rules for the Buck2 migration (ADR-0269).

load(":checks.bzl", "owned_files")

# Contract nix-owned-files: see buck/CONTRACTS.
# `<name>_files` exposes the same files individually (OwnedFilesInfo) for the
# per-file checks: conflict markers and the Python gate.
def nix_owned(name: str = "srcs", srcs = None, **kwargs):
    files = srcs if srcs != None else native.glob(["**", "**/.*", "**/.*/**"], exclude = ["BUCK"])
    native.filegroup(
        name = name,
        srcs = files,
        visibility = ["PUBLIC"],
        **kwargs
    )
    # The toolchains cell is the repository's toolchains/ directory.
    cell = "toolchains" if native.get_cell_name() == "toolchains" else ""
    prefix = "/".join([p for p in [cell, native.package_name()] if p])
    owned_files(name = name + "_files", prefix = prefix, srcs = files, visibility = ["PUBLIC"])

def _nix_flake_attr_impl(ctx: AnalysisContext) -> list[Provider]:
    link = ctx.actions.declare_output("result")
    path = ctx.actions.declare_output("store-path")
    script = ctx.actions.write("build.sh", [
        "set -euo pipefail",
        "out=$(\"$1\" build --print-out-paths --out-link \"$2\" \".#$3\")",
        "printf '%s\\n' \"$out\" > \"$4\"",
    ])
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            script,
            ctx.attrs._nix[RunInfo],
            link.as_output(),
            ctx.attrs.attr,
            path.as_output(),
            hidden = [s for d in ctx.attrs.srcs for s in d[DefaultInfo].default_outputs + d[DefaultInfo].other_outputs],
        ),
        category = "nix_flake_attr",
        local_only = True,
        allow_cache_upload = False,
    )
    return [DefaultInfo(default_output = path, other_outputs = [link])]

# Contract nix-flake-attr-bootstrap-only: see buck/CONTRACTS.
nix_flake_attr = rule(
    impl = _nix_flake_attr_impl,
    attrs = {
        "attr": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.dep(), default = ["root//:flake_srcs"]),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
    },
)

# Package-relative source directories, so assembly can rebuild the tree.
OwnedSrcsInfo = provider(fields = {"dirs": list[(str, Artifact)]})

def _owned_set_impl(ctx: AnalysisContext) -> list[Provider]:
    dirs = [(d.label.package, o) for d in ctx.attrs.deps for o in d[DefaultInfo].default_outputs]
    return [DefaultInfo(other_outputs = [o for _, o in dirs]), OwnedSrcsInfo(dirs = dirs)]

# Union of owned file groups whose outputs share short paths across packages.
owned_set = rule(impl = _owned_set_impl, attrs = {"deps": attrs.list(attrs.dep())})

def _nix_store_run_impl(ctx: AnalysisContext) -> list[Provider]:
    built = ctx.attrs.package[DefaultInfo]
    store_path = built.default_outputs[0]
    return [
        DefaultInfo(default_output = store_path, other_outputs = built.other_outputs),
        RunInfo(args = cmd_args(
            ctx.attrs._bash[RunInfo],
            "-c",
            "p=$(cat \"$1\"); shift; exec \"$p/{}\" \"$@\"".format(ctx.attrs.program),
            "nix_store_run",
            store_path,
        )),
    ]

# Runs `program` from a store path that a dependency built: today a bootstrap
# nix_flake_attr, later the nix_assemble target that replaces it (M3), so the
# runnable label stays stable across that move.
nix_store_run = rule(
    impl = _nix_store_run_impl,
    attrs = {
        "package": attrs.dep(),
        "program": attrs.string(),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
    },
)
