# NixOS assembly from Buck2 artifacts (ADR-0269). Contracts: buck/CONTRACTS.

load(":nix.bzl", "OwnedSrcsInfo")

# Store paths an artifact needs at runtime (ERTS libraries, host tools, ...).
# Producing rules attach it; nix_store_import forwards it to assembly.
RuntimeRefsInfo = provider(fields = {"refs": list[str]})

# A Buck2 artifact imported into the Nix store.
# package_references maps a placeholder store path the artifact embeds to the
# package-set attribute assembly rewrites it to (contract
# mix-release-package-references in nix/assemble/import-artifact.nix).
NixStorePathInfo = provider(fields = {
    "store_path": Artifact,
    "runtime_refs": list[str],
    "self_reference": str | None,
    "allowed_references": list[str] | None,
    "package_references": dict[str, str],
})

# One root per configured target: the encrypted and Antithesis variants of a
# release share its label but not its configuration.
def _import_root_name(ctx: AnalysisContext) -> str:
    name = str(ctx.label)
    return "".join([c if c.isalnum() or c in "-_." else "_" for c in name.elems()])

def _nix_store_import_impl(ctx: AnalysisContext) -> list[Provider]:
    src = ctx.attrs.src[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("store-path")
    script = ctx.actions.write("import.sh", [
        "set -euo pipefail",
        # Outputs can be symlinks into content-hashed directories; import the tree.
        "path=$(\"$1\" --add-fixed --recursive sha256 \"$(realpath \"$2\")\")",
        # Contract nix-store-import-gc-rooted: see buck/CONTRACTS. The same
        # root directory and checkout hash as nix_assemble.sh's roots.
        "roots=${OVERALLS_GCROOT_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/overalls-buck2/gcroots}",
        "mkdir -p \"$roots\"",
        "\"$1\" --realise --add-root \"$roots/$(pwd | sha256sum | cut -c1-12)-import-$4\" \"$path\" > /dev/null",
        "printf '%s\\n' \"$path\" > \"$3\"",
    ])
    ctx.actions.run(
        cmd_args(ctx.attrs._bash[RunInfo], script, ctx.attrs._nix_store[RunInfo], src, out.as_output(), _import_root_name(ctx)),
        category = "nix_store_import",
        local_only = True,
        allow_cache_upload = False,
    )
    refs = ctx.attrs.runtime_refs + (ctx.attrs.src[RuntimeRefsInfo].refs if RuntimeRefsInfo in ctx.attrs.src else [])
    return [DefaultInfo(default_output = out), NixStorePathInfo(
        store_path = out,
        runtime_refs = refs,
        self_reference = ctx.attrs.self_reference,
        allowed_references = ctx.attrs.allowed_references,
        package_references = ctx.attrs.package_references,
    )]

nix_store_import = rule(
    impl = _nix_store_import_impl,
    attrs = {
        # The store paths the imported copy may reference, enforced by Nix
        # (nix/assemble/import-artifact.nix); `[]` for an artifact that must
        # embed none. None leaves it unconstrained.
        "allowed_references": attrs.option(attrs.list(attrs.string()), default = None),
        "package_references": attrs.dict(attrs.string(), attrs.string(), default = {}),
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
        ) | (
            {"allowedReferences": dep[NixStorePathInfo].allowed_references} if dep[NixStorePathInfo].allowed_references != None else {}
        ) | (
            {"packageReferences": dep[NixStorePathInfo].package_references} if dep[NixStorePathInfo].package_references else {}
        )
        for name, dep in ctx.attrs.artifacts.items()
    }, with_inputs = True)
    params = ctx.actions.write_json("params.json", ctx.attrs.params)
    # A machine test's expression (contract machine-test-from-buck), written
    # beside nix/verification/tests/scope.nix in the copied tree.
    test = ctx.actions.write("machine-test.nix", "tests: with tests;\n" + ctx.attrs.test + "\n") if ctx.attrs.test else None
    def run(output: OutputArtifact, mode: str, category: str, attr: str = ctx.attrs.attr, root: str = ""):
        ctx.actions.run(
            cmd_args(
                ctx.attrs._bash[RunInfo],
                ctx.attrs._script,
                ctx.attrs._nix[RunInfo],
                ctx.attrs._jq[RunInfo],
                manifest,
                names,
                artifacts,
                params,
                attr,
                ctx.attrs.revision,
                _gcroot_name(ctx) + root,
                output,
                mode,
                test or "",
                hidden = srcs,
            ),
            category = category,
            identifier = attr,
            local_only = True,
            allow_cache_upload = False,
            # A NixOS system or fleet test evaluation takes several GB; at
            # the default one-per-core, 20 concurrent evaluations were
            # OOM-killed in CI (run 41130542439). At most four run at once.
            weight_percentage = 25,
        )

    out = ctx.actions.declare_output("store-path")
    run(out.as_output(), "build", "nix_assemble")
    # `[drv]` evaluates the same declared tree under the same restrictions
    # and writes the derivation path without building it (contract
    # nix-assemble-drv-evaluation).
    drv = ctx.actions.declare_output("drv-path")
    run(drv.as_output(), "drv", "nix_assemble_drv")
    sub_targets = {"drv": [DefaultInfo(default_output = drv)]}
    # `[meta]` evaluates `meta_attr` to JSON over the same tree (a machine
    # test's features and, for fleet variants, its composed script), so the
    # runner never evaluates the working tree.
    if ctx.attrs.meta_attr:
        meta = ctx.actions.declare_output("meta.json")
        run(meta.as_output(), "json", "nix_assemble_meta", ctx.attrs.meta_attr)
        sub_targets["meta"] = [DefaultInfo(default_output = meta)]
    # Further attributes of the same assembly, built only on request (a machine
    # test's interactive driver).
    for sub, attr in ctx.attrs.sub_attrs.items():
        built = ctx.actions.declare_output(sub, "store-path")
        run(built.as_output(), "build", "nix_assemble_" + sub, attr, "-" + sub)
        sub_targets[sub] = [DefaultInfo(default_output = built)]
    return [DefaultInfo(default_output = out, sub_targets = sub_targets)]

