{ pkgs }:
let
  inherit (pkgs) lib;
  cleanPythonSource = src: lib.cleanSourceWith {
    inherit src;
    filter = path: type: !(type == "directory" && baseNameOf path == "__pycache__")
      && !(lib.hasSuffix ".pyc" path);
  };
  sdkHelpers = cleanPythonSource ./illumos_sdk;
  freebsdPackages = builtins.fromJSON (builtins.readFile ./native_git/freebsd-packages.json);
  illumosPackages = builtins.fromJSON (builtins.readFile ./native_git/illumos-packages.json);
  freebsdSources = map (package: pkgs.fetchurl {
    name = "${package.name}-${package.version}.pkg";
    inherit (package) url sha256;
  }) freebsdPackages;
  illumosManifests = map (package: pkgs.fetchurl {
    name = "omnios-git-${lib.replaceStrings [ "/" ] [ "-" ] package.name}.p5m";
    inherit (package) url sha256;
  }) illumosPackages;
  # @cc [owner:ghuntley,label:build;security] freebsd-git-compatible-package-pins
  # Git and its complete non-base dependency graph MUST come from the retained
  # official 14.3 release repository, with exact archive SHA-256 pins. Packages
  # built for a newer FreeBSD release MUST refuse; extraction never runs scripts.
  freebsd = pkgs.runCommand "overalls-freebsd-14.3-git-runtime" {
    nativeBuildInputs = [ pkgs.python313 pkgs.zstd pkgs.binutils ];
    passthru = { packages = freebsdPackages; gitPath = "/usr/local/bin/git"; };
  } ''
    mkdir packages
    ${lib.concatStringsSep "\n" (lib.zipListsWith (package: source:
      "ln -s ${source} packages/${package.name}.pkg") freebsdPackages freebsdSources)}
    python3.13 ${./native_git/extract_freebsd.py} "$out" ${./native_git/freebsd-packages.json} packages
    python3.13 ${./native_git/verify_runtime.py} freebsd "$out"
  '';
  # @cc [owner:ghuntley,label:build;security] illumos-git-official-runtime-pins
  # OmniOS runtime payloads MUST use exact official r151050 IPS manifest pins,
  # verify every compressed/plain payload and the complete output NAR hash, and
  # preserve /etc/ssl/cacert.pem. Image assembly MUST use this payload offline.
  illumos = pkgs.runCommand "overalls-omnios-r151050-git-runtime" {
    nativeBuildInputs = [ pkgs.python313 pkgs.binutils ];
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = (import ../pins.nix).illumosGitRuntime;
    passthru = { packages = illumosPackages; gitPath = "/usr/bin/git"; };
  } ''
    cp -r ${sdkHelpers} illumos_sdk
    python3.13 -m illumos_sdk.fetch_git "$out" ${lib.escapeShellArgs (map toString illumosManifests)}
    python3.13 ${./native_git/verify_runtime.py} illumos "$out"
  '';
  tests = pkgs.runCommand "overalls-native-git-static-tests" {
    nativeBuildInputs = [ pkgs.python313 pkgs.zstd pkgs.binutils ];
  } ''
    cp -r ${cleanPythonSource ./native_git} native_git
    cp -r ${sdkHelpers} illumos_sdk
    python3.13 -m unittest native_git.test_extract_freebsd native_git.test_verify_runtime illumos_sdk.test_fetch_sdk
    cp -r ${freebsd} freebsd
    cp -r ${illumos} illumos
    chmod -R u+w freebsd illumos
    python3.13 -m native_git.verify_runtime freebsd "$PWD/freebsd"
    python3.13 -m native_git.verify_runtime illumos "$PWD/illumos"
    touch "$out"
  '';
in
{ inherit freebsd illumos tests; }
