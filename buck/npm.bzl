# JavaScript packages and bundles (ADR-0269, M7).
# Contract npm-lock-node-modules: see buck/CONTRACTS.
# Contract esbuild-single-pinned: see buck/CONTRACTS.

load(":checks.bzl", "check_providers", "search_path", "tool", "tool_attr")

_NPM = [
    "set -euo pipefail",
    "root=$PWD out=$1 tree=$2; shift 2",
    "scratch=$(mkdir -p \"$BUCK_SCRATCH_PATH\" && cd \"$BUCK_SCRATCH_PATH\" && pwd)",
    # A short TMPDIR keeps Chromium's singleton socket under the unix socket
    # path limit.
    "short=$(mktemp -d /tmp/ovr-npm.XXXXXX); trap 'rm -rf \"$short\"' EXIT",
    "export HOME=\"$scratch/home\" TMPDIR=\"$short\" npm_config_cache=\"$scratch/npm\" npm_config_offline=true",
    "mkdir -p \"$HOME\"",
    "cp -rL --no-preserve=mode \"$tree\" \"$scratch/package\"",
    "ln -s \"$NPM_NODE_MODULES\" \"$scratch/package/node_modules\"",
    "cd \"$scratch/package\"",
    "eval \"$NPM_COMMANDS\"",
    "if [ -z \"$NPM_INSTALL\" ]; then touch \"$root/$out\"; exit 0; fi",
    "mkdir -p \"$root/$out\"",
    "set -- $NPM_INSTALL",
    "while [ $# -gt 0 ]; do mkdir -p \"$root/$out/$(dirname \"$2\")\"; cp -r \"$1\" \"$root/$out/$2\"; shift 2; done",
]

def _npm_package_impl(ctx: AnalysisContext) -> list[Provider]:
    install = ctx.attrs.install
    out = ctx.actions.declare_output("out", dir = bool(install)) if install else ctx.actions.declare_output("stamp")
    tree = ctx.actions.symlinked_dir("package", {s.short_path: s for s in ctx.attrs.srcs})
    script = ctx.actions.write("npm.sh", _NPM)
    env = dict(ctx.attrs.env)
    env.update({
        "NPM_COMMANDS": "\n".join(ctx.attrs.commands),
        "NPM_INSTALL": " ".join(["{} {}".format(src, dest) for dest, src in sorted(install.items())]),
        "NPM_NODE_MODULES": tool(ctx.attrs.node_modules),
        "PATH": search_path([ctx.attrs._node] + ctx.attrs.path + [ctx.attrs._coreutils, ctx.attrs._bash]),
    })
    for name, dep in ctx.attrs.tools.items():
        env[name] = tool(dep)
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, out.as_output(), tree),
        env = env,
        category = "npm",
    )
    if install:
        return [DefaultInfo(default_output = out)]
    return check_providers(ctx, out)

# Runs npm scripts over a package's declared sources with node_modules from the
# Nix importNpmLock tree. With `install` (dest -> path in the package) the
# output is a directory; without it the target is a cached check.
npm_package = rule(
    impl = _npm_package_impl,
    attrs = {
        "commands": attrs.list(attrs.string()),
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "install": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "node_modules": attrs.exec_dep(doc = "toolchains// input: importNpmLock node_modules"),
        "path": attrs.list(attrs.exec_dep(), default = []),
        "srcs": attrs.list(attrs.source()),
        # Environment variable -> toolchains// tool path (e.g. CHROME).
        "tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_node": tool_attr("node"),
    },
)

def _esbuild_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    tree = ctx.actions.symlinked_dir("srcs", {s.short_path: s for s in ctx.attrs.srcs})
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._esbuild),
            cmd_args(tree, format = "{}/" + ctx.attrs.entry),
            "--bundle",
            cmd_args(out.as_output(), format = "--outfile={}"),
            ctx.attrs.args,
        ),
        env = {"NODE_PATH": cmd_args(ctx.attrs.node_paths, delimiter = ":")} if ctx.attrs.node_paths else {},
        category = "esbuild",
    )
    return [DefaultInfo(default_output = out)]

# Bundles `entry` (a path within srcs) with the single pinned esbuild from
# buckCells, the same esbuild release builds use (no esbuild.install download).
esbuild_bundle = rule(
    impl = _esbuild_bundle_impl,
    attrs = {
        "args": attrs.list(attrs.arg(), default = []),
        "entry": attrs.string(),
        "node_paths": attrs.list(attrs.arg(), default = []),
        "out": attrs.string(),
        "srcs": attrs.list(attrs.source()),
        "_esbuild": tool_attr("esbuild"),
    },
)
