# Execution platform for the Buck2 migration (ADR-0269, ADR-0272).

load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")
load("@prelude//platforms:defs.bzl", "host_configuration")

def _overalls_execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})
    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = False,
            remote_cache_enabled = ctx.attrs.remote_cache,
            allow_cache_uploads = ctx.attrs.remote_cache and ctx.attrs.upload,
            use_windows_path_separators = ctx.attrs.use_windows_path_separators,
        ),
    )
    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(
            platforms = [platform],
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

_overalls_execution_platform = rule(
    impl = _overalls_execution_platform_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "remote_cache": attrs.bool(),
        "upload": attrs.bool(),
        "use_windows_path_separators": attrs.bool(),
    },
)

# Contract buck2-remote-cache-optional: see buck/CONTRACTS.
def overalls_execution_platform(name: str, **kwargs):
    _overalls_execution_platform(
        name = name,
        cpu_configuration = host_configuration.cpu,
        os_configuration = host_configuration.os,
        remote_cache = bool(read_root_config("buck2_re_client", "address", "") or
                            read_root_config("buck2_re_client", "action_cache_address", "")),
        # Buck2 uploads only when both the platform and the action allow it;
        # one native key turns on both.
        upload = read_root_config("buck2", "default_allow_cache_upload", "false") == "true",
        use_windows_path_separators = host_info().os.is_windows,
        **kwargs
    )
