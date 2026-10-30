# First-party Rust crates from the root Cargo workspace (ADR-0273, ADR-0269).
# Contract rust-crate-from-workspace: see buck/CONTRACTS.

load("@prelude//rust:cargo_package.bzl", "apply_platform_attrs")
load("@prelude//rust:outputs.bzl", "RustcExtraOutputsInfo")
load(":assemble.bzl", "NixStorePathInfo")
load(":checks.bzl", "PrecommitInfo", "check_providers", "search_path", "tool", "tool_attr")
load("@rust//:workspace.bzl", "CRATES", "LINT_FLAGS")

# Cargo's `hardened` profile (root Cargo.toml): release optimisation, strip,
# fat LTO, one codegen unit and abort on panic. `release` is -O plus Cargo's
# implicit `strip = "debuginfo"` (Cargo 1.77+ when `debug` is off), without
# which the standard library's debug info made binaries five times larger.
_RELEASE_FLAGS = ["-Copt-level=3", "-Cdebug-assertions=off", "-Coverflow-checks=off", "-Cstrip=debuginfo"]
_HARDENED_FLAGS = _RELEASE_FLAGS + ["-Cstrip=symbols", "-Clto=fat", "-Ccodegen-units=1", "-Cpanic=abort"]

def _crate_env(crate: dict, path: str) -> dict[str, str]:
    major, minor, patch = (crate["version"].split("-")[0].split(".") + ["0", "0"])[:3]
    return {
        "CARGO_MANIFEST_DIR": path,
        "CARGO_PKG_NAME": crate["name"],
        "CARGO_PKG_VERSION": crate["version"],
        "CARGO_PKG_VERSION_MAJOR": major,
        "CARGO_PKG_VERSION_MINOR": minor,
        "CARGO_PKG_VERSION_PATCH": patch,
    }

def _deps(crate: dict, kinds: list[str]) -> (list[str], dict[str, list[str]], dict[str, str]):
    """Unconditional labels, per-platform labels and extern renames for `kinds`."""
    common = []
    by_platform = {}
    named = {}
    for kind in kinds:
        for dep in crate["deps"][kind]:
            label = dep["label"]
            if dep["extern"] != dep["crate"]:
                named[dep["extern"]] = label
                continue
            if dep["platforms"] == None:
                if label not in common:
                    common.append(label)
            else:
                for platform in dep["platforms"]:
                    labels = by_platform.setdefault(platform, [])
                    if label not in labels:
                        labels.append(label)
    return common, by_platform, named

def _with_platform_deps(kwargs: dict, crate: dict, kinds: list[str], extra: list[str] = []) -> dict:
    common, by_platform, named = _deps(crate, kinds)
    kwargs["deps"] = extra + common
    if named:
        kwargs["named_deps"] = named
    return apply_platform_attrs({p: {"deps": labels} for p, labels in by_platform.items()}, kwargs)

