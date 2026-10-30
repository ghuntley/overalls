{ pkgs, buck2 }:
# @cc [owner:ghuntley,label:build;security] buck2-no-nix-kit
# A runner without Nix (Windows) MUST run the same buck2 release and prelude
# as buckCells. tools/buck2 --no-nix downloads them as tools/buck2-no-nix.json
# names them and checks the pin registry's hashes; these kits are the same
# downloads made by Nix, and building one MUST fail when that file or a hash
# no longer matches the pinned nixpkgs buck2 (ADR-0269 M9).
let
  inherit (pkgs) lib;
  pinned = lib.importJSON ../../tools/buck2-no-nix.json;
  base = "https://github.com/facebook/buck2/releases/download/${pinned.release}";
  windowsBinary = pkgs.fetchurl {
    url = "${base}/${pinned.binaries.x86_64-windows.asset}";
    hash = (import ../domains/artifacts/pins.nix).buck2WindowsBinary;
  };
  linuxBinary = pkgs.fetchurl {
    url = "${base}/${pinned.binaries.x86_64-linux.asset}";
    hash = (import ../domains/artifacts/pins.nix).buck2LinuxBinary;
  };
  prelude = pkgs.fetchurl {
    url = "https://github.com/facebook/buck2-prelude/archive/${pinned.prelude}.tar.gz";
    hash = (import ../domains/artifacts/pins.nix).buck2Prelude;
  };
  # The configuration tools/buck2 --no-nix writes: only non_hermetic targets,
  # and `python` (buck/mila_platform.py) by name from PATH.
  buckconfig = python: pkgs.writeText "toolchains.buckconfig" ''
    [overalls]
      no_nix = true
      non_hermetic = true
    [nix]
      python = ${python}
  '';
  kit = { name, binary, file, python }: pkgs.runCommand "overalls-buck2-no-nix-${name}-${pinned.release}" {
    nativeBuildInputs = [ pkgs.zstd ];
  } ''
    # The no-Nix pins must name exactly the buckCells buck2 and prelude.
    test "${pinned.release}" = "${lib.removePrefix "unstable-" buck2.version}" ||
      { echo "tools/buck2-no-nix.json release is not buck2 ${buck2.version}" >&2; exit 1; }
    test "${prelude.url}" = "${buck2.prelude.url}" ||
      { echo "tools/buck2-no-nix.json prelude is not ${buck2.prelude.url}" >&2; exit 1; }
    cmp ${prelude} ${buck2.prelude}
    mkdir -p "$out/bin" "$out/prelude" "$out/rust"
    zstd -q -d ${binary} -o "$out/bin/${file}"
    chmod +x "$out/bin/${file}"
    tar -xzf ${prelude} -C "$out/prelude" --strip-components=1
    cp ${buckconfig python} "$out/toolchains.buckconfig"
    echo "${name} ${pinned.release} ${pinned.prelude}" > "$out/kit-id"
  '';
in
{
  windows = kit { name = "windows"; binary = windowsBinary; file = "buck2.exe"; python = "python"; };
  # The Linux kit runs the no-Nix mode on a development host
  # (OVERALLS_BUCK2_KIT); its binary must be the buckCells one.
  linux = kit { name = "linux"; binary = linuxBinary; file = "buck2"; python = "python3"; };
}
