# @cc [owner:ghuntley,label:build;security] fetch-pin-registry
# Every dependency-hashes.json key that no `mix` or `cargo` entry of
# lib.dependencyPins refreshes MUST belong to exactly one entry here
# (ADR-0267). An entry names the files that declare its fetches (`locks`; also
# flake.lock when the fetcher's output depends on the pinned nixpkgs tools, as
# Go, Cargo, npm and Mix vendors and built fixed outputs do), its registry
# `keys`, and a `closure` derivation that the real consumer builds and whose
# derivation closure contains every fetch of those keys. Closures use the
# consumer's own package set, so a refreshed vendor hash matches the build
# that reads it. scripts/fetch_pins.exs fakes the keys, finds their
# fixed-output derivations in the closure, records the hashes Nix reports and
# builds those fetches again; it never builds the closure itself.
{ pkgs, nixpkgs, packages, checks }:
let
  testPkgs = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  artifacts = "nix/domains/artifacts";
  closureOf = name: drvs: pkgs.linkFarmFromDrvs "${name}-fetch-pins" drvs;
in
{
  toolchain = {
    locks = [ "${artifacts}/infrastructure/toolchain.nix" ];
    keys = [ "otpSource" "elixirSource" ];
    closure = packages.toolchain.elixir;
  };
  lyra-macos-sdk = {
    locks = [ "${artifacts}/infrastructure/lyra.nix" ];
    keys = [ "macosSdk113" ];
    closure = packages.lyra.macosSdk;
  };
  vscode-web = {
    locks = [ "${artifacts}/vscode-web/inputs.nix" "flake.lock" ];
    keys = [ "vscodeSource" "vscodeNpm" "vscodeNodeSource" "vscodeElectronTypes" ];
    closure = packages.vscodeWeb;
  };
  windows-editor = {
    locks = [
      "${artifacts}/vscode-web/inputs.nix"
      "${artifacts}/vscode-web/windows-runtime.nix"
      "${artifacts}/vscode-web/windows-source.nix"
    ];
    keys = [ "nodeWindowsX64" "ripgrepWindowsX64" "nodeHeaders" "nodeWindowsX64Library" "pythonEmbedWindowsX64" ];
    closure = packages.windowsEditorSource;
  };
  github-tools = {
    locks = [ "${artifacts}/guest/github/default.nix" "flake.lock" ];
    keys = [ "ghSource" "ghVendor" "gitLfsSource" "gitLfsVendor" ];
    closure = packages.githubTools.release;
  };
  smtprelay = {
    locks = [ "${artifacts}/smtprelay/default.nix" "flake.lock" ];
    keys = [ "smtprelaySource" "smtprelayVendor" ];
    closure = packages.smtprelay;
  };
  underclass = {
    locks = [ "${artifacts}/underclass/default.nix" "flake.lock" ];
    keys = [ "underclassSource" "underclassCargo" ];
    closure = packages.underclass;
  };
  # An evaluation-time builtins.fetchTarball: evaluating the closure fetches it.
  coding-clis = {
    locks = [ "${artifacts}/guest/coding-clis.nix" ];
    keys = [ "codingClisNixpkgs" ];
    closure = closureOf "coding-clis" packages.codingClis.packages;
  };
  native-images = {
    locks = [ "${artifacts}/guest/native.nix" ];
    keys = [ "freebsdCloudImage" "omniosCloudImage" ];
    closure = closureOf "native-images" [ packages.nativeGuests.mkFreeBSDSource packages.nativeGuests.mkOmniOSSource ];
  };
  # The runtime tree's recursive hash covers the package table it extracts.
  native-git = {
    locks = [ "${artifacts}/guest/native-git.nix" "${artifacts}/guest/native_git/illumos-packages.json" "flake.lock" ];
    keys = [ "illumosGitRuntime" ];
    closure = (import ./guest/native-git.nix { inherit pkgs; }).illumos;
  };
  native-kernels = {
    locks = [
      "${artifacts}/guest/native-kernels/default.nix"
      "${artifacts}/guest/native-kernels/illumos/sdk.nix"
      "flake.lock"
    ];
    keys = [ "freebsdKernelSource" "illumosKernelSource" "omniosBuildSource" "illumosLinkerSysroot" ];
    closure = closureOf "native-kernels" (with packages.nativeKernels; [
      freebsdSource illumosSource omniosBuildSource illumosToolchain.sysroot
    ]);
  };
  arch = {
    locks = [ "${artifacts}/guest/arch/default.nix" ];
    keys = [ "archLinuxBootstrap" ];
    closure = packages.archGuest;
  };
  alma = {
    locks = [ "${artifacts}/guest/alma/default.nix" ];
    keys = [ "almaLinuxCloudImage" ];
    closure = packages.almaGuest;
  };
  letsencrypt-staging-roots = {
    locks = [ "fleet/letsencrypt-staging-roots.nix" ];
    keys = [ "letsencryptStagingRootX1" "letsencryptStagingRootX2" "letsencryptStagingRootYE" "letsencryptStagingRootYR" ];
    closure = import ../../../fleet/letsencrypt-staging-roots.nix { inherit pkgs; };
  };
  antithesis-wheels = {
    locks = [ "antithesis/nix/python-wheels.nix" ];
    keys = [ "antithesisWheelAntithesis" "antithesisWheelPsycopg" "antithesisWheelPsycopgBinary" "antithesisWheelWebsockets" ];
    closure = import ../../../antithesis/nix/python-wheels.nix { inherit pkgs; };
  };
  buck2-no-nix = {
    locks = [ "tools/buck2-no-nix.json" "nix/buck/no-nix.nix" ];
    keys = [ "buck2LinuxBinary" "buck2WindowsBinary" "buck2Prelude" ];
    closure = let kits = import ../../buck/no-nix.nix { inherit pkgs; inherit (pkgs) buck2; };
      in closureOf "buck2-no-nix" [ kits.linux kits.windows ];
  };
  libhegel = {
    locks = [ "nix/verification/hegel/libhegel.nix" "flake.lock" ];
    keys = [ "libhegelSource" "libhegelCargo" ];
    closure = import ../../verification/hegel/libhegel.nix { pkgs = testPkgs; };
  };
  elixir-ls-test = {
    locks = [ "nix/verification/tests/machines/vscode-web/offline-elixir-ls.nix" "flake.lock" ];
    keys = [ "elixirLsSource" "elixirLsMixDeps" ];
    closure = checks.vscode-web-package;
  };
  localization-test = {
    locks = [ "nix/verification/tests/machines/localization/default.nix" ];
    keys = [ "bombadilBinary" "bombadilTypes" ];
    closure = checks.localization-account-porsche;
  };
  host-conversion-test = {
    locks = [ "nix/verification/tests/machines/host-conversion/default.nix" ];
    keys = [ "ubuntuNobleCloudImage" ];
    closure = checks.host-conversion;
  };
}
