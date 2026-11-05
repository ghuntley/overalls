{ host, diskoModule, enrolled ? false, repositoryRoot ? ../../.. }:
{ config, lib, pkgs, ... }:
let
  h = host;
  efi = h.firmware == "uefi";
  mirror = h.platform == "hetzner";
  # @cc [owner:ghuntley,label:deployment;capacity] hcloud-single-zfs-root
  # A Hetzner Cloud host MUST boot from exactly one system disk carrying a ZFS
  # zroot/root dataset. It has no guest disks, guest dataset or guest quota.
  cloud = h.platform == "hcloud";
  ec2 = h.platform == "ec2";
  zfsRoot = mirror || cloud;
  disks = lib.listToAttrs (map (d: lib.nameValuePair d.id d) h.inventory.disks);
  bootDisks = h.storage.system;
  guestDisks = if zfsRoot then [] else h.storage.guests;
  binding = {
    inherit (h) platform firmware identity;
    inventory = h.inventory // { disks = map (d: builtins.removeAttrs d [ "active" "path" "aliases" ]) h.inventory.disks; };
    inherit (h) storage;
    # Bind evaluated hardware settings too, so an enrolled role module cannot
    # bypass maintenance by overriding a profile without changing host.json.
    effective = {
      hostId = config.networking.hostId;
      hostKeys = config.services.openssh.hostKeys;
      boot = { inherit (config.boot.loader.grub) devices mirroredBoots efiSupport efiInstallAsRemovable; };
      filesystems = lib.mapAttrs (_: fs: { inherit (fs) device fsType; }) config.fileSystems;
      disks = lib.mapAttrs (_: d: { inherit (d) device;
        content = if d.content == null then null else {
          inherit (d.content) type;
          partitions = lib.mapAttrs (_: part: { inherit (part) label size;
            content = if part.content == null then null else {
              inherit (part.content) type;
              pool = part.content.pool or null;
              format = part.content.format or null;
            };
          }) (d.content.partitions or {});
        };
      }) config.disko.devices.disk;
      pools = lib.mapAttrs (_: p: {
        inherit (p) mode rootFsOptions;
        datasets = lib.mapAttrs (_: d: { inherit (d) options mountpoint; }) p.datasets;
      }) config.disko.devices.zpool;
    };
  };
  esp = mountpoint: {
    label = "${h.name}-boot${if mountpoint == "/boot" then "0" else "1"}";
    size = "1G"; type = "EF00";
    content = { type = "filesystem"; format = "vfat"; inherit mountpoint;
      mountOptions = [ "umask=0077" "nofail" "x-systemd.device-timeout=5s" ]; };
  };
  systemDisk = index: id: {
    type = "disk"; device = disks.${id}.device;
    content = { type = "gpt"; partitions =
      lib.optionalAttrs (!efi) {
        bios = { size = "1M"; type = "EF02"; };
        boot = { size = "1G"; label = "${h.name}-boot${toString index}";
          content = { type = "filesystem"; format = "ext4";
            mountpoint = if index == 0 then "/boot" else "/boot-mirror";
            mountOptions = [ "nofail" "x-systemd.device-timeout=5s" ];
          };
        };
      }
      // lib.optionalAttrs efi { ESP = esp (if index == 0 then "/boot" else "/boot-mirror"); }
      // { system = { label = "${h.name}-system${toString index}"; size = "100%"; content = if zfsRoot then { type = "zfs"; pool = "zroot"; }
        else { type = "filesystem"; format = "ext4"; mountpoint = "/"; }; }; };
    };
  };
  pool = if zfsRoot then "zroot" else "guests";
  policy = { compression = "lz4"; reservation = "none"; refreservation = "none";
    mountpoint = "none"; canmount = "off"; };
  lillySettings = h.lilly or {};
  lillyBinding = lillySettings.binding or null;
  lillyEnrolled = enrolled && lillyBinding != null;
  transferEndpoint = lillySettings.transferEndpoint or null;
  lillyDocument = lib.findFirst (d: d.name == "${h.name}-lilly") null h.credentials;
  addressDocument = lib.findFirst (d: d.name == "fleet-addresses") null h.credentials;
  backupDocument = lib.findFirst (d: d.name == "${h.name}-backup") null h.credentials;
  underclassDocument = lib.findFirst (d: d.name == "${h.name}-underclass") null h.credentials;
  underclassEnrolled = enrolled && underclassDocument != null;
  tailscaleDocument = lib.findFirst (d: d.name == "fleet-tailscale") null h.credentials;
  tailscaleEnrolled = enrolled && tailscaleDocument != null;
  namespaceDocument = lib.findFirst (d: d.name == "fleet-namespace") null h.credentials;
  namespaceEnrolled = enrolled && namespaceDocument != null;
  fleetExporterInterfaces = lib.unique (map (route: route.dev)
    (lib.filter (route: route.dst == "default") h.discovery.routes));
  lillyPools = if lillyBinding == null then [] else map (p: {
    inherit (p) id filesystem_id storage;
    path = "/var/lib/lilly/pool";
  }) lillyBinding.pools;
  identityTool = pkgs.writeShellScriptBin "overalls-lilly-identity" ''
    set -eu
    export RELEASE_COOKIE RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
    exec ${config.services.lilly.package}/bin/lilly eval 'case Lilly.Host.Identity.read() do {:ok, identity} -> IO.puts(identity); _ -> System.halt(1) end'
  '';
  gitDocument = lib.findFirst (d: d.name == "${h.name}-git") null h.credentials;
  # @cc [owner:ghuntley,label:deployment] host-ciphertext-closure
  # Enrolled Git and Lilly ciphertext MUST be explicit store dependencies so
  # copying the deployment closure includes them without the source checkout.
  encryptedDocument = document: builtins.path {
    path = repositoryRoot + "/${document.path}";
    name = builtins.baseNameOf document.path;
  };
  check = pkgs.writeShellScriptBin "overalls-host-check" ''
    export PATH=${lib.makeBinPath [ pkgs.util-linux config.boot.zfs.package pkgs.iproute2 pkgs.openssh pkgs.systemd pkgs.git pkgs.coreutils ]}
    exec ${pkgs.python3}/bin/python ${../../domains/artifacts/host/remote.py} verify /etc/overalls-host.json "$@"
  '';