def overalls_rust_crate(path: str, profile: str = "release", native_libs: list[str] = [], test_env: dict[str, str] = {}, visibility: list[str] = ["PUBLIC"]):
    """Targets for the workspace member at repository path `path`.

    Called from the BUCK file of the path's top-level directory. Defines
    `<package>-lib` (rust_library), `<package>-unittest` (the library's tests),
    one rust_binary per `[[bin]]` and `<package>-test-<name>` per integration
    test. `profile` is the Cargo profile the Nix build selects for binaries:
    `release` or `hardened`. `native_libs` names `[nix]` library directories
    (cells.nix) searched for the crate's `#[link]` libraries; the cc wrapper
    records them as the binaries' rpath. `test_env` is added to every test's
    environment (the Nix build's check environment).
    """
    crate = CRATES.get(path)
    if crate == None:
        fail("{} is not a member of the root Cargo workspace".format(path))
    if crate["build_script"] != None:
        fail("{}: build scripts are not supported by overalls_rust_crate yet".format(path))
    package = native.package_name()
    if not (path + "/").startswith(package + "/"):
        fail("overalls_rust_crate({}) must be called from {}/BUCK".format(path, path.split("/")[0]))
    sub = path[len(package) + 1:]
    srcs = glob([sub + "/**/*"], exclude = [sub + "/target/**", sub + "/.hegel/**"])
    lints = (LINT_FLAGS if crate["workspace_lints"] else []) + ["-Lnative=" + _store_path(lib_dir) for lib_dir in native_libs]
    profile_flags = {"hardened": _HARDENED_FLAGS, "release": _RELEASE_FLAGS}[profile]
    common = dict(
        srcs = srcs,
        edition = crate["edition"],
        features = crate["features"],
        env = _crate_env(crate, sub),
    )
    name = crate["name"]
    lib = crate["lib"]
    lib_label = []
    targets = []
    if lib != None:
        native.rust_library(**_with_platform_deps(dict(
            name = name + "-lib",
            crate = lib["crate"],
            crate_root = sub + "/" + lib["root"],
            proc_macro = lib["proc_macro"],
            rustc_flags = lints + _RELEASE_FLAGS,
            visibility = visibility,
            **common
        ), crate, ["normal"]))
        lib_label = [":" + name + "-lib"]
        targets.append(name + "-lib")
        if lib["test"]:
            targets.append(name + "-unittest")
            native.rust_test(**_with_platform_deps(dict(
                name = name + "-unittest",
                crate = lib["crate"],
                crate_root = sub + "/" + lib["root"],
                rustc_flags = lints,
                run_env = test_env,
                **common
            ), crate, ["normal", "dev"]))
    for binary in crate["bins"]:
        targets.append(binary["name"])
        native.rust_binary(**_with_platform_deps(dict(
            name = binary["name"],
            crate = binary["name"].replace("-", "_"),
            crate_root = sub + "/" + binary["root"],
            rustc_flags = lints + profile_flags,
            visibility = visibility,
            **common
        ), crate, ["normal"], lib_label))
    # Cargo gives integration tests each binary's path at compile time.
    bin_env = {"CARGO_BIN_EXE_" + b["name"]: "$(location :{})".format(b["name"]) for b in crate["bins"]}
    for test in crate["tests"]:
        targets.append(name + "-test-" + test["name"])
        test_attrs = dict(common)
        test_attrs["env"] = common["env"] | bin_env
        native.rust_test(**_with_platform_deps(dict(
            name = name + "-test-" + test["name"],
            crate = test["name"].replace("-", "_"),
            crate_root = sub + "/" + test["root"],
            rustc_flags = lints,
            run_env = test_env,
            **test_attrs
        ), crate, ["normal", "dev"], lib_label))

    rust_srcs = [f for f in srcs if f.endswith(".rs")]
    rust_clippy_check(
        name = name + "-clippy",
        crates = {t: ":" + t for t in targets},
        # Any source change can change any target's diagnostics.
        paths = {package + "/" + f: targets for f in srcs},
        labels = ["check", "precommit"],
    )
    rust_fmt_check(
        name = name + "-rustfmt",
        srcs = rust_srcs,
        edition = crate["edition"],
        rust = _rust_root(),
        labels = ["check", "precommit"],
    )

def _store_path(name: str) -> str:
    path = read_root_config("nix", name)
    if not path or not path.startswith("/nix/store/"):
        fail("[nix] {} is not a store path; run tools/buck2".format(name))
    return path

def _rust_root() -> str:
    return _store_path("rust")

# Contract rust-checks-precommit: see buck/CONTRACTS.
def _rust_clippy_check_impl(ctx: AnalysisContext) -> list[Provider]:
    script = ctx.actions.write("clippy.sh", [
        "set -euo pipefail",
        "stamp=$1; shift",
        "status=0",
        "for report in \"$@\"; do if [ -s \"$report\" ]; then cat \"$report\" >&2; status=1; fi; done",
        "[ $status -eq 0 ] && touch \"$stamp\"",
        "exit $status",
    ])
    sub_targets = {}
    stamps = []
    for name, crate in ctx.attrs.crates.items():
        report = crate[RustcExtraOutputsInfo].clippy.compile_output.diag_txt
        stamp = ctx.actions.declare_output("clippy/" + name + ".ok")
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), report),
            env = {"PATH": search_path([ctx.attrs._coreutils])},
            category = "rust_clippy",
            identifier = name,
        )
        sub_targets[name] = [DefaultInfo(default_output = stamp)]
        stamps.append(stamp)
    stamp = ctx.actions.declare_output("stamp")
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), hidden = stamps),
        env = {"PATH": search_path([ctx.attrs._coreutils])},
        category = "rust_clippy",
        identifier = "all",
    )
    return check_providers(ctx, stamp, sub_targets) + [PrecommitInfo(
        deletions = [],
        fix = {},
        inputs = {path: True for path in ctx.attrs.paths},
        per_file = {path: names for path, names in ctx.attrs.paths.items()},
        shared = [],
    )]

