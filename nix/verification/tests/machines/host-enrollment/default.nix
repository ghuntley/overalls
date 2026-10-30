{ pkgs, nixpkgs, module, packages, diskoModule, diskoSource, imageSource, nixCompactSource }:
let
  lib = pkgs.lib;
  key = imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519";
  public = lib.removeSuffix "\n" (builtins.readFile (imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519.pub"));
  original = import ../../fixtures/hosts { platform = "hetzner"; firmware = "bios"; };
  ids = [ "disk-a7442feada5c5e87c3db0c92" "disk-4dbb9b95b4622be2eba057e6" ];
  host = original // {
    name = "fixture-enrollment";
    inventory = original.inventory // {
      machine = "11111111-1111-4111-8111-111111111111";
      disks = lib.imap0 (i: d: d // { id = builtins.elemAt ids i; model = ""; size = 17179869184; }) original.inventory.disks;
    };
    storage = original.storage // { system = ids; };
    # What `host plan` records from the installed uplink; enrolled profiles
    # read the default route's interface (the fleet exporter's uplink).
    discovery.routes = [ { dev = "eth0"; dst = "default"; } ];
  };
  common = pkgs.writeText "fixture-common.nix" ''
    { lib, modulesPath, ... }: {
      imports = [ (modulesPath + "/testing/test-instrumentation.nix") ];
      users.users.root.hashedPasswordFile = lib.mkForce null;
      overalls.access.users = lib.mkForce {
        tester = { login = true; admin = true; secretRecovery = true; sshKeys = [ ${builtins.toJSON public} ]; };
      };
      boot.kernelParams = [ "console=ttyS0" ];
      boot.loader.grub.extraConfig = "serial; terminal_output serial";
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      disko.devices.disk.system0.device = lib.mkForce "/dev/vda";
      disko.devices.disk.system1.device = lib.mkForce "/dev/vdb";
    }
  '';
  cargoWorkspace = import ../../../../domains/artifacts/infrastructure/cargo-workspace.nix { inherit pkgs; };
  source = lib.cleanSourceWith {
    src = ../../../../..;
    name = "overalls-host-enrollment-source";
    filter = path: _type:
      let relative = lib.removePrefix ((toString ../../../../..) + "/") (toString path);
      in toString path == toString ../../../../.. || relative == "nix" || relative == "fleet"
        # The public root CAs that every enrolled host and its guests trust.
        || relative == "secrets" || relative == "secrets/brady-root.pem"
        || relative == "secrets/private-services-root.pem"
        # Enrolled Rust services build from the root Cargo workspace (ADR-0273).
        || (!builtins.elem (baseNameOf path) [ "target" ".hegel" ] && cargoWorkspace.workspaceFile relative)
        || lib.hasPrefix "fleet/" relative
        || (lib.hasPrefix "nix/" relative && relative != "nix/verification" && !lib.hasPrefix "nix/verification/tests/" relative);
  };
  # Locked archives let repeated native builds reuse the immutable Nixpkgs input
  # instead of rescanning its many files through a path-flake input each time.
  nixpkgsArchive = pkgs.runCommand "host-enrollment-nixpkgs.tar.gz" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    tar --sort=name --mtime=@1 --owner=0 --group=0 -czf "$out" -C ${nixpkgs} .
  '';
  # Application roles remain disabled in this host-only acceptance test; their
  # unused package defaults need no application builds. Secret tools are real.
  recipe = pkgs.writeText "fixture-flake.nix" ''
    {
      inputs = {
        nixpkgs = { type = "tarball"; url = "file://${nixpkgsArchive}"; flake = false; };
        project = { url = "path:${source}"; flake = false; };
        disko = { url = "path:${diskoSource}"; flake = false; };
        nixCompact = { url = "path:${nixCompactSource}"; flake = false; };
        marshall = { url = "path:${pkgs.hello}"; flake = false; };
        lilly = { url = "path:${pkgs.hello}"; flake = false; };
        secretspec = { url = "path:${packages.secretTools.secretspec}"; flake = false; };
        sops = { url = "path:${packages.secretTools.sops}"; flake = false; };
        sshToAge = { url = "path:${packages.secretTools.ssh-to-age}"; flake = false; };
      };
      outputs = { self, nixpkgs, project, disko, nixCompact, marshall, lilly, secretspec, sops, sshToAge }: {
        nixosConfigurations.fixture-enrollment = import (nixpkgs.outPath + "/nixos/lib/eval-config.nix") {
          system = "x86_64-linux";
          modules = [
            (import (project.outPath + "/nix/domains/system/catalog.nix") {
              # The flake's locked nix-compact, from its preloaded source: the
              # default reads the root flake.lock and fetches from GitHub.
              nixCompact = {
                lib.mkPackage = import (nixCompact.outPath + "/package");
                nixosModules.default = import (nixCompact.outPath + "/modules/nixos.nix") {
                  packageForSystem = _: throw "the catalog selects the nix-compact package";
                };
              };
              packages = { marshall = marshall.outPath; lilly = lilly.outPath;
                encrypted = { marshall = marshall.outPath; lilly = lilly.outPath; };
                secretTools = { secretspec = secretspec.outPath; sops = sops.outPath; ssh-to-age = sshToAge.outPath; };
              };
            })
            (import (project.outPath + "/nix/platform/hosts/profile.nix") {
              host = builtins.fromJSON (builtins.readFile ./fleet/hosts/fixture-enrollment/host.json);
              diskoModule = import (disko.outPath + "/module.nix");
              enrolled = true;
              repositoryRoot = self.outPath;
            })
            ./common.nix
            ({ pkgs, ... }: {
              environment.etc."overalls-enrollment-generation".text = builtins.readFile ./generation;
              environment.systemPackages = [ pkgs.nix ];
              nix.settings.substituters = [];
              system.nixos.versionSuffix = ${builtins.toJSON target.config.system.nixos.versionSuffix};
              system.nixos.revision = ${builtins.toJSON target.config.system.nixos.revision};
            })
          ];
        };
      };
    }
  '';
  # A real enrolled host substitutes the outputs its first published build
  # shares with the fleet cache; this fixture is offline and has no cache. An
  # enrolled build of the same catalog, profile and package stand-ins as the
  # recipe stands in for it, so the in-VM build reuses those outputs (the
  # enrolled-only nix-compact Nix, fleet exporter and their toolchains) and
  # still evaluates and builds everything the publication itself changes.
  cacheHost = host // {
    identity = host.identity // { sshKeys = [ public ]; };
    git = { repository = "ssh://tester@127.0.0.1/home/tester/public-fleet"; knownHosts = "127.0.0.1 ${public}\n"; };
    # Any public file stands in for the ciphertext, whose bundle the recipe rebuilds.
    credentials = [ { name = "${host.name}-git"; path = "secrets/brady-root.pem"; } ];
  };
  enrolled = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      (import ../../../../domains/system/catalog.nix {
        nixCompact = {
          lib.mkPackage = import (nixCompactSource + "/package");
          nixosModules.default = import (nixCompactSource + "/modules/nixos.nix") {
            packageForSystem = _: throw "the catalog selects the nix-compact package";
          };
        };
        packages = { marshall = pkgs.hello; lilly = pkgs.hello;
          encrypted = { marshall = pkgs.hello; lilly = pkgs.hello; };
          inherit (packages) secretTools;
        };
      })
      (import ../../../../platform/hosts/profile.nix {
        host = cacheHost; inherit diskoModule; enrolled = true; repositoryRoot = ../../../../..;
      })
      (toString common)
      ({ pkgs, ... }: {
        environment.systemPackages = [ pkgs.nix ];
        nix.settings.substituters = [];
      })
    ];
  };
  extraTools = [ nixpkgsArchive target.config.system.build.toplevel enrolled.config.system.build.toplevel
    (pkgs.perl.withPackages (p: with p; [ ConfigIniFiles FileSlurp ]))
    pkgs.remarshal pkgs.cpio pkgs.zstd pkgs.nixos-rebuild pkgs.curl pkgs.jq
    pkgs.desktop-file-utils pkgs.getconf pkgs.texinfo pkgs.libxslt.bin pkgs.lndir ] ++ pkgs.bind.all;
  target = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module (toString common) (import ../../../../platform/hosts/profile.nix { inherit host diskoModule; }) ({ config, ... }: {
      disko.memSize = 4096;
      disko.imageBuilder.imageFormat = "qcow2";
      # Disko image generation otherwise reintroduces automatic BIOS devices.
      disko.imageBuilder.extraConfig.boot.loader.grub.devices = lib.mkOverride 0 [];
      disko.devices.disk.system0.imageSize = "16G";
      disko.devices.disk.system1.imageSize = "16G";
      environment.systemPackages = [ (import ../../../../domains/artifacts/host { inherit pkgs; }) pkgs.git pkgs.nix pkgs.sops pkgs.ssh-to-age ];
      # Native builds change only public configuration. Preload their toolchain
      # and immutable source inputs so this isolated test needs no network cache.
      system.extraDependencies = [ source nixpkgs.outPath diskoSource nixCompactSource pkgs.hello
        packages.secretTools.secretspec packages.secretTools.sops packages.secretTools.ssh-to-age
        pkgs.stdenv pkgs.stdenvNoCC ];
      system.build.overallsEnrollmentImages = lib.overrideDerivation config.system.build.diskoImages (old: {
        buildCommand = old.buildCommand + "\n${config.boot.zfs.package}/bin/zpool export zroot\n";
      });
    }) ];
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-host-enrollment";
  nodes = {};
  requiredFeatures.kvm = true;
  globalTimeout = 3600;
  testScript = ''
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    images = "${target.config.system.build.overallsEnrollmentImages}"
    operator_key = "${key}"
    recipe = "${recipe}"
    common = "${common}"
    remote_script = "${../../../../domains/artifacts/host/remote.py}"
    nix_store = "${pkgs.nix}/bin/nix-store"
    nix = "${pkgs.nix}/bin/nix"
    ssh_path = "${pkgs.openssh}/bin"
    extra_paths = ${builtins.toJSON extraTools}
    registration = "${pkgs.closureInfo { rootPaths = extraTools; }}/registration"
    test_program = "${./exercise.py}"
  '' + builtins.readFile ./driver.py;
}
