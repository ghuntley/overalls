{ pkgs }:
# @cc [owner:ghuntley,label:build;security] cargo-workspace-source
# Every Nix build of a first-party Rust crate MUST compile against the single
# root Cargo workspace and its one Cargo.lock (ADR-0273), vendored with
# importCargoLock and no separate hash (ADR-0267). A build's source MUST hold
# the root manifest, lock and clippy.toml, every member manifest and the full
# sources of only the crates it compiles; other members get empty target stubs
# so Cargo can load the workspace and `--locked` sees the unchanged lock, while
# their source edits cannot change the build's inputs.
let
  inherit (pkgs) lib;
  rust = import ../../../rust-toolchain.nix { inherit pkgs; };
  vendor = import ./locked-cargo-vendor.nix { inherit pkgs; } {
    name = "overalls-cargo-vendor";
    inherit lockFile;
  };
  root = ../../../..;
  rootString = toString root;
  lockFile = root + "/Cargo.lock";
  workspace = (builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"))).workspace;
  members = workspace.members;

  # Path dependencies the root manifest patches in for every member.
  patches = [ "lyra/vendor/fs2" ];

  manifestOf = member: builtins.fromTOML (builtins.readFile (root + "/${member}/Cargo.toml"));

  # Files Cargo must find to load a member manifest: the default library root
  # plus every explicitly declared target path and build script.
  stubPaths = member:
    let
      manifest = manifestOf member;
      asList = value: if builtins.isList value then value else [ value ];
      declared = lib.concatMap (kind: asList (manifest.${kind} or [ ])) [ "lib" "bin" "test" "example" "bench" ];
      build = manifest.package.build or null;
    in
    lib.unique ([ "src/lib.rs" ]
      ++ map (target: target.path) (builtins.filter (target: target ? path) declared)
      ++ lib.optional (builtins.isString build) build);

  relative = path: lib.removePrefix (rootString + "/") (toString path);
  within = prefix: rel: rel == prefix || lib.hasPrefix (prefix + "/") rel;
  ancestorOf = rel: target: lib.hasPrefix (rel + "/") target;

  # Whether a repository-relative path is workspace scaffolding that every
  # consumer's source holds whatever crates it compiles: the root files, the
  # member manifests and their directories, and the patched path dependencies.
  # Callers that copy a repository subset for an in-guest build keep these.
  workspaceFile = rel:
    builtins.elem rel [ "Cargo.toml" "Cargo.lock" "clippy.toml" ]
    || lib.any (anchor: ancestorOf rel anchor) (patches ++ members)
    || lib.any (dir: within dir rel) patches
    || lib.any (member: rel == member || rel == "${member}/Cargo.toml") members;

  defaultCrateFile = name: lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "CONTRACTS" ];

  # name: store name of the source tree.
  # crates: workspace members whose full sources the build compiles; their
  #   first-party path dependencies MUST be listed too.
  # extraFiles: additional repository-relative files or directories to keep
  #   (fixtures, licences), included whole.
  # crateFile: predicate on a file's base name and repository-relative path
  #   selecting the files kept inside each listed crate.
  source = { name, crates, extraFiles ? [ ], crateFile ? (fileName: _rel: defaultCrateFile fileName) }:
    let
      unknown = builtins.filter (crate: !(builtins.elem crate members)) crates;
      kept = crates ++ patches ++ extraFiles;
      filtered = lib.cleanSourceWith {
        name = "${name}-filtered";
        src = root;
        filter = path: type:
          let
            rel = relative path;
            fileName = builtins.baseNameOf path;
          in
          fileName != "target" && fileName != ".hegel" && (
            workspaceFile rel
            || lib.any (anchor: ancestorOf rel anchor) kept
            || lib.any (dir: within dir rel) extraFiles
            || lib.any (crate: within crate rel && (type == "directory" || crateFile fileName rel)) crates
          );
      };
      stubs = lib.concatMap (member: map (path: "${member}/${path}") (stubPaths member))
        (builtins.filter (member: !(builtins.elem member crates)) members);
    in
    assert lib.assertMsg (unknown == [ ]) "cargo-workspace: not workspace members: ${toString unknown}";
    pkgs.runCommand name { } ''
      cp -r --no-preserve=mode ${filtered} "$out"
      ${lib.concatMapStringsSep "\n" (stub: ''
        mkdir -p "$out/${builtins.dirOf stub}"
        test -e "$out/${stub}" || : > "$out/${stub}"
      '') stubs}
    '';
