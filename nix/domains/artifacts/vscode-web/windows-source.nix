{ pkgs }:
let
  inherit (pkgs) lib;
  inputs = import ./inputs.nix;
  runtime = import ./windows-runtime.nix { inherit pkgs; };
  npmCache = import ./npm-cache.nix { inherit pkgs; };
  extensionLock = builtins.fromJSON (builtins.readFile ./extensions.lock.json);
  extensionInputs = map (extension: {
    inherit (extension) id;
    vsix = pkgs.fetchurl { inherit (extension.vsix) url hash; };
    signature = pkgs.fetchurl { inherit (extension.signature) url hash; };
  }) extensionLock.extensions;
  patches = [ ./patches/0001-overalls-browser-editor.patch ./patches/0002-overalls-editor-policy.patch ./patches/0003-overalls-startup-defaults.patch ./patches/0004-overalls-personal-bundled-updates.patch ];
  nodeArchive = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v${inputs.nodeVersion}/node-v${inputs.nodeVersion}-win-x64.zip";
    hash = (import ../pins.nix).nodeWindowsX64;
  };
  nodeHeaders = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v${inputs.nodeVersion}/node-v${inputs.nodeVersion}-headers.tar.gz";
    hash = (import ../pins.nix).nodeHeaders;
  };
  nodeLibrary = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v${inputs.nodeVersion}/win-x64/node.lib";
    hash = (import ../pins.nix).nodeWindowsX64Library;
  };
  python = pkgs.fetchurl {
    url = "https://www.python.org/ftp/python/3.13.7/python-3.13.7-embed-amd64.zip";
    hash = (import ../pins.nix).pythonEmbedWindowsX64;
  };
  electronTypes = pkgs.fetchurl {
    url = "https://github.com/electron/electron/releases/download/v${inputs.electronTypesVersion}/electron.d.ts";
    hash = inputs.electronTypesHash;
  };
  releaseId = builtins.hashString "sha256" (builtins.toJSON {
    inherit inputs;
    target = "win32-x64";
    patches = map (path: builtins.hashFile "sha256" path) patches;
    recipe = builtins.hashFile "sha256" ./windows-source.nix;
    build = builtins.hashFile "sha256" ./windows-build.ps1;
    preparation = builtins.hashFile "sha256" ./prepare-windows.mts;
    npmDirectories = builtins.hashFile "sha256" ./npm-directories.json;
    runtime = toString runtime;
    nodeHeaders = toString nodeHeaders;
    nodeLibrary = toString nodeLibrary;
    python = toString python;
    signingKey = builtins.hashFile "sha256" ./open-vsx-key.pem;
    extensionLock = builtins.hashFile "sha256" ./extensions.lock.json;
    extensionValidation = builtins.hashFile "sha256" ./extensions.py;
    maintenanceEntry = builtins.hashFile "sha256" ./maintenance-entry.ts;
    maintenanceValidator = builtins.hashFile "sha256" ./check-extension.mts;
    languageAdapters = [
      (builtins.hashFile "sha256" ./windows-language-adapters/language_server.bat)
      (builtins.hashFile "sha256" ./windows-language-adapters/debug_adapter.bat)
      (builtins.hashFile "sha256" ./windows-language-adapters/elixir_check.bat)
    ];
  });
  productOverlay = pkgs.writeText "overalls-windows-editor-product.json" (builtins.toJSON {
    nameShort = "Overalls Code";
    nameLong = "Overalls Code";
    applicationName = "overalls-code";
    serverApplicationName = "overalls-code";
    dataFolderName = ".overalls-code";
    serverDataFolderName = ".overalls-code-server";
    urlProtocol = "overalls-code";
    quality = "stable";
    enableTelemetry = false;
    builtInExtensions = [ ];
    webBuiltInExtensions = [ ];
    builtInExtensionsEnabledWithAutoUpdates = [ ];
    trustedExtensionAuthAccess = { };
    extensionsGallery = {
      serviceUrl = "https://open-vsx.org/vscode/gallery";
      itemUrl = "https://open-vsx.org/vscode/item";
      resourceUrlTemplate = "https://open-vsx.org/vscode/unpkg/{publisher}/{name}/{version}/{path}";
    };
    overallsEditor = {
      inherit releaseId;
      protocol = 1;
      extensionSigningKeys = [ (builtins.readFile ./open-vsx-key.pem) ];
      policy = { builtInAI = "disabled"; workspaceTrust = "disabled"; };
      configurationDefaults = {
        "rust-analyzer.server.path" = "rust-analyzer";
        "elixirLS.languageServerOverridePath" = "C:/overalls/editor/project-language-adapters";
        "workbench.startupEditor" = "none";
        "workbench.welcomePage.walkthroughs.openOnInstall" = false;
      };
      userUpdatableBundledExtensions = [ "editorconfig.editorconfig" "cab404.vscode-direnv" "elixir-lsp.elixir-ls" "rust-lang.rust-analyzer" ];
    };
  });
