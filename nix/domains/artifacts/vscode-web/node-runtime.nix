{ pkgs }:
let
  inputs = import ./inputs.nix;
  recipe = pkgs.path + "/pkgs/development/web/nodejs";
  buildNode = pkgs.callPackage (recipe + "/nodejs.nix") { };
  # @cc [owner:ghuntley,label:build] editor-exact-node-source
  # The editor and its maintenance command MUST use the reviewed Node version
  # and source hash with the supplied pinned Nixpkgs builder and patch stack.
  # The runtime MUST include the matching npm and corepack outputs.
  slim = buildNode {
    version = inputs.nodeVersion;
    sha256 = inputs.nodeSourceHash;
    patches = pkgs.nodejs-slim_24.patches;
  };
in
pkgs.callPackage (recipe + "/symlink.nix") { nodejs-slim = slim; }
