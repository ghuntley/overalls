{ pkgs, toolchain }:
# @cc [owner:ghuntley,label:build] buck-cells-from-pins
# Buck2's prelude and every toolchain path MUST come from this derivation,
# built only from flake.lock-pinned nixpkgs and the dependency registry, so
# store paths enter action keys through configuration and nothing resolves
# from PATH (ADR-0269).
let
  inherit (pkgs) lib;
  python = import ./python.nix { inherit pkgs; };
  # The one Rust toolchain (ADR-0273), shared with the Nix builds and devenv.
  rust = (import ../rust-toolchain.nix { inherit pkgs; }).toolchain;
  # The reindeer third-party cell (rust//), generated from the root Cargo.lock.
  rustCell = import ./rust.nix { inherit pkgs; };
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
      # The pinned cc-check behind the repository contract check (M8).
      code_contracts_node_modules = "${nodeModules "code-contracts" ../../tools/code-contracts}/node_modules";
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
    # The single Rust toolchain root (rustc, rustdoc, clippy-driver, rustfmt,
    # cargo) and the binutils its links and archives use (M5).
    rust = "${rust}";
    bintools = "${pkgs.stdenv.cc.bintools.bintools}/bin";
    # The cc wrapper with an empty environment: it reads NIX_LDFLAGS and
    # friends, so a Buck2 daemon started in a dev shell would otherwise link
    # that shell's rpaths into every binary.
    cc_hermetic = "${pkgs.writeShellScript "overalls-buck-cc" ''
      exec ${pkgs.coreutils}/bin/env -i PATH=${pkgs.coreutils}/bin ${pkgs.stdenv.cc}/bin/cc "$@"
    ''}";
    # Libraries every Buck2-linked Rust binary records in its rpath (the cc
    # wrapper's glibc and libgcc_s); imports declare them as runtime refs.
    glibc_lib = "${lib.getLib pkgs.stdenv.cc.libc}/lib";
    gcc_lib = "${lib.getLib pkgs.stdenv.cc.cc}/lib";
    # Session fixture utility for enrico git-owner's tests.
    setsid = "${pkgs.util-linux}/bin/setsid";
    # Native libraries first-party crates link (overalls_rust_crate native_libs),
    # the same packages their Nix builds take as buildInputs.
    zfs_lib = "${lib.getLib pkgs.zfs}/lib";
    netfilter_conntrack_lib = "${lib.getLib pkgs.libnetfilter_conntrack}/lib";
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
    # M8: repository checks that list files with git ls-files.
    git = "${pkgs.git}/bin";
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
  ln -s ${rustCell} "$out/rust"
  tar -xzf ${pkgs.buck2.prelude} -C "$out/prelude" --strip-components=1
  cp ${buckconfig} "$out/toolchains.buckconfig"
''
