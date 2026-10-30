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
            remote_enabled = ctx.attrs.remote_execution,
            remote_cache_enabled = ctx.attrs.remote_cache,
            # Part of every action digest, cached or executed, so cache-only
            # hosts and executing clients share action-cache entries.
            remote_execution_properties = ctx.attrs.remote_properties,
            remote_execution_use_case = "buck2-default",
            # Remote first; local only when remote execution fails as
            # infrastructure (an unreachable scheduler, or no worker holding
            # these cells, which the scheduler fails after a short timeout).
            # local_only actions never leave the machine.
            use_limited_hybrid = True,
            allow_limited_hybrid_fallbacks = True,
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
        "remote_execution": attrs.bool(),
        "remote_properties": attrs.dict(attrs.string(), attrs.string()),
        "upload": attrs.bool(),
        "use_windows_path_separators": attrs.bool(),
    },
)

# Contracts buck2-remote-cache-optional and buck2-remote-execution-optional:
# see buck/CONTRACTS.
def overalls_execution_platform(name: str, **kwargs):
    remote_cache = bool(read_root_config("buck2_re_client", "address", "") or
                        read_root_config("buck2_re_client", "action_cache_address", ""))
    cells = read_root_config("nix", "cells_id", "")

    # Only Linux x86_64 has workers, and only an explicit opt-in executes
    # remotely: hosts write remote_execution = false and use a read-only
    # listener without an execution service.
    remote_execution = (
        remote_cache and cells != "" and
        host_info().os.is_linux and host_info().arch.is_x86_64 and
        read_root_config("overalls", "remote_execution", "false") == "true"
    )
    _overalls_execution_platform(
        name = name,
        cpu_configuration = host_configuration.cpu,
        os_configuration = host_configuration.os,
        remote_cache = remote_cache,
        remote_execution = remote_execution,
        remote_properties = {"overalls-cells": cells} if cells else {},
        # Buck2 uploads only when both the platform and the action allow it;
        # one native key turns on both.
        upload = read_root_config("buck2", "default_allow_cache_upload", "false") == "true",
        use_windows_path_separators = host_info().os.is_windows,
        **kwargs
    )
