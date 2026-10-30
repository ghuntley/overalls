# Contract nix-toolchain-paths-in-action-keys: see toolchains/CONTRACTS.

NixToolInfo = provider(fields = {"path": str})

# `tools/buck2 --no-nix` (runners without Nix, ADR-0269 M9) loads the same
# graph with `[overalls] no_nix = true`. Only non_hermetic targets build there;
# a tool its kit does not name fails when a target is analysed, not at load.
NO_NIX = read_root_config("overalls", "no_nix", "false") == "true"

def _nix_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    if not ctx.attrs.path:
        fail("{} is not available without Nix (tools/buck2 --no-nix builds only non_hermetic targets)".format(ctx.label.name))
    return [DefaultInfo(), NixToolInfo(path = ctx.attrs.path), RunInfo(args = cmd_args(ctx.attrs.path))]

_nix_tool = rule(
    impl = _nix_tool_impl,
    attrs = {"path": attrs.string()},
)

def nix_tool(name: str, **kwargs):
    path = read_root_config("nix", name)
    if NO_NIX:
        # The kit's tools come from PATH by name: non_hermetic by definition.
        _nix_tool(name = name, path = path or "", **kwargs)
        return
    if not path or not path.startswith("/nix/store/"):
        fail("[nix] {} is not a store path; run tools/buck2".format(name))
    _nix_tool(name = name, path = path, **kwargs)