in {
  imports = [ diskoModule ];
  assertions = [
    { assertion = !(h ? lilly) || (builtins.isInt (lillySettings.credentialTtlSeconds or 157680000) && (lillySettings.credentialTtlSeconds or 157680000) >= 1 && (lillySettings.credentialTtlSeconds or 157680000) <= 157680000); message = "Lilly credential lifetime must be 1..157680000 seconds"; }
    { assertion = !lillyEnrolled || transferEndpoint == null ||
        (config.services.lillyTransfer.port == transferEndpoint.port
          && builtins.elem transferEndpoint.host_key h.identity.sshKeys);
      message = "Lilly transfer endpoint must match the installed port and declared SSH identity."; }
    { assertion = !lillyEnrolled || (lillyDocument != null && config.services.lilly.enable && config.services.lilly.hostId == lillyBinding.host_id && config.services.lilly.controlPlane == lillySettings.controlPlane && config.services.lilly.credentialFile == "/run/overalls-secrets/lilly/credential.json" && builtins.elem "overalls-secrets-lilly.service" config.services.lilly.secretUnits); message = "Generated Lilly enrollment binding conflicts with manual configuration"; }
    { assertion = !lillyEnrolled || (config.services.overallsSecrets.enable
        && config.services.overallsSecrets.bundles.lilly.group == "root"
        && config.services.overallsSecrets.bundles.lilly.directory == "/run/overalls-secrets/lilly"
        && config.services.overallsSecrets.bundles.lilly.unit == "overalls-secrets-lilly.service"
        && config.services.overallsSecrets.bundles.lilly.encryptedFile == toString (encryptedDocument lillyDocument)
        && config.services.overallsSecrets.bundles.lilly.outputs."credential.json".format == "raw"
        && config.services.overallsSecrets.bundles.lilly.outputs."credential.json".secrets == [ "LILLY_CREDENTIAL" ]
        && config.services.lilly.egressInterface == lillySettings.egressInterface); message = "Generated Lilly secret delivery or egress conflicts with manual configuration"; }
    { assertion = !lillyEnrolled || map (p: builtins.removeAttrs p [ "max_iops" "max_iops_source" ]) config.services.lilly.pools == lillyPools; message = "Generated Lilly pools conflict with manual configuration"; }
    { assertion = builtins.elem h.platform [ "hetzner" "ec2" "hcloud" ] && builtins.elem h.firmware [ "bios" "uefi" ]; message = "Unsupported host platform or firmware"; }
    { assertion = h.inventory.arch == "x86_64" && h.reviewed; message = "Hosts require reviewed x86_64 hardware and network"; }
    { assertion = builtins.length bootDisks == (if mirror then 2 else 1); message = "Invalid system disk count"; }
    { assertion = if cloud then builtins.attrNames h.budgets == [ "arcMaxMiB" ] && h.budgets.arcMaxMiB > 0
        else builtins.attrNames h.budgets == [ "arcMaxMiB" "guestCpuCores" "guestMemoryMiB" ] && h.budgets.guestMemoryMiB > 0 && h.budgets.guestCpuCores > 0 && h.budgets.arcMaxMiB > 0; message = "Explicit production resource budgets required"; }
    # @cc [owner:ghuntley,label:deployment;security] hcloud-no-kvm-no-lilly
    # Hetzner Cloud hosts have no reviewed KVM and no guest storage, so they
    # MUST NOT declare or run Lilly and MUST NOT reserve a guest quota.
    { assertion = !cloud || (h.storage.guests == [] && builtins.elem (h.storage.quotaBytes or null) [ null 0 ] && !(h ? lilly) && !config.services.lilly.enable); message = "Hetzner Cloud hosts carry no guest storage, quota or Lilly role"; }
    # @cc [owner:ghuntley,label:security;deployment] hcloud-addresses-outside-repository
    # Hetzner Cloud declarations MUST NOT hold address literals: every network
    # takes IPv4 from DHCP and any public address arrives through SOPS.
    { assertion = !cloud || lib.all (network:
        (network.networkConfig.DHCP or null) == "ipv4" && !(network.networkConfig ? Address) && !(network ? address)
        && lib.all (route: !(route ? PreferredSource)) (network.routes or [])) (builtins.attrValues h.network);
      message = "Hetzner Cloud networks use DHCP for IPv4 and keep addresses out of the repository"; }
    # @cc [owner:ghuntley,label:security;deployment] uplink-addresses-outside-repository
    # A host with a runtime uplink MUST NOT also declare static IPv4 addresses,
    # preferred sources or IPv4 gateways for it.
    { assertion = !(h ? addresses && h.addresses ? uplink) || lib.all (network:
        !(network.networkConfig ? Address) && !(network ? address)
        && lib.all (route: !(route ? PreferredSource) && !(lib.hasInfix "." (route.Gateway or ""))
          && !(lib.hasInfix "." (route.Destination or ""))) (network.routes or [])) (builtins.attrValues h.network);
      message = "Runtime uplink networks keep IPv4 addresses and routes out of the repository"; }
    { assertion = lillyBinding == null || lib.all (p: builtins.attrNames p == [ "filesystem_id" "id" "name" "storage" ]) lillyBinding.pools; message = "Lilly binding pools must carry exactly id, name, filesystem_id and storage"; }
    { assertion = !mirror || h.storage.quotaBytes > 0; message = "Shared root storage requires a reviewed guest quota"; }
    { assertion = !ec2 || (guestDisks != [] && lib.sort builtins.lessThan guestDisks == lib.sort builtins.lessThan (map (d: d.id) (lib.filter (d: d.kind == "local-nvme") h.inventory.disks)) && disks.${builtins.head bootDisks}.kind == "ebs"); message = "EC2 requires EBS root and every local NVMe drive"; }
    { assertion = !config.services.lilly.enable || lib.all (path: !lib.hasPrefix "/var/lib/lilly/pool" path)
        [ config.services.lilly.stateDirectory config.services.lilly.vmStateDirectory config.services.lilly.networkStateDirectory ]; message = "Lilly control journals must remain on system storage"; }
    { assertion = !config.services.lilly.enable || (builtins.length config.services.lilly.pools == 1
        && (builtins.head config.services.lilly.pools).path == "/var/lib/lilly/pool"
        && (builtins.head config.services.lilly.pools).storage.dataset == "${pool}/lilly"); message = "Lilly pool must use the reviewed host guest dataset"; }
    { assertion = !enrolled || (h.identity.sshKeys != [] && gitDocument != null && h.git.knownHosts != ""); message = "Enrollment requires host and Git authentication and ciphertext"; }
    { assertion = !(enrolled && config.services.overallsBackups.enable) || backupDocument != null;
      message = "Enrolled backups require a hostname-specific backup credential document in host.json"; }
  ];
  system.stateVersion = "26.05";
  networking.hostName = h.name;
  # @cc [owner:ghuntley,label:security] fleet-brady-public-trust
  # Every fleet host MUST trust only the public Brady root. Signer keys and the
  # offline root key MUST remain outside Nix store inputs.
  security.pki.certificateFiles = [ ../../../secrets/brady-root.pem ];
  networking.hostId = h.identity.hostId;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.networks = h.network;
  # @cc [owner:ghuntley,label:security;deployment] host-addresses-from-declaration
  # A host's public addresses MUST come from the shared fleet-addresses SOPS
  # document named by its declaration; the declaration holds only logical
  # names and secret names. A base system without the credential uses the
  # uplink recovery copy written at installation.
  overalls.fleetAddresses = lib.mkIf (h ? addresses) {
    enable = true;
    names = import ../../policy/network/fleet-addresses.nix // (h.addresses.names or {});
    uplink = h.addresses.uplink or null;
    encryptedFile = if addressDocument == null then null
      else "${repositoryRoot + ("/" + addressDocument.path)}";
  };
  overalls.access.enable = true;
  overalls.fleetFirewall.enable = true;
  # Reviewed fleet sources follow the decrypted fleet addresses; a base system
  # without the document admits them only through Tailscale.
  overalls.fleetFirewall.allowedHosts = lib.mkIf (h ? addresses && addressDocument != null)
    (lib.mapAttrs (_: grant: {
      addressFile = config.overalls.fleetAddresses.files.${grant.name};
      addressUnit = config.overalls.fleetAddresses.unit;
      inherit (grant) comment;
    }) (import ../../policy/network/allowed-hosts.nix));
  # @cc [owner:ghuntley,label:security;deployment] base-installer-source
  # The authenticated installing operator's source, recorded root-only at
  # installation, MUST be admitted only to the administrative SSH ports, so a
  # base system without the fleet-address document (and an enrollment that
  # moves the host to another deployment's reviewed sources) stays reachable.
  # The address MUST stay out of the repository; deleting the recorded file
  # withdraws the grant at the next boot or activation.
  systemd.services.overalls-base-source = {
    description = "Publish the installing operator source for administrative SSH";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/var/lib/overalls-host/base-source";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "overalls-host";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      ExecStart = "${pkgs.coreutils}/bin/install -m 0600 /var/lib/overalls-host/base-source /run/overalls-host/base-source";
    };
  };
  overalls.runtimeFirewall.rules.base-installer = {
    sourceFile = "/run/overalls-host/base-source";
    protocol = "tcp";
    ports = config.services.openssh.ports;
    comment = "Installing operator administrative SSH";
    optional = true;
    units = [ "overalls-base-source.service" ];
  };
  # @cc [owner:ghuntley,label:deployment;security] fleet-tailscale-mesh
  # Every base and enrolled fleet host MUST run the Tailscale client daemon so
  # operators retain a management path independent of the provider network.
  # An enrolled host naming the shared fleet-tailscale credential MUST join the
  # tailnet automatically with the SOPS-delivered auth key (ADR-0241); the key
  # MUST NOT enter the Nix store. A base system starts unauthenticated and
  # joins only through an explicit operator action.
  services.tailscale.enable = true;
  services.tailscale.authKeyFile = lib.mkIf tailscaleEnrolled "/run/overalls-secrets/tailscale/auth-key";
  # @cc [owner:ghuntley,label:build;security] namespace-buck2-token-delivery
  # The Namespace Buck2 token (ADR-0276) MUST reach only root (the host
  # updater) and wheel, the fleet administrators who already hold sudo, as
  # /run/overalls-secrets/fleet-namespace/token, where tools/buck2 reads it.
  # It MUST NOT enter the Nix store; without it Buck2 builds stay local.
  systemd.services.overalls-secrets-fleet-namespace = lib.mkIf namespaceEnrolled {
    wantedBy = [ "multi-user.target" ];
  };
  systemd.services.tailscaled-autoconnect = lib.mkIf tailscaleEnrolled {
    requires = [ "overalls-secrets-tailscale.service" ];
    after = [ "overalls-secrets-tailscale.service" ];
  };
  # @cc [owner:ghuntley,label:deployment] fleet-default-store-reclamation
  # Every base and enrolled fleet host MUST enable bounded Nix store garbage
  # collection; hosts override the reviewed thresholds through their own
  # configuration. Disabling the timer remains the manual-recovery control.
  services.overallsNixGc.enable = true;
  nix.settings = {
    trusted-users = [ "root" "@wheel" ];
    # @cc [owner:ghuntley,label:deployment;verification] fleet-nested-kvm-builder
    # Every base and enrolled fleet host MUST advertise nested-kvm in addition
    # to Nix's detected system features. The kernel module settings below MUST
    # enable nesting for both supported CPU vendors; advertisement alone is not
    # runtime evidence, so native suites still verify /dev/kvm in the inner VM.
    extra-system-features = [ "nested-kvm" ];
  };
  boot.initrd.availableKernelModules = [ "nvme" "ahci" "virtio_pci" "virtio_blk" "virtio_scsi" ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ] ++ lib.optional ec2 "ena";
  boot.initrd.kernelModules = lib.optional ec2 "ena";
  boot.kernelParams = lib.optionals ec2 [ "console=ttyS0,115200n8" "nvme_core.io_timeout=4294967295" ];
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.forceImportAll = false;
  # Nested KVM lets guests run their own hypervisors (the Inception profile)
  # and lets these hosts execute the repository's nested-KVM test suites.
  # AMD enables nesting by default on modern kernels; Intel requires the flag.
  # The ARC budget sizes the metadata and dnode caches for hundreds of mounted
  # guest datasets; the dnode limit follows it at a quarter, as the updater
  # applies live (ADR-0164).
  boot.extraModprobeConfig = ''
    options kvm-intel nested=Y
    options kvm-amd nested=1
    options zfs zfs_arc_max=${toString (h.budgets.arcMaxMiB * 1048576)} zfs_arc_dnode_limit=${toString (h.budgets.arcMaxMiB * 1048576 / 4)}
  '';
  boot.loader.grub = {
    enable = true; efiSupport = efi; efiInstallAsRemovable = efi;
    devices = lib.mkForce [];
    extraConfig = lib.optionalString ec2 ''
      serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
      terminal_output console serial
    '';
    mirroredBoots = lib.imap0 (index: _: {
      path = if index == 0 then "/boot" else "/boot-mirror";
      devices = [ (if efi then "nodev" else config.disko.devices.disk.${"system" + toString index}.device) ];
    }) bootDisks;
  };
  boot.loader.efi.canTouchEfiVariables = false;
  services.cloud-init.enable = lib.mkForce false;
  services.amazon-ssm-agent.enable = lib.mkForce false;
  disko.devices = {
    disk = lib.listToAttrs (lib.imap0 (index: id: lib.nameValuePair "system${toString index}" (systemDisk index id)) bootDisks)
      // lib.listToAttrs (map (id: lib.nameValuePair id { type = "disk"; device = disks.${id}.device;
        content = { type = "gpt"; partitions.data = { size = "100%"; content = { type = "zfs"; inherit pool; }; }; };
      }) guestDisks);
    zpool.${pool} = {
      type = "zpool"; mode = if mirror then "mirror" else "";
      options = { ashift = toString h.storage.ashift; cachefile = "none"; };
      rootFsOptions = policy;
      datasets = lib.optionalAttrs zfsRoot { root = {
        type = "zfs_fs"; options = { mountpoint = "legacy"; canmount = "on"; }; mountpoint = "/";
      }; } // lib.optionalAttrs (!cloud) { lilly = {
        type = "zfs_fs";
        options = { mountpoint = "/var/lib/lilly/pool"; canmount = "on"; }
          // lib.optionalAttrs mirror { quota = toString h.storage.quotaBytes; };
        mountpoint = "/var/lib/lilly/pool";
      }; };
    };
  };
  # Guest-storage failure must not prevent the EBS-backed host from booting.
  fileSystems."/var/lib/lilly/pool" = lib.mkIf (!cloud) { options = [ "nofail" "x-systemd.device-timeout=5s" "x-systemd.after=zfs-mount.service" ]; };
  # @cc [owner:ghuntley,label:deployment] host-probe-runtime-tools
  # The installed administrative command path MUST provide Python, Git and ZFS
  # tools for SSH-delivered host probes, including receipt Git-access checks.

  # @cc [owner:ghuntley,label:deployment] fleet-common-utilities
  # Every base and enrolled fleet host MUST provide htop, btop, Vim, Mosh,
  # jq, direnv, devenv and DNS utilities (dig, nslookup) through its system
  # packages.
  environment.systemPackages = [
    check pkgs.python3 pkgs.git config.boot.zfs.package
    pkgs.htop pkgs.btop pkgs.vim pkgs.mosh pkgs.jq
    pkgs.direnv pkgs.devenv pkgs.bind.dnsutils
  ] ++ lib.optional (h ? lilly) identityTool;
  # @cc [owner:ghuntley,label:deployment] fleet-direnv-shell-hook
  # Every base and enrolled fleet host MUST hook direnv into interactive Bash,
  # Zsh and Fish shells system-wide. Each .envrc still requires `direnv allow`.
  programs.direnv.enable = true;
  # @cc [owner:ghuntley,label:deployment] fleet-default-editor
  # Every base and enrolled fleet host MUST set Vim as the default editor.
  environment.variables.EDITOR = "vim";
  # @cc [owner:ghuntley,label:deployment] host-unpacked-dynamic-executables
  # Fleet host profiles MUST enable programs.nix-ld so unpackaged dynamically
  # linked Linux executables can use the FHS interpreter path. Guest images and
  # service-only module imports MUST NOT receive this setting from this profile.
  programs.nix-ld.enable = true;
  environment.etc."overalls-host.json".text = builtins.toJSON h;
  environment.etc."overalls-installation.json".text = builtins.toJSON binding;
  services.overallsAutoUpdate = {
    installationBinding = binding;
    resourcePolicy = if lillyEnrolled && mirror then {
      version = 1;
      cpuCores = h.budgets.guestCpuCores;
      memoryMiB = h.budgets.guestMemoryMiB;
      arcMaxBytes = h.budgets.arcMaxMiB * 1048576;
      quotaBytes = h.storage.quotaBytes;
      dataset = (builtins.head lillyBinding.pools).storage.dataset;
      zpoolGuid = (builtins.head lillyBinding.pools).storage.zpool_guid;
      datasetGuid = (builtins.head lillyBinding.pools).storage.dataset_guid;
    } else null;
    enable = enrolled;
    repository = h.git.repository;
    branch = "trunk";
    flakeAttr = h.name;
    sshKeyFile = "/run/overalls-secrets/git/deploy-key";
    knownHostsFile = "/etc/overalls-git-known-hosts";
    secretUnits = [ "overalls-secrets-git.service" ];
    enrollmentReceipt = "/var/lib/overalls-host/enrollment.json";
  };
  environment.etc."overalls-git-known-hosts".text = h.git.knownHosts;
  services.lilly = lib.mkMerge [
    (lib.mkIf config.services.lilly.enable {
      guestCpuCores = h.budgets.guestCpuCores;
      guestMemoryMiB = h.budgets.guestMemoryMiB;
      guestTrustRoots = [ ../../../secrets/private-services-root.pem ../../../secrets/brady-root.pem ];
    })
    (lib.mkIf lillyEnrolled {
      enable = true;
      hostId = lillyBinding.host_id;
      controlPlane = lillySettings.controlPlane;
      egressInterface = lillySettings.egressInterface;
      credentialFile = "/run/overalls-secrets/lilly/credential.json";
      secretUnits = [ "overalls-secrets-lilly.service" ];
      pools = lillyPools;
    })
  ];
  # Enrollment and the installed listener use the same public port declaration.
  services.lillyTransfer.port = lib.mkIf (lillyEnrolled && lillySettings ? transferEndpoint)
    lillySettings.transferEndpoint.port;
  services.overallsSecrets = lib.mkIf enrolled {
    enable = true;
    bundles.lilly = lib.mkIf lillyEnrolled {
      encryptedFile = toString (encryptedDocument lillyDocument);
      outputs."credential.json" = { format = "raw"; secrets = [ "LILLY_CREDENTIAL" ]; };
    };
    bundles.git = {
      encryptedFile = toString (encryptedDocument gitDocument);
      outputs.deploy-key = { format = "raw"; secrets = [ "GIT_DEPLOY_KEY" ]; };
    };
    bundles.tailscale = lib.mkIf tailscaleEnrolled {
      encryptedFile = toString (encryptedDocument tailscaleDocument);
      outputs.auth-key = { format = "raw"; secrets = [ "TAILSCALE_AUTH_KEY" ]; };
    };
    bundles.fleet-namespace = lib.mkIf namespaceEnrolled {
      encryptedFile = toString (encryptedDocument namespaceDocument);
      group = "wheel";
      outputs.token = { format = "raw"; secrets = [ "NAMESPACE_RBE_TOKEN" ]; };
    };
    bundles.underclass = lib.mkIf underclassEnrolled {
      encryptedFile = toString (encryptedDocument underclassDocument);
      outputs."proxy.key" = { format = "raw"; secrets = [ "UNDERCLASS_PROXY_KEY" ]; };
      outputs.environment = {
        format = "environment";
        secrets = [ "UNDERCLASS_PROXY_KEY" "UNDERCLASS_UI_TOKEN" ];
      };
    };
    bundles.backup = lib.mkIf (backupDocument != null) {
      encryptedFile = toString (encryptedDocument backupDocument);
      outputs.password = { format = "raw"; secrets = [ "RESTIC_PASSWORD" ]; };
      outputs."s3.env" = {
        format = "environment";
        secrets = [ "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" ];
      };
    };
  };
  services.overallsFleetExporter = lib.mkIf enrolled {
    enable = true;
    externalInterfaces = fleetExporterInterfaces;
  };
  # @cc [owner:ghuntley,label:deployment] enrolled-host-underclass
  # Every credentialed enrolled fleet host MUST run an independent Underclass
  # pool with host-specific credentials and host-local state. Base and generic
  # enrollment hosts without that explicit document MUST run neither.
  services.underclass = lib.mkIf underclassEnrolled {
    enable = true;
    environmentFile = "/run/overalls-secrets/underclass/environment";
    secretUnits = [ "overalls-secrets-underclass.service" ];
    # ADR-0185, amended by ADR-0260: provider traffic leaves only through the
    # dedicated egress node's proxy, with no exit node, so it uses the host's own
    # address. Join each host's node first (`sudo underclass-egress up`), or
    # Underclass refuses to start.
    egress = { enable = true; route = true; };
  };
  # @cc [owner:ghuntley,label:security;deployment] ziggy-host-local-underclass
  # Enrolled Ziggy uses only the proxy credential, never the Underclass UI token.
  services.ziggy = lib.mkIf (lillyEnrolled && underclassEnrolled) {
    agentEnable = true;
    openaiOrigin = "http://127.0.0.1:8080";
    openaiKeyFile = lib.mkForce "/run/overalls-secrets/underclass/proxy.key";
    secretUnits = [ "overalls-secrets-underclass.service" ];
  };
  systemd.services.overalls-host-ready = {
    wantedBy = [ "multi-user.target" ]; wants = [ "network-online.target" ];
    # Resource receipt replay must precede readiness during switch and boot.
    requires = lib.optional (lillyEnrolled && mirror) "overalls-resource-policy.service";
    after = [ "network-online.target" "zfs-mount.service" ]
      ++ lib.optional (lillyEnrolled && mirror) "overalls-resource-policy.service";
    serviceConfig = { Type = "oneshot"; ExecStart = "${check}/bin/overalls-host-check --storage"; };
  };
  systemd.services.lilly = lib.mkIf config.services.lilly.enable {
    requires = [ "overalls-host-ready.service" ]; after = [ "overalls-host-ready.service" ];
    # `+`: the check reads root-only enrollment state (the storage baseline
    # and the SSH host key) while Lilly itself runs as `lilly` (ADR-0182).
    serviceConfig.ExecStartPre = [ "+${check}/bin/overalls-host-check --storage" ];
  };
  systemd.services.overalls-auto-update = lib.mkIf enrolled {
    serviceConfig.ExecStartPre = [ "${check}/bin/overalls-host-check --receipt" ];
  };
  system.build.overallsHostInstall = pkgs.writeShellScript "overalls-host-install" ''
    export PATH=${lib.makeBinPath [ pkgs.util-linux config.boot.zfs.package pkgs.openssh ]}
    exec ${pkgs.util-linux}/bin/flock -n /run/overalls-host-install.lock ${pkgs.writeShellScript "guarded-disko" ''
      set -eu
      ${pkgs.python3}/bin/python ${../../domains/artifacts/host/remote.py} guard < ${config.system.build.overallsHostDeclaration}
      exec ${lib.getExe config.system.build.destroyFormatMount} --yes-wipe-all-disks
    ''}
  '';
  system.build.overallsHostDeclaration = pkgs.writeText "host.json" (builtins.toJSON h);
  system.build.overallsHostBinding = pkgs.writeText "binding.json" (builtins.toJSON binding);
}
