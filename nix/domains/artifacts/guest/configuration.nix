{ config, lib, options, pkgs, modulesPath, ... }@arguments:
let
  codingClis = arguments.codingClis or (import ./coding-clis.nix { inherit pkgs; });
  githubTools = import ./github { inherit pkgs; };
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    ../../system/nix-cache.nix
    ./private-services.nix
    ./terminald.nix
  ];

  system.stateVersion = "26.05";
  # @cc [owner:ghuntley,label:build] guest-nix-command-enabled
  # Guest users MUST be able to use the installed Nix CLI, including `nix
  # profile`, without supplying per-command experimental-feature overrides.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  networking.hostName = "lilly-guest";
  networking.useDHCP = false;
  networking.usePredictableInterfaceNames = false;
  networking.enableIPv6 = false;
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

  boot.loader.grub.enable = false;
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.initrd.availableKernelModules = [ "virtio_mmio" "virtio_blk" "virtio_net" "ext4" ];
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  # @cc [owner:ghuntley,label:recovery] guest-quiet-serial-console
  # The serial console MUST carry only kernel errors, systemd failures, the
  # boot-complete line and the bounded boot report: every console byte is a
  # VMM exit on the 1-vCPU boot path (measured ~20 KB -> 0.7 KB, ADR-0154).
  # printk.time=1 stamps kernel lines; the host writer adds monotonic offsets.
  # systemd.getty_auto=0 stops the getty generator offering a serial login
  # (see no-serial-login-shell below).
  boot.kernelParams = [ "console=ttyS0" "reboot=k" "panic=1" "pci=off" "systemd.getty_auto=0" "printk.time=1" "quiet" "systemd.show_status=error" ];
  boot.consoleLogLevel = 3;
  boot.enableContainers = false;

  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
    autoResize = true;
  };

  # @cc [owner:ghuntley,label:build] guest-lean-initrd
  # The Firecracker guest initrd MUST carry only what mounts its virtio-mmio
  # ext4 root: no default PC storage/USB module set, LVM, TPM2 or virtual
  # console setup. The serial console and vsock terminals need no VT keymap.
  boot.initrd.includeDefaultModules = false;
  services.lvm.enable = false;
  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;
  console.enable = false;

  # Terminal access rides the vsock multiplexer, not the serial console. The
  # serial console captures kernel output only; no login shell is offered on it.

  # @cc [owner:ghuntley,label:security] no-serial-login-shell
  # The guest MUST NOT offer a login shell on the serial console; terminal
  # sessions require the host-fenced vsock multiplexer. Guest SSH is Audi-fenced.
  # The getty generator is disabled on the kernel command line and the serial
  # and console getty units are masked, so no login prompt can start there.
  # The console instead carries one fixed, non-interactive boot-complete line,
  # followed by the bounded boot report ending `lilly-boot-report: end`.
  systemd.services."serial-getty@".enable = false;
  systemd.services."console-getty".enable = false;
  systemd.services.lilly-console-ready = {
    description = "Mark guest boot completion on the serial console";
    wantedBy = [ "multi-user.target" ];
    # This unit is pulled in by multi-user.target; ordering it after that
    # target creates a dependency cycle and leaves the target perpetually
    # activating. Readiness probes multi-user.target, so keep the completion
    # marker after the guest readiness service instead.
    after = [ "lilly-readiness.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyS0";
      ExecStart = "${pkgs.coreutils}/bin/echo lilly-guest boot complete";
    };
  };
  # @cc [owner:ghuntley,label:recovery] guest-boot-report-observation-only
  # The boot profile MUST start only after lilly-readiness, MUST NOT be
  # required by or ordered before any unit (beyond multi-user.target's implicit
  # wanted-unit ordering), and MUST NOT fail the boot transaction: Type=exec
  # ends its start job at once so systemd can finish booting while the report
  # waits (bounded) for it. It does not wait for multi-user.target, so a guest
  # whose roster sync cannot finish still reports. Output is the bounded
  # marker-prefixed profile on the serial console that Lilly retains.
  systemd.services.lilly-boot-report = {
    description = "Report bounded guest boot timing on the serial console";
    wantedBy = [ "multi-user.target" ];
    after = [ "lilly-readiness.service" ];
    serviceConfig = {
      Type = "exec";
      StandardOutput = "tty";
      StandardError = "null";
      TTYPath = "/dev/ttyS0";
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      TasksMax = 8;
      MemoryMax = "64M";
      ExecStart = "-${pkgs.python3}/bin/python3 ${./boot_report.py} ${pkgs.systemd}/bin/systemd-analyze ${pkgs.systemd}/bin/systemctl ${pkgs.systemd}/bin/journalctl";
    };
  };
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      X11Forwarding = false;
      PermitTunnel = false;
      GatewayPorts = "no";
      PermitUserEnvironment = false;
      AuthorizedKeysFile = "none";
    };
  };
  networking.firewall.allowedTCPPorts = [ 22 ];
  users.users.root.initialHashedPassword = "!";
  users.mutableUsers = true;
  users.allowNoPasswordLogin = true;
  security.sudo.enable = true;

  # @cc [owner:ghuntley,label:product] guest-default-interactive-prompt
  # Ordinary guest accounts MUST default to Bash. Global Starship startup MUST
  # cover root and runtime-created users in interactive Bash, except TERM=dumb
  # terminals skipped by the pinned module. Noninteractive shells MUST NOT
  # emit prompt initialization output.
  users.defaultUserShell = pkgs.bashInteractive;
  programs.starship = {
    enable = true;
    interactiveOnly = true;
  };

  documentation.enable = false;
  environment.defaultPackages = lib.mkForce [ ];
  environment.systemPackages = (with pkgs; [
    curl
    python3
    iproute2
    iputils
    dnsutils
    wget
    tmux
    vim
    neovim
    less
    lsof
    jq
    ripgrep
    mercurial
    git
    atop
    btop
    iotop
    ncdu
    sqlite
    podman-compose
    direnv
    devenv
  ]) ++ codingClis.packages ++ githubTools.packages "linux-amd64";
  environment.etc."overalls/github.gitconfig".source = githubTools.configuration;
  environment.etc."codex/config.toml".source = codingClis.codexConfiguration;
  environment.etc."claude-code/managed-settings.json".source = codingClis.claudeConfiguration;
  environment.sessionVariables = codingClis.environmentVariables;
  environment.localBinInPath = true;

  # @cc [owner:ghuntley,label:isolation] guest-toolset-container-boundary
  # Podman MUST stay rootful-only inside the guest and MUST NOT open a network
  # listener beyond the root-owned /run/docker.sock compatibility socket.
  # Container egress remains confined to the guest's own address and host fences.
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };

  # The host supplies a validated control address; the guest's /32 link never grants
  # access to siblings in the profile's /16 allocation pool.

  # @cc [owner:ghuntley,label:security] kernel-address-validation
  # lilly-network MUST reject duplicate, malformed or reserved lilly.ipv4 values
  # before configuring eth0 and MUST configure /32 addresses with its profile
  # gateway. Only Inception may derive a second address, in 10.41 at the same slot.
  systemd.services.lilly-network = {
    description = "Lilly guest IPv4 configuration";
    wantedBy = [ "multi-user.target" ];
    wants = [ "systemd-udev-settle.service" ];
    after = [ "systemd-udev-settle.service" ];
    before = [ "network-online.target" ];
    unitConfig.ConditionKernelCommandLine = "lilly.ipv4";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.python3}/bin/python3 ${./network.py} ${pkgs.iproute2}/bin/ip";
    };
  };

  # @cc [owner:ghuntley,label:recovery] guest-readiness-service-boundary
  # Readiness MUST use the pinned guest implementation and explicit boot identity.
  # It MUST NOT delay multi-user.target while waiting for that same target, expose
  # a TCP listener, or make its writable-root probe run in a read-only sandbox.
  systemd.services.lilly-readiness = {
    description = "Lilly placement-bound guest boot readiness";
    wantedBy = [ "multi-user.target" ];
    wants = [ "lilly-network.service" ];
    after = [ "lilly-network.service" ];
    unitConfig.ConditionKernelCommandLine = [
      "lilly.placement" "lilly.execution_epoch" "lilly.boot_challenge" "lilly.ipv4"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${./readiness.py} ${pkgs.systemd}/bin/systemctl ${pkgs.iproute2}/bin/ip";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_VSOCK" "AF_UNIX" "AF_NETLINK" ];
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      PrivateDevices = true;
      TasksMax = 16;
      MemoryMax = "64M";
      StandardOutput = "null";
    };
  };

  # @cc [owner:ghuntley,label:recovery] guest-flush-independent-of-readiness
  # Best-effort backup sync MUST use a separate host-only vsock endpoint and
  # MUST NOT freeze guests or change their boot readiness requirements.
  systemd.services.lilly-flush = {
    description = "Lilly best-effort guest backup flush";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionKernelCommandLine = [
      "lilly.placement" "lilly.execution_epoch" "lilly.boot_challenge" "lilly.ipv4"
    ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./flush.py} ${./readiness.py} ${pkgs.coreutils}/bin/sync";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_VSOCK" ];
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      PrivateDevices = true;
      TasksMax = 4;
      MemoryMax = "64M";
      StandardOutput = "null";
      StandardError = "null";
    };
  };

  # Keep guest system logs in memory. Guest images and the fleet machine tests
  # evaluate this module under different pinned NixOS revisions; newer ones
  # replace `storage` with freeform `settings`.
  services.journald =
    if options.services.journald ? settings then
      { settings.Journal.Storage = "volatile"; }
    else
      { storage = "volatile"; };
}