in
{
  inherit lockFile members source workspaceFile;
  # @cc [owner:ghuntley,label:build] cargo-workspace-single-toolchain
  # Every first-party buildRustPackage MUST use these platforms and tools,
  # built from the one rust-overlay toolchain (nix/rust-toolchain.nix,
  # ADR-0273 decision 2), never nixpkgs' rustPlatform, clippy or rustfmt.
  rustPlatform = rust.rustPlatform // {
    # @cc [owner:ghuntley,label:build] cargo-workspace-declared-profile
    # A leaf MUST select its Cargo profile with buildRustPackage's `buildType`,
    # the attribute that takes effect. `cargoBuildType` is refused: nixpkgs
    # overwrites it from `buildType`, which is how T2 (a89cde0de) silently
    # built the declared-`hardened` helpers with `release` (ADR-0273).
    buildRustPackage = args:
      if args ? cargoBuildType then
        throw "${args.pname or "a Rust leaf"}: cargoBuildType is ignored by buildRustPackage; declare the profile with buildType"
      else rust.rustPlatform.buildRustPackage args;
  };
  # @cc [owner:ghuntley,label:build;security] cargo-workspace-static-musl
  # buildStaticMusl MUST produce x86_64 musl executables that link only
  # rustc's self-contained musl CRT through rust-lld (no Nix libc and no store
  # reference), with the Cargo profile `buildType` declares; with `check` it also
  # runs the crate's host tests, rustfmt and clippy -D warnings. nixpkgs'
  # pkgsStatic Rust cannot take this toolchain: its build scripts crashed.
  buildStaticMusl = { pname, crate, binaries, buildType, features ? [ ], check ? false, meta ? { } }:
    let
      package = (manifestOf crate).package.name;
      selection = "-p ${package}" + lib.optionalString (features != [ ]) " --features ${lib.concatStringsSep "," features}";
    in
    pkgs.stdenv.mkDerivation {
      inherit pname meta;
      version = "0.1.0";
      src = source { name = "${pname}-source"; crates = [ crate ]; };
      strictDeps = true;
      nativeBuildInputs = [ rust.toolchain ];
      dontConfigure = true;
      dontStrip = true;
      allowedReferences = [ ];
      buildPhase = ''
        runHook preBuild
        export CARGO_HOME="$TMPDIR/cargo-home" CARGO_TARGET_DIR="$TMPDIR/target"
        mkdir -p "$CARGO_HOME"
        substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-Clinker-flavor=ld.lld --remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
        cargo build --offline --locked --profile ${buildType} --target x86_64-unknown-linux-musl ${selection}
        runHook postBuild
      '';
      doCheck = check;
      checkPhase = ''
        runHook preCheck
        cargo test --offline --locked ${selection}
        cargo fmt --check -p ${package}
        cargo clippy --offline --locked --all-targets ${selection} -- -D warnings
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        ${lib.concatMapStringsSep "\n" (binary: ''install -Dm755 "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/${buildType}/${binary}" "$out/bin/${binary}"'') binaries}
        runHook postInstall
      '';
    };
  # clippy-driver, cargo-clippy and rustfmt of the same release, for postCheck.
  rustTools = rust.toolchain;
  # buildRustPackage attribute: the one vendored dependency set.
  cargoLock = { inherit lockFile; };
  # fetchCargoVendor layout (`@vendor@` placeholder) for hand-written builds.
  inherit vendor;
  # SHA-256 of the root lock, for build manifests that record their inputs.
  lockSha256 = builtins.hashFile "sha256" lockFile;
}
