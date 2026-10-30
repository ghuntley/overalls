{ pkgs, module, packages, buck2 }:
let
  inherit (pkgs) lib;
  # Test-only CAs: private keys in the store are acceptable for fixtures and
  # are sealed to each VM's host identity at runtime like production bundles.
  tailnet = { cache = "192.168.1.1"; ci = "192.168.1.2"; host = "192.168.1.3"; };
  public = { cache = "192.168.2.1"; outsider = "192.168.2.3"; };
  fixtures = pkgs.runCommand "buck-remote-cache-fixtures" { nativeBuildInputs = [ pkgs.openssl ]; } ''
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
    ca ca; ca uploader-ca; ca rogue-ca
    leaf ca server serverAuth IP:${tailnet.cache}
    leaf ca reader-host clientAuth
    leaf uploader-ca uploader-ci clientAuth
    leaf rogue-ca rogue clientAuth
  '';
  # The real execution platform rule, in a minimal project with two actions.
  project = pkgs.runCommand "buck-remote-cache-project" { } ''
    mkdir $out
    # Renamed in the repository so they do not form a nested Buck2 package.
    cp ${./project/BUCK.fixture} $out/BUCK
    cp ${./project/buckconfig.fixture} $out/.buckconfig
    cp ${./project/rules.bzl.fixture} $out/rules.bzl
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
  # Bundles are sealed to each VM's real host key at runtime.
  sealed = {
    services.openssh.enable = true;
    environment.systemPackages = [ pkgs.python3 packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."seal.py".source = ./seal.py;
    environment.etc."fixtures".source = fixtures;
    overalls.buckRemoteCache.encryptedFile = "/run/fixture/buck-re.enc.json";
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-buck-remote-cache";
  globalTimeout = 1200;
  defaults = {
    imports = [ module ];
    system.stateVersion = "26.05";
    networking.useDHCP = false;
  };
  nodes = {
    cache = {
      imports = [ (addressed [ 1 2 ] [ tailnet.cache public.cache ]) sealed ];
      virtualisation = vm 1024;
      # Production trusts only tailscale0 but admits every reviewed public
      # fleet source to all ports (fleet-firewall). Trust both fixture
      # networks so only the binding and interface restriction stand between
      # the public side and the listeners.
      networking.firewall.trustedInterfaces = [ "eth1" "eth2" ];
      overalls.buckRemoteCache.server = {
        enable = true;
        listenAddress = tailnet.cache;
        interface = "eth1";
        certificate = "${fixtures}/server.crt";
        readerCaCertificate = "${fixtures}/ca.crt";
        uploaderCaCertificate = "${fixtures}/uploader-ca.crt";
        casMaxBytes = 256 * 1024 * 1024;
        acMaxBytes = 16 * 1024 * 1024;
      };
    };
    ci = { imports = [ (addressed [ 1 ] [ tailnet.ci ]) buckClient ]; };
    # A fleet host: its read-only client configuration comes from the module.
    host = { config, ... }: {
      imports = [ (addressed [ 1 ] [ tailnet.host ]) buckClient sealed ];
      overalls.buckRemoteCache.client = { enable = true; address = tailnet.cache; caCertificate = "${fixtures}/ca.crt"; };
      # The host updater's own configuration path (ADR-0271): the module's
      # cache settings and the production runtime that turns them into the
      # checkout's .buckconfig.local.
      environment.etc."updater-remote-cache.json".text = builtins.toJSON config.services.overallsAutoUpdate.remoteCache;
      environment.etc."updater-runtime.py".source = ../../../../domains/system/auto-update/runtime.py;
      environment.etc."updater-config.py".source = ./updater_config.py;
    };
    outsider = {
      imports = [ (addressed [ 2 ] [ public.outsider ]) ];
      virtualisation = vm 512;
    };
  };
  testScript = builtins.readFile ./driver.py;
}