_nix_assemble = rule(
    impl = _nix_assemble_impl,
    attrs = {
        "artifacts": attrs.dict(attrs.string(), attrs.dep(providers = [NixStorePathInfo]), default = {}),
        "attr": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "meta_attr": attrs.option(attrs.string(), default = None),
        # lib.assemble's per-target parameters (contract
        # assembly-params-validated): JSON scalars and string lists only.
        "params": attrs.dict(attrs.string(), attrs.one_of(attrs.bool(), attrs.string(), attrs.list(attrs.string())), default = {}),
        "revision": attrs.string(),
        "srcs": attrs.list(attrs.dep(providers = [OwnedSrcsInfo]), default = ["root//:flake_srcs"]),
        "sub_attrs": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # A machine test's Nix expression in the test scope; lib.assemble
        # evaluates it as `machineTest` (contract machine-test-from-buck).
        "test": attrs.option(attrs.string(), default = None),
        "_bash": attrs.default_only(attrs.exec_dep(default = "toolchains//:bash")),
        "_jq": attrs.default_only(attrs.exec_dep(default = "toolchains//:jq")),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
        "_script": attrs.default_only(attrs.source(default = "root//buck:nix_assemble.sh")),
    },
)

def nix_assemble(name: str, attr: str, **kwargs):
    """Build `lib.assemble { revision; artifacts; params; }.<attr>`.

    The revision is read from `-c overalls.revision=<sha>` at load time, so it
    is part of the action key; it defaults to "unknown" for local builds.
    """
    _nix_assemble(
        name = name,
        attr = attr,
        revision = read_root_config("overalls", "revision", "unknown"),
        **kwargs
    )
