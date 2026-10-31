{ pkgs, nixpkgs, module, diskoModule }:
let
  inherit (pkgs) lib;
  original = import ../fixtures/hosts { platform = "hetzner"; firmware = "bios"; };
  host = original // {
    discovery.routes = [{ dst = "default"; dev = "eth0"; }];
    identity = original.identity // { sshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsQS6M+wN+SkBaDY5JQqmXEXWnAs76wDRtZjgvYUAWk" ]; };
    git = original.git // { knownHosts = "fixture-pinned-host-key"; };
    credentials = (map (kind: { name = "${original.name}-${kind}"; path = "secrets/${original.name}-${kind}.enc.json"; }) [ "git" "lilly" ])
      # Evaluation-only ciphertext path; this suite does not decrypt credentials.
      ++ [
        { name = "${original.name}-underclass"; path = "secrets/${original.name}-git.enc.json"; }
        { name = "fleet-tailscale"; path = "secrets/${original.name}-git.enc.json"; }
        { name = "fleet-namespace"; path = "secrets/${original.name}-git.enc.json"; }
      ];
    lilly = {
      controlPlane = "https://control.test";
      egressInterface = "eth0";
      transferEndpoint = {
        address = "192.0.2.10";
        port = 2224;
        host_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsQS6M+wN+SkBaDY5JQqmXEXWnAs76wDRtZjgvYUAWk";
      };
      overheads = { cores = 1; memoryBytes = 1073741824; storageBytes = 1073741824; };
      binding = {
        host_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        machine_id = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        credential_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        expires_at = "2031-09-16T00:00:00Z";
        pools = [{ id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
          name = "guests"; filesystem_id = "zfs:1:2";
          storage = { backend = "zfs"; zpool_guid = "1"; dataset_guid = "2"; dataset = "zroot/lilly"; };
        }];
      };
    };
  };
  evaluate = h: extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module (import ../../../platform/hosts/profile.nix { host = h; inherit diskoModule; enrolled = true; repositoryRoot = ../fixtures/hosts; }) extra ];
  }).config;
  valid = c: lib.all (a: a.assertion) c.assertions;
  good = evaluate host {};
  wrongIdentity = evaluate host { services.lilly.hostId = lib.mkForce "dddddddd-dddd-4ddd-8ddd-dddddddddddd"; };
  wrongSecret = evaluate host { services.lilly.credentialFile = lib.mkForce "/run/wrong.json"; };
  wrongGroup = evaluate host { services.overallsSecrets.bundles.lilly.group = lib.mkForce "wheel"; };
  wrongTransferPort = evaluate host { services.lillyTransfer.port = lib.mkForce 2225; };
  noTailscale = evaluate (host // { credentials = lib.filter (c: c.name != "fleet-tailscale") host.credentials; }) {};
  noNamespace = evaluate (host // { credentials = lib.filter (c: c.name != "fleet-namespace") host.credentials; }) {};
  tooLong = evaluate (host // { lilly = host.lilly // { credentialTtlSeconds = 157680001; }; }) {};
in
assert lib.assertMsg (valid good) (lib.concatMapStringsSep "\n" (a: a.message) (lib.filter (a: !a.assertion) good.assertions));
assert good.services.lillyTransfer.enable;
assert good.services.lillyTransfer.port == host.lilly.transferEndpoint.port;
assert good.networking.firewall.allowedTCPPorts == [];
# Fleet addresses are SOPS-delivered, so a host without the document gets no grant.
assert good.overalls.fleetFirewall.allowedHosts == {};
# Only the recorded installing operator reaches administrative SSH, and only
# while its root-only installation file exists.
assert builtins.attrNames good.overalls.runtimeFirewall.rules == [ "base-installer" ];
assert good.overalls.runtimeFirewall.rules.base-installer == {
  source = null; sourceFile = "/run/overalls-host/base-source";
  destination = null; destinationFile = null; interface = null;
  protocol = "tcp"; ports = good.services.openssh.ports; optional = true;
  comment = "Installing operator administrative SSH";
  units = [ "overalls-base-source.service" ];
};
assert good.systemd.services.overalls-base-source.unitConfig.ConditionPathExists
  == "/var/lib/overalls-host/base-source";
assert builtins.hasContext good.services.overallsSecrets.bundles.git.encryptedFile;
assert builtins.hasContext good.services.overallsSecrets.bundles.lilly.encryptedFile;
assert good.services.underclass.enable;
assert good.services.underclass.environmentFile == "/run/overalls-secrets/underclass/environment";
assert builtins.elem "overalls-secrets-underclass.service" good.systemd.services.underclass.requires;
assert good.services.underclass.egress.enable && good.services.underclass.egress.route
  && good.services.underclass.egress.exitNode == null;
assert good.services.overallsSecrets.bundles.underclass.outputs.environment.secrets
  == [ "UNDERCLASS_PROXY_KEY" "UNDERCLASS_UI_TOKEN" ];
assert !valid wrongIdentity;
assert !valid wrongSecret;
assert !valid tooLong;
assert !valid wrongGroup;
assert !valid wrongTransferPort;
assert good.services.lilly.hostId == host.lilly.binding.host_id;
assert good.services.lilly.credentialFile == "/run/overalls-secrets/lilly/credential.json";
assert builtins.elem "overalls-secrets-lilly.service" good.systemd.services.lilly.requires;
assert good.services.overallsSecrets.bundles.lilly.outputs."credential.json".secrets == [ "LILLY_CREDENTIAL" ];
assert builtins.elem "nested-kvm" good.nix.settings.extra-system-features;
assert good.services.tailscale.enable && good.systemd.services ? tailscaled;
# @cc [owner:ghuntley,label:verification;security] tailscale-auto-join-evaluation
# An enrolled host with the fleet-tailscale credential joins from the decrypted
# runtime key after its secret unit; without it no auth key or join unit exists.
assert good.services.tailscale.authKeyFile == "/run/overalls-secrets/tailscale/auth-key";
assert builtins.elem "overalls-secrets-tailscale.service" good.systemd.services.tailscaled-autoconnect.requires;
assert builtins.elem "overalls-secrets-tailscale.service" good.systemd.services.tailscaled-autoconnect.after;
assert good.services.overallsSecrets.bundles.tailscale.outputs.auth-key.secrets == [ "TAILSCALE_AUTH_KEY" ];
assert builtins.hasContext good.services.overallsSecrets.bundles.tailscale.encryptedFile;
assert noTailscale.services.tailscale.authKeyFile == null;
assert !(noTailscale.systemd.services ? tailscaled-autoconnect);
assert !(noTailscale.services.overallsSecrets.bundles ? tailscale);
# @cc [owner:ghuntley,label:verification;security] namespace-buck2-token-evaluation
# An enrolled host with the fleet-namespace credential publishes the Namespace
# token to root and wheel only, from its own boot-started secret unit; without
# the credential no bundle or unit exists (ADR-0276).
assert good.services.overallsSecrets.bundles.fleet-namespace.outputs.token.secrets == [ "NAMESPACE_RBE_TOKEN" ];
assert good.services.overallsSecrets.bundles.fleet-namespace.group == "wheel";
assert good.services.overallsSecrets.bundles.fleet-namespace.directory == "/run/overalls-secrets/fleet-namespace";
assert builtins.hasContext good.services.overallsSecrets.bundles.fleet-namespace.encryptedFile;
assert builtins.elem "multi-user.target" good.systemd.services.overalls-secrets-fleet-namespace.wantedBy;
assert !(noNamespace.services.overallsSecrets.bundles ? fleet-namespace);
assert !(noNamespace.systemd.services ? overalls-secrets-fleet-namespace);
pkgs.writeText "enrollment-configuration" "passed\n"
