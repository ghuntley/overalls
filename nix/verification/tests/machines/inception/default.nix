{ pkgs, packages }:
let
  # @cc [owner:ghuntley,label:verification] inception-browser-subprocess-typing
  # The executed browser helper MUST pass its own type check against the same
  # packaged Python and Playwright; the guest-side copy MUST use the checked bytes.
  checkedBrowser = pkgs.runCommand "inception-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${pkgs.python3.withPackages (p: [ p.playwright ])}/bin/python3 "$out/browser.py"
  '';
  # Native builders may intentionally deny outbound TCP. Keep the machine
  # lifecycle test real by serving a small Git transport fixture from the
  # isolated provider node; production still defaults to GitHub in the guest
  # image and the preparation tests cover that canonical default.
  sourceFixture = pkgs.runCommand "inception-source-fixture" {
    nativeBuildInputs = [ pkgs.git ];
  } ''
    mkdir -p "$out/work"
    printf '%s\n' '# Inception source fixture' > "$out/work/README.md"
    printf '%s\n' 'fixture = true' > "$out/work/file.ex"
    git -C "$out/work" init --initial-branch=main >/dev/null
    git -C "$out/work" config user.name fixture
    git -C "$out/work" config user.email fixture@example.test
    git -C "$out/work" add .
    git -C "$out/work" commit -m fixture >/dev/null
    mkdir -p "$out/ghuntley"
    git clone --bare "$out/work" "$out/ghuntley/overalls" >/dev/null
    git --git-dir="$out/ghuntley/overalls" symbolic-ref HEAD refs/heads/main
    git --git-dir="$out/ghuntley/overalls" update-server-info
    rm -rf "$out/work"
  '';
  sourceFixtureTls = pkgs.runCommand "inception-source-fixture-tls" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p "$out"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=inception-github-fixture-ca \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout "$out/ca.key" -out "$out/ca.pem" 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=github.com -keyout "$out/server.key" -out "$out/server.csr" 2>/dev/null
    printf 'subjectAltName=DNS:github.com,DNS:api.openai.com,DNS:api.anthropic.com\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in "$out/server.csr" -CA "$out/ca.pem" -CAkey "$out/ca.key" \
      -CAcreateserial -days 3650 -extfile extensions -out "$out/server.pem" 2>/dev/null
  '';
  # Public trust is filled from the running isolated issuer before Marshall
  # starts. No private issuer key or parent credential enters this envelope.
  publicSettings = pkgs.writeText "inception-fixture-public-settings.json" (builtins.toJSON {
    issuer = "https://11.0.0.2:9443/dir";
    accept_terms = true;
    nameservers = [
      { name = "ns1.inception.test"; address = "11.0.0.3"; port = 53; }
      { name = "ns2.inception.test"; address = "11.0.0.4"; port = 53; }
    ];
    mailbox = "hostmaster.inception.test"; issuer_ca_pem = null; trust_pem = null;
  });
  # @cc [owner:ghuntley,label:verification;protocol] inception-fixture-complete-image-validator
  # Standalone image identity validation MUST load EditorRelease before
  # ImageManifest and derive the ID from the packaged manifest without a second
  # identity algorithm, even when this fixture consumes a legacy image.
  imageId = pkgs.runCommand "native-inception-image-id" { nativeBuildInputs = [ packages.toolchain.elixir ]; } ''
    export ERL_FLAGS="+S 2:2"
    elixir -r ${../../../../../protocol/lib/overalls_protocol/editor_release.ex} -r ${../../../../../protocol/lib/overalls_protocol/guest_agents.ex} -r ${../../../../../protocol/lib/overalls_protocol/image_manifest.ex} -e '
      [source, output] = System.argv()
      {:ok, image} = source |> File.read!() |> JSON.decode!() |> OverallsProtocol.ImageManifest.validate()
      File.write!(output, image.id)
    ' ${packages.inceptionGuest}/manifest.json "$out"
  '';
