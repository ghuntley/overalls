{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  keys = builtins.fromJSON (builtins.readFile ./builder-public-keys.json);
  roster = import ../nix/policy/fleet/hosts.nix { inherit lib; };
  ports = import ../nix/policy/fleet/ports.nix { };
  # Builders are reached over Tailscale on administrative SSH, so no public
  # address is evaluated; CPU counts are the roster's measured observations.
  endpoints = lib.mapAttrs (_: host: {
    address = host.tailnetAddress;
    port = ports.adminSsh;
    inherit (host.builder) logicalCpus;
  }) (lib.filterAttrs (_: host: host.builder != null) roster.hosts);
in
# @cc [owner:ghuntley,label:security] fleet-builder-authority
# Host pins and encrypted document paths MUST derive from authoritative host
# inventory; CPU slots MUST reflect authenticated physical CPU observations.
# A host awaiting its installed identity (a base declaration) is not a builder.
lib.mapAttrs (name: endpoint: endpoint // {
  systems = [ "${inventory.${name}.inventory.arch}-linux" ];
  supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" "nested-kvm" ];
  clientPublicKeys = [ keys.${name} ];
  hostPublicKey = builtins.head inventory.${name}.identity.sshKeys;
  encryptedFile = let
    document = lib.findFirst (item: item.name == "${name}-remote-builders")
      (throw "Missing remote builder credential") inventory.${name}.credentials;
    path = ../. + ("/" + document.path);
  in assert lib.assertMsg (builtins.pathExists path) "Missing remote builder ciphertext"; "${path}";
}) (lib.filterAttrs (name: _: inventory.${name}.identity.sshKeys != []) endpoints)
