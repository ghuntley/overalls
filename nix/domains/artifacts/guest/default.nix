{ pkgs, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null,
  codingClis ? import ./coding-clis.nix { inherit pkgs; },
  extraModules ? [ ], imageName ? "lilly-nixos-x86_64",
  minimumMemoryBytes ? (if vscodeWeb == null then 536870912 else 2147483648),
  minimumDiskBytes ? null,
  privateServiceRoots ? [ ],
  guestAgents ? null,
  gitIdentityVersion ? null }:
let
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    specialArgs = { inherit codingClis; };
    modules = [ ./configuration.nix ({ config, ... }: {
      # Profiles such as Inception deliberately disable administrative SSH
      # while still enabling the boot-bound trust receiver below.
      services.openssh.enable = pkgs.lib.mkDefault (privateServiceRoots != []);
      environment.systemPackages = [ lyraLinux ];
      services.openssh.generateHostKeys = false;
      services.openssh.hostKeys = [{ type = "ed25519"; path = "/run/overalls-ssh-host/ssh_host_ed25519_key"; }];
      services.openssh.settings = {
        HostCertificate = "/run/overalls-ssh-host/ssh_host_ed25519_key-cert.pub";
        HostKeyAlgorithms = "ssh-ed25519-cert-v01@openssh.com";
        AuthorizedKeysCommand = "/run/overalls-ssh-authorize authorize %u %t %k";
        AuthorizedKeysCommandUser = "overalls-ssh";
      };
      users.users.overalls-ssh = {
        isSystemUser = true;
        group = "overalls-ssh";
      };
      users.groups.overalls-ssh = {};
      # @cc [owner:ghuntley,label:security] guest-account-sudo-policy
      # Sudo MUST load the shared reconciler's current per-user policies.
      security.sudo.extraConfig = "@includedir /etc/sudoers.d";
      security.pam.services.sshd.rules.session.overalls-login = {
        order = config.security.pam.services.sshd.rules.session.unix.order + 1;
        control = "requisite";
        modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
        args = [ "quiet" "quiet_log" "type=open_session" "${lyraLinux}/bin/overalls-ssh-authorize" "login" ];
      };
      # @cc [owner:ghuntley,label:security;recovery] guest-ssh-roster-before-listener
      # A verified private roster MUST reconcile before sshd starts; later
      # refreshes disable removed accounts while preserving their homes.
      systemd.services.overalls-ssh-sync = pkgs.lib.mkIf (privateServiceRoots != []) {
        description = "Reconcile current Overalls SSH guest accounts";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-private-dns.service" ];
        wants = [ "network-online.target" ];
        after = [ "lilly-private-dns.service" "network-online.target" ];
        before = [ "sshd.service" ];
        path = [ pkgs.shadow pkgs.coreutils pkgs.glibc.getent pkgs.util-linux pkgs.openssh ];
        environment.OVERALLS_SSH_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        # @cc [owner:ghuntley,label:security;deployment] guest-ssh-safe-callback-path
        # OpenSSH rejects a callback below the group-writable Nix store root.
        # Publish a root-owned copy atomically before the listener can start.
        preStart = ''
          rm -f /run/overalls-ssh-ready
          ${lyraLinux}/bin/overalls-host-certificate
          if [ ! -x /run/overalls-ssh-authorize ] ||
             [ "$(cat /run/overalls-ssh-authorize.source 2>/dev/null)" != "${lyraLinux}/bin/overalls-ssh-authorize" ]; then
            install -m 0755 ${lyraLinux}/bin/overalls-ssh-authorize /run/overalls-ssh-authorize.new
            mv -f /run/overalls-ssh-authorize.new /run/overalls-ssh-authorize
            printf '%s\n' '${lyraLinux}/bin/overalls-ssh-authorize' > /run/overalls-ssh-authorize.source.new
            mv -f /run/overalls-ssh-authorize.source.new /run/overalls-ssh-authorize.source
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "overalls-ssh";
          StateDirectoryMode = "0700";
          ExecStart = "${lyraLinux}/bin/overalls-ssh-authorize sync";
          ExecStartPost = "${pkgs.coreutils}/bin/touch /run/overalls-ssh-ready";
        };
        # A startup roster request can fail before private authority is ready.
        # A later successful timer refresh must reopen the dependent listener.
        unitConfig.OnSuccess = "sshd.service";
      };
      systemd.timers.overalls-ssh-sync = pkgs.lib.mkIf (privateServiceRoots != []) {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "3s"; OnUnitActiveSec = "2s"; AccuracySec = "1s"; };
      };
      # OpenSSH caches its certificate until reload. Atomic renewal must become
      # visible to new connections without interrupting existing sessions.
      systemd.paths.overalls-ssh-certificate = pkgs.lib.mkIf (privateServiceRoots != []) {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "/run/overalls-ssh-host/ssh_host_ed25519_key-cert.pub";
      };
      systemd.services.overalls-ssh-certificate = pkgs.lib.mkIf (privateServiceRoots != []) {
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl try-reload-or-restart sshd.service";
        };
      };
      systemd.services.sshd = pkgs.lib.mkIf (privateServiceRoots != []) {
        after = [ "overalls-ssh-sync.service" ];
        unitConfig.ConditionPathExists = "/run/overalls-ssh-ready";
        environment.OVERALLS_SSH_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      };
      systemd.services.lilly-readiness.serviceConfig.Environment =
        pkgs.lib.optionalString (privateServiceRoots != []) "LILLY_SSH_UNIT=sshd.service";
      overalls.terminald.package = pkgs.lib.mkDefault terminald;
      systemd.services.lilly-terminals = {
        path = [ pkgs.shadow pkgs.coreutils pkgs.glibc.getent pkgs.util-linux ];
        environment.LILLY_TERMINALD_ACCOUNT_HELPER = "${lyraLinux}/bin/overalls-ssh-authorize";
        environment.OVERALLS_SSH_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        serviceConfig.StateDirectory = "overalls-ssh";
        serviceConfig.StateDirectoryMode = "0700";
      };
      overalls.privateServices = {
        enable = privateServiceRoots != [];
        rootCertificates = privateServiceRoots;
        trustReceiver = lyraLinux;
      };
      environment.etc."overalls/guest-agent" = pkgs.lib.mkIf (privateServiceRoots != []) { text = "enabled\n"; };
      # @cc [owner:ghuntley,label:deployment;recovery] guest-agent-private-start
      # The executor starts only after the current host CA bundle and private
      # DNS route are installed for this boot.
      # A VM restart re-registers a fresh fence before claiming tool work.
      systemd.services.overalls-agent-executor = pkgs.lib.mkIf (privateServiceRoots != []) {
        description = "Overalls guest agent tool executor";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.coreutils pkgs.bash ];
        requires = [ "lilly-private-dns.service" ];
        after = [ "lilly-private-dns.service" "network-online.target" ];
        unitConfig.ConditionKernelCommandLine = "lilly.ipv4";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${lyraLinux}/bin/overalls agent-supervisor";
          # @cc [owner:ghuntley,label:security] guest-agent-state-traversal
          # Ordinary guest accounts MUST be able to traverse, never list or
          # write, the agent state root so the public managed gh/git-lfs
          # launcher can read its root-written activation pointer. Private
          # logs and update state keep their own owner-only directories.
          StateDirectory = "overalls";
          StateDirectoryMode = "0711";
          RuntimeDirectory = "overalls-agent";
          RuntimeDirectoryMode = "0700";
          Restart = "always";
          RestartSec = 5;
          NoNewPrivileges = true;
          StandardOutput = "null";
          StandardError = "null";
        };
      };
    }) ] ++ pkgs.lib.optional (vscodeWeb != null) (import ./vscode-web.nix {
      inherit pkgs vscodeWeb vscodeWebBroker lyraLinux privateServiceRoots;
    }) ++ extraModules;
  };
  system = guest.config.system.build.toplevel;
  # Capability follows the evaluated enabled boot service, including overlays.
  workspaceSourceEnabled = guest.config.systemd.services ? overalls-workspace
    && guest.config.systemd.services.overalls-workspace.enable
    && builtins.elem "multi-user.target" guest.config.systemd.services.overalls-workspace.wantedBy;
  bootKernel = import ./kernel.nix {
    inherit pkgs;
    kernel = guest.config.boot.kernelPackages.kernel;
  };
  # @cc [owner:ghuntley,label:build] reproducible-ext4-template
  # rootfs MUST rebuild byte-identically from unchanged pinned inputs. Filesystem
  # timestamps, ext4 tool time and directory hash seed MUST NOT vary per build.

  # @cc [owner:ghuntley,label:build] guest-image-local-build
  # The rootfs image and its manifest MUST prefer local execution so fleet cache
  # peers never receive forwarded builds for them; peers obtain the realized
  # outputs through reciprocal substitution instead.
  rootfs = (pkgs.callPackage (pkgs.path + "/nixos/lib/make-ext4-fs.nix") {
    storePaths = [ system ];
    volumeLabel = "lilly-root";
    populateImageCommands = ''
      mkdir -p ./files/etc ./files/nix/var/nix/profiles ./files/boot
      touch ./files/etc/NIXOS
      ln -s ${system} ./files/nix/var/nix/profiles/system
    '';
  }).overrideAttrs (previous:
    let
      # @cc [owner:ghuntley,label:build] guest-nix-store-registration
      # Every NixOS guest MUST boot with the closure bundled in its root
      # filesystem already registered in the guest Nix database, created at
      # image build time by the guest's own Nix from the image's closure
      # registration and canonicalized (fixed registrationTime, no WAL/SHM)
      # so the rootfs stays reproducible. No boot-time registration unit or
      # /nix-path-registration manifest remains (ADR-0154).
      registrationAnchor = "# Make a crude approximation of the size of the target image.";
      registerAtBuild = ''
        NIX_STATE_DIR=$PWD/rootImage/nix/var/nix ${guest.config.nix.package.out}/bin/nix-store \
          --load-db --option build-users-group "" < ./rootImage/nix-path-registration
        rm ./rootImage/nix-path-registration ./rootImage/nix/var/nix/db/reserved
        ${pkgs.python3}/bin/python3 ${./ubuntu/normalize_nix_db.py} ./rootImage/nix/var/nix/db/db.sqlite
      '';
    in
    assert pkgs.lib.assertMsg (pkgs.lib.hasInfix registrationAnchor previous.buildCommand
      && pkgs.lib.hasInfix "./rootImage/nix-path-registration" previous.buildCommand)
      "make-ext4-fs no longer stages nix-path-registration where build-time registration expects it";
    {
    preferLocalBuild = true;
    # The upstream helper otherwise retains construction timestamps and a
    # random directory-hash seed. Normalize all copied metadata and ext4 tools.
    buildCommand = ''
      export E2FSPROGS_FAKE_TIME=1
      export FAKETIME_DONT_FAKE_STAT=1
    '' + builtins.replaceStrings
      [ registrationAnchor "faketime -f" "fakeroot mkfs.ext4" ]
      [ (registerAtBuild + registrationAnchor)
        "find ./rootImage -print0 | xargs -0 touch -h -d @1\nfaketime -f"
        "fakeroot mkfs.ext4 -E hash_seed=44444444-4444-4444-8888-888888888888,lazy_itable_init=0,lazy_journal_init=0" ]
      previous.buildCommand;
  });