in
(pkgs.testers.runNixOSTest {
  name = "overalls-inception";
  globalTimeout = 14400;
  requiredFeatures.nested-kvm = true;
  nodes.ns1 = import ./public-dns.nix { inherit packages; address = "11.0.0.3"; };
  nodes.ns2 = import ./public-dns.nix { inherit packages; address = "11.0.0.4"; };
  nodes.outer = { config, lib, ... }: {
    imports = [ (import ../../support/role-node.nix {
      inherit packages;
      module = import ../../../../domains/system/catalog.nix { inherit packages; };
    }) ];
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    networking.enableIPv6 = false;
    networking.hosts."11.0.0.1" = [ "control.example.test" ];
    networking.firewall.interfaces.eth1.allowedTCPPorts = [ 5443 ];
    networking.dhcpcd.denyInterfaces = [ "lu*" ];
    # The nested guest's public clone uses the provider fixture on eth1 as a
    # reviewed test egress path. Lilly's configured egress is eth1, and the
    # outer host routes that segment to the fixture at 11.0.0.2.
    networking.nat = {
      enable = true;
      externalInterface = "eth1";
      internalInterfaces = [ ];
      # Lilly's per-guest TAP links are dynamic lu* devices and therefore
      # cannot be named in internalInterfaces. Their router rewrites every
      # nested guest to this fixed source before forwarding out eth1; matching
      # the source here makes the public clone path work without widening the
      # fixture to arbitrary TAP traffic.
      internalIPs = [ "169.254.255.2/32" "10.40.0.0/16" ];
    };
    networking.interfaces.eth1.ipv4.addresses = [
      { address = "11.0.0.1"; prefixLength = 24; }
      { address = "11.0.0.5"; prefixLength = 24; }
    ];
    # Route nested guest public traffic through the fixture router on the
    # isolated provider VLAN. The control-plane fixture is also on this VLAN;
    # Lilly's policy intentionally permits only its configured eth1 egress.
    networking.interfaces.eth1.ipv4.routes = [
      # The nested image keeps its reviewed public resolver addresses. Keep
      # explicit host routes so DHCP's eth0 default route can never divert
      # those packets away from the isolated provider fixture.
      { address = "1.1.1.1"; prefixLength = 32; via = "11.0.0.2"; }
      { address = "9.9.9.9"; prefixLength = 32; via = "11.0.0.2"; }
      { address = "0.0.0.0"; prefixLength = 0; via = "11.0.0.2"; }
    ];
    networking.dhcpcd.extraConfig = ''
      interface eth0
        metric 200
    '';
    networking.firewall.extraForwardRules = ''
      iifname "lu*" oifname "eth1" ip saddr 169.254.255.2 ct state { new, established, related } accept
      iifname "eth1" oifname "lu*" ip daddr 169.254.255.2 ct state { established, related } accept
      iifname "lu*" oifname "eth1" ip saddr 10.40.0.0/16 ct state { new, established, related } accept
      iifname "eth1" oifname "lu*" ip daddr 10.40.0.0/16 ct state { established, related } accept
    '';
    # Clamp TCP MSS across the nested TAP/NAT path so larger ACME certificate
    # responses do not depend on fragmented packets surviving the provider VLAN.
    networking.interfaces.eth1.mtu = 1200;
    networking.nftables.tables.inception-mss = {
      family = "ip";
      content = ''
        chain forward {
          type filter hook forward priority mangle; policy accept;
          iifname "lu*" oifname "eth1" tcp flags syn tcp option maxseg size set 1160
          iifname "eth1" oifname "lu*" tcp flags syn tcp option maxseg size set 1160
        }
      '';
    };
    # Nested Firecracker TAP traffic crosses the outer VM's virtio uplink and
    # dynamically-created Lilly uplinks (lu*) and guest TAPs (lv*) in its
    # network namespace. Disable segmentation/coalescing on this fixture path
    # so a large ACME certificate response is delivered as normal MTU-sized
    # frames; both loops cover links created after boot.
    systemd.services.inception-disable-network-offloads = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 1;
        ExecStart = pkgs.writeShellScript "inception-disable-network-offloads" ''
          set -eu
          while :; do
            for device in eth1 lu*; do
              test -e "/sys/class/net/$device" || continue
              ${pkgs.iproute2}/bin/ip link set dev "$device" mtu 1200 >/dev/null 2>&1 || true
              ${pkgs.ethtool}/bin/ethtool -K "$device" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
            done
            for namespace in $(${pkgs.iproute2}/bin/ip netns list | ${pkgs.coreutils}/bin/cut -d' ' -f1); do
              case "$namespace" in
                lilly-*)
                  ${pkgs.iproute2}/bin/ip netns exec "$namespace" \
                    ${pkgs.runtimeShell} -c '
                      ethtool="$1"
                      for device in uplink; do
                        ${pkgs.iproute2}/bin/ip link set dev "$device" mtu 1200 >/dev/null 2>&1 || true
                        ${pkgs.ethtool}/bin/ethtool -K "$device" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
                      done
                      for device_path in /sys/class/net/lv*; do
                        test -e "$device_path" || continue
                        device="''${device_path##*/}"
                        ${pkgs.iproute2}/bin/ip link set dev "$device" mtu 1200 >/dev/null 2>&1 || true
                        "$ethtool" -K "$device" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
                      done
                    ' -- ${pkgs.ethtool}/bin/ethtool || true
                  ;;
              esac
            done
            ${pkgs.coreutils}/bin/sleep 1
          done
        '';
      };
    };
    boot.supportedFilesystems = [ "zfs" ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
    systemd.services.zfs-zed.enable = false;
    # The outer fixture hosts the 68-GiB Inception core and a documented
    # 16-vCPU/32-GiB workload concurrently.  Keep enough physical headroom
    # for both Firecracker guests and the outer services; the previous 90-GiB
    # envelope left the workload executor permanently deferred on capacity.
    virtualisation.memorySize = lib.mkForce 131072;
    virtualisation.cores = lib.mkForce 48;
    virtualisation.diskSize = 32768;
    virtualisation.emptyDiskImages = [ {
      size = 1048576;
      driveConfig.driveExtraOpts.cache = "writeback";
    } ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    services.lilly = {
      enable = true;
      # Preserve bounded Firecracker diagnostics for failed nested boots; the
      # collector redacts and caps per-VM logs and is required for native
      # execution failure diagnosis.
      firecrackerLogging.enable = true;
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = lib.mkForce "https://control.example.test:5443";
      egressInterface = "eth1";
      # The isolated HTTPS GitHub fixture uses a test-only CA; deliver only
      # its public root to the nested guest trust bundle.
      guestTrustRoots = [ "${sourceFixtureTls}/ca.pem" ];
      # The lifecycle scenario runs two 16-vCPU/32-GiB Inception children at
      # once.  Marshall reserves one host core and 1 GiB for host services,
      # so the aggregate guest slice must exceed 32 cores and 64 GiB or the
      # second placement remains deferred as execution_unavailable.
      guestCpuCores = lib.mkForce 48;
      guestMemoryMiB = lib.mkForce 98304;
      images = [ { path = "${packages.inceptionGuest}"; } ];
      inceptionImageId = builtins.readFile imageId;
      inceptionSMTPFile = "/run/inception-test/smtp.json";
      ingress.enable = true;
    };
    # The nested probe may exhaust the ordinary service deadline while this
    # QEMU fixture copies its large probe disk. Preserve the probe's own bound
    # and require its boot receipt before the test proceeds.
    systemd.services.lilly-inception-preflight.serviceConfig.TimeoutStartSec = lib.mkForce 900;
    # The enrolled Lilly release below consumes production outer dispatch.
    systemd.services.lilly.enable = false;
    # Like the fixture's manually enrolled Lilly, private service enrollment is
    # a separate phase. Keep the required Ziggy module enabled, but do not start
    # it with an invented host credential or provider key in this lifecycle test.
    # This fixture makes no private inference acceptance claim.
    services.ziggy.secretsFile = "/run/inception-outer/ziggy.enc.json";
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    # The fixture enrolls its test Lilly explicitly and does not exercise named
    # edge integrations; keep Galileo configured but out of the boot target.
    services.galileo.secretsFile = "/run/inception-outer/galileo.enc.json";
    systemd.services.galileo.wantedBy = lib.mkForce [];
    services.marshall = {
      enable = true;
      instances.outer.fleetBindAddress = "11.0.0.1";
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      inceptionImageId = builtins.readFile imageId;
      ingress.zone = "apps.inception.test";
      ingress.wildcardAcme = {
        issuerInstance = "outer";
        directory = "https://11.0.0.2:9443/dir";
        issuerCaFile = "/run/inception-public-issuer-ca.pem";
        certificateRootsFile = "/run/inception-public-roots.pem";
        acceptTerms = true;
        nameservers = [
          { address = "11.0.0.3"; port = 53; }
          { address = "11.0.0.4"; port = 53; }
        ];
      };
      ingress.inceptionPublicFile = "/run/inception-public-settings.json";
      secretUnits = [ "inception-public-settings.service" ];
    };
    services.marshallProxy = { enable = true; bindAddress = lib.mkForce "11.0.0.1"; openFirewall = true; };
    services.audi = {
      enable = true;
      administrativeAccess = "console";
      bindAddress = "11.0.0.5";
      openFirewall = true;
      # The template identity is replaced by the dynamically enrolled host in
      # the private runtime credential below; it never authorizes this fixture.
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://control.example.test:5443";
      credentialFile = "/run/inception-outer/audi.token";
      caFile = "/run/overalls-test/ca.crt";
      tls = {
        enable = true;
        zone = "apps.inception.test";
        browserOrigin = "https://control.example.test";
        certificateRootsFile = "/run/inception-public-roots.pem";
      };
    };
    # role-node supplies the shared PostgreSQL default; this fixture pins the
    # same major release explicitly and must override that unique option.
    services.postgresql.package = lib.mkForce pkgs.postgresql_18;
    systemd.services.audi = {
      wantedBy = lib.mkForce [];
      environment.AUDI_CONFIG_FILE = lib.mkForce "/run/credentials/audi.service/runtime.json";
      serviceConfig.LoadCredential = lib.mkAfter [ "runtime.json:/run/inception-outer/audi.json" ];
    };
    # Host certificate renewal normally starts five minutes after boot and
    # Requires Audi. This fixture enrolls the gateway later, so suppress the
    # timer to prevent an early Audi start before its runtime credentials exist.
    systemd.timers.audi-ssh-certificate.wantedBy = lib.mkForce [];
    systemd.services.inception-public-settings = {
      script = ''
        while ! test -s /run/inception-public-settings.json; do
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 180; };
    };
    systemd.services.marshall-outer = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
    };
    environment.etc."inception-outer.exs".source = ./outer.exs;
    systemd.services."inception-outer@" = {
      environment = {
        PHX_SERVER = "false";
        PHX_HOST = "control.example.test";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-inception-operator";
        MARSHALL_INSTANCE_ID = "inception-operator";
        MARSHALL_DB_TLS = "verify";
        MARSHALL_DB_CA_CERTFILE = "/run/overalls-test/ca.crt";
        MARSHALL_REPLICA_COUNT = "3";
        MARSHALL_DB_CONNECTION_BUDGET = "64";
        POOL_SIZE = "2";
        ERL_FLAGS = "+S 2:2";
        ERL_CRASH_DUMP = "/dev/null";
        INCEPTION_IMAGE = "${packages.inceptionGuest}";
        INCEPTION_PROBE_IMAGE = "${packages.inceptionProbeGuest}";
        INCEPTION_TOOLS = "${packages.lilly}/overalls-release.json";
        INCEPTION_ID_BINARY = "${pkgs.coreutils}/bin/id";
        INCEPTION_SOURCE_CA = "${sourceFixtureTls}/ca.pem";
      };
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        TimeoutStartSec = 2700;
        EnvironmentFile = "/run/overalls-test/marshall.env";
        ExecStart = pkgs.writeShellScript "inception-outer-operator" ''
          export INCEPTION_OUTER_ACTION="$1"
          export MARSHALL_INCEPTION_IMAGE_ID=${builtins.readFile imageId}
          export MARSHALL_INSTANCE_ID=inception-operator MARSHALL_DB_TLS=verify
          unset PORT
          exec ${packages.marshall}/bin/marshall eval 'Code.eval_file("/etc/inception-outer.exs")'
        '' + " %i";
      };
    };
    # The enrolled Lilly release is deliberately root-launched so the fixture
    # can keep its bootstrap credentials root-only. Give it a fixture-owned
    # hostd with the same typed VM tool policy as production. The production
    # hostd authenticates only the `lilly` uid, while a private hostd has no
    # Firecracker tool configuration; this daemon bridges both requirements.
    systemd.services.inception-outer-hostd = {
      path = [ config.boot.zfs.package "${packages.lilly}/host-tools" pkgs.systemd ];
      wantedBy = [];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0700 /run/inception-outer";
        ExecStart = lib.escapeShellArgs [
          "${packages.lilly}/host-tools/bin/lilly-hostd"
          "--socket" "/run/inception-outer/hostd.sock"
          "--cgroup" "self"
          "--root" "/"
          "--socket-root" "/pool"
          "--pool-dataset" "tank/lilly"
          "--service-uid" (toString config.users.users.lilly.uid)
          "--vm-boot-log" "${packages.lilly}/host-tools/bin/lilly-boot-log"
          "--vm-unshare" "${packages.lilly}/host-tools/bin/unshare"
          "--vm-launch-guard" "${packages.lilly}/host-tools/bin/lilly-launch-guard"
          "--vm-jailer" "${packages.vmm}/bin/jailer"
          "--vm-firecracker" "${packages.vmm}/bin/firecracker"
          "--ingress-peer-user" "audi"
          "--ingress-slice" "lilly_ingress.slice"
        ];
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 30;
        LimitNOFILE = 65536;
        # hostd creates command cgroups beneath its own delegated cgroup;
        # without delegation its typed systemd-run requests fail before the
        # Firecracker unit can be created.
        Delegate = true;
      };
    };
    systemd.services.inception-outer-lilly = {
      path = [ config.boot.zfs.package "${packages.lilly}/host-tools" pkgs.systemd ];
      environment = {
        LILLY_CONFIG_FILE = "/run/inception-outer/lilly.json";
        LILLY_STATUS_SOCKET = "/run/inception-outer/status.sock";
        # Use the fixture-owned hostd so root's peer credentials and the
        # trusted Firecracker, jailer and launch-guard paths agree.
        LILLY_HOSTD_SOCKET = "/run/inception-outer/hostd.sock";
        # This manually launched release runs as root, while its durable
        # state is owned by the system's lilly account.  Match the production
        # service UID so PrivateFiles and the private hostd accept that state.
        LILLY_SERVICE_UID = toString config.users.users.lilly.uid;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-inception-lilly";
        RELEASE_TMP = "/run/inception-outer/release";
        ERL_FLAGS = "+S 2:2";
        ERL_CRASH_DUMP = "/dev/null";
      };
      requires = [ "inception-outer-hostd.service" ];
      after = [ "inception-outer-hostd.service" ];
      bindsTo = [ "inception-outer-hostd.service" ];
      serviceConfig = { Type = "exec"; UMask = "0077"; };
      script = ''
        mkdir -p "$RELEASE_TMP"
        exec ${packages.lilly}/bin/lilly start
      '';
    };
    environment.etc."inception-probe.exs".source = ./probe.exs;
    environment.etc."inception-public-settings.json".source = publicSettings;
    environment.etc."inception-dns-probe.py".source = ./dns_probe.py;
    environment.etc."inception-wildcard-probe.py".source = ./wildcard_probe.py;
    environment.etc."inception-inner.exs".source = ./inner.exs;
    environment.etc."inception-inner-physical.exs".source = ./inner_physical.exs;
    environment.etc."inception-inner-ziggy.exs".source = ./inner_ziggy.exs;
    environment.etc."inception-inner-browser.exs".source = ./inner_browser.exs;
    environment.etc."inception-provider-configure.py".source = ./provider_configure.py;
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq pkgs.python3
    (pkgs.writeShellScriptBin "inception-probe" ''
      export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
      export ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
      export RELEASE_COOKIE=isolated-inception-fixture RELEASE_TMP=/run/inception-probe-release
      umask 077
      mkdir -p "$RELEASE_TMP" /run/inception-test
      {
        date -u +"wrapper start %s"
        id -u
        stat -c 'image %n' ${packages.inceptionGuest}/manifest.json
      } > /run/inception-test/probe-steps.log 2>&1
      export INCEPTION_ACTION="$1" INCEPTION_GENERATION="''${2:-1}"
      export INCEPTION_MANAGED="''${3:-0}" INCEPTION_INSTANCE="''${4:-1}"
      export INCEPTION_IMAGE=${packages.inceptionGuest}
      export INCEPTION_PROBE_IMAGE=${packages.inceptionProbeGuest}
      export INCEPTION_TOOLS=${packages.lilly}/overalls-release.json
      exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/inception-probe.exs")'
    '')
    ];
  };
  nodes.internet = { lib, ... }: {
    imports = [ ./public-issuer.nix ];
    environment.systemPackages = [
      pkgs.bind.dnsutils
      pkgs.git
      pkgs.chromium
      (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.playwright ]))
    ];
    environment.etc."inception-browser.py".source = checkedBrowser + "/browser.py";
    system.stateVersion = "26.05";
    virtualisation.memorySize = 3072;
    networking.enableIPv6 = false;
    # The HTTPS source fixture uses a test CA whose public root is also
    # delivered to the nested Inception guest. Trust it on the provider node
    # so the canonical GitHub preflight exercises the same TLS endpoint.
    security.pki.certificateFiles = [ "${sourceFixtureTls}/ca.pem" ];
    # Use the isolated provider's resolver for ordinary libc/Git lookups as
    # well as the explicit dig probe below. QEMU's DHCP resolver does not know
    # the canonical github.com fixture address.
    networking.nameservers = [ "11.0.0.2" ];
    networking.interfaces.eth1.ipv4.addresses = [
      { address = "11.0.0.2"; prefixLength = 24; }
      # Keep the nested guest's production public resolver addresses local to
      # this isolated provider.  The explicit aliases make both DNS and HTTPS
      # follow the declared outer route while preserving github.com's URL.
      { address = "1.1.1.1"; prefixLength = 32; }
      { address = "9.9.9.9"; prefixLength = 32; }
    ];
    networking.interfaces.eth1.mtu = 1200;
    # The fixture's resolver redirection is declared as an nftables table;
    # enabling the backend also makes the matching firewall and NAT modules
    # use the same ruleset.
    networking.nftables.enable = true;
    # This fixture node is the reviewed public egress router for the outer
    # machine. It forwards only the isolated provider VLAN to its QEMU user
    # network and masquerades that traffic there. The outer machine already
    # rewrites Lilly's 169.254.255.2 source to its provider address on eth1,
    # so this router must NAT the provider VLAN (not the pre-NAT source) on
    # the final hop to QEMU's upstream network.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    # The nested Inception image deliberately uses public recursive resolvers
    # (1.1.1.1 and 9.9.9.9).  NixOS machine tests run behind QEMU's private
    # network, where those addresses are not reachable directly.  Provide a
    # real forwarding resolver on the isolated provider VLAN and transparently
    # redirect only those two DNS destinations to it; GitHub HTTPS still
    # follows the ordinary routed/NAT path below.
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        interface = "eth1";
        bind-interfaces = true;
        listen-address = "11.0.0.2";
        no-resolv = true;
        server = [ "10.0.2.3" ];
        # The NixOS test QEMU network does not provide a usable recursive DNS
        # service in every builder. Resolve the canonical GitHub hostname to
        # the isolated HTTPS mirror's public test address; the guest still
        # performs an HTTPS Git exchange with the canonical URL and validates
        # its fixture CA.
        address = [ "/github.com/1.1.1.1" ];
      };
    };
    networking.firewall.allowedUDPPorts = [ 53 ];
    networking.firewall.allowedTCPPorts = [ 53 443 8080 ];
    networking.nftables.tables.inception-public-dns = {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority -100; policy accept;
          iifname "eth1" ip daddr 1.1.1.1 udp dport 53 dnat to 11.0.0.2:53
          iifname "eth1" ip daddr 1.1.1.1 tcp dport 53 dnat to 11.0.0.2:53
          iifname "eth1" ip daddr 9.9.9.9 udp dport 53 dnat to 11.0.0.2:53
          iifname "eth1" ip daddr 9.9.9.9 tcp dport 53 dnat to 11.0.0.2:53
        }
      '';
    };
    networking.nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = [ "eth1" ];
      # The normal path presents the outer fixture's eth1 address after the
      # outer Lilly NAT. Keep the pre-NAT address too: this makes the fixture
      # valid for both the production namespace route and the native driver's
      # direct provider link while still limiting masquerade to Lilly traffic.
      internalIPs = [ "11.0.0.0/24" "169.254.255.2/32" "10.40.0.0/16" ];
    };
    networking.firewall.extraForwardRules = ''
      iifname "eth1" oifname "eth0" ip saddr { 11.0.0.0/24, 169.254.255.2, 10.40.0.0/16 } accept
      iifname "eth0" oifname "eth1" ip daddr { 11.0.0.0/24, 169.254.255.2, 10.40.0.0/16 } ct state { established, related } accept
    '';
    # The provider router is the final segment for nested ACME traffic. Keep
    # its QEMU-facing and isolated-VLAN links from coalescing the certificate
    # response into an oversized frame before it returns to the outer guest.
    systemd.services.inception-provider-offloads = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "inception-disable-provider-offloads" ''
          set -eu
          for device in eth0 eth1; do
            ${pkgs.iproute2}/bin/ip link set dev "$device" mtu 1200 >/dev/null 2>&1 || true
            ${pkgs.ethtool}/bin/ethtool -K "$device" tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
          done
        '';
      };
    };
    # Preserve the image's explicit public resolver addresses while routing
    # their DNS packets to the fixture's local forwarder.  The DNAT is
    # limited to DNS from the isolated provider VLAN and both transports so
    # resolver retries cannot escape to the QEMU user network directly.
    systemd.services.public-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /etc";
    };
    # Public-issuer's provider already owns the isolated TLS listener. Extend
    # that same listener with Git's smart HTTP backend so github.com and the
    # synthetic API hosts share the issuer's runtime certificate.
    systemd.services.inception-provider-fixture.serviceConfig.ExecStart = lib.mkForce
      "${pkgs.python3}/bin/python3 ${./provider.py} /var/lib/inception-fixture-issuer/tls.crt /var/lib/inception-fixture-issuer/tls.key ${sourceFixture} ${pkgs.git}/libexec/git-core/git-http-backend";
  };
  testScript = builtins.readFile ../../support/transfer.py + "\n" + builtins.readFile ./driver.py;
}) // { inherit checkedBrowser; }
