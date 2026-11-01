# Mila platform builds (ADR-0269 M9, ADR-0235).
#
# Apple (Xcode/SwiftPM), Android (Gradle) and Windows (.NET) builds need a
# platform SDK that Nix does not supply, so they are `non_hermetic` targets:
# their actions run the SDK from the Buck2 daemon's PATH in the repository and
# copy the outputs into buck-out. Their third-party inputs are pinned by lock
# files instead (Gradle dependency verification metadata, NuGet
# packages.lock.json in locked mode; the Swift packages have no dependencies).
# They build only when `-c overalls.non_hermetic=true` is set, which
# `tools/buck2 --no-nix` sets, and only on their host OS (Android on Linux or
# macOS), so `buck2 build //...` and the verification and selection jobs skip
# them.
#
# `mila_windows_ffi` is hermetic: it cross-builds the FFI crate for
# x86_64-pc-windows-gnu on Linux. Its DLL is the published Windows FFI
# artifact: built deterministically (SOURCE_DATE_EPOCH=0, so lld writes no PE
# timestamp; build paths remapped), rebuilt independently and compared byte
# for byte, and checked against the C header and the .NET imports by
# `mila_windows_dll_check`. The Windows job imports it rather than building.
#
# Contract mila-non-hermetic-targets: see buck/CONTRACTS.

load(":checks.bzl", "check_providers", "tool", "tool_attr")

NON_HERMETIC = "non_hermetic"

_ENABLED = "toolchains//:non_hermetic_enabled"
_OS = {
    "linux": "prelude//os:linux",
    "macos": "prelude//os:macos",
    "windows": "prelude//os:windows",
}

def _mila_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    spec = json.decode(ctx.attrs.spec)
    path_env = {}
    hidden = list(ctx.attrs.srcs)
    for name, dep in ctx.attrs.path_env.items():
        artifact = dep[DefaultInfo].default_outputs[0]
        path_env[name] = artifact
        hidden.append(artifact)
    spec["path_env"] = path_env
    spec_file = ctx.actions.write_json("spec.json", spec, with_inputs = True)
    out = ctx.actions.declare_output("out", dir = True)
    stamp = ctx.actions.declare_output("stamp") if ctx.attrs.check else None
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._python),
            ctx.attrs._driver,
            spec_file,
            out.as_output(),
            [stamp.as_output()] if stamp else [],
            hidden = hidden,
        ),
        category = "mila_platform",
        identifier = ctx.label.name,
        # The SDKs come from the daemon's environment, which no action key
        # records: never share these outputs through a cache.
        local_only = True,
        allow_cache_upload = False,
    )
    if stamp:
        # Like check_providers, but `buck2 test` reads the stamp with the
        # rule's own Python: no coreutils exists without Nix.
        return [
            DefaultInfo(default_output = stamp, sub_targets = {"out": [DefaultInfo(default_output = out)]}),
            ExternalRunnerTestInfo(
                type = "custom",
                command = [cmd_args(tool(ctx.attrs._python)), "-c", "import sys; print(open(sys.argv[1]).read())", stamp],
                labels = ctx.attrs.labels,
            ),
        ]
    return [DefaultInfo(default_output = out)]

_mila_platform = rule(
    impl = _mila_platform_impl,
    attrs = {
        "check": attrs.bool(default = False),
        "labels": attrs.list(attrs.string(), default = []),
        "path_env": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "spec": attrs.string(),
        "srcs": attrs.list(attrs.source(), default = []),
        "_driver": attrs.default_only(attrs.source(default = "root//buck:mila_platform.py")),
        "_python": tool_attr("python"),
    },
)

