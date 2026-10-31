{ pkgs, source, sourceRevision, sourceHash, abiPatch, faultInjection ? false }:
let
  inherit (pkgs) lib;
  # The fault kernel is a separately identified, test-only build that appends
  # received-frame injection to the unchanged driver source. Its configuration
  # inputs differ, so it can never share the production build identity.
  kernelConfigurationName = if faultInjection then "GENERIC-OVERALLS-FAULT" else "GENERIC-OVERALLS";
  # FreeBSD 14.3 ships Clang 19.1.7. Use the corresponding pinned compiler,
  # including its separately packaged intrinsic headers, for host and target.
  llvm = pkgs.llvmPackages_19;
  compiler = "clang-${lib.getVersion llvm.clang-unwrapped} (x86_64-unknown-freebsd14.3)";
  # The build token also binds compiler/linker flags and cross-build source
  # transformations, not only the GENERIC configuration file.
  configurationInputs = {
    kernel_configuration = builtins.hashFile "sha256" ./GENERIC-OVERALLS;
    build_recipe = builtins.hashFile "sha256" ./default.nix;
  } // lib.optionalAttrs faultInjection {
    fault_configuration = builtins.hashFile "sha256" ./GENERIC-OVERALLS-FAULT;
    fault_injection = builtins.hashFile "sha256" ./ovfb_fault.h;
  };
  configurationHash = builtins.hashString "sha256" (builtins.toJSON configurationInputs);
  patchInputs = {
    abi = builtins.hashFile "sha256" abiPatch;
    driver = builtins.hashFile "sha256" ./virtio_vsock.c;
    accept_lifetime = builtins.hashFile "sha256" ./ovfb_accept.h;
    public_header = builtins.hashFile "sha256" ./vsock.h;
    wire_header = builtins.hashFile "sha256" ../common/ov_vsock.h;
    wire_core = builtins.hashFile "sha256" ../common/ov_vsock.c;
  };
  patchHash = builtins.hashString "sha256" (builtins.toJSON patchInputs);
  buildId = builtins.hashString "sha256" (builtins.toJSON {
    inherit sourceRevision sourceHash patchHash configurationHash compiler;
  });
  acceptCheck = pkgs.runCommand "freebsd-vsock-accept-lifetime" {
    nativeBuildInputs = [ llvm.clang ];
  } ''
    clang -std=c11 -pedantic -Wall -Wextra -Werror -O1 -g \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      -I${../common} -I${./.} \
      ${../common/ov_vsock.c} ${./accept_test.c} -o accept-test
    ./accept-test
    mkdir "$out"
    printf '%s\n' 'Actual accept helper with native socket lifetime mocks passed.' > "$out/result"
  '';
