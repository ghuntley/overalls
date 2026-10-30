# Native Windows source bundle (ADR-0235). Deliberately excludes the retained
# legacy application, package sources and package cache; Windows builds the WinUI
# host and Rust FFI directly.
{ pkgs, root, version }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
  milaRust = builtins.filter (pkgs.lib.hasPrefix "mila/rust/") workspace.members;
  # The root Cargo workspace (ADR-0273): its manifest, single lock and the
  # member stubs Cargo needs to load it, with full sources for the Mila Rust crates.
  cargoWorkspace = workspace.source {
    name = "mila-bundle-cargo-workspace";
    crates = milaRust;
    crateFile = _name: _rel: true;
  };
in
pkgs.runCommand "mila-windows-source-bundle-${version}" {} ''
  name=mila-windows-source-bundle-${version}
  b="$PWD/$name"
  cp -r --no-preserve=mode ${cargoWorkspace}/. "$b/"
  mkdir -p "$b/mila/windows-dotnet" "$b/mila/rust" "$b/mila/localization/catalogs"
  # `root` is the cleaned Mila source tree (not the repository root).
  cp -r ${root}/windows-dotnet/. "$b/mila/windows-dotnet/"
  cp -r ${root}/rust/. "$b/mila/rust/"
  cp ${root}/localization/generate_catalogs.py "$b/mila/localization/generate_catalogs.py"
  # The native host generates its Windows resources from the checked-in ARB
  # catalogs. Keep these alongside the path used by the project file so the
  # standalone bundle has all inputs required by dotnet build.
  cp ${root}/localization/catalogs/*.arb "$b/mila/localization/catalogs/"
  cat > "$b/flake.nix" <<'EOT'
  { outputs = _: { }; }
  EOT
  # A native bundle must never carry legacy compatibility inputs.
  if find "$b" -type f \( -iname '*flutter*' -o -iname '*.dart' \) -print -quit | grep -q .; then
    echo "native Windows bundle contains Flutter/Dart input" >&2
    exit 1
  fi
  (cd "$b" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
  mkdir -p $out
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu -cf - "$name" | gzip -n -9 > $out/$name.tar.gz
  (cd $out && sha256sum $name.tar.gz > SHA256SUMS)
''
