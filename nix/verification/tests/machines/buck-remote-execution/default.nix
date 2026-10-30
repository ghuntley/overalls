{ pkgs, module, packages, buck2 }:
let
  inherit (pkgs) lib;
  # Test-only CAs: private keys in the store are acceptable for fixtures and
  # are sealed to each VM's host identity at runtime like production bundles.
  # The test framework also gives each node 192.168.<vlan>.<index>, by node
  # name order; these match it.
  tailnet = { ci = "192.168.1.1"; dev = "192.168.1.2"; scheduler = "192.168.1.4"; worker = "192.168.1.5"; };
  public = { outsider = "192.168.2.3"; scheduler = "192.168.2.4"; };
  fixtures = pkgs.runCommand "buck-remote-execution-fixtures" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out; cd $out
    ca() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $1.key -out $1.crt \
      -days 30 -subj "/CN=$1" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2>/dev/null; }
    leaf() { # ca name eku [san]
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $2.key -out $2.csr -subj "/CN=$2" 2>/dev/null
      { printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\n' $3
        if [ -n "''${4:-}" ]; then printf 'subjectAltName=%s\n' $4; fi; } > $2.ext
      openssl x509 -req -in $2.csr -CA $1.crt -CAkey $1.key -CAcreateserial -out $2.crt -days 30 -extfile $2.ext 2>/dev/null
      cat $2.crt $2.key > $2.pem
      rm $2.csr $2.ext
    }
    ca ca; ca uploader-ca; ca executor-ca; ca worker-ca
    leaf ca server serverAuth IP:${tailnet.scheduler}
    leaf ca reader-host clientAuth
    leaf uploader-ca uploader-ci clientAuth
    leaf executor-ca executor-dev clientAuth
    leaf worker-ca worker-scheduler clientAuth
    leaf worker-ca worker-worker clientAuth
  '';
  # A cells closure stand-in: the [nix] section with the id workers advertise.
  cellsConfig = "[nix]\n  cells_id = ${builtins.hashString "sha256" "buck-remote-execution fixture cells"}\n";
  cells = pkgs.runCommand "buck-remote-execution-cells" { } ''
    mkdir $out
    printf '%s' ${lib.escapeShellArg cellsConfig} > $out/toolchains.buckconfig
  '';
  # The real execution platform rule, in a minimal project of probes.
  project = pkgs.runCommand "buck-remote-execution-project" { } ''
    mkdir $out
    # Renamed in the repository so they do not form a nested Buck2 package.
    cp ${./project/BUCK.fixture} $out/BUCK
    cp ${./project/buckconfig.fixture} $out/.buckconfig
    cp ${./project/rules.bzl.fixture} $out/rules.bzl
    cp ${cells}/toolchains.buckconfig $out/cells.buckconfig
    cp ${../../../../../buck/platforms.bzl} $out/platforms.bzl
    mkdir $out/prelude $out/none
    touch $out/none/BUCK
    tar -xzf ${buck2.prelude} -C $out/prelude --strip-components=1
  '';
  vm = memorySize: { inherit memorySize; cores = 2; qemu.forceAccel = lib.mkForce true; };
  addressed = vlans: addresses: {
    virtualisation.vlans = vlans;
    networking.interfaces = lib.listToAttrs (lib.imap1 (i: address: lib.nameValuePair "eth${toString i}" {
      ipv4.addresses = [ { inherit address; prefixLength = 24; } ];
    }) addresses);
  };
  buckClient = {
    virtualisation = vm 1536;
    environment.systemPackages = [ buck2 pkgs.grpcurl ];
    environment.etc."buck-project".source = project;
    environment.etc."rev2-protos".source = "${packages.nativelink.src}/nativelink-proto";
    environment.etc."fixtures".source = fixtures;
  };
  # A worker host with a fixture Lilly pool: /srv/pool, and a guest dataset
  # mounted inside it before the worker starts (ADR-0144). The pool stays
  # shared, so only the worker's own namespace keeps later mounts out.
  workerHost = {
    services.openssh.enable = true;
    environment.systemPackages = [ pkgs.python3 packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."seal.py".source = ./seal.py;
    environment.etc."fixtures".source = fixtures;
    fileSystems."/srv/pool" = { device = "pool"; fsType = "tmpfs"; };
    # Fixture Lilly state, world-readable so only the worker's sandbox hides it.
    systemd.tmpfiles.rules = [
      "d /run/lilly 0755 root root -" "f /run/lilly/marker 0644 root root - lilly"
      "d /var/lib/lilly 0755 root root -" "f /var/lib/lilly/marker 0644 root root - lilly"
    ];
    systemd.services.fixture-guest-dataset = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nativelink-worker.service" ];
      unitConfig.RequiresMountsFor = [ "/srv/pool" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        mkdir -p /srv/pool/guest
        ${pkgs.util-linux}/bin/mountpoint -q /srv/pool/guest || ${pkgs.util-linux}/bin/mount -t tmpfs guest /srv/pool/guest
        echo guest > /srv/pool/guest/marker
      '';
    };
    overalls.buckRemoteCache.worker = {
      enable = true;
      encryptedFile = "/run/fixture/buck-re-worker.enc.json";
      schedulerAddress = tailnet.scheduler;
      interface = "eth1";
      caCertificate = "${fixtures}/ca.crt";
      cellsLinks = [];
      cells = [ cells ];
      excludedMounts = [ "/srv/pool" ];
      maxInflightTasks = 2;
      casMaxBytes = 128 * 1024 * 1024;
    };
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-buck-remote-execution";
  globalTimeout = 1800;
  defaults = {
    imports = [ module ];
    system.stateVersion = "26.05";
    networking.useDHCP = false;
  };
  nodes = {
    # Panterloons: cache, scheduler and a worker.
    scheduler = {
      imports = [ (addressed [ 1 2 ] [ tailnet.scheduler public.scheduler ]) workerHost ];
      virtualisation = vm 1536;
      # Production admits reviewed public fleet sources to every port; only
      # the binding and interface restriction keep the public side out.
      networking.firewall.trustedInterfaces = [ "eth1" "eth2" ];
      overalls.buckRemoteCache.encryptedFile = "/run/fixture/buck-re.enc.json";
      overalls.buckRemoteCache.server = {
        enable = true;
        listenAddress = tailnet.scheduler;
        interface = "eth1";
        certificate = "${fixtures}/server.crt";
        readerCaCertificate = "${fixtures}/ca.crt";
        uploaderCaCertificate = "${fixtures}/uploader-ca.crt";
        casMaxBytes = 256 * 1024 * 1024;
        acMaxBytes = 16 * 1024 * 1024;
        execution = {
          enable = true;
          executorCaCertificate = "${fixtures}/executor-ca.crt";
          workerCaCertificate = "${fixtures}/worker-ca.crt";
          unmatchedTimeout = 10;
        };
      };
    };
    # Dungarees: a worker only.
    worker = {
      imports = [ (addressed [ 1 ] [ tailnet.worker ]) workerHost ];
      virtualisation = vm 1024;
    };
    ci = { imports = [ (addressed [ 1 ] [ tailnet.ci ]) buckClient ]; };
    dev = { imports = [ (addressed [ 1 ] [ tailnet.dev ]) buckClient ]; };
    outsider = {
      imports = [ (addressed [ 2 ] [ public.outsider ]) ];
      virtualisation = vm 512;
    };
  };
  testScript = builtins.readFile ./driver.py;
}
