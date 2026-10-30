{ pkgs, toolchain }:
# @cc [owner:ghuntley,label:build] buck-cells-from-pins
# Buck2's prelude and every toolchain path MUST come from this derivation,
# built only from flake.lock-pinned nixpkgs and the dependency registry, so
# store paths enter action keys through configuration and nothing resolves
# from PATH (ADR-0269).
let
  inherit (pkgs) lib;
  python = import ./python.nix { inherit pkgs; };
  githubTools = import ../domains/artifacts/guest/github { inherit pkgs; };
  # Third-party npm trees from each committed package-lock.json (importNpmLock);
  # Buck2 npm_package actions link them as node_modules.
  nodeModules = name: root: pkgs.importNpmLock.buildNodeModules {
    package = lib.importJSON (root + "/package.json");
    packageLock = lib.importJSON (root + "/package-lock.json");
    nodejs = pkgs.nodejs;
    derivationArgs = { pname = "overalls-${name}-node-modules"; npmFlags = [ "--ignore-scripts" ]; };
  };
  # Pinned third-party inputs, grouped as the plan's go/, npm/ and python/
  # cells. Each is also a [nix] entry so its store path enters action keys.
  inputs = {
    go = {
      gh_source = "${githubTools.gh.linux-amd64.src}";
      gh_vendor = "${githubTools.gh.linux-amd64.goModules}";
      git_lfs_source = "${githubTools.lfs.linux-amd64.src}";
      git_lfs_modules = "${githubTools.lfs.linux-amd64.goModules}";
    };
    npm = {
      marvin_node_modules = "${nodeModules "marvin" ../../marvin}/node_modules";
    };
    python = {
      python_static = "${python.tyPython}/bin/python3";
      python_harness = "${python.harnessPython}/bin/python3";
      antithesis_wheels = "${python.antithesisWheels}";
    };
  };
  tools = lib.foldl' (acc: group: acc // group) {
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
    # M7: Go, JavaScript, Python and script checks.
    go = "${pkgs.go_1_27}";
    patch = "${pkgs.gnupatch}/bin/patch";
    # stdenv's fixup strip (`strip -S -p`), which Nix Go builds go through.
    strip = "${pkgs.stdenv.cc.bintools}/bin/strip";
    node = "${pkgs.nodejs}/bin";
    esbuild = "${pkgs.esbuild}/bin/esbuild";
    ruff = "${python.ruff}/bin/ruff";
    ty = "${python.ty}/bin/ty";
    findutils = "${pkgs.findutils}/bin";
    gnugrep = "${pkgs.gnugrep}/bin";
    gnused = "${pkgs.gnused}/bin";
    pwsh = "${pkgs.powershell}/bin/pwsh";
    chromium = "${lib.getExe pkgs.chromium}";
    unzip = "${pkgs.unzip}/bin";
    fonts_conf = "${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}";
  } (lib.attrValues inputs);
  buckconfig = pkgs.writeText "toolchains.buckconfig" (''
    [nix]
  '' + lib.concatStrings (lib.mapAttrsToList (name: path: "  ${name} = ${path}\n") tools));
in
pkgs.runCommand "overalls-buck-cells" { } ''
  mkdir -p "$out/prelude" "$out/bin"
  ${lib.concatStrings (lib.mapAttrsToList (cell: group: lib.concatStrings (lib.mapAttrsToList (name: path: ''
    mkdir -p "$out/${cell}"
    ln -s ${path} "$out/${cell}/${name}"
  '') group)) inputs)}
  ln -s ${pkgs.buck2}/bin/buck2 "$out/bin/buck2"
  tar -xzf ${pkgs.buck2.prelude} -C "$out/prelude" --strip-components=1
  cp ${buckconfig} "$out/toolchains.buckconfig"
''