in
assert pkgs.lib.assertMsg ((vscodeWeb == null) == (vscodeWebBroker == null)) "Guest editor and broker packages must be supplied together";
assert pkgs.lib.assertMsg (vscodeWeb == null || minimumMemoryBytes >= 2147483648) "Browser editor guests require at least 2 GiB RAM";
assert pkgs.lib.assertMsg (gitIdentityVersion == null || gitIdentityVersion == 1)
  "Git identity capability must be version 1";
# @cc [owner:ghuntley,label:protocol] guest-manifest-exact-artifacts
# The output manifest MUST describe the exact linked kernel/initrd/rootfs bytes
# using exact hashes and lengths. Version 4 MUST bind the actual source receiver
# capability and optional immutable editor descriptor. The kernel MUST be uncompressed Firecracker ELF.
pkgs.runCommand imageName {
  nativeBuildInputs = [ pkgs.jq ];
  preferLocalBuild = true;
  passthru = {
    inherit rootfs bootKernel workspaceSourceEnabled;
    initrd = guest.config.system.build.initialRamdisk;
    editorEnabled = vscodeWeb != null;
  };
} ''
  mkdir -p $out
  ln -s ${bootKernel}/vmlinux $out/kernel
  ln -s ${guest.config.system.build.initialRamdisk}/initrd $out/initrd
  ln -s ${rootfs} $out/rootfs.ext4
  rootfs_bytes=$(stat -Lc %s ${rootfs})
  kernel_bytes=$(stat -Lc %s $out/kernel)
  initrd_bytes=$(stat -Lc %s $out/initrd)
  kernel_sha256=$(sha256sum $out/kernel | cut -d' ' -f1)
  initrd_sha256=$(sha256sum $out/initrd | cut -d' ' -f1)
  rootfs_sha256=$(sha256sum $out/rootfs.ext4 | cut -d' ' -f1)
  minimum_disk_bytes=$rootfs_bytes
  ${pkgs.lib.optionalString (minimumDiskBytes != null) ''
    minimum_disk_bytes=$(( minimum_disk_bytes > ${toString minimumDiskBytes} ? minimum_disk_bytes : ${toString minimumDiskBytes} ))
  ''}
  ${pkgs.lib.optionalString (vscodeWeb != null) ''
    minimum_disk_bytes=$(( (rootfs_bytes + 2147483648 + 1073741823) / 1073741824 * 1073741824 ))
  ''}
  jq -n \
    --arg architecture x86_64 \
    --arg boot_args '${pkgs.lib.concatStringsSep " " guest.config.boot.kernelParams} root=/dev/vda rw init=${system}/init' \
    --argjson minimum_disk_bytes "$minimum_disk_bytes" --argjson rootfs_bytes "$rootfs_bytes" \
    --argjson minimum_memory_bytes ${toString minimumMemoryBytes} \
    --argjson kernel_bytes "$kernel_bytes" --arg kernel_sha256 "$kernel_sha256" \
    --argjson initrd_bytes "$initrd_bytes" --arg initrd_sha256 "$initrd_sha256" \
    --arg rootfs_sha256 "$rootfs_sha256" \
    --argjson workspace_source_version '${if workspaceSourceEnabled then "2" else "null"}' \
    --argjson git_identity_version '${if gitIdentityVersion == null then "null" else toString gitIdentityVersion}' \
    --argjson guest_agents '${if guestAgents == null then "null" else builtins.toJSON guestAgents}' \
    --argjson editor '${builtins.toJSON (if vscodeWeb == null then null else { protocol = vscodeWeb.editorProtocol; commit = vscodeWeb.sourceCommit; release = vscodeWeb.releaseId; })}' \
    '{version: 4, architecture: $architecture, boot_args: $boot_args, minimum_disk_bytes: $minimum_disk_bytes, minimum_memory_bytes: $minimum_memory_bytes, workspace_source_version: $workspace_source_version, kernel: {bytes: $kernel_bytes, sha256: $kernel_sha256}, initrd: {bytes: $initrd_bytes, sha256: $initrd_sha256}, rootfs: {bytes: $rootfs_bytes, sha256: $rootfs_sha256}} + (if $guest_agents == null then {} else {guest_agents:$guest_agents} end) + (if $workspace_source_version == 2 or $git_identity_version == 1 then {git_identity_version:1} else {} end) + (if $editor == null then {} else {editor:$editor} end)' \
    > $out/manifest.json
''
