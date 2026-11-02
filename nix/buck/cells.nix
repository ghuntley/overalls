{ pkgs, toolchain ? null, artifacts ? null, buck2 ? pkgs.buck2, fixture ? null }:
# @cc [owner:ghuntley,label:build] buck-cells-from-pins
# Buck2's prelude and every toolchain path MUST come from this derivation,
# built only from flake.lock-pinned nixpkgs and the dependency registry, so
# store paths enter action keys through configuration and nothing resolves
# from PATH (ADR-0269).
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  # Only x86_64-linux builds hermetic targets. Elsewhere (aarch64-darwin, for
  # the Mila Apple builds on macOS runners) the cells carry buck2, the
  # prelude and the few tools the non_hermetic rules run; every other tool is
  # a stub that fails when run, and the rust// cell is empty (ADR-0269 M9).
  hermeticHost = system == "x86_64-linux";
  hostTools = [ "bash" "coreutils" "python" "git" "jq" ];
  unavailable = pkgs.writeShellScript "overalls-buck-unavailable" ''
    echo "this tool is not in buckCells.${system}; build hermetic targets on x86_64-linux" >&2
    exit 1
  '';
  noNix = import ./no-nix.nix { inherit pkgs buck2; };
  # The pinned Namespace CLI (ADR-0276), as a derivation only: tools/buck2
  # realises it where no nsc is on PATH, to resolve the cache endpoints. It
  # stays out of cells_id and of the worker image, which leaves out .drv files.
  nscDrv = builtins.unsafeDiscardOutputDependency (import ./nsc.nix { inherit pkgs; }).drvPath;
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
  pinnedInputs = {
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
  # `fixture` is for offline machine-test repositories only (ADR-0271):
  # { tools = { <name> = <path>; }; stub = <store path>; }. Named tools keep
  # their paths; every other tool and pinned input becomes `stub`, and the
  # rust// cell is empty (fixtures load no Rust targets), so the cells closure
  # stays small and nothing outside it is realised.
  inputs = if fixture != null then lib.mapAttrs (_: lib.mapAttrs (_: _: fixture.stub)) pinnedInputs
    else if hermeticHost then pinnedInputs
    else lib.mapAttrs (_: lib.mapAttrs (_: _: "${unavailable}")) pinnedInputs;
  allTools = lib.foldl' (acc: group: acc // group) {
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
    # Cargo-driven builds outside the prelude rules (the Mila Windows FFI
    # cross-build, M9): the rust// cell's vendored root-lock crates, and
    # cargo-zigbuild with zig as the windows-gnu linker.
    rust_bin = "${rust}/bin";
    rust_vendor = "${rustCell}/vendor";
    cargo_zigbuild = "${pkgs.cargo-zigbuild}/bin";
    cc_bin = "${pkgs.stdenv.cc}/bin";
    zig = "${pkgs.zig}/bin";
    # tools/buck2 --no-nix kits (M9): their derivations only, so the cells
    # never fetch them; //tools:buck2-no-nix-<os> realises one on demand.
    buck2_no_nix_windows = builtins.unsafeDiscardOutputDependency noNix.windows.drvPath;
    buck2_no_nix_linux = builtins.unsafeDiscardOutputDependency noNix.linux.drvPath;
    # Lyra's cross builds (buck/lyra.bzl, M5): the derivation of their tools
    # and SDKs only, realised by the action, so the cells never fetch them.
    lyra_build_inputs = builtins.unsafeDiscardOutputDependency
      (import ../domains/artifacts/infrastructure/lyra.nix { inherit pkgs; }).buckInputs.drvPath;
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
    # terminald's PTY tests start the user's login shell. Buck2 runs tests
    # outside the build sandbox, where bash would read the host's
    # /etc/profile; this one skips it, as the sandbox's absent file does.
    test_login_shell = "${pkgs.writeShellScript "overalls-test-login-shell" ''
      exec ${pkgs.bash}/bin/bash --noprofile --norc "$@"
    ''}";
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
    bwrap = "${pkgs.bubblewrap}/bin/bwrap";
  } (lib.attrValues inputs);
  tools = if fixture != null then lib.mapAttrs (name: _: fixture.tools.${name} or fixture.stub) allTools
    else if hermeticHost then allTools
    else lib.mapAttrs (name: path: if lib.elem name hostTools then path else "${unavailable}") allTools;
  rustCellPath = if fixture == null && hermeticHost then rustCell else pkgs.emptyDirectory;
  toolLines = lib.concatStrings (lib.mapAttrsToList (name: path: "  ${name} = ${path}\n") tools);
  # The identity of this cells closure for remote execution (ADR-0276):
  # every store path an action can name, so a worker image recorded for the
  # same id holds the same toolchains. Actions carry it as overalls-cells.
  cellsId = builtins.hashString "sha256" (toolLines + "rust = ${rustCellPath}\nbuck2 = ${buck2}\n");
  # The [mix] section needs the package set; fixtures (ADR-0271) load no Mix
  # targets and omit it, as do the macOS host-tool cells. Mix actions run
  # locally only, so cells_id leaves the section out.
  withMix = artifacts != null && fixture == null && hermeticHost;
  mixState = import ./mix.nix { inherit pkgs artifacts; };
  # @cc [owner:ghuntley,label:build] mix-cells-from-pins
  # Mix rules MUST read their dependency sets, OTP variants and runtime paths
  # from this section only: the prod fixed-output fetches that the Nix releases
  # use, the test fetches, both OTP builds' mixRelease shell state and the
  # store paths the releases record (ADR-0269).
  mixProjects = [ "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" "peach" "susan" ];
  mix = {
    state_plain = "${mixState.plain}/state.sh";
    state_encrypted = "${mixState.encrypted}/state.sh";
    elixir_version = toolchain.elixir.version;
    otp_version = toolchain.erlang.version;
    erlang_encrypted = "${artifacts.encrypted.toolchain.erlang}";
    crash_dump_public_key = "${../domains/artifacts/build-crash-dump-public.pem}";
    cedar_vendor = "${artifacts.cargoWorkspace.vendor}";
    cedar_source = "${artifacts.cedarSource}";
    esbuild = lib.getExe pkgs.esbuild;
    esbuild_version = pkgs.esbuild.version;
    hegel_nif = "${artifacts.hegelNif}/lib/hegel_nif.so";
    postgres = "${pkgs.postgresql}/bin";
    # Tools the suites run that devenv takes from the developer's PATH.
    test_tools = "${pkgs.buildEnv { name = "overalls-mix-test-tools"; paths = [ pkgs.openssl.bin pkgs.openssh pkgs.python3 ]; }}/bin";
    git = "${pkgs.git}/bin";
    # The OS trust store that the release probe and the suites expect at
    # /etc/ssl (:public_key.cacerts_get).
    ca_bundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    # Lilly's release metadata and host-tools link only.
    host_tools = "${artifacts.hostTools}";
    # The host tools minus the Rust helpers, which Mix suites take from
    # //lilly:host-helpers (test_path_deps).
    host_system_tools = "${artifacts.hostSystemTools}/bin";
    vmm = "${artifacts.vmm}";
    util_linux_bin = "${pkgs.util-linux.bin}";
  } // lib.listToAttrs (map (app: lib.nameValuePair "deps_${app}_prod" "${artifacts.dependencies.${app}}") mixProjects)
    // lib.mapAttrs' (project: deps: lib.nameValuePair "deps_${project}_test" "${deps}") artifacts.testDependencies;
  # Every store path a release may reference at runtime: both OTP builds and
  # their libraries, the release wrapper's runtime PATH, Marshall's esbuild
  # and Lilly's host tools. The Cargo vendor is a build input only, so it is
  # absent. mix_release fails on a reference outside this closure; assembly
  # keeps only what it finds (RuntimeRefsInfo).
  runtimeClosure = pkgs.closureInfo {
    rootPaths = [
      toolchain.erlang artifacts.encrypted.toolchain.erlang pkgs.bash pkgs.coreutils pkgs.gnused
      pkgs.gnugrep pkgs.gawk pkgs.esbuild artifacts.hostTools artifacts.vmm
      pkgs.util-linux.bin
    ];
  };
  buckconfig = pkgs.writeText "toolchains.buckconfig" (''
    [nix]
  '' + toolLines + "  cells_id = ${cellsId}\n" + lib.optionalString withMix (''
    [mix]
  '' + lib.concatStrings (lib.mapAttrsToList (name: value: "  ${name} = ${value}\n") mix)));
in
# A symlink farm: build it locally rather than through a remote builder
# (a wedged relay once held every checkout's cells rebuild).
pkgs.runCommandLocal "overalls-buck-cells" { } (''
  mkdir -p "$out/prelude" "$out/bin"
  ${lib.concatStrings (lib.mapAttrsToList (cell: group: lib.concatStrings (lib.mapAttrsToList (name: path: ''
    mkdir -p "$out/${cell}"
    ln -s ${path} "$out/${cell}/${name}"
  '') group)) inputs)}
  ln -s ${buck2}/bin/buck2 "$out/bin/buck2"
  ln -s ${rustCellPath} "$out/rust"
  tar -xzf ${buck2.prelude} -C "$out/prelude" --strip-components=1
  cp ${buckconfig} "$out/toolchains.buckconfig"
'' + lib.optionalString (fixture == null && hermeticHost) ''
  echo ${nscDrv} > "$out/nsc.drv"
'' + lib.optionalString withMix ''
  # [mix] is the last section, so the closure computed at build time joins it.
  chmod u+w "$out/toolchains.buckconfig"
  printf '  runtime_refs = %s\n' "$(tr '\n' ' ' < ${runtimeClosure}/store-paths)" >> "$out/toolchains.buckconfig"
'')
