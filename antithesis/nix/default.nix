{ pkgs, nixpkgs, packageSet }:
import ./images.nix { inherit pkgs nixpkgs packageSet; }
