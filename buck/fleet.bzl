# Fleet host targets (ADR-0271). Contract fleet-host-deployment-target: see
# buck/CONTRACTS.

load(":artifacts.bzl", "ASSEMBLY_ARTIFACTS")
load(":assemble.bzl", "nix_assemble")
load(":nix.bzl", "nix_owned")

def fleet_host():
    """Declares a fleet host package: its owned files and system targets.

    The host is the package directory name, as in the inventory. nix_assemble
    reads the candidate revision from `-c overalls.revision=<commit>` at load
    time, so it is part of the action key and replaces self.rev (contract
    deployment-revision-source); without it the system names "unknown".
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
        labels = ["deployment"],
        visibility = ["PUBLIC"],
    )

    # The unenrolled installation base and its installer bundle.
    nix_assemble(
        name = "base",
        attr = "systems.{}-base.config.system.build.toplevel".format(host),
        artifacts = ASSEMBLY_ARTIFACTS,
        visibility = ["PUBLIC"],
    )
    nix_assemble(
        name = "install",
        attr = "systems.{}-base.config.system.build.overallsHostInstall".format(host),
        artifacts = ASSEMBLY_ARTIFACTS,
        visibility = ["PUBLIC"],
    )
