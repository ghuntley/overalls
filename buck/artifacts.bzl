# The single artifact dict every assembly reads: machine tests (buck/nixos.bzl)
# and host deployments. Switching a leaf's default is a change here or in the
# per-language dicts it merges (ADR-0269).
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.

load(":mix_artifacts.bzl", "MIX_ARTIFACTS")
load(":rust_artifacts.bzl", "RUST_ARTIFACTS")

def _merge(*dicts) -> dict[str, str]:
    merged = {}
    for d in dicts:
        for name, target in d.items():
            if name in merged:
                fail("assembly artifact {} is defined twice".format(name))
            merged[name] = target
    return merged

ASSEMBLY_ARTIFACTS = _merge(RUST_ARTIFACTS, MIX_ARTIFACTS)
