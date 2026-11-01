# Clippy for a root-workspace member on a target whose cfg code Buck2's own
# Rust rules never compile (ADR-0265, ADR-0273).
#
# Contract rust-cargo-target-clippy: see buck/CONTRACTS.
#
# The prelude toolchain (toolchains//:rust) only targets Linux, so
# `<pkg>-clippy` cannot see `cfg(target_os = "freebsd")` or "illumos" code.
# The single Nix toolchain ([nix] rust_bin) carries those targets' standard
# libraries and clippy, so this rule runs Cargo itself: it copies the root
# workspace (the given filegroups, stubs for the other members, as
# buck/lyra.bzl does), then runs
# `cargo clippy -p <package> --all-targets --locked --offline --target <triple>
# -- -D warnings` against the rust// cell's vendored root-lock crates, in a
# clean environment. Clippy only type-checks the target crates, so no target
# C toolchain or linker is needed; host build scripts and proc macros link
# with the Nix cc.

load(":checks.bzl", "check_providers", "tool", "tool_attr")

def _rust_cargo_clippy_impl(ctx: AnalysisContext) -> list[Provider]:
    stamp = ctx.actions.declare_output("clippy.stamp")
    # Each filegroup's output holds its files relative to its package.
    groups = [(dep.label.package, out) for dep in ctx.attrs.srcs for out in dep[DefaultInfo].default_outputs]
    srcs = ctx.actions.write("srcs.txt", [cmd_args(package or ".", "\t", out, delimiter = "") for package, out in groups])
    script = ctx.actions.write("cargo_clippy.sh", [
        "set -euo pipefail",
        "stamp=$1 vendor=$2 python=$3 stubs=$4 srcs=$5 member=$6 crate=$7 triple=$8",
        "root=$PWD",
        "scratch=$root/${BUCK_SCRATCH_PATH:?}",
        "work=$scratch/workspace",
        "mkdir -p \"$work\" \"$scratch/cargo-home\"",
        # The declared sources at their repository paths, then empty stubs for
        # the members this check does not compile (cargo-workspace.nix's layout).
        "while IFS=$'\\t' read -r package dir || [ -n \"$package\" ]; do mkdir -p \"$work/$package\" && cp -rL \"$dir/.\" \"$work/$package/\"; done < \"$srcs\"",
        "chmod -R u+w \"$work\"",
        "\"$python\" \"$stubs\" \"$work\" \"$member\"",
        "export HOME=\"$scratch\" CARGO_HOME=\"$scratch/cargo-home\" CARGO_TARGET_DIR=\"$scratch/target\"",
        "printf '[source.crates-io]\\nreplace-with = \"vendored-sources\"\\n[source.vendored-sources]\\ndirectory = \"%s\"\\n' \"$vendor\" > \"$CARGO_HOME/config.toml\"",
        "cd \"$work\"",
        "cargo clippy -p \"$crate\" --all-targets --locked --offline --target \"$triple\" -- -D warnings",
        "touch \"$root/$stamp\"",
    ])
    path = ":".join([
        tool(ctx.attrs._rust),
        tool(ctx.attrs._coreutils),
        # The host C compiler links build scripts and proc macros.
        tool(ctx.attrs._cc),
    ])
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._bash),
            "-c",
            # A clean environment, keeping only Buck2's per-action scratch dir.
            "exec \"$1/env\" -i PATH=\"$2\" BUCK_SCRATCH_PATH=\"$BUCK_SCRATCH_PATH\" TZ=UTC LC_ALL=C \"$3\" \"${@:4}\"",
            "rust_cargo_clippy",
            tool(ctx.attrs._coreutils),
            path,
            tool(ctx.attrs._bash),
            script,
            stamp.as_output(),
            tool(ctx.attrs._vendor),
            tool(ctx.attrs._python),
            ctx.attrs._stubs,
            srcs,
            ctx.attrs.member,
            ctx.attrs.package,
            ctx.attrs.target,
            hidden = [out for _, out in groups],
        ),
        category = "rust_cargo_clippy",
        identifier = ctx.attrs.target,
    )
    return check_providers(ctx, stamp)

# Clippy over `package` (the workspace member at `member`) for the Rust
# target triple `target`, as `cargo clippy --all-targets -- -D warnings`:
# any diagnostic fails it. `srcs` are filegroups whose files Cargo needs:
# //:workspace_files, every package's cargo_manifests and the member's sources.
rust_cargo_clippy = rule(
    impl = _rust_cargo_clippy_impl,
    attrs = {
        "labels": attrs.list(attrs.string(), default = []),
        "member": attrs.string(),
        "package": attrs.string(),
        "srcs": attrs.list(attrs.dep()),
        "target": attrs.string(),
        "_bash": tool_attr("bash"),
        "_cc": tool_attr("cc_bin"),
        "_coreutils": tool_attr("coreutils"),
        "_python": tool_attr("python"),
        "_rust": tool_attr("rust_bin"),
        "_stubs": attrs.default_only(attrs.source(default = "root//buck:cargo_workspace_stubs.py")),
        "_vendor": tool_attr("rust_vendor"),
    },
)
