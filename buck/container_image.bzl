# Dockerfile images built and published through Buck2 (ADR-0269 M11).
#
# `docker buildx` needs a Docker daemon or a remote BuildKit builder and the
# network, which no action key records, so these targets are `non_hermetic`
# like the Mila platform builds (buck/mila.bzl): Linux only, compatible only
# with `-c overalls.non_hermetic=true`, local_only, never cached. `buck2 build
# //...`, verification and tools/affected skip them. docker and the selected
# buildx builder come from the Buck2 daemon's environment for `<name>` and
# from the caller's for `<name>-publish` (a `buck2 run` command).
#
# The build context is the repository root, `.git` included; every owned
# source (//:flake_srcs) and the revision (`-c overalls.revision=<commit>`)
# are inputs, so a source or revision change rebuilds. Nix outputs the image
# carries are Buck2 dependencies (`stores`, name -> nix_assemble target):
# each one's closure is exported to a Nix binary cache directory and passed
# as the named build context `<name>`, which the Dockerfile imports with
# `nix copy --from file://` from a bind mount. Nothing builds them inside the
# image, where Lyra's bubblewrap sandbox cannot run.
#
# Contracts container-image-buck2-only and container-image-no-token: see
# .oss-scanner/CONTRACTS.

load(":checks.bzl", "tool", "tool_attr")
load(":mila.bzl", "NON_HERMETIC")

def _spec(ctx: AnalysisContext) -> Artifact:
    return ctx.actions.write_json("spec.json", {
        "dockerfile": ctx.attrs.dockerfile,
        "repository": ctx.attrs.repository,
        "revision": ctx.attrs.revision,
    })

def _common_args(ctx: AnalysisContext, mode: str) -> cmd_args:
    stores = [
        cmd_args("--store", cmd_args(name, "=", dep[DefaultInfo].default_outputs[0], delimiter = ""))
        for name, dep in sorted(ctx.attrs.stores.items())
    ]
    return cmd_args(
        tool(ctx.attrs._python),
        ctx.attrs._driver,
        mode,
        _spec(ctx),
        "--nix",
        ctx.attrs._nix[RunInfo],
        stores,
        # The nix_assemble outputs' store paths (RuntimeRefs, gcroots).
        hidden = [dep[DefaultInfo].other_outputs for dep in ctx.attrs.stores.values()],
    )

def _container_image_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output("out", dir = True)
    ctx.actions.run(
        cmd_args(
            _common_args(ctx, "build"),
            "--out",
            out.as_output(),
            hidden = [ctx.attrs.srcs[DefaultInfo].default_outputs, ctx.attrs.srcs[DefaultInfo].other_outputs],
        ),
        category = "container_image",
        identifier = ctx.label.name,
        # Docker and the builder come from the daemon's environment, which
        # no action key records: never share these outputs through a cache.
        local_only = True,
        allow_cache_upload = False,
    )
    return [DefaultInfo(default_output = out)]

def _container_image_publish_impl(ctx: AnalysisContext) -> list[Provider]:
    args = _common_args(ctx, "publish")
    return [
        DefaultInfo(default_output = _spec(ctx)),
        RunInfo(args = args),
    ]

_ATTRS = {
    "dockerfile": attrs.string(),
    "labels": attrs.list(attrs.string(), default = []),
    "repository": attrs.string(),
    "revision": attrs.string(),
    "stores": attrs.dict(attrs.string(), attrs.dep(), default = {}),
    "_driver": attrs.default_only(attrs.source(default = "root//buck:container_image.py")),
    "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
    "_python": tool_attr("python"),
}

_container_image = rule(
    impl = _container_image_impl,
    attrs = _ATTRS | {"srcs": attrs.dep()},
)

_container_image_publish = rule(
    impl = _container_image_publish_impl,
    attrs = _ATTRS,
)

def container_image(
        name: str,
        dockerfile: str,
        repository: str,
        stores: dict[str, str] = {},
        visibility: list[str] = []):
    """`<name>` builds `dockerfile` (a repository path) with the repository
    root as context and each `stores` entry as a named Nix binary cache
    context, loads it into the local Docker image store as
    `<repository>:buck2` and scans every member for the Namespace token
    prefix; its output holds metadata.json, image-id, size and token-scan.
    `<name>-publish` is a `buck2 run` command that pushes the same build:
    `tools/buck2 run -c overalls.non_hermetic=true //pkg:<name>-publish --
    --registry REG --tag TAG...`."""
    common = dict(
        dockerfile = dockerfile,
        repository = repository,
        stores = stores,
        # Read at load time (rule 2), so the revision enters the target hash.
        revision = read_root_config("overalls", "revision", "unknown"),
        labels = [NON_HERMETIC, "linux", "container_image"],
        target_compatible_with = ["toolchains//:non_hermetic_enabled", "prelude//os:linux"],
        visibility = visibility,
    )
    _container_image(name = name, srcs = "root//:flake_srcs", **common)
    _container_image_publish(name = name + "-publish", **common)
