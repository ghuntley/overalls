{ nixCompact ? import ../artifacts/nix-compact/source.nix }:
{ lib, ... }:
let
  standalone = nixCompact;
in {
  imports = [ standalone.nixosModules.default ];
  # @cc [owner:ghuntley,label:build] compact-native-nix-selection
  # Hosts MUST enable the public `programs.nix-compact` module by default and,
  # without an explicit nix.package override, MUST select the source-patched
  # package the pinned nix-compact flake builds from its own Nixpkgs input
  # (the module default): the stable input does not ship its Nix 2.36.0.
  # Disabling `programs.nix-compact` or explicitly choosing a package MUST
  # retain ordinary NixOS precedence.
  config = {
    programs.nix-compact.enable = lib.mkDefault true;
  };
}
