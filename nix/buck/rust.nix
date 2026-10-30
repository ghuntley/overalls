{ pkgs }:
# @cc [owner:ghuntley,label:build;security] rust-cell-from-root-lock
# The Buck2 `rust` cell MUST be generated hermetically from the root
# Cargo.lock: crate sources come only from its importCargoLock vendor tree
# (no network, no second hash), and every third-party version the cell builds
# MUST be one the root lock resolved, which this derivation checks. The cell
# holds reindeer's BUCK, the copied vendored sources, the patched fs2 crate and
# workspace.bzl, the member table that buck/rust.bzl turns into first-party
# targets (ADR-0273, ADR-0267).
let
  inherit (pkgs) lib;
  rust = (import ../rust-toolchain.nix { inherit pkgs; }).toolchain;
  workspace = import ../domains/artifacts/infrastructure/cargo-workspace.nix { inherit pkgs; };
  root = ../..;
  # Every file whose existence makes Cargo discover a target (or that a
  # manifest names), as an empty stub: `cargo metadata` then reports each
  # member's real lib, bins, tests and build script, while the cell depends on
  # file names only, not on first-party sources.
  targetFiles = member:
    let
      dir = root + "/${member}";
      manifest = builtins.fromTOML (builtins.readFile (dir + "/Cargo.toml"));
      exists = rel: builtins.pathExists (dir + "/${rel}");
      entries = rel: if exists rel then builtins.readDir (dir + "/${rel}") else { };
      # Cargo's auto-discovery: <dir>/*.rs and <dir>/*/main.rs.
      discovered = rel: lib.concatLists (lib.mapAttrsToList (name: type:
        if type == "regular" && lib.hasSuffix ".rs" name then [ "${rel}/${name}" ]
        else if type == "directory" && exists "${rel}/${name}/main.rs" then [ "${rel}/${name}/main.rs" ]
        else [ ]) (entries rel));
      asList = value: if builtins.isList value then value else [ value ];
      declared = map (target: target.path) (builtins.filter (target: target ? path)
        (lib.concatMap (kind: asList (manifest.${kind} or [ ])) [ "lib" "bin" "test" "example" "bench" ]));
      build = manifest.package.build or null;
    in
    builtins.filter exists (lib.unique ([ "src/lib.rs" "src/main.rs" "build.rs" ]
      ++ discovered "src/bin" ++ discovered "tests" ++ discovered "examples" ++ discovered "benches"
      ++ declared ++ lib.optional (builtins.isString build) build));
  skeleton = pkgs.runCommand "overalls-rust-skeleton" { } ''
    mkdir -p "$out"
    cp ${workspace.lockFile} "$out/Cargo.lock"
    cp ${root + "/Cargo.toml"} "$out/Cargo.toml"
    mkdir -p "$out/lyra/vendor"
    cp -r ${root + "/lyra/vendor/fs2"} "$out/lyra/vendor/fs2"
    ${lib.concatMapStrings (member: ''
      mkdir -p "$out/${member}"
      cp ${root + "/${member}/Cargo.toml"} "$out/${member}/Cargo.toml"
      ${lib.concatMapStrings (rel: ''
        mkdir -p "$out/${member}/${builtins.dirOf rel}"
        : > "$out/${member}/${rel}"
      '') (targetFiles member)}
    '') workspace.members}
  '';
  vendored = pkgs.rustPlatform.importCargoLock { inherit (workspace) lockFile; };
  # Crates with build scripts default to running them (buildscript_run);
  # a committed nix/buck/rust/fixups/<crate>/fixups.toml overrides that.
  committedFixups = ./rust/fixups;
  hasCommittedFixups = builtins.pathExists committedFixups;
in
pkgs.runCommand "overalls-buck-rust-cell" {
  nativeBuildInputs = [ rust pkgs.reindeer pkgs.python3 ];
} ''
  export HOME="$TMPDIR"
  mkdir -p "$out/vendor" "$out/patches" "$out/.cargo"
  # Real copies: Buck2 reads sources inside the cell, not through links.
  for crate in ${vendored}/*; do
    cp -rL --no-preserve=mode "$crate" "$out/vendor/$(basename "$crate")"
  done
  cp -r --no-preserve=mode ${../../lyra/vendor/fs2} "$out/patches/fs2"
  printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "%s/vendor"\n' "$out" \
    > "$out/.cargo/config.toml"
  export CARGO_HOME="$out/.cargo"

  cp -r --no-preserve=mode ${skeleton} "$TMPDIR/workspace"
  cargo metadata --manifest-path "$TMPDIR/workspace/Cargo.toml" --format-version 1 \
    --locked --offline > "$TMPDIR/metadata.json"
  # reindeer's default platforms (its src/default_platforms.toml), which the
  # prelude maps to Buck2 constraints; first-party conditional deps use them too.
  python3 ${./rust_cell.py} platforms ${rust}/bin/rustc "$TMPDIR/platforms.json" \
    linux-x86_64=x86_64-unknown-linux-gnu linux-arm64=aarch64-unknown-linux-gnu \
    macos-x86_64=x86_64-apple-darwin macos-arm64=aarch64-apple-darwin \
    windows-msvc=x86_64-pc-windows-msvc windows-gnu=x86_64-pc-windows-gnu
  python3 ${./rust_cell.py} "$TMPDIR/metadata.json" "$TMPDIR/workspace/Cargo.toml" "$TMPDIR/platforms.json" "$out"

  # The pseudo-package's lock starts as the root lock; Cargo only prunes it.
  cp ${workspace.lockFile} "$out/Cargo.lock"
  chmod u+w "$out/Cargo.lock"
  (cd "$out" && cargo metadata --format-version 1 --offline > /dev/null)

  python3 ${./rust_cell.py} check-lock "$out/Cargo.lock" ${workspace.lockFile}

  cp ${./rust/reindeer.toml} "$out/reindeer.toml"
  mkdir -p "$out/fixups"
  ${lib.optionalString hasCommittedFixups ''cp -r --no-preserve=mode ${committedFixups}/. "$out/fixups/"''}
  (cd "$out" && cargo metadata --format-version 1 --locked --offline > "$TMPDIR/cell-metadata.json")
  python3 ${./rust_cell.py} default-fixups "$TMPDIR/cell-metadata.json" "$out/fixups" "$out/vendor"
  buckify() {
    (cd "$out" && reindeer --cargo-path ${rust}/bin/cargo --rustc-path ${rust}/bin/rustc buckify)
  }
  # The defaults cover every vendored crate, but reindeer refuses a fixup for
  # a crate no platform graph reaches ("matches no files", "unused buildscript
  # fixup"). Drop those generated defaults (never a committed fixup) and retry.
  if ! buckify 2> "$TMPDIR/reindeer.log"; then
    for name in $(sed -n 's#^ *fixups/\([^/]*\)/fixups.toml line [0-9]*: .*\(matches no files\|unused buildscript fixup\).*#\1#p' "$TMPDIR/reindeer.log" | sort -u); do
      ${lib.optionalString hasCommittedFixups ''[ -e "${committedFixups}/$name" ] && { echo "committed fixup for $name is unused" >&2; exit 1; }''}
      rm -r "$out/fixups/$name"
    done
    buckify
  fi
  rm -rf "$out/.cargo"
''