in
# @cc [owner:ghuntley,label:build;security] windows-editor-offline-source-payload
# The native build payload MUST contain the hash-pinned official source with
# the maintained patch stack, closed Overalls product policy, complete pinned
# npm caches, Node headers/import library, Python and Windows runtime tools.
# It MUST remain an unadmitted build input; source assembly alone grants no
# editor capability and no Code OSS product binary may replace compilation.
pkgs.stdenvNoCC.mkDerivation {
  pname = "overalls-vscode-web-windows-source";
  inherit (inputs) version;
  src = pkgs.fetchFromGitHub {
    owner = "microsoft";
    repo = "vscode";
    rev = inputs.sourceCommit;
    hash = inputs.sourceHash;
  };
  inherit patches;
  nativeBuildInputs = [ pkgs.jq pkgs.unzip ];
  dontConfigure = true;
  dontBuild = true;
  # These upstream shell assets also ship in the Windows server for Git Bash.
  # Host Nix shebang rewriting would make them unusable and leak store paths.
  dontPatchShebangs = true;
  postPatch = ''
    jq --slurp '(.[0] | del(.trustedExtensionAuthAccess)) * .[1] | del(.defaultChatAgent, .voiceWsUrl, .webviewContentExternalBaseUrlTemplate, .agentsTelemetryAppName)' \
      product.json ${productOverlay} > product.overalls.json
    mv product.overalls.json product.json
    substituteInPlace remote/.npmrc --replace-fail 'target="24.21.0"' 'target="${inputs.nodeVersion}"'
    cp LICENSE.txt remote/LICENSE
    mkdir -p .build/typings
    cp ${electronTypes} .build/typings/electron.d.ts
  '';
  installPhase = ''
    mkdir -p "$out/source" "$out/node" "$out/python" "$out/headers/x64" "$out/headers/Release" "$out/ripgrep"
    cp -R . "$out/source/"
    cp -R ${npmCache} "$out/npm-cache"
    unzip -q ${nodeArchive} -d "$TMPDIR/node"
    cp -R "$TMPDIR/node/node-v${inputs.nodeVersion}-win-x64/." "$out/node/"
    unzip -q ${python} -d "$out/python"
    # node-gyp needs its own Python package path under the embedded interpreter.
    cat >> "$out/python/python313._pth" <<'EOF_PYTHON'
../node/node_modules/npm/node_modules/node-gyp/gyp/pylib
import site
EOF_PYTHON
    tar -xf ${nodeHeaders} --strip-components=1 -C "$out/headers"
    cp ${nodeLibrary} "$out/headers/x64/node.lib"
    cp ${nodeLibrary} "$out/headers/Release/node.lib"
    cp ${runtime}/bin/rg.exe "$out/ripgrep/rg.exe"
    cp ${./windows-build.ps1} "$out/windows-build.ps1"
    cp ${./prepare-windows.mts} "$out/prepare-windows.mts"
    cp ${./npm-directories.json} "$out/npm-directories.json"
    cp ${./extensions.lock.json} "$out/extensions.lock.json"
    cp ${./extensions.py} "$out/extensions.py"
    cp ${./check-extension.mts} "$out/check-extension.mts"
    cp ${./maintenance-entry.ts} "$out/maintenance-entry.ts"
    cp ${./open-vsx-key.pem} "$out/open-vsx-key.pem"
    mkdir -p "$out/extension-inputs"
    ${lib.concatMapStringsSep "\n" (extension: ''
      mkdir -p "$out/extension-inputs/${extension.id}"
      cp ${extension.vsix} "$out/extension-inputs/${extension.id}/extension.vsix"
      cp ${extension.signature} "$out/extension-inputs/${extension.id}/extension.sigzip"
    '') extensionInputs}
    mkdir -p "$out/windows-language-adapters"
    cp ${./windows-language-adapters}/*.bat "$out/windows-language-adapters/"
    printf '%s' '${inputs.sourceCommit}' > "$out/source-commit"
    printf '%s' '${inputs.nodeVersion}' > "$out/node-version"
    printf '%s' '${builtins.toJSON { source_commit = inputs.sourceCommit; editor_protocol = 1; release_id = releaseId; }}' > "$out/overalls-editor-release.json"
  '';
  passthru = {
    targetPlatform = "win32-x64";
    inherit releaseId;
    sourceCommit = inputs.sourceCommit;
    editorProtocol = 1;
    editorCapability = false;
  };
  meta = {
    description = "Offline native-Windows source build payload for Overalls Code OSS";
    platforms = [ "x86_64-linux" ];
  };
}
