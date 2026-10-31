# Lyra's cross builds on Buck2 (ADR-0273 M5): the client (Linux musl, macOS,
# Windows), the Windows guest agents and the FreeBSD and illumos native agents.
#
# Contract lyra-cross-buck2: see buck/CONTRACTS.
#
# Each target runs nix/domains/artifacts/infrastructure/lyra-build.sh, the
# script the Nix derivations run (contract lyra-shared-build), over the same
# workspace source layout and, inside bubblewrap, the same /build root the Nix
# sandbox gives them. The /build root is the interim parity method: vendored
# OpenSSL embeds absolute build paths (an open finding in the Buck2 migration
# review), so only an identical layout yields identical bytes.
#
# Tools come from one Nix derivation (lyra.nix `buckInputs`) whose .drv the
# cells name (`[nix] lyra_build_inputs`); the action realises it locally, so
# checkouts that never build Lyra never fetch its SDKs. Crates come from the
# rust// cell's vendor tree, as for every Buck2 Rust build.

load(":checks.bzl", "tool", "tool_attr")

# Environment the shared script reads, forwarded into the sandbox from the
# realised env.sh (LYRA_VENDOR is the cells' vendor tree instead).
_LYRA_VARS = [
    "LYRA_RUST",
    "LYRA_PYTHON",
    "LYRA_MANIFEST",
    "LYRA_MACOS_SDK",
    "LYRA_ILLUMOS_CC",
    "LYRA_ILLUMOS_AR",
    "LYRA_NATIVE_MANIFEST",
    "LYRA_NATIVE_METADATA",
    "LYRA_READELF",
]

def _lyra_cross_impl(ctx: AnalysisContext) -> list[Provider]:
    native = ctx.attrs.mode == "native"
    out = ctx.actions.declare_output("out", dir = True)
    probes = ctx.actions.declare_output("probes", dir = True) if native else None
    # Each filegroup's output holds its files relative to its package.
    groups = [(dep.label.package, out) for dep in ctx.attrs.srcs for out in dep[DefaultInfo].default_outputs]
    srcs = ctx.actions.write("srcs.txt", [cmd_args(package or ".", "\t", out, delimiter = "") for package, out in groups])
    forwarded = []
    for var in _LYRA_VARS:
        forwarded.append("--setenv {} \"${}\"".format(var, var))
    script = ctx.actions.write("lyra_cross.sh", [
        "set -euo pipefail",
        "mode=$1 out=$2 probes=$3 drv=$4 nix_store=$5 vendor=$6 python=$7 stubs=$8 build=$9 srcs=${10} jobs=${11}",
        "root=$PWD",
        "scratch=$root/${BUCK_SCRATCH_PATH:?}",
        "inputs=$(\"$nix_store\" --realise \"$drv\" --add-root \"$scratch/inputs\" --indirect)",
        "source \"$inputs/env.sh\"",
        "work=$scratch/build",
        "mkdir -p \"$work/lyra-source\"",
        # The declared sources at their repository paths, then empty stubs for
        # the members Lyra does not compile (cargo-workspace.nix's layout).
        "while IFS=$'\\t' read -r package dir || [ -n \"$package\" ]; do mkdir -p \"$work/lyra-source/$package\" && cp -rL \"$dir/.\" \"$work/lyra-source/$package/\"; done < \"$srcs\"",
        "chmod -R u+w \"$work/lyra-source\"",
        "\"$python\" \"$stubs\" \"$work/lyra-source\" lyra",
        "cp \"$build\" \"$work/lyra-build.sh\"",
        "\"$LYRA_BWRAP\" --die-with-parent --unshare-net --unshare-ipc --unshare-pid \\",
        "  --tmpfs / --ro-bind /nix /nix --dev /dev --proc /proc --tmpfs /tmp \\",
        "  --bind \"$work\" /build --ro-bind \"$LYRA_SH\" /bin/sh --chdir /build/lyra-source --clearenv \\",
        "  --setenv PATH \"$PATH\" --setenv HOME /homeless-shelter --setenv NIX_BUILD_TOP /build \\",
        "  --setenv TMPDIR /build --setenv TMP /build --setenv TEMP /build --setenv TEMPDIR /build \\",
        "  --setenv LYRA_VENDOR \"$vendor\" --setenv LYRA_JOBS \"$jobs\" \\",
        "  " + " ".join(forwarded) + " \\",
        "  \"$LYRA_SH\" /build/lyra-build.sh \"$mode\" /build/out /build/probes",
        "cp -r \"$work/out/.\" \"$out\"",
        "if [ \"$mode\" = native ]; then cp -r \"$work/probes/.\" \"$probes\"; fi",
    ])
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._bash),
            "-c",
            # A clean environment, keeping only Buck2's per-action scratch dir.
            "exec \"$1/env\" -i BUCK_SCRATCH_PATH=\"$BUCK_SCRATCH_PATH\" \"$2\" \"${@:3}\"",
            "lyra_cross",
            tool(ctx.attrs._coreutils),
            tool(ctx.attrs._bash),
            script,
            ctx.attrs.mode,
            out.as_output(),
            probes.as_output() if probes else "-",
            tool(ctx.attrs._inputs),
            ctx.attrs._nix_store[RunInfo],
            tool(ctx.attrs._vendor),
            tool(ctx.attrs._python),
            ctx.attrs._stubs,
            ctx.attrs.build_script,
            srcs,
            str(ctx.attrs.jobs),
            hidden = [out for _, out in groups],
        ),
        category = "lyra_cross",
        identifier = ctx.attrs.mode,
        # bubblewrap and the realised store path need the local host.
        local_only = True,
    )
    sub_targets = {"probes": [DefaultInfo(default_output = probes)]} if probes else {}
    return [DefaultInfo(default_output = out, sub_targets = sub_targets)]

lyra_cross = rule(
    impl = _lyra_cross_impl,
    attrs = {
        "build_script": attrs.source(),
        # Cargo jobs inside the action (panterloons runs production guests).
        "jobs": attrs.int(default = 16),
        "labels": attrs.list(attrs.string(), default = []),
        "mode": attrs.enum(["client", "windows", "native"]),
        "srcs": attrs.list(attrs.dep()),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_inputs": tool_attr("lyra_build_inputs"),
        "_nix_store": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix_store")),
        "_python": tool_attr("python"),
        "_stubs": attrs.default_only(attrs.source(default = "root//buck:cargo_workspace_stubs.py")),
        "_vendor": tool_attr("rust_vendor"),
    },
)
