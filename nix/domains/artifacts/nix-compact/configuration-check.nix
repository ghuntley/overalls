{ nixpkgs, nixCompact ? import ./source.nix }:
let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ (import ../../system/nix-compact.nix { inherit nixCompact; }) extra ];
  }).config;
  enabled = evaluate {};
  disabled = evaluate { programs.nix-compact.enable = false; };
  override = evaluate { nix.package = pkgs.nix; };
  # The flake's package, built from nix-compact's own Nixpkgs input.
  patched = nixCompact.packages.${system}.default;
  upstream = nixCompact.inputs.nixpkgs.legacyPackages.${system}.nixVersions.nix_2_36;
  checks = {
    nativePackageSelected = enabled.nix.package.outPath == patched.outPath;
    cliActuallyPatched = patched.nix-cli.outPath != upstream.nix-cli.outPath;
    daemonLibrariesUnchanged = patched.libs.nix-store.outPath == upstream.libs.nix-store.outPath;
    canDisable = disabled.nix.package.outPath == pkgs.nix.outPath;
    explicitPackageWins = override.nix.package.outPath == pkgs.nix.outPath;
    enabledByDefault = enabled.programs.nix-compact.enable;
  };
in
assert builtins.all (result: result) (builtins.attrValues checks);
pkgs.runCommand "nix-compact-configuration-check" {
  result = builtins.toJSON checks;
} ''
  printf '%s\n' "$result" > $out
''
