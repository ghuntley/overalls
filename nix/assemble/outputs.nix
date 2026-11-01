# Package outputs and assembly-built checks as lib.assemble attributes
# (ADR-0269). Buck2 builds each with nix_assemble over the Buck2 artifacts
# (`//:package-<name>`, `//:check-<name>`); the flake exports none of them.

# @cc [owner:ghuntley,label:build] assembly-flake-outputs
# Every package output and every check that is neither a machine test nor a
# repository script check MUST be defined here, never in flake.nix, so Buck2
# reaches it through lib.assemble instead of evaluating flake outputs. Revision-dependent outputs MUST read `revision`, never self.rev.
{ nixpkgs, pkgs, revision, packages, modules, systems, kexec, antithesis, nix-compact }:
let
  inherit (nixpkgs) lib;
  system = "x86_64-linux";
  stablePkgs = nixpkgs.legacyPackages.${system};
  built = packages;
  # Hermetic Mila journey backend launcher (ADR-0264); the app runs it.
  milaJourneyFixture = import ../verification/tests/machines/mila-journey/launcher.nix {
    inherit nixpkgs; pkgs = stablePkgs;
    module = modules.default; inherit packages;
  };
in
{
  packages = {
    default = built.marshall;
    mila-journey-fixture = milaJourneyFixture;
    service-marshall = built.marshall;
    service-lilly = built.lilly;
    service-audi = built.audi;
    service-porsche = built.porsche;
    service-ziggy = built.ziggy;
    service-galileo = built.galileo;
    service-enrico = built.enrico;
    service-brady = built.brady;
    service-peach = built.peach;
    service-susan = built.susan;
    image-susan = built.mkSusanImage (if revision == null then "unknown" else revision);
    guest-nixos = built.guest;
    android-sdk = built.androidSdk;
    guest-android = built.androidGuest;
    guest-ubuntu = built.ubuntuGuest;
    guest-arch = built.archGuest;
    guest-alma = built.almaLinuxGuest;
    freebsd-kernel-receipt = built.nativeKernels.freebsdKernel;
    freebsd-kernel-candidate = built.nativeKernels.freebsdCandidate;
    freebsd-image-candidate = built.freebsdImageCandidate;
    omnios-image-candidate-kit = built.omniosImageCandidateKit;
    omnios-image-candidate = built.omniosImageCandidate;
    freebsd-transport-probe-image = built.freebsdTransportProbeImage;
    freebsd-kernel-fault = built.nativeKernels.freebsdFaultCandidate;
    freebsd-fault-probe-image = built.freebsdFaultProbeImage;
    native-vsock-core-check = built.nativeKernels.vsockCoreCheck;
    illumos-sdk = built.nativeKernels.illumosToolchain.sysroot;
    illumos-kernel-receipt = built.nativeKernels.illumosKernel;
    illumos-kernel-candidate-objects = built.nativeKernels.illumosCandidate;
    illumos-sdk-receipt = built.nativeKernels.illumosSdk;
    guest-freebsd = built.freebsdGuest;
    guest-omnios = built.omniosGuest;
    guest-illumos = built.illumosGuest;
    guest-inception = built.inceptionGuest;
    guest-windows = built.windowsGuest;
    host-tools = built.hostTools;
    host = import ../domains/artifacts/host { pkgs = stablePkgs; };
    host-kexec = kexec;
    tool-nix-compact = nix-compact.lib.mkPackage { inherit pkgs; };
    tool-nix-compact-host = nix-compact.lib.mkPackage { pkgs = stablePkgs; };
    tool-lyra = built.lyra;
    # mila-build's Linux dev and release targets (ADR-0235).
    tool-mila-linux-native = built.mila.linuxNative;
    tool-mila-linux-release = built.mila.linuxRelease;
    # Sources and pinned dependencies for the Windows build (ADR-0235).
    tool-mila-source-bundle = built.mila.sourceBundle;
    # Native Windows sources (WinUI/Rust/localization only; no Flutter or Dart).
    tool-mila-windows-source-bundle = built.mila.windowsSourceBundle;
    tool-mila-rust = built.mila.rust;
    tool-github-managed = built.githubTools.release;
    tool-vscode-web = built.vscodeWeb;
    tool-vscode-web-broker = built.vscodeWebBroker;
    tool-vscode-web-broker-windows = built.windowsEditorBroker;
    tool-update-vscode-extensions = built.updateVscodeExtensions;
    tool-underclass = built.underclass;
    tool-nativelink = built.nativelink;
    tool-smtprelay = built.smtprelay;
    security-user-recipients = built.userRecipients;
    security-secrets = built.secrets;
    security-marshall-encrypted-dumps = built.encrypted.marshall;
    security-lilly-encrypted-dumps = built.encrypted.lilly;
    security-audi-encrypted-dumps = built.encrypted.audi;
    security-brady-encrypted-dumps = built.encrypted.brady;
    security-porsche-encrypted-dumps = built.encrypted.porsche;
    security-ziggy-encrypted-dumps = built.encrypted.ziggy;
    security-galileo-encrypted-dumps = built.encrypted.galileo;
    security-enrico-encrypted-dumps = built.encrypted.enrico;
    security-peach-encrypted-dumps = built.encrypted.peach;
    security-susan-encrypted-dumps = built.encrypted.susan;
  } // (lib.mapAttrs' (name: context:
    lib.nameValuePair "antithesis-${name}-context" context
  ) antithesis.contexts);

  # Checks beyond the machine-test catalog. The repository script checks
  # (conflict markers, pins, Rust lints, the package input lock, the
  # PowerShell installer and Marvin) are Buck2 targets of their own.
  checks = {
    nix-compact-core = nix-compact.lib.mkCoreCheck { inherit pkgs; };
    nix-compact-native = nix-compact.lib.mkNativeCheck { inherit pkgs; };
    nix-compact-native-host = nix-compact.lib.mkNativeCheck { pkgs = stablePkgs; };
    nix-compact-configuration = import ../domains/artifacts/nix-compact/configuration-check.nix {
      inherit nixpkgs; nixCompact = nix-compact;
    };
    # Built (not booted) by the cache job so the linux-native journey
    # substitutes the fixture VM closure instead of building it.
    mila-journey-fixture = milaJourneyFixture;
    fleet-builds-configuration = import ../verification/tests/evaluation/fleet-builds.nix {
      inherit nixpkgs; pkgs = stablePkgs;
      module = modules.default; fleetModule = modules.fleetBuilds;
      hosts = systems;
    };
    terminald-windows = built.terminaldWindows;
    lyra = built.lyra.tests;
    mila-rust = built.mila.rustCheck;
  };
}