def mila_platform(
        name: str,
        os: str | list[str],
        steps: list[dict[str, typing.Any]],
        outputs: dict[str, str] = {},
        sums: dict[str, str] = {},
        sha256: dict[str, str] = {},
        env: dict[str, str] = {},
        path_env: dict[str, str] = {},
        require: list[str] = [],
        srcs: list[str] = [],
        check: bool = False,
        labels: list[str] = [],
        visibility: list[str] = ["PUBLIC"]):
    """A non_hermetic platform build for `os` ("linux", "macos" or "windows",
    or a list of them when the SDK runs on several hosts).

    `steps` are `{"argv": [...], "cwd": <repo path>}` commands, run in order
    with `env` and with `path_env` (variable -> target whose output path is
    passed, absolute). `outputs` maps an output name to the repository path
    the steps produce; the target's output directory holds copies of them and
    their SHA256SUMS. An output another job produced names, in `sums`, the
    SHA256SUMS file that MUST list its digest, and, in `sha256`, a digest it
    MUST have (which also enters the action key). `require` names programs that must be on the daemon's
    PATH. `srcs` are the declared inputs (changes rerun the build). A `check`
    writes a stamp that `buck2 test` reads.
    """
    oses = [os] if type(os) == type("") else os
    if len(oses) == 1:
        compatible = [_ENABLED, _OS[oses[0]]]
    else:
        # Any one of the hosts: prelude//os:none matches no build host.
        compatible = [_ENABLED] + select(dict({_OS[o]: [] for o in oses}, DEFAULT = ["prelude//os:none"]))
    _mila_platform(
        name = name,
        spec = json.encode({
            "env": env,
            "outputs": [{"name": n, "source": s, "sums": sums.get(n), "sha256": sha256.get(n)} for n, s in outputs.items()],
            "require": require,
            "steps": steps,
        }),
        path_env = path_env,
        srcs = srcs,
        check = check,
        labels = [NON_HERMETIC] + oses + labels + (["check"] if check else []),
        target_compatible_with = compatible,
        visibility = visibility,
    )

def _mila_windows_ffi_impl(ctx: AnalysisContext) -> list[Provider]:
    clippy = ctx.attrs.mode == "clippy"
    output = ctx.actions.declare_output("clippy.stamp" if clippy else "out", dir = not clippy)
    script = ctx.actions.write("build.sh", [
        "set -euo pipefail",
        "root=$PWD mode=$1 out=$2 vendor=$3",
        # Absolute: cargo-zigbuild hands its wrapper paths to rustc and cc,
        # which run in each crate's directory.
        "scratch=$root/${BUCK_SCRATCH_PATH:?}",
        "mkdir -p \"$scratch/cargo-home\" \"$scratch/cache\"",
        "export HOME=\"$scratch\" CARGO_HOME=\"$scratch/cargo-home\" XDG_CACHE_HOME=\"$scratch/cache\"",
        "export CARGO_ZIGBUILD_CACHE_DIR=\"$scratch/zigbuild\" CARGO_TARGET_DIR=\"$scratch/target\"",
        # Vendored root-lock crates only. Keep store and checkout paths out of
        # panic locations (see lyra.nix) through the target's config rustflags:
        # RUSTFLAGS would replace the flags cargo-zigbuild adds (its dlltool).
        "printf '[source.crates-io]\\nreplace-with = \"vendored-sources\"\\n[source.vendored-sources]\\ndirectory = \"%s\"\\n[target.x86_64-pc-windows-gnu]\\nrustflags = [\"--remap-path-prefix=%s=/vendor\", \"--remap-path-prefix=%s=/source\", \"--remap-path-prefix=%s=/target\"]\\n' \"$vendor\" \"$vendor\" \"$root\" \"$CARGO_TARGET_DIR\" > \"$CARGO_HOME/config.toml\"",
        "if [ \"$mode\" = clippy ]; then",
        # ADR-0265: the cfg(windows) code only compiles for the Windows target.
        "  cargo-zigbuild clippy --locked --offline -p mila-ffi --all-targets --target x86_64-pc-windows-gnu -- -D warnings",
        "  echo ok > \"$out\"",
        "else",
        "  cargo zigbuild --locked --offline --release -p mila-ffi --target x86_64-pc-windows-gnu",
        "  mkdir -p \"$out\"",
        "  cp \"$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/mila_ffi.dll\" \"$out/mila_ffi.dll\"",
        "  (cd \"$out\" && sha256sum mila_ffi.dll > SHA256SUMS)",
        "fi",
    ])
    path = ":".join([
        tool(ctx.attrs._rust),
        tool(ctx.attrs._cargo_zigbuild),
        tool(ctx.attrs._zig),
        tool(ctx.attrs._coreutils),
        # The host C compiler links build scripts and proc macros.
        tool(ctx.attrs._cc),
    ])
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._bash),
            "-c",
            # A clean environment, keeping only Buck2's per-action scratch dir.
            # zig's lld honours SOURCE_DATE_EPOCH for the PE TimeDateStamp
            # (zig cc refuses -Wl,--no-insert-timestamp), so 0 means none.
            "exec \"$1/env\" -i PATH=\"$2\" BUCK_SCRATCH_PATH=\"$BUCK_SCRATCH_PATH\" SOURCE_DATE_EPOCH=0 TZ=UTC LC_ALL=C \"$3\" \"${@:4}\"",
            "mila_windows_ffi",
            tool(ctx.attrs._coreutils),
            path,
            tool(ctx.attrs._bash),
            script,
            ctx.attrs.mode,
            output.as_output(),
            tool(ctx.attrs._vendor),
            hidden = ctx.attrs.srcs,
        ),
        category = "mila_windows_ffi",
        identifier = ctx.attrs.mode,
        # An independent rebuild never comes from, or goes to, a cache, so the
        # reproducibility check compares two real executions.
        local_only = ctx.attrs.independent,
        allow_cache_upload = not ctx.attrs.independent,
    )
    return check_providers(ctx, output) if clippy else [DefaultInfo(default_output = output)]

