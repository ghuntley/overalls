{ pkgs }:
let
  inherit (pkgs) lib;
  baseUrl = "https://pkg.omnios.org/r151050/core";
  packages = [
    { name = "system/header"; version = "0.5.11,5.11-151050.0:20240426T120142Z"; sha256 = "12718cbe9487ff0bc12a514c3ee56d502c1ec6e293fde5be3add53f56513390e"; }
    { name = "system/library"; version = "0.5.11,5.11-151050.0:20240426T120154Z"; sha256 = "00b07a2526d266da3e38d39f924c04f79b18099f1c121b91249997d55382cf70"; }
    { name = "system/library/c-runtime"; version = "0.5.11,5.11-151050.0:20240426T120145Z"; sha256 = "1c9151dbabd184138ce0fd6529119973f309cb1709dc0ebe5e51aa70bfbed7c9"; }
    { name = "system/library/gcc-runtime"; version = "13,5.11-151050.0:20240426T124318Z"; sha256 = "b83ea5d7db9333c25a90779b3888e60ef7e1ada9c58186820e7ae5f92bba0c4e"; }
    { name = "system/library/math"; version = "0.5.11,5.11-151050.0:20240426T120149Z"; sha256 = "a341e36f4005d6f0ed7907977bc3c2b8377bc165bb32de53d1078a1350c89e21"; }
    { name = "developer/gcc13"; version = "13.2.0,5.11-151050.0:20240426T114345Z"; sha256 = "9459823041e4105cccaa387aa9aa0a6729a4311568093c80584bf17066216e39"; }
    { name = "developer/linker"; version = "0.5.11,5.11-151050.0:20240426T120027Z"; sha256 = "36e89c77203b59bbb7c12e81974f973f2707af061f949e0ee62bb061419beaf4"; }
  ];
  manifests = map (package: pkgs.fetchurl {
    name = "omnios-${lib.replaceStrings [ "/" ] [ "-" ] package.name}.p5m";
    url = "${baseUrl}/manifest/0/${lib.escapeURL (package.name + "@" + package.version)}";
    inherit (package) sha256;
  }) packages;
  # @cc [owner:ghuntley,label:build;security] illumos-sdk-fixed-inputs
  # The SDK MUST use exact official package manifests and verify compressed and
  # plain payload hashes before extraction, plus the complete output NAR hash.
  # Ordinary compiler and Lyra builds MUST use this prefetched sysroot offline.
  sysroot = pkgs.runCommand "omnios-r151050-linker-sysroot" {
    nativeBuildInputs = [ pkgs.python313 ];
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = (import ../../../pins.nix).illumosLinkerSysroot;
    passthru = { inherit packages; };
  } ''
    python3.13 ${../../illumos_sdk/fetch_sdk.py} "$out" ${lib.escapeShellArgs (map toString manifests)}
  '';
  targetPlatform = (lib.systems.elaborate "x86_64-solaris") // { config = "x86_64-pc-solaris2.11"; };
  binutils = (pkgs.binutils-unwrapped.override {
    stdenv = pkgs.stdenv // { inherit targetPlatform; };
    enableGold = false;
  }).overrideAttrs (old: {
    configurePlatforms = [ "build" "host" ];
    configureFlags = old.configureFlags ++ [ "--target=x86_64-pc-solaris2.11" ];
  });
  clang = (pkgs.llvmPackages.clang-unwrapped.override {
    enableClangToolsExtra = false;
    extraPatches = [ ./overalls-clang-solaris-linker-path.patch ];
  }).overrideAttrs (old: {
    # run-clang-tidy is installed only with clang-tools-extra, but the pinned
    # postInstall moves it unconditionally.
    postInstall = builtins.replaceStrings [ "run-clang-tidy," ] [ "" ] old.postInstall;
  });
  # @cc [owner:ghuntley,label:build] illumos-sdk-linker-semantics
  # The compiler MUST select the pinned Solaris GNU linker through Clang's
  # validated --ld-path and GNU driver mode. Rust's Solaris -z ignore/record
  # pair MUST map to GNU as-needed/no-as-needed; other arguments MUST survive.
  # Produced executables MUST retain guest interpreters and no Linux rpaths.
  compiler = pkgs.writeShellScriptBin "illumos-clang" ''
    declare -a arguments=()
    linking=true
    for argument in "$@"; do
      case "$argument" in
        -c|-S|-E|-fsyntax-only|--version|-dumpmachine|-print-*) linking=false ;;
      esac
      case "$argument" in
        -Wl,-z,ignore) arguments+=("-Wl,--as-needed") ;;
        -Wl,-z,record) arguments+=("-Wl,--no-as-needed") ;;
        *) arguments+=("$argument") ;;
      esac
    done
    declare -a driver=(
      --target=x86_64-pc-solaris2.11
      --sysroot=${sysroot}
      --gcc-install-dir=${sysroot}/opt/gcc-13/lib/gcc/x86_64-pc-solaris2.11/13.2.0
    )
    if "$linking"; then
      driver+=(
        -fuse-ld=bfd
        --ld-path=${binutils}/bin/x86_64-pc-solaris2.11-ld
        -Wl,--sysroot=${sysroot}
        -Wl,-rpath-link,${sysroot}/lib/amd64:${sysroot}/usr/lib/amd64
        -Wl,-z,noexecstack
      )
    fi
    exec ${clang}/bin/clang "''${driver[@]}" "''${arguments[@]}"
  '';
  testSources = lib.cleanSourceWith {
    src = ../../illumos_sdk;
    filter = path: type:
      builtins.baseNameOf path != "__pycache__" &&
      (type == "directory" || lib.hasSuffix ".py" path);
  };
  tests = pkgs.runCommand "illumos-sdk-tests" {
    nativeBuildInputs = [ pkgs.python313 pkgs.binutils ];
  } ''
    cp -r ${testSources} illumos_sdk
    python3.13 -m unittest discover -s illumos_sdk -t . -p 'test_*.py'
    cat > probe.c <<'C'
    #include <stdio.h>
    int main(void) { return puts("overalls illumos SDK link probe") < 0; }
    C
    ${compiler}/bin/illumos-clang -Wall -Wextra -Werror -c probe.c -o probe.o
    ${compiler}/bin/illumos-clang probe.o -o probe
    readelf --program-headers --wide probe > program-headers
    grep -F '[Requesting program interpreter: /usr/lib/amd64/ld.so.1]' program-headers
    if ${compiler}/bin/illumos-clang --ld-path="$TMPDIR/missing-linker" probe.o -o refused > refusal.log 2>&1; then
      echo "Clang accepted a nonexistent explicit linker" >&2
      exit 1
    fi
    grep -F 'invalid linker name' refusal.log
    test ! -e refused
    touch "$out"
  '';
in
{ inherit sysroot packages binutils clang compiler tests; }
