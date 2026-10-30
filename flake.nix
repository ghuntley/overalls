{
  description = "Marshall control plane and Lilly Firecracker hosts";

  # @cc [owner:ghuntley,label:build] flake-package-inputs
  # Application packages MUST use the same locked package input as devenv;
  # NixOS host modules MUST use the separately locked stable NixOS input.
  # buildNixpkgs follows the same devenv-nixpkgs branch as devenv.yaml and is
  # pinned only by flake.lock; the package-input-lock check MUST fail when
  # flake.lock and devenv.lock lock different revisions.
  inputs = {
    nix-compact.url = "github:ghuntley/nix-compact/84475ca7652fcdabd36428d80d4c1122bb03bab6";
    buildNixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-images = {
      url = "github:nix-community/nixos-images/4fcaaefd02b5bc777f99afd620cb1a9aa1fb5b83";
      inputs.nixos-stable.follows = "nixpkgs";
      inputs.nixos-unstable.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/ff8702b4de27f72b4c78573dfb89ec74e36abdf1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Fleet build scheduling (ADR-0248): host modules and packages follow the
    # stable NixOS input; crane stays separately locked.
    tribuchet = {
      url = "github:Mic92/tribuchet/1a1002096f3c1f6d7b32b3ef9822e542b095a948";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "";
      inputs.nix-darwin.follows = "";
    };
    nix-grpc-store = {
      url = "github:Mic92/nix-grpc-store/17f4ff97a6fdac3c68458a0f15210762eba261ea";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.niks3.inputs.treefmt-nix.follows = "";
    };
  };

  outputs = { self, buildNixpkgs, nixpkgs, disko, nixos-images, nix-compact, tribuchet, nix-grpc-store }:
    let
      system = "x86_64-linux";
      pkgs = buildNixpkgs.legacyPackages.${system};
      built = import ./nix/domains/artifacts/default.nix { inherit pkgs; };
      antithesisImages = import ./antithesis/nix { inherit pkgs nixpkgs; };
      hostPackages = import ./nix/domains/artifacts/default.nix {
        inherit pkgs;
        privateServiceRoots = [ ./secrets/private-services-root.pem ./secrets/brady-root.pem ];
      };
      inventory = import ./nix/platform/hosts/inventory.nix { inherit (nixpkgs) lib; };
      fixtures = import ./nix/verification/tests/fixtures/hosts/configurations.nix { inherit nixpkgs disko; modules = self.nixosModules; };
      hostSystem = name: enrolled: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { overallsPackages = hostPackages; };
        modules = [ self.nixosModules.default self.nixosModules.fleetBuilds
          # Telemetry and backups name the deployed source revision.
          { system.configurationRevision = self.rev or self.dirtyRev or null; }
          (import ./nix/platform/hosts/profile.nix {
          host = inventory.hosts.${name}; diskoModule = disko.nixosModules.disko; inherit enrolled;
        }) ] ++ nixpkgs.lib.optionals (enrolled && builtins.pathExists (./fleet/hosts + "/${name}/configuration.nix"))
          [ (./fleet/hosts + "/${name}/configuration.nix") ];
      };
    in
    {
      # @cc [owner:ghuntley,label:build] flake-releases-from-source
      # Exported application packages MUST compile clean source and locked
      # dependencies; existing working-tree releases MUST NOT be build inputs.
      lib.mkUbuntuGuest = built.mkUbuntuGuest;
      lib.mkAndroidGuest = built.mkAndroidGuest;
      lib.mkArchGuest = built.mkArchGuest;
      lib.mkArchLinuxGuest = built.mkArchLinuxGuest;
      lib.mkAlmaLinuxGuest = built.mkAlmaLinuxGuest;
      lib.mkAlmaGuest = built.mkAlmaGuest;
      lib.mkWindowsGuest = built.mkWindowsGuest;
      lib.mkWindowsEditorCandidate = built.mkWindowsEditorCandidate;
      lib.mkWindowsEditorBundle = built.mkWindowsEditorBundle;
      lib.nativeKernels = built.nativeKernels;
      lib.mkFreeBSDGuest = built.mkFreeBSDGuest;
      lib.mkFreeBSDImageCandidate = built.mkFreeBSDImageCandidate;
      lib.mkOmniOSGuest = built.mkOmniOSGuest;
      lib.mkIllumosGuest = built.mkIllumosGuest;
      # Lock files, builds and fixed-output hash keys for the scheduled
      # Mix and Cargo security upgrade scripts.
      lib.dependencyPins = built.dependencyPins;
      packages.${system} = {
        default = built.marshall;
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
        image-susan = built.mkSusanImage (self.rev or self.dirtyRev or "unknown");
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
        host = import ./nix/domains/artifacts/host { pkgs = nixpkgs.legacyPackages.${system}; };
        host-kexec = (nixpkgs.lib.nixosSystem {
          inherit system;
            modules = [ nixos-images.nixosModules.kexec-installer nixos-images.nixosModules.noninteractive
              ./nix/domains/system/nix-cache.nix
            ({ config, pkgs, ... }: {
              system.kexec-installer.name = "overalls-host-installer";
              environment.systemPackages = [ pkgs.python3 config.boot.zfs.package ];
              boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
            }) ];
        }).config.system.build.kexecInstallerTarball;
        tool-nix-compact = nix-compact.lib.mkPackage { inherit pkgs; };
        tool-nix-compact-host = nix-compact.lib.mkPackage { pkgs = nixpkgs.legacyPackages.${system}; };
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
        tool-browser = built.browser;
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
      } // (pkgs.lib.mapAttrs' (name: context:
        pkgs.lib.nameValuePair "antithesis-${name}-context" context
      ) antithesisImages.contexts);

      # Hermetic Mila journey backend for platform journey tests (ADR-0264).
      apps.${system}.mila-journey-fixture = {
        type = "app";
        program = "${import ./nix/verification/tests/machines/mila-journey/launcher.nix {
          inherit nixpkgs; pkgs = nixpkgs.legacyPackages.${system};
          module = self.nixosModules.default; packages = built;
        }}/bin/mila-journey-fixture";
        meta.description = "Boot the hermetic Mila journey backend and print its descriptor";
      };

      legacyPackages.${system} = built;

      nixosModules = {
        default = import ./nix/domains/system/catalog.nix { packages = built; nixCompact = nix-compact; };
        # Kept out of the default catalog: only flake-built hosts and tests that
        # pass the locked inputs import tribuchet and nix-grpc-store (ADR-0248).
        fleetBuilds = import ./nix/domains/system/fleet-builds.nix { inherit tribuchet; nixGrpcStore = nix-grpc-store; };
        services = {
          marshall = import ./nix/domains/system/marshall.nix { packages = built; };
          lilly = import ./nix/domains/system/lilly.nix { packages = built; };
          brady = import ./nix/domains/system/brady { packages = built; };
          porsche = import ./nix/domains/system/porsche.nix { packages = built; };
          audi-private = import ./nix/domains/system/audi-private.nix { packages = built; };
          ziggy = import ./nix/domains/system/ziggy.nix { packages = built; };
          galileo = import ./nix/domains/system/galileo.nix { packages = built; };
          enrico = import ./nix/domains/system/enrico.nix { packages = built; };
          peach = import ./nix/domains/system/peach.nix { packages = built; };
          susan = import ./nix/domains/system/susan.nix { packages = built; };
          audi = import ./nix/domains/system/audi.nix { packages = built; };
        };
        platform = {
          nix-cache = ./nix/domains/system/nix-cache.nix;
          nix-compact = import ./nix/domains/system/nix-compact.nix { nixCompact = nix-compact; };
          remote-builders = { imports = [ ./nix/domains/system/remote-builders.nix self.nixosModules.security.secrets ]; };
          sysctl = ./nix/domains/system/sysctl.nix;
          auto-update = import ./nix/domains/system/auto-update/default.nix { packages = built; };
        };
        network = {
          proxy = { imports = [ self.nixosModules.services.marshall ./nix/domains/system/proxy.nix ]; };
          acme = { imports = [ self.nixosModules.network.proxy ./nix/domains/system/acme/default.nix ]; };
          fleet-firewall = ./nix/domains/system/fleet-firewall.nix;
          tailscale = ./nix/domains/system/tailscale.nix;
        };
        security = {
          access = ./nix/domains/system/access.nix;
          audit = ./nix/domains/system/security-audit.nix;
          host-identity = ./nix/domains/system/host-identity.nix;
          ssh-host-certificate = ./nix/domains/system/ssh-host-certificate.nix;
          secrets = import ./nix/domains/system/secrets/default.nix { packages = built; };
        };
        storage = {
          backups = { imports = [ (import ./nix/domains/system/backups { packages = built; }) self.nixosModules.services.lilly self.nixosModules.services.marshall self.nixosModules.security.secrets ]; };
          crash-dumps = import ./nix/domains/system/crash-dumps { lib = nixpkgs.lib; pkgs = pkgs; };
        };
        observability = {
          logging = ./nix/domains/system/logging/default.nix;
          cloudwatch = ./nix/domains/system/cloudwatch/default.nix;
          fleet-exporter = ./nix/domains/system/fleet-exporter/default.nix;
          otel-guest = ./nix/domains/system/otel-guest/default.nix;
          otel-fleet = ./nix/domains/system/otel-fleet/default.nix;
          underclass = import ./nix/domains/system/underclass.nix { packages = built; };
          log-store = ./nix/domains/system/log-store/default.nix;
        };
      };

      nixosConfigurations = nixpkgs.lib.mapAttrs (name: _: hostSystem name true)
        (nixpkgs.lib.filterAttrs (name: host: host.identity.sshKeys != []
          && host.git.knownHosts != "" && nixpkgs.lib.any (document: document.name == "${name}-git") host.credentials) inventory.hosts)
        // nixpkgs.lib.mapAttrs' (name: _: nixpkgs.lib.nameValuePair "${name}-base" (hostSystem name false)) inventory.hosts;

      checks.${system} = import ./nix/verification/tests/ci.nix { inherit (pkgs) lib; checks = (import ./nix/verification/tests/catalog.nix {
        buildPkgs = pkgs;
        testPkgs = nixpkgs.legacyPackages.${system};
        inherit nixpkgs;
        packages = built;
        modules = self.nixosModules;
        inherit fixtures;
        diskoModule = disko.nixosModules.disko;
        diskoSource = disko.outPath;
        kexec = self.packages.${system}.host-kexec;
        imageSource = nixos-images.outPath;
      }) // {
        nix-compact-core = nix-compact.lib.mkCoreCheck { inherit pkgs; };
        nix-compact-native = nix-compact.lib.mkNativeCheck { inherit pkgs; };
        nix-compact-native-host = nix-compact.lib.mkNativeCheck { pkgs = nixpkgs.legacyPackages.${system}; };
        nix-compact-configuration = import ./nix/domains/artifacts/nix-compact/configuration-check.nix { inherit nixpkgs; nixCompact = nix-compact; };
        fleet-builds-configuration = import ./nix/verification/tests/evaluation/fleet-builds.nix {
          inherit nixpkgs; pkgs = nixpkgs.legacyPackages.${system};
          module = self.nixosModules.default; fleetModule = self.nixosModules.fleetBuilds;
          hosts = self.nixosConfigurations;
        };
        package-input-lock =
          let
            flakeLock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.buildNixpkgs.locked;
            devenvNodes = (builtins.fromJSON (builtins.readFile ./devenv.lock)).nodes;
            devenvLock = devenvNodes.${devenvNodes.root.inputs.nixpkgs}.locked;
            pinned = lock: "${lock.owner}/${lock.repo}/${lock.rev}";
          in
          if pinned flakeLock == pinned devenvLock
          then pkgs.runCommand "overalls-package-input-lock-check" { } "touch $out"
          else throw "flake.lock buildNixpkgs (${pinned flakeLock}) differs from devenv.lock nixpkgs (${pinned devenvLock})";
        conflict-markers = pkgs.runCommand "overalls-conflict-markers-check" {
          nativeBuildInputs = [ built.toolchain.elixir pkgs.git ];
          LC_ALL = "C.UTF-8";
          source = ./.;
        } ''
          export HOME="$TMPDIR"
          cd "$source"
          find . -type f -not -path './.git/*' -print0 > "$TMPDIR/files"
          xargs -0 elixir scripts/check_conflict_markers.exs < "$TMPDIR/files"
          touch "$out"
        '';
        terminald = built.terminaldChecks;
        terminald-windows = built.terminaldWindows;
        overalls-install-ps1 = import ./nix/verification/tests/overalls-install-ps1.nix { inherit pkgs; };
        lyra = built.lyra.tests;
        marvin = built.marvin.tests;
        mila-rust = built.mila.rustCheck;
      }; };
    };
}
