# NixOS assembly from Buck2 artifacts (ADR-0269). Contracts: buck/CONTRACTS.

load(":nix.bzl", "OwnedSrcsInfo")

# Store paths an artifact needs at runtime (ERTS libraries, host tools, ...).
# Producing rules attach it; nix_store_import forwards it to assembly.
RuntimeRefsInfo = provider(fields = {"refs": list[str]})

# A Buck2 artifact imported into the Nix store.
NixStorePathInfo = provider(fields = {"store_path": Artifact, "runtime_refs": list[str], "self_reference": str | None})

def _nix_store_import_impl(ctx: AnalysisContext) -> list[Provider]:
    src = ctx.attrs.src[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("store-path")
    script = ctx.actions.write("import.sh", [
        "set -euo pipefail",
        # Outputs can be symlinks into content-hashed directories; import the tree.
        "\"$1\" --add-fixed --recursive sha256 \"$(realpath \"$2\")\" > \"$3\"",
    ])
    ctx.actions.run(
        cmd_args(ctx.attrs._bash[RunInfo], script, ctx.attrs._nix_store[RunInfo], src, out.as_output()),
        category = "nix_store_import",
        local_only = True,
        allow_cache_upload = False,
    )
    refs = ctx.attrs.runtime_refs + (ctx.attrs.src[RuntimeRefsInfo].refs if RuntimeRefsInfo in ctx.attrs.src else [])
    return [DefaultInfo(default_output = out), NixStorePathInfo(store_path = out, runtime_refs = refs, self_reference = ctx.attrs.self_reference)]

nix_store_import = rule(
    impl = _nix_store_import_impl,
    attrs = {
        "runtime_refs": attrs.list(attrs.string(), default = []),
        # Placeholder store path the artifact embeds for itself; assembly
        # rewrites it to the imported path (see nix/assemble/import-artifact.nix).
        "self_reference": attrs.option(attrs.string(), default = None),
        "src": attrs.dep(),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_nix_store": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix_store")),
    },
)

# GC roots live outside the repository: a store symlink under buck-out makes
# the file watcher crawl the whole closure on every start.
def _gcroot_name(ctx: AnalysisContext) -> str:
    return str(ctx.label.raw_target()).replace("/", "_").replace(":", "__")

def _nix_assemble_impl(ctx: AnalysisContext) -> list[Provider]:
    dirs = [pair for d in ctx.attrs.srcs for pair in d[OwnedSrcsInfo].dirs]
    srcs = [o for _, o in dirs]
    manifest = ctx.actions.write("srcs.txt", srcs)
    names = ctx.actions.write("srcs-names.txt", [package or "." for package, _ in dirs])
    artifacts = ctx.actions.write_json("artifacts.json", {
        name: {"path": dep[NixStorePathInfo].store_path, "runtimeRefs": dep[NixStorePathInfo].runtime_refs} | (
            {"selfReference": dep[NixStorePathInfo].self_reference} if dep[NixStorePathInfo].self_reference else {}
        )
        for name, dep in ctx.attrs.artifacts.items()
    }, with_inputs = True)
    def run(output: OutputArtifact, mode: str, category: str):
        ctx.actions.run(
            cmd_args(
                ctx.attrs._bash[RunInfo],
                ctx.attrs._script,
                ctx.attrs._nix[RunInfo],
                ctx.attrs._jq[RunInfo],
                manifest,
                names,
                artifacts,
                ctx.attrs.attr,
                ctx.attrs.revision,
                _gcroot_name(ctx),
                output,
                mode,
                hidden = srcs,
            ),
            category = category,
            identifier = ctx.attrs.attr,
            local_only = True,
            allow_cache_upload = False,
        )

    out = ctx.actions.declare_output("store-path")
    run(out.as_output(), "build", "nix_assemble")
    # `[drv]` evaluates the same declared tree under the same restrictions
    # and writes the derivation path without building it (contract
    # nix-assemble-drv-evaluation).
    drv = ctx.actions.declare_output("drv-path")
    run(drv.as_output(), "drv", "nix_assemble_drv")
    return [DefaultInfo(default_output = out, sub_targets = {"drv": [DefaultInfo(default_output = drv)]})]

_nix_assemble = rule(
    impl = _nix_assemble_impl,
    attrs = {
        "artifacts": attrs.dict(attrs.string(), attrs.dep(providers = [NixStorePathInfo]), default = {}),
        "attr": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "revision": attrs.string(),
        "srcs": attrs.list(attrs.dep(providers = [OwnedSrcsInfo]), default = ["root//:flake_srcs"]),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_jq": attrs.default_only(attrs.exec_dep(default = "toolchains//:jq")),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
        "_script": attrs.default_only(attrs.source(default = "root//buck:nix_assemble.sh")),
    },
)

def nix_assemble(name: str, attr: str, **kwargs):
    """Build `lib.assemble { revision; artifacts; }.<attr>`.

    The revision is read from `-c overalls.revision=<sha>` at load time, so it
    is part of the action key; it defaults to "unknown" for local builds.
    """
    _nix_assemble(
        name = name,
        attr = attr,
        revision = read_root_config("overalls", "revision", "unknown"),
        **kwargs
    )
