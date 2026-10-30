{ pkgs
, nodeVersion ? "24.21.0"
, nodeSha256 ? (import ../pins.nix).nodeWindowsX64
, ripgrepVersion ? "15.1.0"
, ripgrepSha256 ? (import ../pins.nix).ripgrepWindowsX64
}:
let
  nodeArchive = pkgs.fetchurl {
    name = "node-v${nodeVersion}-win-x64.zip";
    url = "https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}-win-x64.zip";
    hash = nodeSha256;
  };
  ripgrepArchive = pkgs.fetchurl {
    name = "ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc.zip";
    url = "https://github.com/BurntSushi/ripgrep/releases/download/${ripgrepVersion}/ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc.zip";
    hash = ripgrepSha256;
  };
  node = pkgs.runCommand "overalls-editor-node-win32-x64" {
    nativeBuildInputs = [ pkgs.unzip ];
    allowedReferences = [ ];
  } ''
    mkdir -p "$out/bin" "$out/licenses/node"
    unzip -q ${nodeArchive} "node-v${nodeVersion}-win-x64/node.exe" "node-v${nodeVersion}-win-x64/LICENSE" -d "$TMPDIR/node"
    install -m 0555 "$TMPDIR/node/node-v${nodeVersion}-win-x64/node.exe" "$out/bin/node.exe"
    install -m 0444 "$TMPDIR/node/node-v${nodeVersion}-win-x64/LICENSE" "$out/licenses/node/LICENSE"
  '';
  ripgrep = pkgs.runCommand "overalls-editor-ripgrep-win32-x64" {
    nativeBuildInputs = [ pkgs.unzip ];
    allowedReferences = [ ];
  } ''
    mkdir -p "$out/bin" "$out/licenses/ripgrep"
    unzip -q ${ripgrepArchive} "ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/rg.exe" "ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/COPYING" "ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/LICENSE-MIT" "ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/UNLICENSE" -d "$TMPDIR/ripgrep"
    install -m 0555 "$TMPDIR/ripgrep/ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/rg.exe" "$out/bin/rg.exe"
    for notice in COPYING LICENSE-MIT UNLICENSE; do
      install -m 0444 "$TMPDIR/ripgrep/ripgrep-${ripgrepVersion}-x86_64-pc-windows-msvc/$notice" "$out/licenses/ripgrep/$notice"
    done
  '';
in
pkgs.runCommand "overalls-editor-windows-runtime" {
  allowedReferences = [ ];
  passthru = {
    targetPlatform = "win32-x64";
    nodeVersion = nodeVersion;
    ripgrepVersion = ripgrepVersion;
    editorCapability = false;
    runtimeOnly = true;
  };
  meta = {
    description = "Pinned Windows runtime inputs for a future Overalls Code OSS guest build";
    platforms = [ "x86_64-linux" ];
  };
} ''
  mkdir -p "$out/bin"
  cp ${node}/bin/node.exe "$out/bin/node.exe"
  cp ${ripgrep}/bin/rg.exe "$out/bin/rg.exe"
  mkdir -p "$out/licenses"
  cp -R ${node}/licenses/node ${ripgrep}/licenses/ripgrep "$out/licenses/"
  node_sha256=$(sha256sum "$out/bin/node.exe" | cut -d' ' -f1)
  ripgrep_sha256=$(sha256sum "$out/bin/rg.exe" | cut -d' ' -f1)
  cat > "$out/overalls-editor-windows-runtime.json" <<EOF
{"version":1,"target":"win32-x64","node":{"version":"${nodeVersion}","path":"bin/node.exe","sha256":"$node_sha256"},"ripgrep":{"version":"${ripgrepVersion}","path":"bin/rg.exe","sha256":"$ripgrep_sha256"},"editor_capability":false}
EOF
  # Keep runtime staging auditable and refuse an incomplete closure.
  test -s "$out/bin/node.exe"
  test -s "$out/bin/rg.exe"
  test -s "$out/overalls-editor-windows-runtime.json"
''
