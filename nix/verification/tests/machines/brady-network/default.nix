{ pkgs, packages, storage ? false, large ? false }:
let
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  pressureProbe = pkgs.writeText "brady-pressure-fixture.py" ''
    import json, runpy
    module = runpy.run_path("/etc/brady-storage.py")
    observe = module["observe"]
    def checked(config):
        try:
            return observe(config)
        except Exception as error:
            print("fixture pressure failure: " + type(error).__name__ + ": " + str(error), flush=True)
            raise
    module["publish_pressure"].__globals__["observe"] = checked
    module["publish_pressure"](json.load(open("/run/brady-storage.json")))
  '';
in pkgs.testers.runNixOSTest {
  name = if large then "overalls-brady-large-storage" else if storage then "overalls-brady-native-storage" else "overalls-brady-network";
  nodes.router = { lib, config, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = lib.optional storage "zfs";
    systemd.services.zfs-zed.enable = false;
    # @cc [owner:ghuntley,label:verification;capacity] brady-storage-fixture-discard
    # The sparse ZFS vdev images MUST pass guest discards to the host, so a
    # pool trim (large-storage.py, between subtests) returns freed blocks and
    # host allocation tracks live pool data. Without it every body the large
    # scenario rewrites stays allocated
    # in the qcow2 files until the runner's build volume is exhausted (guest
    # WRITE I/O errors near 50 GB per vdev). Pool sizes and quotas are unchanged.
    virtualisation.emptyDiskImages = map (size: { inherit size; driveConfig.driveExtraOpts.discard = "unmap"; })
      (lib.optionals storage (if large then [ 524288 524288 ] else [ 4096 4096 ]));
    virtualisation.memorySize = 2048;
    boot.extraModprobeConfig = lib.optionalString storage "options zfs zfs_arc_max=268435456";
    environment.etc."brady-storage.py".source = ../../../../domains/system/brady/storage.py;
    systemd.services.brady-pressure-test = lib.mkIf storage {
      serviceConfig = { ExecStart = "${python}/bin/python3 ${pressureProbe}";
        User = "root"; Group = "brady"; UMask = "0027";
        RuntimeDirectory = "brady-pressure"; RuntimeDirectoryMode = "0750";
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        ReadWritePaths = [ "/var/cache/brady" "/pool" ];
        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_DAC_READ_SEARCH" ];
        MemoryMax = "64M"; CPUQuota = "100%"; TasksMax = 16; };
    };
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    boot.kernelModules = [ "nf_tproxy_ipv4" "nft_tproxy" ];
    users.users.brady = { isSystemUser = true; group = "brady"; uid = 991; };
    users.groups.brady = {};
    networking.extraHosts = "8.8.4.4 origin.brady.test tunnel.brady.test codeload.github.com\n";
    environment.systemPackages = [ pkgs.git pkgs.iproute2 pkgs.nftables pkgs.curl python pkgs.util-linux pkgs.jq config.boot.zfs.package
      (pkgs.writeShellScriptBin "brady-network-prepare" ''
        ${lib.optionalString large "export BRADY_TEST_LARGE=1"}
        export ERL_FLAGS="+S 2:2" RELEASE_COOKIE=isolated-brady-network RELEASE_DISTRIBUTION=none
        export RELEASE_TMP=/run/brady-network-release
        mkdir -p "$RELEASE_TMP"
        ${packages.lilly}/bin/lilly eval 'Code.eval_file("${./prepare.exs}")'
        ${python}/bin/python3 ${./origin.py} prepare
      '')
    ];
    systemd.services.brady-rss-test = lib.mkIf large {
      serviceConfig.ExecStart = "${python}/bin/python3 ${./rss.py}";
    };
    systemd.services.brady-origin-test = {
      path = [ pkgs.git ];
      environment.BRADY_TEST_ADDRESSES = "8.8.4.4,8.8.4.6";
      serviceConfig = { ExecStart = "${python}/bin/python3 ${./origin.py} serve";
        NetworkNamespacePath = "/run/netns/origin"; };
    };
    systemd.services.brady-network-test = {
      preStart = ''
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/brady/credentials
        for credential in issuer.pem issuer.key; do
          ${pkgs.coreutils}/bin/stat -c 'fixture credential mode=%a links=%h' "$CREDENTIALS_DIRECTORY/$credential"
          ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/brady/credentials/$credential"
        done
      '';
      environment = { BRADY_CONFIG_FILE = "/run/brady-fixture/config.json"; BRADY_FLEET_MONITOR = "1";
        RELEASE_DISTRIBUTION = "none"; RELEASE_COOKIE = "isolated-brady-network";
        RELEASE_TMP = "/run/brady"; ERL_FLAGS = "+S 2:2"; ERL_CRASH_DUMP = "/dev/null"; };
      serviceConfig = { User = "brady"; Group = "brady"; RuntimeDirectory = "brady";
        LoadCredential = [ "issuer.pem:/run/brady-fixture/issuer.pem" "issuer.key:/run/brady-fixture/ca.key" ];
        ExecStart = "${packages.brady}/bin/brady start";
        NetworkNamespacePath = "/run/netns/lilly-bd7662a5eeb4";
        NoNewPrivileges = true;
        AmbientCapabilities = [ "CAP_NET_RAW" ]; CapabilityBoundingSet = [ "CAP_NET_RAW" ]; };
    };
  };
  testScript = builtins.readFile ./driver.py + pkgs.lib.optionalString storage (builtins.readFile (if large then ./large-storage.py else ./storage.py));
}
