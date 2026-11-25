{ pkgs, module, fleetModule, packages }:
let
  inherit (pkgs) lib;
  # Test-only CAs: private keys in the store are acceptable for fixtures and
  # are sealed to each VM's host identity at runtime like production bundles.
  addresses = { alpha = "192.168.1.1"; beta = "192.168.1.2"; };
  fixtures = pkgs.runCommand "fleet-builds-fixtures" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out; cd $out
    ca() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $1-ca.key -out $1-ca.crt \
      -days 30 -subj "/CN=$1-ca" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2>/dev/null; }
    leaf() { # ca name cn ip
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $2.key -out $2.csr -subj "/CN=$3" 2>/dev/null
      printf 'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:%s\n' $4 > $2.ext
      openssl x509 -req -in $2.csr -CA $1-ca.crt -CAkey $1-ca.key -CAcreateserial -out $2.crt -days 30 -extfile $2.ext 2>/dev/null
      rm $2.csr $2.ext
    }
    ca grpc
    leaf grpc grpc-alpha build-alpha ${addresses.alpha}
    leaf grpc grpc-beta build-beta ${addresses.beta}
    leaf grpc grpc-mallory build-mallory ${addresses.beta}
  '';
  machine = name: {
    address = addresses.${name};
    systems = [ "x86_64-linux" ];
    logicalCpus = 2;
    supportedFeatures = [ "big-parallel" ];
    grpcCertificate = "${fixtures}/grpc-${name}.crt";
    encryptedFile = "/run/fixture/keys.enc.json";
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-fleet-builds";
  globalTimeout = 900;
  defaults = { config, ... }: {
    imports = [ module fleetModule ];
    system.stateVersion = "26.05";
    virtualisation = { memorySize = 2048; cores = 2; writableStore = true; qemu.forceAccel = lib.mkForce true; };
    # Production trusts only tailscale0; the fixture network stands in for it.
    networking.firewall.trustedInterfaces = [ "eth1" ];
    # The sealing fixture targets the host key, as production bundles do.
    services.openssh.enable = true;
    # The test disks are below the production 10G build admission floor.
    services.nix-grpc-daemon.minFree = "0";
    overalls.fleetBuilds = {
      enable = true;
      localName = config.networking.hostName;
      scheduler = "alpha";
      grpcCaCertificate = "${fixtures}/grpc-ca.crt";
      machines = { alpha = machine "alpha"; beta = machine "beta"; };
    };
    nix.settings = {
      sandbox = true;
      experimental-features = [ "nix-command" ];
      connect-timeout = 2;
    };
    environment.systemPackages = [ pkgs.python3 pkgs.curl pkgs.busybox packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."seal.py".source = ./seal.py;
    environment.etc."fixtures".source = fixtures;
    environment.etc."jobs.nix".text = ''
      { batch, count ? 4, seconds ? 8 }:
      builtins.genList (i: builtins.derivation {
        name = "fleet-build-" + batch + "-" + toString i;
        system = "x86_64-linux";
        builder = (builtins.storePath "${pkgs.busybox}") + "/bin/sh";
        args = [ "-c" ("export PATH=${pkgs.busybox}/bin; mkdir $out; sleep " + toString seconds + "; echo " + batch + " > $out/batch") ];
      }) count
    '';
  };
  nodes = { alpha = {}; beta = {}; };
  testScript = builtins.readFile ./driver.py;
}
