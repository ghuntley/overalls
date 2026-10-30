{ pkgs }:
let
  inherit (pkgs) lib;

  # These commits are the release inputs for the native guest plan. Keep the
  # complete revisions here: an abbreviated revision in a manifest would permit
  # two different archives to acquire the same image identity.
  freebsdRevision = "833d39bd2e38421a14ea489a956261a0fa993fbc";
  illumosRevision = "6f87d0b5d63b957991dc9d4a01a7e6c95483282c";
  omniosBuildRevision = "595bfdc217ae3cc19f982bc483701cdb89649a2d";

  freebsdSource = pkgs.fetchFromGitHub {
    owner = "freebsd";
    repo = "freebsd-src";
    rev = freebsdRevision;
    hash = (import ../../pins.nix).freebsdKernelSource;
  };
  illumosSource = pkgs.fetchFromGitHub {
    owner = "omniosorg";
    repo = "illumos-omnios";
    rev = illumosRevision;
    hash = (import ../../pins.nix).illumosKernelSource;
  };
  omniosBuildSource = pkgs.fetchFromGitHub {
    owner = "omniosorg";
    repo = "omnios-build";
    rev = omniosBuildRevision;
    hash = (import ../../pins.nix).omniosBuildSource;
  };

  freebsdPatch = ./freebsd/0001-vsock-contract-scaffold.patch;
  illumosPatch = ./illumos/0001-vsock-contract-scaffold.patch;
  freebsdConfig = ./freebsd/GENERIC-OVERALLS;
  illumosConfig = ./illumos/amd64-overalls.conf;

  # `builtins.hashFile` emits lower-case hexadecimal SHA-256, the only digest
  # representation accepted by ImageManifest.kernel_provenance/1.
  freebsdPatchHash = builtins.hashFile "sha256" freebsdPatch;
  illumosPatchHash = builtins.hashFile "sha256" illumosPatch;
  freebsdConfigurationHash = builtins.hashFile "sha256" freebsdConfig;
  illumosConfigurationHash = builtins.hashFile "sha256" illumosConfig;

  compiler = "clang-${lib.getVersion pkgs.llvmPackages.clang} (x86_64 cross target)";
  unavailableDigest = builtins.hashString "sha256" "native-kernel-artifact-unavailable";

  mkReceipt = {
    name,
    os,
    source,
    sourceRevision,
    sourceHash,
    patch,
    patchHash,
    configuration,
    configurationHash,
    buildSystem,
  }:
    pkgs.runCommand name {
      nativeBuildInputs = [ pkgs.patch pkgs.llvmPackages.clang-unwrapped ];
      passthru = {
        inherit os source sourceRevision sourceHash patch patchHash configuration configurationHash buildSystem;
        # Runtime image admission must reject this receipt until the OS-specific
        # cross build provides a real kernel. Keeping the descriptor complete
        # lets evaluators check every identity input without claiming bootability.
        artifact = {
          available = false;
          bytes = 0;
          sha256 = unavailableDigest;
        };
        provenance = {
          # A receipt is metadata until the OS-specific cross build emits a
          # bootable kernel.  Zero is intentional: ImageManifest's artifact
          # predicate rejects it, so an unavailable receipt cannot become a
          # native image merely because a caller copied its provenance.
          bytes = 0;
          sha256 = unavailableDigest;
          source_revision = sourceRevision;
          patch_hash = patchHash;
          configuration_hash = configurationHash;
          inherit compiler;
        };
      };
    } ''
      set -eu
      # Apply the reviewed patch to the pinned source before publishing the
      # receipt.  This catches stale paths and malformed patches during the
      # ordinary Nix build instead of silently treating the patch as a label.
      work="$TMPDIR/native-kernel-source"
      mkdir -p "$work"
      cp -a ${source}/. "$work/"
      chmod -R u+w "$work"
      mkdir -p "$work/sys/dev/virtio/vsock" "$work/usr/src/uts/common/io/vsock"
      # Patch files carry an mbox subject for review provenance; GNU patch
      # consumes the unified diff beginning at the /dev/null header.
      sed -n '/^--- \/dev\/null$/,$p' ${patch} | patch --directory="$work" -p1 --forward --batch
      test -f "$work/${if os == "freebsd" then "sys/dev/virtio/vsock/overalls_vsock_contract.h" else "usr/src/uts/common/io/vsock/overalls_vsock_contract.h"}"
      # Check the proposed OS-specific address layout against the pinned
      # operating system's real headers. This proves ABI type/offset agreement,
      # not that the header registers a family or provides a runnable transport.
      abi_include="$TMPDIR/native-abi-include"
      mkdir -p "$abi_include"
      ${lib.optionalString (os == "freebsd") ''
        ln -s "$work/sys/amd64/include" "$abi_include/machine"
        ln -s "$work/sys/x86/include" "$abi_include/x86"
      ''}
      ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
        --target=${if os == "freebsd" then "x86_64-unknown-freebsd14" else "x86_64-pc-solaris2.11"} \
        -std=gnu11 -Werror -fsyntax-only -x c -nostdinc \
        ${if os == "freebsd" then ''
          -I "$abi_include" -I "$work/sys" \
          "$work/sys/dev/virtio/vsock/overalls_vsock_contract.h"
        '' else ''
          -D__EXTENSIONS__ -I "$work/usr/src/uts/intel" \
          -I "$work/usr/src/uts/common" -I "$work/usr/src/head" \
          "$work/usr/src/uts/common/io/vsock/overalls_vsock_contract.h"
        ''}
      mkdir -p "$out/share/overalls/native-kernel"
      cat > "$out/share/overalls/native-kernel/provenance.json" <<'JSON'
      ${builtins.toJSON {
        version = 1;
        inherit os compiler;
        source_revision = sourceRevision;
        source_hash = sourceHash;
        patch_hash = patchHash;
        configuration_hash = configurationHash;
        build_system = buildSystem;
        artifact = { available = false; bytes = 0; sha256 = unavailableDigest; };
        patch_applied = true;
        abi_header_checked = true;
      }}
      JSON
      cp ${patch} "$out/share/overalls/native-kernel/vsock.patch"
      cp ${configuration} "$out/share/overalls/native-kernel/kernel.conf"
      printf '%s\n' '${sourceRevision}' > "$out/share/overalls/native-kernel/source-revision"
      printf '%s\n' 'patch-applied;cross-build-pending' > "$out/share/overalls/native-kernel/status"
    '';

  freebsd = mkReceipt {
    name = "overalls-freebsd-kernel-receipt-${freebsdRevision}";
    os = "freebsd";
    source = freebsdSource;
    sourceRevision = freebsdRevision;
    sourceHash = (import ../../pins.nix).freebsdKernelSource;
    patch = freebsdPatch;
    patchHash = freebsdPatchHash;
    configuration = freebsdConfig;
    configurationHash = freebsdConfigurationHash;
    buildSystem = "freebsd-buildkernel-releng-14.3";
  };
  illumos = mkReceipt {
    name = "overalls-illumos-kernel-receipt-${illumosRevision}";
    os = "illumos";
    source = illumosSource;
    sourceRevision = illumosRevision;
    sourceHash = (import ../../pins.nix).illumosKernelSource;
    patch = illumosPatch;
    patchHash = illumosPatchHash;
    configuration = illumosConfig;
    configurationHash = illumosConfigurationHash;
    buildSystem = "omnios-build-r151050";
  };

  freebsdCandidate = import ./freebsd {
    inherit pkgs;
    source = freebsdSource;
    sourceRevision = freebsdRevision;
    sourceHash = (import ../../pins.nix).freebsdKernelSource;
    abiPatch = freebsdPatch;
  };
  # Test-only: received-frame injection for native wrong-CID machine tests.
  freebsdFaultCandidate = import ./freebsd {
    inherit pkgs;
    source = freebsdSource;
    sourceRevision = freebsdRevision;
    sourceHash = (import ../../pins.nix).freebsdKernelSource;
    abiPatch = freebsdPatch;
    faultInjection = true;
  };
  vsockCoreCheck = import ./common { inherit pkgs; };
  illumosToolchain = import ./illumos/sdk.nix { inherit pkgs; };
  illumosCandidate = import ./illumos {
    inherit pkgs;
    source = illumosSource;
    sourceRevision = illumosRevision;
    sourceHash = (import ../../pins.nix).illumosKernelSource;
    abiPatch = illumosPatch;
    toolchain = illumosToolchain;
  };

  # The SDK source is kept as a separate fixed-output input. It is intentionally not
  # folded into the illumos source archive: a sysroot refresh must alter image
  # provenance and trigger a reviewed native capability receipt.
  illumosSdk = pkgs.runCommand "overalls-illumos-sdk-${omniosBuildRevision}" {
    passthru = {
      source = omniosBuildSource;
      sourceRevision = omniosBuildRevision;
      sourceHash = (import ../../pins.nix).omniosBuildSource;
      artifact = {
        available = false;
        bytes = 0;
        sha256 = unavailableDigest;
      };
    };
  } ''
    set -eu
    # Keep the fixed-output source in the derivation graph even while the
    # illumos-native SDK builder is unavailable. The receipt must not claim a
    # sysroot merely because its revision is recorded in passthru metadata.
    test -d ${omniosBuildSource}
    mkdir -p "$out/share/overalls/illumos-sdk"
    # The full SDK is produced by omnios-build on an illumos cross builder. A
    # receipt is still useful to Nix evaluation and carries the exact source.
    printf '%s\n' '${omniosBuildRevision}' > "$out/share/overalls/illumos-sdk/source-revision"
    printf '%s\n' 'sha256-vx3zvMiKaZiLF9IudtxboOqU8VAkxQMnrho2n0JWcMw=' > "$out/share/overalls/illumos-sdk/source-hash"
    printf '%s\n' '0' > "$out/share/overalls/illumos-sdk/artifact-bytes"
    printf '%s\n' '${unavailableDigest}' > "$out/share/overalls/illumos-sdk/artifact-sha256"
    printf '%s\n' 'cross-sdk-pending' > "$out/share/overalls/illumos-sdk/status"
  '';

  # A machine-readable source pin is exported for image and provenance checks.
  pins = {
    freebsd = {
      revision = freebsdRevision;
      hash = (import ../../pins.nix).freebsdKernelSource;
    };
    illumos = {
      revision = illumosRevision;
      hash = (import ../../pins.nix).illumosKernelSource;
    };
    omniosBuild = {
      revision = omniosBuildRevision;
      hash = (import ../../pins.nix).omniosBuildSource;
    };
  };
in
{
  inherit freebsdSource illumosSource omniosBuildSource illumosSdk freebsd illumos pins
    freebsdCandidate freebsdFaultCandidate vsockCoreCheck illumosToolchain illumosCandidate;
  freebsdKernel = freebsd;
  illumosKernel = illumos;
  freebsdRevision = freebsdRevision;
  illumosRevision = illumosRevision;
  omniosBuildRevision = omniosBuildRevision;
  freebsdPatchHash = freebsdPatchHash;
  illumosPatchHash = illumosPatchHash;
  freebsdConfigurationHash = freebsdConfigurationHash;
  illumosConfigurationHash = illumosConfigurationHash;
  compiler = compiler;
}