# Clippy over a crate's targets with the workspace lints and root clippy.toml,
# as `cargo clippy --all-targets -- -D warnings`: any diagnostic fails it.
# `[<target>]` sub-targets check one target each.
rust_clippy_check = rule(
    impl = _rust_clippy_check_impl,
    attrs = {
        "crates": attrs.dict(attrs.string(), attrs.dep(providers = [RustcExtraOutputsInfo])),
        "labels": attrs.list(attrs.string(), default = []),
        # Repository path -> the sub-targets whose sources include it.
        "paths": attrs.dict(attrs.string(), attrs.list(attrs.string())),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
    },
)

def _rust_fmt_check_impl(ctx: AnalysisContext) -> list[Provider]:
    rustfmt = ctx.attrs.rust + "/bin/rustfmt"
    script = ctx.actions.write("rustfmt.sh", [
        "set -euo pipefail",
        "stamp=$1 rustfmt=$2 edition=$3; shift 3",
        "\"$rustfmt\" --check --edition \"$edition\" \"$@\"",
        "touch \"$stamp\"",
    ])
    prefix = ctx.label.package + "/"
    files = {prefix + f.short_path: f for f in ctx.attrs.srcs}
    sub_targets = {}
    for path, f in sorted(files.items()):
        stamp = ctx.actions.declare_output("rustfmt/" + path + ".ok")
        # rustfmt also reads the file's out-of-line modules.
        ctx.actions.run(
            cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), rustfmt, ctx.attrs.edition, f, hidden = ctx.attrs.srcs),
            env = {"PATH": search_path([ctx.attrs._coreutils])},
            category = "rustfmt",
            identifier = path,
        )
        sub_targets["rustfmt/" + path] = [DefaultInfo(default_output = stamp)]
    stamp = ctx.actions.declare_output("stamp")
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, stamp.as_output(), rustfmt, ctx.attrs.edition, ctx.attrs.srcs),
        env = {"PATH": search_path([ctx.attrs._coreutils])},
        category = "rustfmt",
        identifier = "all",
    )
    return check_providers(ctx, stamp, sub_targets) + [PrecommitInfo(
        deletions = [],
        fix = {},
        inputs = {path: True for path in files},
        per_file = {path: ["rustfmt/" + path] for path in files},
        shared = [],
    )]

# `cargo fmt --check` over a crate's Rust sources with the single toolchain's
# rustfmt; `[rustfmt/<path>]` sub-targets check one file each.
rust_fmt_check = rule(
    impl = _rust_fmt_check_impl,
    attrs = {
        "edition": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        "rust": attrs.string(),
        "srcs": attrs.list(attrs.source()),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
    },
)

# Contract rust-leaf-parity: see buck/CONTRACTS.
def _rust_leaf_parity_test_impl(ctx: AnalysisContext) -> list[Provider]:
    imported = ctx.attrs.buck[NixStorePathInfo]
    command = cmd_args(
        ctx.attrs._python[RunInfo],
        ctx.attrs._script,
        ctx.attrs._nix[RunInfo],
        ctx.attrs.readelf,
        ctx.attrs._nix_store[RunInfo],
        imported.store_path,
        ctx.attrs.nix_attr,
        imported.runtime_refs,
    )
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [command],
            labels = ctx.attrs.labels,
            default_executor = CommandExecutorConfig(local_enabled = True, remote_enabled = False, remote_cache_enabled = False),
            run_from_project_root = True,
            use_project_relative_paths = True,
        ),
    ]

_rust_leaf_parity_test = rule(
    impl = _rust_leaf_parity_test_impl,
    attrs = {
        "buck": attrs.dep(providers = [NixStorePathInfo]),
        "labels": attrs.list(attrs.string(), default = []),
        "nix_attr": attrs.string(),
        "readelf": attrs.string(),
        "_nix": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix")),
        "_nix_store": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix_store")),
        "_python": attrs.default_only(attrs.exec_dep(default = "toolchains//:python")),
        "_script": attrs.default_only(attrs.source(default = "root//buck:rust_parity.py")),
    },
)

def rust_leaf_parity_test(name: str, buck: str, nix_attr: str, labels: list[str] = []):
    """Fails when an imported Buck2 Rust leaf links differently from the flake
    attribute `nix_attr` it replaces. Builds the Nix side, so callers label it
    `heavy`."""
    _rust_leaf_parity_test(
        name = name,
        buck = buck,
        nix_attr = nix_attr,
        readelf = _store_path("bintools") + "/readelf",
        labels = labels,
    )
