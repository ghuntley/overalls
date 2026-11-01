# Package outputs and assembly-built checks as lib.assemble attributes
# (ADR-0269). Buck2 builds each with nix_assemble over the Buck2 artifacts
# (`//:package-<name>`, `//:check-<name>`); the flake exports none of them.

# @cc [owner:ghuntley,label:build] assembly-flake-outputs
# Every package output and every check that is neither a machine test nor a
# repository script check MUST be defined here, never in flake.nix, so Buck2
# reaches it through lib.assemble instead of evaluating flake outputs. Revision-dependent outputs MUST read `revision`, never self.rev.
{ nixpkgs, pkgs, revision, packages, modules, systems, kexec, antithesis, nix-compact, tests }:
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
  ownChecks = {
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
  # @cc [owner:ghuntley,label:verification] explicit-check-catalog
  # Every current required check MUST be explicitly exported: a machine test
  # by its BUCK target (contract machine-test-from-buck), every other test
  # check here. Superseded checks MUST be replaced without compatibility
  # aliases. Release checks MUST use buildPkgs; machine checks MUST use testPkgs.
  # These were catalog.nix's non-machine checks; their paths are unchanged
  # files under nix/verification/tests.
  testChecks = let inherit (tests) buildPkgs testPkgs fixtures diskoModule hegelLibhegel hegelPython featureFleets; in
    buildPkgs.lib.genAttrs [ "marshall-release" "lilly-release" "audi-release" "porsche-release" "ziggy-release" "brady-release" "galileo-release" "enrico-release" "peach-release" "susan-release" ] (name:
      let application = buildPkgs.lib.removeSuffix "-release" name;
      in import ../verification/tests/release {
        pkgs = buildPkgs;
        inherit application;
        package = packages.${application};
        inherit (packages) toolchain;
        cargoVendor = packages.cargoWorkspace.vendor;
      }) // {
      # Keep the engine/binding smoke suite as an explicit check. Machine tests
      # depend on these packages transitively, but that does not make
      # shrinking, replay mismatch handling, or concurrent state-machine
      # cleanup observable when no migrated machine is selected by a CI matrix.
      hegel-framework-packages = buildPkgs.linkFarm "overalls-hegel-framework-packages" [
        { name = "libhegel"; path = hegelLibhegel; }
        { name = "python"; path = hegelPython; }
      ];
      windows-editor-acceptance-harness = import ../verification/tests/machines/windows-editor { pkgs = testPkgs; inherit packages; };
      vscode-web-broker = packages.vscodeWebBroker;
      vscode-web-extensions = import ../domains/artifacts/vscode-web/check-extensions.nix {
        pkgs = buildPkgs;
        vscodeWeb = packages.vscodeWeb;
      };
      underclass-package = packages.underclass;
      underclass-configuration = import ../verification/tests/evaluation/underclass.nix {
        pkgs = testPkgs; inherit nixpkgs; module = modules.default;
      };
      porsche-configuration = import ../verification/tests/evaluation/porsche.nix { pkgs = testPkgs; module = modules.default; };
      logging-transports = import ../verification/tests/evaluation/logging.nix { pkgs = testPkgs; inherit packages; };
      encrypted-crash-dumps = buildPkgs.runCommand "overalls-encrypted-crash-dumps" { nativeBuildInputs = [ buildPkgs.python3 buildPkgs.openssl ]; } ''
        python3 ${../verification/tests/evaluation/encrypted-crash-dumps.py} ${packages.encrypted.toolchain.erlang}/bin/erl
        touch $out
      '';
      public-grafana-configuration = import ../verification/tests/evaluation/public-grafana.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
      runtime-socket-configuration =import ../verification/tests/evaluation/runtime-socket.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
      otel-slo-rules = import ../verification/tests/evaluation/otel-slo-rules.nix { pkgs = buildPkgs; };
      telemetry-diagnostics = import ../verification/tests/evaluation/telemetry-diagnostics.nix { pkgs = buildPkgs; };
      relocation-diagnostics = buildPkgs.runCommand "overalls-relocation-diagnostics-tests" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
        export PYTHONDONTWRITEBYTECODE=1
        python3 -W error ${../verification/tests/evaluation/relocation-diagnostics.py} ${../verification/tests/machines/fleet/relocation-diagnostics.py}
        touch "$out"
      '';
      fleet-monitor = buildPkgs.runCommand "overalls-fleet-monitor-tests" { nativeBuildInputs = [ (buildPkgs.python3.withPackages (p: [ p.hypothesis ])) ]; } ''
        python3 ${../verification/tests/evaluation/fleet-monitor.py} ${../domains/system/fleet-exporter/metrics.py} ${../domains/system/fleet-exporter}/runtime.py
        python3 ${../verification/tests/evaluation/fleet-exporter.py} ${../domains/system/fleet-exporter}
        python3 ${../verification/tests/evaluation/terminal-metrics.py} ${../domains/system/fleet-exporter/terminal_metrics.py}
        touch $out
      '';
      brady-storage = buildPkgs.runCommand "brady-storage-tests" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
        python3 ${../verification/tests/evaluation/brady-storage.py} ${../domains/system/brady/storage.py}
        touch $out
      '';
      brady-configuration = import ../verification/tests/evaluation/brady.nix { pkgs = testPkgs; module = modules.default; };
      fleet-monitor-configuration = import ../verification/tests/evaluation/fleet-monitor.nix { pkgs = testPkgs; module = modules.default; };
      remote-builders-configuration = import ../verification/tests/evaluation/remote-builders.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
      fleet-roster = import ../verification/tests/evaluation/fleet-roster.nix { pkgs = buildPkgs; };
      access-configuration = import ../verification/tests/evaluation/access.nix {
        pkgs = testPkgs; inherit nixpkgs;
        accessModule = modules.security.access; secretsModule = modules.security.secrets;
      };
      fleet-firewall-configuration = import ../verification/tests/evaluation/fleet-firewall.nix {
        pkgs = testPkgs; inherit nixpkgs; module = modules.network.fleet-firewall;
      };
      secret-reconciliation = import ../verification/tests/evaluation/secrets.nix { pkgs = buildPkgs; };
      auto-update-compatibility = import ../verification/tests/evaluation/auto-update-compatibility.nix { pkgs = buildPkgs; };
      auto-update-custody = import ../verification/tests/evaluation/auto-update-custody.nix { pkgs = buildPkgs; };
      ubuntu-build-boundaries = import ../verification/tests/evaluation/ubuntu-build-boundaries.nix { pkgs = buildPkgs; inherit packages; };
      ubuntu-guest-unit = import ../verification/tests/evaluation/ubuntu-guest.nix { pkgs = buildPkgs; inherit packages; };
      foreign-linux-guest-unit = import ../verification/tests/evaluation/foreign-linux-guests.nix { pkgs = buildPkgs; inherit packages; };
      foreign-linux-guest-filesystem = import ../verification/tests/evaluation/foreign-linux-filesystem.nix { pkgs = buildPkgs; inherit packages; };
      editor-target-boundaries = import ../verification/tests/evaluation/editor-target-boundaries.nix { pkgs = buildPkgs; inherit packages; };
      windows-editor-runtime = import ../verification/tests/evaluation/windows-editor-runtime.nix { pkgs = buildPkgs; inherit packages; };
      native-os-guest-unit = import ../verification/tests/evaluation/native-os-guests.nix { pkgs = buildPkgs; inherit packages; };
      native-image-promotion = packages.nativeImagePromotionChecks;
      # Windows guest spike (ADR-0169): VMM identity, firmware provenance and the
      # offline image assembly rules, without installing or booting Windows.
      firecracker-vmm = import ../verification/tests/evaluation/firecracker-vmm.nix { pkgs = buildPkgs; inherit packages; };
      native-vsock-core = import ../domains/artifacts/guest/native-kernels/common { pkgs = buildPkgs; };
      native-fixture-unit = import ../verification/tests/evaluation/native-fixtures.nix { pkgs = buildPkgs; };
      native-reset-probes = import ../verification/tests/evaluation/native-reset-probes.nix { pkgs = buildPkgs; inherit packages; };
      android-guest-unit = import ../verification/tests/evaluation/android-guest.nix { pkgs = buildPkgs; inherit packages; };
      windows-firmware = packages.windowsFirmware;
      windows-guest-unit = import ../verification/tests/evaluation/windows-guest.nix { pkgs = buildPkgs; inherit packages; };
      guest-readiness = import ../verification/tests/evaluation/guest-readiness.nix { pkgs = buildPkgs; };
      guest-ssh = import ../verification/tests/evaluation/guest-ssh.nix { pkgs = buildPkgs; };
      guest-flush = import ../verification/tests/evaluation/guest-flush.nix { pkgs = buildPkgs; };
      guest-toolset = import ../verification/tests/evaluation/guest-toolset.nix { pkgs = buildPkgs; };
      backup-types = import ../verification/tests/evaluation/backup-types.nix { pkgs = buildPkgs; };
      backup-operators = import ../verification/tests/evaluation/backup-operators.nix { pkgs = buildPkgs; };
      backup-custody = import ../verification/tests/evaluation/backup-custody.nix { pkgs = buildPkgs; };
      backup-configuration = import ../verification/tests/evaluation/backup-configuration.nix { pkgs = testPkgs; module = modules.default; };
      private-services-guest = import ../verification/tests/evaluation/private-services.nix { pkgs = buildPkgs; };
      audi-private-pki = import ../verification/tests/evaluation/private-pki.nix { pkgs = buildPkgs; };
      inception-runtime = import ../verification/tests/evaluation/inception-runtime.nix { pkgs = buildPkgs; inherit (packages) toolchain; };
      inception-image-builder = import ../verification/tests/evaluation/inception-image-builder.nix { pkgs = buildPkgs; inherit packages; };
      inception-probe = import ../verification/tests/evaluation/inception-probe.nix { pkgs = testPkgs; };
      inception-systemd = import ../verification/tests/evaluation/inception-systemd.nix { pkgs = testPkgs; };
      inception-proof-broker = buildPkgs.runCommand "inception-proof-broker-check" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
        export PYTHONDONTWRITEBYTECODE=1
        python3 -W error ${../verification/tests/evaluation/inception-proof-broker.py} ${../domains/artifacts/guest/inception} ${packages.audi}/bin/audi
        touch $out
      '';
      module-configuration = import ../verification/tests/evaluation/module-configuration.nix {
        pkgs = testPkgs;
        inherit nixpkgs;
        module = modules.default;
        sysctlModule = modules.platform.sysctl;
      };
      storage-configuration = import ../verification/tests/evaluation/storage-configuration.nix {
        pkgs = testPkgs;
        inherit fixtures;
      };
      ziggy-configuration = import ../verification/tests/evaluation/ziggy.nix { pkgs = testPkgs; module = modules.default; inherit packages; };
      audi-configuration = import ../verification/tests/evaluation/audi.nix { pkgs = testPkgs; module = modules.default; };
      nix-gc-configuration = import ../verification/tests/evaluation/nix-gc.nix {
        pkgs = testPkgs; inherit nixpkgs; module = modules.default; inherit fixtures;
      };
      nix-cache-configuration = import ../verification/tests/evaluation/nix-cache.nix {
        pkgs = testPkgs; inherit nixpkgs fixtures; module = modules.default;
      };
      tailscale-configuration = import ../verification/tests/evaluation/tailscale.nix {
        pkgs = testPkgs; inherit nixpkgs; module = modules.default; inherit fixtures;
      };
      fleet-guest-trust-configuration = import ../verification/tests/evaluation/fleet-guest-trust.nix {
        pkgs = buildPkgs; variants = featureFleets;
      };
      acme-lookup = import ../verification/tests/evaluation/acme-lookup.nix { pkgs = testPkgs; };
      peach-service = import ../verification/tests/evaluation/peach-service.nix { pkgs = testPkgs; packages = packages; };
      enrollment-configuration = import ../verification/tests/evaluation/enrollment-configuration.nix { pkgs = testPkgs; inherit nixpkgs diskoModule; module = modules.default; };
      enrollment-preparation = import ../verification/tests/evaluation/enrollment-preparation.nix { pkgs = buildPkgs; };
      host-planning = import ../verification/tests/evaluation/host-planning.nix { pkgs = buildPkgs; };
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

  # The machine tests are BUCK targets (contract machine-test-from-buck); the
  # repository script checks (conflict markers, pins, Rust lints, the package
  # input lock, the PowerShell installer and Marvin) are Buck2 targets of their own.
  checks = assert lib.assertMsg (lib.intersectLists (lib.attrNames testChecks) (lib.attrNames ownChecks) == [ ])
    "outputs.nix: a check is defined twice"; testChecks // ownChecks;
}
