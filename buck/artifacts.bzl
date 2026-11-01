# The single artifact dict every assembly reads: machine tests (buck/nixos.bzl)
# and host deployments. Switching a leaf's default is a change here or in the
# per-language dicts it merges (ADR-0269).
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.

load(":mix_artifacts.bzl", "MIX_ARTIFACTS")
load(":rust_artifacts.bzl", "RUST_ARTIFACTS", "TEST_ARTIFACTS")

def _merge(*dicts) -> dict[str, str]:
    merged = {}
    for d in dicts:
        for name, target in d.items():
            if name in merged:
                fail("assembly artifact {} is defined twice".format(name))
            merged[name] = target
    return merged

# Buck2 packages that are neither Rust leaves nor Mix releases: the managed
# GitHub tools release (gh and git-lfs for every guest platform) and Marvin's
# browser-extension release. Contract github-tools-from-buck2: see
# nix/domains/artifacts/guest/github/default.nix.
PACKAGE_ARTIFACTS = {
    "github-tools": "root//nix/domains/artifacts/guest/github:release-import",
    "marvin": "root//marvin:import",
}

ASSEMBLY_ARTIFACTS = _merge(RUST_ARTIFACTS, MIX_ARTIFACTS, PACKAGE_ARTIFACTS)

# Machine tests also get the test-only fixtures; hosts never do.
MACHINE_TEST_ARTIFACTS = _merge(ASSEMBLY_ARTIFACTS, TEST_ARTIFACTS)