in
# @cc [owner:ghuntley,label:build;verification] freebsd-candidate-kernel
# The candidate MUST compile the complete pinned GENERIC kernel with the reviewed
# static domain/driver overlay and shared wire core, using pinned host tools and
# target compiler. Artifact bytes/digest MUST come from the resulting ELF. Build
# and symbol success MUST NOT establish runtime transport or native admission.
pkgs.runCommand "overalls-freebsd-kernel-${if faultInjection then "fault" else "candidate"}-${sourceRevision}" {
  nativeBuildInputs = [
    pkgs.python3 llvm.clang llvm.clang-unwrapped llvm.lld llvm.llvm
    pkgs.flex pkgs.byacc pkgs.bison pkgs.gnumake pkgs.pkg-config pkgs.which
    pkgs.file pkgs.perl pkgs.libarchive pkgs.inetutils pkgs.time pkgs.patch pkgs.jq
  ];
  buildInputs = [ pkgs.zlib pkgs.libelf ];
  passthru = {
    inherit acceptCheck;
    inherit source sourceRevision sourceHash compiler patchHash configurationHash configurationInputs patchInputs buildId;
    inherit faultInjection;
    configuration = if faultInjection then ./GENERIC-OVERALLS-FAULT else ./GENERIC-OVERALLS;
    nativeAdmission = false;
    runtimeValidated = false;
  };
} ''
  set -euo pipefail
  test -s ${acceptCheck}/result
  unset STRIP
  export MAKEOBJDIRPREFIX="$TMPDIR/freebsd-obj"
  mkdir -p "$MAKEOBJDIRPREFIX"
  export CC=${llvm.clang}/bin/clang
  export CXX=${llvm.clang}/bin/clang++
  export CPP=${llvm.clang}/bin/clang-cpp
  export XCC='${llvm.clang-unwrapped}/bin/clang -resource-dir=${llvm.clang-unwrapped.lib}/lib/clang/19'
  export XCXX='${llvm.clang-unwrapped}/bin/clang++ -resource-dir=${llvm.clang-unwrapped.lib}/lib/clang/19'
  export XCPP='${llvm.clang-unwrapped}/bin/clang-cpp -resource-dir=${llvm.clang-unwrapped.lib}/lib/clang/19'
  export XLD=${llvm.lld}/bin/ld.lld
  export STRIPBIN=${llvm.llvm}/bin/llvm-strip
  export SOURCE_DATE_EPOCH=1
  cp -a --reflink=auto ${source} "$TMPDIR/freebsd-src"
  chmod -R u+w "$TMPDIR/freebsd-src"
  cd "$TMPDIR/freebsd-src"
  mkdir -p sys/dev/virtio/vsock
  sed -n '/^--- \/dev\/null$/,$p' ${abiPatch} | patch -p1 --forward --batch
  cp ${./virtio_vsock.c} sys/dev/virtio/vsock/virtio_vsock.c
  cp ${./ovfb_accept.h} sys/dev/virtio/vsock/ovfb_accept.h
  cp ${./vsock.h} sys/sys/vsock.h
  cp ${../common/ov_vsock.h} sys/dev/virtio/vsock/ov_vsock.h
  cp ${../common/ov_vsock.c} sys/dev/virtio/vsock/ov_vsock.c
  cat > sys/dev/virtio/vsock/overalls_vsock_build.h <<'BUILD'
  #define OV_VSOCK_BUILD_ID "${buildId}"
  BUILD
  cp ${./GENERIC-OVERALLS} sys/amd64/conf/GENERIC-OVERALLS
  ${lib.optionalString faultInjection ''
    cp ${./GENERIC-OVERALLS-FAULT} sys/amd64/conf/GENERIC-OVERALLS-FAULT
    cp ${./ovfb_fault.h} sys/dev/virtio/vsock/ovfb_fault.h
    chmod u+w sys/dev/virtio/vsock/virtio_vsock.c
    printf '\n#define OVFB_FAULT_INJECTION 1\n#include "ovfb_fault.h"\n' >> sys/dev/virtio/vsock/virtio_vsock.c
  ''}
  cat >> sys/conf/files <<'FILES'
  dev/virtio/vsock/virtio_vsock.c optional virtio_vsock
  dev/virtio/vsock/ov_vsock.c optional virtio_vsock
  FILES
  # FreeBSD's Linux cross-build bootstrap assumes FHS tools and glibc headers.
  # Normalize those paths to fixed Nix inputs and keep every bootstrap test.
  substituteInPlace tools/build/mk/Makefile.boot \
    --replace-fail '/usr/bin/ar' '${llvm.llvm}/bin/llvm-ar' \
    --replace-fail '/usr/bin/ranlib' '${llvm.llvm}/bin/llvm-ranlib' \
    --replace-fail '/usr/bin/nm' '${llvm.llvm}/bin/llvm-nm'
  substituteInPlace Makefile \
    --replace-fail '/usr/bin/env' '${pkgs.coreutils}/bin/env'
  substituteInPlace sys/conf/newvers.sh \
    --replace-fail 'date -r $SOURCE_DATE_EPOCH' 'date --date=@$SOURCE_DATE_EPOCH'
  substituteInPlace tools/build/Makefile \
    --replace-fail '/bin/bash:sh' '${pkgs.bash}/bin/bash:sh' \
    --replace-fail 'HOST_INCLUDE_ROOT=/usr/include' 'HOST_INCLUDE_ROOT=${pkgs.stdenv.cc.libc.dev}/include'
  substituteInPlace contrib/bmake/unit-tests/unexport-env.mk \
    --replace-fail '/bin:/usr/bin:/sbin:/usr/sbin' '${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}'
  substituteInPlace contrib/bmake/unit-tests/opt-keep-going-indirect.mk \
    --replace-fail 'env -i ' 'env -i PATH=${pkgs.coreutils}/bin '
  # glibc 2.43+ defines C23 qualifier-preserving macros for these search
  # functions under _GNU_SOURCE. FreeBSD 14.3 declares them as plain functions,
  # and its host tools assign their results to char *. The cross-build headers
  # emulate FreeBSD's headers on Linux, so remove the macros there (ISO C
  # 7.1.4) rather than relaxing -Werror.
  cat >> tools/build/cross-build/include/linux/string.h <<'HEADER'

  #undef memchr
  #undef strchr
  #undef strpbrk
  #undef strrchr
  #undef strstr
  HEADER
  cat >> tools/build/cross-build/include/linux/stdlib.h <<'HEADER'

  #undef bsearch
  HEADER
  # specspec.c alone among mtree's sources relied on glibc < 2.44 including
  # <sys/stat.h> transitively. Include it before mtree.h like its siblings, so
  # the cross-build st_mtimespec mapping renames the field and its uses alike.
  substituteInPlace contrib/mtree/specspec.c \
    --replace-fail '#include <err.h>' $'#include <sys/stat.h>\n\n#include <err.h>'
  # bmake's bootstrap self-tests (cmd-interrupt, deptgt-interrupt) send SIGINT
  # to bmake and expect its handler to run. A make that starts with SIGINT
  # ignored keeps it ignored, and a builder inherits the daemon's ignored
  # signals across exec: a daemon started as a non-interactive shell's
  # background job ignores SIGINT and SIGQUIT (POSIX). Restore the default
  # dispositions so the build does not depend on how the daemon was started.
  for stage in kernel-toolchain buildkernel; do
    ${pkgs.coreutils}/bin/env --default-signal=INT,QUIT \
      ${pkgs.python3}/bin/python3 tools/build/make.py -j16 \
      TARGET=amd64 TARGET_ARCH=amd64 __MAKE_CONF=/dev/null SRCCONF=/dev/null \
      HOST_INCLUDE_ROOT=${pkgs.stdenv.cc.libc.dev}/include \
      WITHOUT_TOOLCHAIN=yes WITHOUT_CLANG=yes WITHOUT_LLD=yes WITHOUT_LLDB=yes \
      KERNCONF=${kernelConfigurationName} NO_MODULES=yes "$stage"
  done
  kernel=$(find "$MAKEOBJDIRPREFIX" -type f -path '*/${kernelConfigurationName}/kernel' -print -quit)
  test -n "$kernel"
  mkdir -p "$out/share/overalls/native-kernel"
  cp "$kernel" "$out/kernel"
  evidence="$out/share/overalls/native-kernel"
  cat > "$TMPDIR/public-vsock-abi.c" <<'C'
  #include <sys/vsock.h>
  _Static_assert(AF_VSOCK == 45, "vendor family");
  _Static_assert(VMADDR_CID_HOST == 2, "host CID");
  _Static_assert(VMADDR_CID_ANY == 0xffffffffU, "wildcard CID");
  _Static_assert(VMADDR_PORT_ANY == 0xffffffffU, "wildcard port");
  _Static_assert(VSOCK_SO_BUILD_ID == 1, "build identity option");
  _Static_assert(VSOCK_BUILD_ID_SIZE == 65, "build identity size");
  _Static_assert(sizeof(struct sockaddr_vm) == 16, "address size");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_len) == 0, "length");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_family) == 1, "family");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_port) == 4, "port");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_cid) == 8, "CID");
  C
  ${llvm.clang-unwrapped}/bin/clang --target=x86_64-unknown-freebsd14.3 \
    -std=c11 -Werror -fsyntax-only -nostdinc -I "$(dirname "$kernel")" \
    -I "$TMPDIR/freebsd-src/sys" "$TMPDIR/public-vsock-abi.c"
  mkdir -p "$out/include/sys"
  cp ${./vsock.h} "$out/include/sys/vsock.h"
  ${llvm.llvm}/bin/llvm-readelf --file-header "$out/kernel" > "$evidence/elf-header"
  grep -Fq 'ELF64' "$evidence/elf-header"
  grep -Fq 'UNIX - FreeBSD' "$evidence/elf-header"
  grep -Fq 'Advanced Micro Devices X86-64' "$evidence/elf-header"
  ${llvm.llvm}/bin/llvm-nm "$out/kernel" > "$evidence/symbols"
  for symbol in ov_vsock_decode ov_vsock_receive ovfb_domain ovfb_driver; do
    grep -Eq " [Ttd] $symbol$" "$evidence/symbols"
  done
  ${if faultInjection then ''
    grep -Eq " [Tt] ovfb_fault_inject$" "$evidence/symbols"
    grep -Eq " [Tt] ovfb_fault_reset$" "$evidence/symbols"
  '' else ''
    if grep -Eq " [Tt] ovfb_fault_(inject|reset)$" "$evidence/symbols"; then exit 1; fi
  ''}
  bytes=$(stat -c %s "$out/kernel")
  test "$bytes" -gt 1024
  test "$bytes" -lt 134217728
  digest=$(sha256sum "$out/kernel" | cut -d ' ' -f1)
  jq -n --argjson bytes "$bytes" --arg sha256 "$digest" \
    --arg source_revision '${sourceRevision}' --arg patch_hash '${patchHash}' \
    --arg configuration_hash '${configurationHash}' --arg compiler '${compiler}' \
    '{bytes:$bytes,sha256:$sha256,source_revision:$source_revision,
      patch_hash:$patch_hash,configuration_hash:$configuration_hash,compiler:$compiler}' \
    > "$evidence/provenance.json"
  jq -n --slurpfile kernel "$evidence/provenance.json" \
    --arg source_hash '${sourceHash}' --argjson patch_inputs '${builtins.toJSON patchInputs}' \
    --arg build_id '${buildId}' \
    '{version:1,os:"freebsd",source_hash:$source_hash,patch_inputs:$patch_inputs,
      build_id:$build_id,boot_identity_oid:"kern.overalls_vsock_build_id",
      kernel:$kernel[0],compiled:true,linked:true,symbol_checked:true,public_abi_checked:true,
      fault_injection:${lib.boolToString faultInjection},
      runtime_validated:false,native_admission:false}' > "$evidence/build-receipt.json"
  printf '%s\n' '${buildId}' > "$evidence/build-id"
  cp ${if faultInjection then ./GENERIC-OVERALLS-FAULT else ./GENERIC-OVERALLS} "$evidence/kernel.conf"
''