# Contract mila-windows-ffi-cross-build: see buck/CONTRACTS.
mila_windows_ffi = rule(
    impl = _mila_windows_ffi_impl,
    attrs = {
        "independent": attrs.bool(default = False),
        "labels": attrs.list(attrs.string(), default = []),
        # "build" outputs mila_ffi.dll and SHA256SUMS; "clippy" is a check.
        "mode": attrs.enum(["build", "clippy"], default = "build"),
        "srcs": attrs.list(attrs.source()),
        "_bash": tool_attr("bash"),
        "_cargo_zigbuild": tool_attr("cargo_zigbuild"),
        "_cc": tool_attr("cc_bin"),
        "_coreutils": tool_attr("coreutils"),
        "_rust": tool_attr("rust_bin"),
        "_vendor": tool_attr("rust_vendor"),
        "_zig": tool_attr("zig"),
    },
)

def _mila_windows_dll_check_impl(ctx: AnalysisContext) -> list[Provider]:
    stamp = ctx.actions.declare_output("stamp")
    builds = [dep[DefaultInfo].default_outputs[0] for dep in ctx.attrs.builds]
    if ctx.attrs.mode == "reproducible":
        if len(builds) != 2:
            fail("mila_windows_dll_check(reproducible) compares exactly two builds")
        args = builds
    else:
        if len(builds) != 1:
            fail("mila_windows_dll_check(abi) checks exactly one build")
        args = [cmd_args(builds[0], format = "{}/mila_ffi.dll"), ctx.attrs.header] + ctx.attrs.csharp
    ctx.actions.run(
        cmd_args(
            tool(ctx.attrs._python),
            "-I",
            ctx.attrs._driver,
            ctx.attrs.mode,
            stamp.as_output(),
            args,
        ),
        category = "mila_windows_dll_check",
        identifier = ctx.attrs.mode,
    )
    return check_providers(ctx, stamp)

# Contract mila-windows-ffi-published: see buck/CONTRACTS.
mila_windows_dll_check = rule(
    impl = _mila_windows_dll_check_impl,
    attrs = {
        # reproducible: two mila_windows_ffi builds; abi: one.
        "builds": attrs.list(attrs.dep()),
        "csharp": attrs.list(attrs.source(), default = []),
        "header": attrs.option(attrs.source(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        "mode": attrs.enum(["reproducible", "abi"]),
        "_coreutils": tool_attr("coreutils"),
        "_driver": attrs.default_only(attrs.source(default = "root//buck:mila_windows_dll.py")),
        "_python": tool_attr("python"),
    },
)
