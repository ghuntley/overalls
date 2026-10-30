{ pkgs, toolchain }:
# @cc [owner:ghuntley,label:build] buck-cells-from-pins
# Buck2's prelude and every toolchain path MUST come from this derivation,
# built only from flake.lock-pinned nixpkgs and the dependency registry, so
# store paths enter action keys through configuration and nothing resolves
# from PATH (ADR-0269).
let
  inherit (pkgs) lib;
  tools = {
    bash = "${pkgs.bash}/bin/bash";
    coreutils = "${pkgs.coreutils}/bin";
    python = "${pkgs.python3}/bin/python3";
    nix = "${pkgs.nix}/bin/nix";
    nix_store = "${pkgs.nix}/bin/nix-store";
    jq = "${pkgs.jq}/bin/jq";
    erlang = "${toolchain.erlang}";
    elixir = "${toolchain.elixir}";
    cc = "${pkgs.stdenv.cc}/bin/cc";
    cxx = "${pkgs.stdenv.cc}/bin/c++";
    ar = "${pkgs.stdenv.cc.bintools.bintools}/bin/ar";
    ld = "${pkgs.stdenv.cc}/bin/cc";
    rustc = "${pkgs.rustc}/bin/rustc";
    rustdoc = "${pkgs.rustc}/bin/rustdoc";
    clippy = "${pkgs.clippy}/bin/clippy-driver";
    rustfmt = "${pkgs.rustfmt}/bin/rustfmt";
  };
  buckconfig = pkgs.writeText "toolchains.buckconfig" (''
    [nix]
  '' + lib.concatStrings (lib.mapAttrsToList (name: path: "  ${name} = ${path}\n") tools));
in
pkgs.runCommand "overalls-buck-cells" { } ''
  mkdir -p "$out/prelude" "$out/bin"
  ln -s ${pkgs.buck2}/bin/buck2 "$out/bin/buck2"
  tar -xzf ${pkgs.buck2.prelude} -C "$out/prelude" --strip-components=1
  cp ${buckconfig} "$out/toolchains.buckconfig"
''
