# Rust and C linker toolchains from Nix store paths (ADR-0269, ADR-0273).
# Contract nix-rust-toolchain: see toolchains/CONTRACTS.

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "CxxPlatformInfo",
    "CxxToolchainInfo",
    "DepTrackingMode",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "RuntimeDependencyHandling",
    "ShlibInterfacesMode",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//linking:link_info.bzl", "LinkStyle")
load("@prelude//linking:lto.bzl", "LtoMode")
load("@prelude//rust:rust_toolchain.bzl", "PanicRuntime", "RustToolchainInfo")
load(":nix.bzl", "NO_NIX")

def _store_path(name: str) -> str:
    path = read_root_config("nix", name)
    if NO_NIX:
        # No Rust or C target builds without Nix; analysis of one fails.
        return path or "/unavailable-without-nix"
    if not path or not path.startswith("/nix/store/"):
        fail("[nix] {} is not a store path; run tools/buck2".format(name))
    return path

def _run(path: str) -> RunInfo:
    return RunInfo(args = cmd_args(path))

def _nix_cxx_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    bintools = ctx.attrs.bintools
    return [
        DefaultInfo(),
        CxxToolchainInfo(
            internal_tools = ctx.attrs._internal_tools[CxxInternalTools],
            linker_info = LinkerInfo(
                # The Nix cc wrapper: it adds glibc's and every -L store
                # directory's rpath, as buildRustPackage's links do.
                linker = _run(ctx.attrs.linker or ctx.attrs.cc),
                linker_flags = ctx.attrs.link_flags,
                post_linker_flags = [],
                archiver = _run(bintools + "/ar"),
                archiver_type = "gnu",
                archiver_supports_argfiles = True,
                generate_linker_maps = False,
                lto_mode = LtoMode("none"),
                type = LinkerType("gnu"),
                link_binaries_locally = True,
                link_libraries_locally = True,
                archive_objects_locally = True,
                use_archiver_flags = True,
                static_dep_runtime_ld_flags = [],
                static_pic_dep_runtime_ld_flags = [],
                shared_dep_runtime_ld_flags = [],
                independent_shlib_interface_linker_flags = [],
                shlib_interfaces = ShlibInterfacesMode("disabled"),
                link_style = LinkStyle("static"),
                link_weight = 1,
                binary_extension = "",
                object_file_extension = "o",
                shared_library_name_default_prefix = "lib",
                shared_library_name_format = "{}.so",
                shared_library_versioned_name_format = "{}.so.{}",
                static_library_extension = "a",
                force_full_hybrid_if_capable = False,
                is_pdb_generated = False,
                link_ordering = None,
            ),
            bolt_enabled = False,
            binary_utilities_info = BinaryUtilitiesInfo(
                nm = _run(bintools + "/nm"),
                objcopy = _run(bintools + "/objcopy"),
                objdump = _run(bintools + "/objdump"),
                ranlib = _run(bintools + "/ranlib"),
                strip = _run(bintools + "/strip"),
                dwp = None,
            ),
            cxx_compiler_info = CxxCompilerInfo(
                compiler = _run(ctx.attrs.cxx),
                preprocessor_flags = [],
                compiler_flags = [],
                compiler_type = "gcc",
            ),
            c_compiler_info = CCompilerInfo(
                compiler = _run(ctx.attrs.cc),
                preprocessor_flags = [],
                compiler_flags = [],
                compiler_type = "gcc",
            ),
            as_compiler_info = CCompilerInfo(compiler = _run(ctx.attrs.cc), compiler_type = "gcc"),
            asm_compiler_info = CCompilerInfo(compiler = _run(ctx.attrs.cc), compiler_type = "gcc"),
            header_mode = HeaderMode("symlink_tree_only"),
            cpp_dep_tracking_mode = DepTrackingMode("makefile"),
            pic_behavior = PicBehavior("supported"),
            llvm_link = None,
            use_dep_files = True,
            runtime_dependency_handling = RuntimeDependencyHandling("no_symlink"),
        ),
        CxxPlatformInfo(name = "x86_64"),
    ]

_nix_cxx_toolchain = rule(
    impl = _nix_cxx_toolchain_impl,
    attrs = {
        "bintools": attrs.string(),
        "cc": attrs.string(),
        "cxx": attrs.string(),
        "link_flags": attrs.list(attrs.string(), default = []),
        # A linker other than the cc wrapper: rust-lld for static musl links.
        "linker": attrs.option(attrs.string(), default = None),
        "_internal_tools": attrs.default_only(attrs.exec_dep(providers = [CxxInternalTools], default = "prelude//cxx/tools:internal_tools")),
    },
    is_toolchain_rule = True,
)

def rust_lld() -> str:
    """The single toolchain's bundled lld, which links static musl executables."""
    return _store_path("rust") + "/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld"

def nix_cxx_toolchain(name: str, **kwargs):
    """The Nix stdenv C compiler and binutils, as Buck2's C/linker toolchain."""
    _nix_cxx_toolchain(
        name = name,
        cc = _store_path("cc_hermetic"),
        cxx = _store_path("cxx"),
        bintools = _store_path("bintools"),
        **kwargs
    )

def _nix_rust_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    rust = ctx.attrs.rust
    return [
        DefaultInfo(),
        RustToolchainInfo(
            compiler = _run(rust + "/bin/rustc"),
            rustdoc = _run(rust + "/bin/rustdoc"),
            clippy_driver = _run(rust + "/bin/clippy-driver"),
            clippy_toml = ctx.attrs.clippy_toml[DefaultInfo].default_outputs[0] if ctx.attrs.clippy_toml else None,
            default_edition = "2021",
            panic_runtime = PanicRuntime("unwind"),
            nightly_features = False,
            doctests = False,
            report_unused_deps = False,
            rustc_target_triple = ctx.attrs.rustc_target_triple,
            rustc_flags = ctx.attrs.rustc_flags,
            rustc_binary_flags = [],
            rustc_test_flags = [],
            rustdoc_flags = [],
            allow_lints = [],
            deny_lints = [],
            warn_lints = [],
        ),
    ]

_nix_rust_toolchain = rule(
    impl = _nix_rust_toolchain_impl,
    attrs = {
        "clippy_toml": attrs.option(attrs.dep(providers = [DefaultInfo]), default = None),
        "rust": attrs.string(),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        "rustc_target_triple": attrs.string(default = "x86_64-unknown-linux-gnu"),
    },
    is_toolchain_rule = True,
)

def nix_rust_toolchain(name: str, **kwargs):
    """The single rust-overlay toolchain (nix/rust-toolchain.nix)."""
    _nix_rust_toolchain(name = name, rust = _store_path("rust"), **kwargs)
