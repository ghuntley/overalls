{ pkgs }:
let
  inherit (pkgs) lib;
  platforms = {
    linux-amd64 = "linux";
    windows-amd64 = "windows";
    freebsd-amd64 = "freebsd";
    illumos-amd64 = "illumos";
  };
  mkGh = platform: goos: pkgs.buildGo127Module {
    pname = "overalls-managed-gh-${platform}";
    version = "2.102.0";
    src = pkgs.fetchzip {
      url = "https://codeload.github.com/cli/cli/tar.gz/refs/tags/v2.102.0";
      hash = (import ../../pins.nix).ghSource;
    };
    vendorHash = (import ../../pins.nix).ghVendor;
    patches = [ ./gh.patch ];
    postPatch = ''
      mkdir -p internal/overalls
      cp ${./transport}/*.go internal/overalls/
    '';
    env.CGO_ENABLED = "0";
    buildPhase = ''
      runHook preBuild
      chmod -R u+w vendor
      patch -p1 < ${./survey-illumos.patch}
      GOOS=${goos} GOARCH=amd64 go build -ldflags '-s -w -X github.com/cli/cli/v2/internal/build.Version=2.102.0 -X github.com/cli/cli/v2/internal/build.Date=overalls' -o gh${lib.optionalString (goos == "windows") ".exe"} ./cmd/gh
      runHook postBuild
    '';
    doCheck = platform == "linux-amd64";
    checkPhase = ''
      go test ./internal/overalls
    '';
    installPhase = ''
      install -D -m 0755 gh${lib.optionalString (goos == "windows") ".exe"} "$out/bin/gh${lib.optionalString (goos == "windows") ".exe"}"
    '';
    meta.license = lib.licenses.mit;
  };
  mkLfs = platform: goos: pkgs.buildGo127Module {
    pname = "overalls-managed-git-lfs-${platform}";
    version = "3.7.1";
    # Keep the reviewed patch and module hash bound to this exact release;
    # the supplied Nixpkgs git-lfs package may advance independently.
    src = pkgs.fetchFromGitHub {
      owner = "git-lfs";
      repo = "git-lfs";
      tag = "v3.7.1";
      hash = (import ../../pins.nix).gitLfsSource;
    };
    proxyVendor = true;
    vendorHash = (import ../../pins.nix).gitLfsVendor;
    patches = [ ./git-lfs.patch ];
    postPatch = ''
      mkdir -p internal/overalls
      cp ${./transport}/*.go internal/overalls/
    '';
    env.CGO_ENABLED = "0";
    buildPhase = ''
      runHook preBuild
      GOOS=${goos} GOARCH=amd64 go build -ldflags '-s -w -X github.com/git-lfs/git-lfs/v3/config.Vendor=3.7.1-overalls' -o git-lfs${lib.optionalString (goos == "windows") ".exe"} .
      runHook postBuild
    '';
    doCheck = platform == "linux-amd64";
    checkPhase = ''
      go test ./internal/overalls
    '';
    installPhase = ''
      install -D -m 0755 git-lfs${lib.optionalString (goos == "windows") ".exe"} "$out/bin/git-lfs${lib.optionalString (goos == "windows") ".exe"}"
    '';
    meta.license = lib.licenses.mit;
  };
  gh = lib.mapAttrs mkGh platforms;
  lfs = lib.mapAttrs mkLfs platforms;
  packages = platform: [ gh.${platform} lfs.${platform} ];
  release = pkgs.runCommand "overalls-github-tools-release-v1" {
    nativeBuildInputs = [ pkgs.jq ];
    passthru = { inherit gh lfs; configuration = ./github.gitconfig; };
  } ''
    mkdir -p "$out"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (platform: goos: ''
      mkdir -p "$out/${platform}"
      cp ${gh.${platform}}/bin/gh${lib.optionalString (goos == "windows") ".exe"} "$out/${platform}/gh${lib.optionalString (goos == "windows") ".exe"}"
      cp ${lfs.${platform}}/bin/git-lfs${lib.optionalString (goos == "windows") ".exe"} "$out/${platform}/git-lfs${lib.optionalString (goos == "windows") ".exe"}"
      cp ${./github.gitconfig} "$out/${platform}/github.gitconfig"
    '') platforms)}
    config_digest=$(sha256sum ${./github.gitconfig} | cut -d ' ' -f 1)
    jq -nc --arg configuration_sha256 "$config_digest" '{version:1,configuration_sha256:$configuration_sha256,platforms:{}}' > manifest.json
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (platform: goos: ''
      files='[]'
      for name in gh git-lfs github.gitconfig; do
        file="$name"
        ${lib.optionalString (goos == "windows") ''if [ "$name" != github.gitconfig ]; then file="$name.exe"; fi''}
        digest=$(sha256sum "$out/${platform}/$file" | cut -d ' ' -f 1)
        bytes=$(wc -c < "$out/${platform}/$file")
        files=$(jq -nc --argjson files "$files" --arg name "$name" --arg sha256 "$digest" --argjson bytes "$bytes" --arg path "${platform}/$file" '$files + [{name:$name,sha256:$sha256,bytes:$bytes,path:$path}] | sort_by(.name)')
      done
      jq -c --arg platform ${lib.escapeShellArg platform} --argjson files "$files" '.platforms[$platform] = {files:$files}' manifest.json > manifest.next
      mv manifest.next manifest.json
    '') platforms)}
    jq -Scj . manifest.json > manifest.canonical
    generation=$(sha256sum manifest.canonical | cut -d ' ' -f 1)
    jq -Sc --arg generation "$generation" '. + {generation:$generation}' manifest.json > "$out/manifest.json"
  '';
in {
  inherit gh lfs packages release;
  configuration = ./github.gitconfig;
}
