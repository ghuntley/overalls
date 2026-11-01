# Fleet host targets (ADR-0271). Contract fleet-host-deployment-target: see
# buck/CONTRACTS.

load(":artifacts.bzl", "ASSEMBLY_ARTIFACTS")
load(":assemble.bzl", "nix_assemble")
load(":nix.bzl", "nix_owned")

def fleet_host(params: dict[str, bool | str | list[str]] = {}):
    """Declares a fleet host package: its owned files and system targets.

    The host is the package directory name, as in the inventory. nix_assemble
    reads the candidate revision from `-c overalls.revision=<commit>` at load
    time, so it is part of the action key and replaces self.rev (contract
    deployment-revision-source); without it the system names "unknown".

    `params` are this host's lib.assemble parameters (for example
    `privateServiceRoots = ["secrets/private-services-root.pem"]`), passed to
    every system target so the host's deployment, base, installer and
    enrollment agree; lib.assemble refuses unknown keys and types (contract
    assembly-params-validated). Omitted keys keep the fleet-wide defaults.
    """
    host = native.package_name().split("/")[-1]
    nix_owned()

    # The enrolled bundle the updater activates: the system plus its deployment
    # descriptor (contract deployment-descriptor-baseline).
    nix_assemble(
        name = "deployment",
        attr = "systems.{}.config.system.build.overallsDeployment".format(host),
        # Every Buck2-built leaf replaces its Nix build, as in machine tests
        # (ADR-0269).
        artifacts = ASSEMBLY_ARTIFACTS,
        params = params,
        labels = ["deployment"],
        visibility = ["PUBLIC"],
    )

    # The unenrolled installation base and its installer bundle.
    nix_assemble(
        name = "base",
        attr = "systems.{}-base.config.system.build.toplevel".format(host),
        artifacts = ASSEMBLY_ARTIFACTS,
        params = params,
        visibility = ["PUBLIC"],
    )
    nix_assemble(
        name = "install",
        attr = "systems.{}-base.config.system.build.overallsHostInstall".format(host),
        artifacts = ASSEMBLY_ARTIFACTS,
        params = params,
        visibility = ["PUBLIC"],
    )

    # What `host enroll` (nix/domains/artifacts/host/cli.py) builds. No labels:
    # :deployment alone carries "deployment", which CI's host builds select.
    for name, build in [
        # The enrolled system, built before enrollment activates it.
        ("system", "toplevel"),
        # The installation binding enrollment must not change.
        ("binding", "overallsHostBinding"),
        # The activation enrollment copies to the host and runs.
        ("enrollment", "overallsHostEnrollment"),
    ]:
        nix_assemble(
            name = name,
            attr = "systems.{}.config.system.build.{}".format(host, build),
            artifacts = ASSEMBLY_ARTIFACTS,
            params = params,
            visibility = ["PUBLIC"],
        )
