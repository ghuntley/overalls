# Nix boundary rules for the Buck2 migration (ADR-0269).

# Contract nix-owned-files: see buck/CONTRACTS.
def nix_owned(name: str = "srcs", srcs = None, **kwargs):
    native.filegroup(
        name = name,
        srcs = srcs if srcs != None else native.glob(["**", "**/.*", "**/.*/**"], exclude = ["BUCK"]),
        visibility = ["PUBLIC"],
        **kwargs
    )

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
