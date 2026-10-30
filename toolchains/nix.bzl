# Contract nix-toolchain-paths-in-action-keys: see toolchains/CONTRACTS.

NixToolInfo = provider(fields = {"path": str})

def _nix_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    return [DefaultInfo(), NixToolInfo(path = ctx.attrs.path), RunInfo(args = cmd_args(ctx.attrs.path))]

_nix_tool = rule(
    impl = _nix_tool_impl,
    attrs = {"path": attrs.string()},
)

def nix_tool(name: str, **kwargs):
    path = read_root_config("nix", name)
    if not path or not path.startswith("/nix/store/"):
        fail("[nix] {} is not a store path; run tools/buck2".format(name))
    _nix_tool(name = name, path = path, **kwargs)
