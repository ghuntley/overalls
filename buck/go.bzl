# Go binaries and tests from Nix-vendored third-party modules (ADR-0269, M7).
# Contract go-binary-nix-parity: see buck/CONTRACTS.

load(":checks.bzl", "check_providers", "tool", "tool_attr")

# Reproduces nixpkgs buildGoModule's environment for a custom buildPhase:
# GOTOOLCHAIN=local, GOPROXY=off, GOSUMDB=off, CGO_ENABLED=0 and
# GOFLAGS="-mod=vendor -trimpath" (or GOPROXY=file://<modules> and "-trimpath"
# for proxyVendor). The tree is built outside the repository so Go never finds
# the checkout's .git and never stamps VCS metadata that Nix builds lack.
_PREPARE = [
    "set -euo pipefail",
    "root=$PWD",
    "abs() { case $1 in /*) printf '%s' \"$1\" ;; *) printf '%s/%s' \"$root\" \"$1\" ;; esac; }",
    "work=$(mktemp -d /tmp/overalls-go.XXXXXX)",
    "trap 'chmod -R u+w \"$work\"; rm -rf \"$work\"' EXIT",
    "export HOME=\"$work/home\" GOCACHE=\"$work/go-cache\" GOPATH=\"$work/go\"",
    "export GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off CGO_ENABLED=0",
    "cp -r --no-preserve=mode \"$GO_SOURCE\" \"$work/src\"",
    "cd \"$work/src\"",
    "for p in $GO_PATCHES; do patch -p1 < \"$(abs \"$p\")\"; done",
    "mkdir -p \"$GO_OVERLAY_DIR\"",
    "for f in $GO_OVERLAY; do cp \"$(abs \"$f\")\" \"$GO_OVERLAY_DIR/\"; done",
    "if [ \"$GO_VENDOR_MODE\" = proxy ]; then",
    "  export GOPROXY=\"file://$GO_MODULES\" GOFLAGS=-trimpath",
    "else",
    "  rm -rf vendor; cp -r --no-preserve=mode \"$GO_MODULES\" vendor",
    "  export GOFLAGS='-mod=vendor -trimpath'",
    "fi",
    "for p in $GO_VENDOR_PATCHES; do patch -p1 < \"$(abs \"$p\")\"; done",
]

def _env(ctx: AnalysisContext) -> dict:
    return {
        "GO_MODULES": tool(ctx.attrs.modules),
        "GO_OVERLAY": cmd_args(ctx.attrs.overlay, delimiter = " "),
        "GO_OVERLAY_DIR": ctx.attrs.overlay_dir,
        "GO_PATCHES": cmd_args(ctx.attrs.patches, delimiter = " "),
        "GO_SOURCE": tool(ctx.attrs.source),
        "GO_VENDOR_MODE": ctx.attrs.vendor_mode,
        "GO_VENDOR_PATCHES": cmd_args(ctx.attrs.vendor_patches, delimiter = " "),
        "PATH": "{}/bin:{}:{}".format(tool(ctx.attrs._go), tool(ctx.attrs._coreutils), tool(ctx.attrs._patch).rsplit("/", 1)[0]),
    }

_COMMON_ATTRS = {
    "labels": attrs.list(attrs.string(), default = []),
    "modules": attrs.exec_dep(doc = "toolchains// input: vendor dir or proxyVendor module cache"),
    "overlay": attrs.list(attrs.source(), default = []),
    "overlay_dir": attrs.string(default = "internal/overalls"),
    "patches": attrs.list(attrs.source(), default = []),
    "source": attrs.exec_dep(doc = "toolchains// input: unpacked upstream source"),
    "vendor_mode": attrs.enum(["vendor", "proxy"], default = "vendor"),
    "vendor_patches": attrs.list(attrs.source(), default = []),
    "_bash": tool_attr("bash"),
    "_coreutils": tool_attr("coreutils"),
    "_go": tool_attr("go"),
    "_patch": tool_attr("patch"),
}

def _go_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    exe = ctx.attrs.out + (".exe" if ctx.attrs.goos == "windows" else "")
    out = ctx.actions.declare_output(exe)
    script = ctx.actions.write("build.sh", _PREPARE + [
        "GOOS=\"$GO_OS\" GOARCH=\"$GO_ARCH\" go build -ldflags \"$GO_LDFLAGS\" -o \"$work/out\" \"$GO_PACKAGE\"",
        # stdenv's fixup phase runs `strip -S -p` over bin/ and ignores files
        # that strip cannot handle (PE executables).
        "if [ \"$GO_STRIP\" = 1 ]; then \"$GO_STRIP_TOOL\" -S -p \"$work/out\" 2>/dev/null || true; fi",
        "cd \"$root\"",
        "install -m 0755 \"$work/out\" \"$1\"",
    ])
    env = _env(ctx)
    env.update({
        "GO_ARCH": ctx.attrs.goarch,
        "GO_LDFLAGS": ctx.attrs.ldflags,
        "GO_OS": ctx.attrs.goos,
        "GO_PACKAGE": ctx.attrs.package,
        "GO_STRIP": "1" if ctx.attrs.strip else "0",
        "GO_STRIP_TOOL": tool(ctx.attrs._strip),
    })
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, out.as_output()),
        env = env,
        category = "go_build",
    )
    providers = [DefaultInfo(default_output = out)]
    if ctx.attrs.goos == "linux":
        providers.append(RunInfo(args = cmd_args(out)))
    return providers

# A statically linked (CGO_ENABLED=0) Go binary for one GOOS/GOARCH.
go_binary = rule(
    impl = _go_binary_impl,
    attrs = _COMMON_ATTRS | {
        "goarch": attrs.string(default = "amd64"),
        "goos": attrs.string(default = "linux"),
        "ldflags": attrs.string(default = ""),
        "out": attrs.string(),
        "package": attrs.string(),
        "strip": attrs.bool(default = True),
        "_strip": tool_attr("strip"),
    },
)

def _go_test_impl(ctx: AnalysisContext) -> list[Provider]:
    stamp = ctx.actions.declare_output("stamp")
    script = ctx.actions.write("test.sh", _PREPARE + [
        # buildGoModule's checkPhase drops -trimpath for tests.
        "export GOFLAGS=\"${GOFLAGS//-trimpath/}\"",
        "go test $GO_TEST_PACKAGES",
        "cd \"$root\"",
        "touch \"$1\"",
    ])
    env = _env(ctx)
    env["GO_TEST_PACKAGES"] = " ".join(ctx.attrs.packages)
    ctx.actions.run(
        cmd_args(tool(ctx.attrs._bash), script, stamp.as_output()),
        env = env,
        category = "go_test",
    )
    return check_providers(ctx, stamp)

# `go test` over packages of the patched tree; the stamp is the cached result.
go_test = rule(
    impl = _go_test_impl,
    attrs = _COMMON_ATTRS | {"packages": attrs.list(attrs.string())},
)
