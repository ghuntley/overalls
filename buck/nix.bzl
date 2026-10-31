# Nix boundary rules for the Buck2 migration (ADR-0269).

load(":checks.bzl", "owned_files")

# Contract nix-owned-files: see buck/CONTRACTS.
# `<name>_files` exposes the same files individually (OwnedFilesInfo) for the
# per-file checks: conflict markers and the Python gate.
def nix_owned(name: str = "srcs", srcs = None, **kwargs):
    files = srcs if srcs != None else native.glob(["**", "**/.*", "**/.*/**"], exclude = ["BUCK", "BUCK.v2"])
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
    path = ctx.actions.declare_output("store-path")
    script = ctx.actions.write("build.sh", [
        "set -euo pipefail",
        "roots=${OVERALLS_GCROOT_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/overalls-buck2/gcroots}",
        "mkdir -p \"$roots\"",
        "out=$(\"$1\" build --print-out-paths --out-link \"$roots/$(pwd | sha256sum | cut -c1-12)-$2\" \".#$3\")",
        "printf '%s\\n' \"$out\" > \"$4\"",
    ])
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            script,
            ctx.attrs._nix[RunInfo],
            str(ctx.label.raw_target()).replace("/", "_").replace(":", "__"),
            ctx.attrs.attr,
            path.as_output(),
            hidden = [s for d in ctx.attrs.srcs for s in d[DefaultInfo].default_outputs + d[DefaultInfo].other_outputs],
        ),
        category = "nix_flake_attr",
        local_only = True,
        allow_cache_upload = False,
    )
    # `[drv]` evaluates the attribute without building it, so CI can check
    # every affected bootstrap check per push (evaluation-only assertions in
    # a check are otherwise found only by publish-cache.yml).
    drv = ctx.actions.declare_output("drv-path")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            "-c",
            "set -euo pipefail; \"$1\" eval --raw \".#$2.drvPath\" > \"$3\"",
            "nix_flake_attr_drv",
            ctx.attrs._nix[RunInfo],
            ctx.attrs.attr,
            drv.as_output(),
            hidden = [s for d in ctx.attrs.srcs for s in d[DefaultInfo].default_outputs + d[DefaultInfo].other_outputs],
        ),
        category = "nix_flake_attr_drv",
        local_only = True,
        allow_cache_upload = False,
        weight_percentage = 25,
    )
    return [DefaultInfo(default_output = path, sub_targets = {"drv": [DefaultInfo(default_output = drv)]})]

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

def _owned_dir(label: Label) -> str:
    # The toolchains cell is the repository's toolchains/ directory.
    cell = "toolchains" if label.cell == "toolchains" else ""
    return "/".join([p for p in [cell, label.package] if p])

def _owned_set_impl(ctx: AnalysisContext) -> list[Provider]:
    dirs = [(_owned_dir(d.label), o) for d in ctx.attrs.deps for o in d[DefaultInfo].default_outputs]
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

def _buck2_no_nix_kit_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.os, dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._bash[RunInfo],
            "-c",
            "kit=$(\"$2\" --realise \"$3\") && \"$1/cp\" -rL \"$kit\" \"$4\" && \"$1/chmod\" -R u+w \"$4\"",
            "buck2_no_nix_kit",
            ctx.attrs._coreutils[RunInfo],
            ctx.attrs._nix_store[RunInfo],
            ctx.attrs.kit[RunInfo],
            out.as_output(),
        ),
        category = "buck2_no_nix_kit",
        # A copy of a store path that exists only in the local store.
        local_only = True,
        allow_cache_upload = False,
    )
    return [DefaultInfo(default_output = out)]

# Contract buck2-no-nix-mode: see tools/CONTRACTS.
# The kit for `tools/buck2 --no-nix` (`OVERALLS_BUCK2_KIT`): buck2 for `os`,
# the prelude and a non_hermetic-only toolchains.buckconfig. `kit` names the
# kit's derivation (nix/buck/no-nix.nix); building it fetches the pinned
# downloads and fails when they are not the buckCells buck2 and prelude.
buck2_no_nix_kit = rule(
    impl = _buck2_no_nix_kit_impl,
    attrs = {
        "kit": attrs.exec_dep(),
        "os": attrs.string(),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_coreutils": attrs.default_only(attrs.exec_dep(default = "toolchains//:coreutils")),
        "_nix_store": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix_store")),
    },
)
