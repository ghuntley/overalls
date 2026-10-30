# packageSet is lib.assemble's single package-set constructor (ADR-0269); the
# harness variants differ from production only by their explicit flags.
{ pkgs, nixpkgs, packageSet }:
let
  inherit (pkgs) lib;
  productionPackages = packageSet { };
  packages = packageSet { antithesisSdk = true; };
  guestPackages = packageSet {
    antithesisSdk = true;
    antithesisGuest = true;
  };
  hostPackages = packageSet {
    antithesisSdk = true;
    antithesisGuest = true;
    antithesisIntegratedHost = true;
  };
  closure = import ./closures.nix { inherit pkgs; };
  guest = import ./guest.nix {
    inherit pkgs;
    inherit (packages) terminald lyraLinux vscodeWeb vscodeWebBroker;
  };
  # @cc [owner:ghuntley,label:security;verification] private-guest-bootstrap-root
  # The public bootstrap certificate MUST have no retained signing key. Real
  # private trust MUST arrive through boot-bound delivery before readiness.
  privateGuest = import ./guest.nix {
    inherit pkgs;
    inherit (packages) terminald lyraLinux vscodeWeb vscodeWebBroker;
    privateServiceRoots = [ ../fixtures/guest-bootstrap-ca.crt ];
  };
  router = import ./storage-router.nix { inherit nixpkgs; packages = productionPackages; };
  host = import ./lilly-host.nix { inherit nixpkgs guest; packages = hostPackages; };
  privateHost = import ./lilly-host.nix {
    inherit nixpkgs;
    packages = hostPackages;
    guest = privateGuest;
    privateServices = true;
  };
  recorderHost = import ./recorder-host.nix { inherit nixpkgs; packages = productionPackages; };
  # @cc [owner:ghuntley,label:build] router-image-exact-artifacts
  # The router image MUST carry the exact stable-NixOS root, kernel, initrd and
  # toplevel identity selected at evaluation, with a checked byte/hash manifest.
  routerImage = pkgs.runCommand "overalls-antithesis-router-image" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq ];
  } ''
    mkdir -p "$out"
    cp ${router.rootImage}/overalls-storage-router.qcow2 "$out/root.qcow2"
    cp ${router.kernel}/bzImage "$out/kernel"
    cp ${router.initrd}/initrd "$out/initrd"
    rootBytes=$(stat -c %s "$out/root.qcow2")
    kernelBytes=$(stat -c %s "$out/kernel")
    initrdBytes=$(stat -c %s "$out/initrd")
    rootSha=$(sha256sum "$out/root.qcow2" | cut -d ' ' -f 1)
    kernelSha=$(sha256sum "$out/kernel" | cut -d ' ' -f 1)
    initrdSha=$(sha256sum "$out/initrd" | cut -d ' ' -f 1)
    jq -n --arg top "${router.toplevel}" \
      --arg rootSha "$rootSha" --arg kernelSha "$kernelSha" \
      --arg initrdSha "$initrdSha" --argjson rootBytes "$rootBytes" \
      --argjson kernelBytes "$kernelBytes" --argjson initrdBytes "$initrdBytes" \
      '{version:1,root:{bytes:$rootBytes,sha256:$rootSha},kernel:{bytes:$kernelBytes,sha256:$kernelSha},initrd:{bytes:$initrdBytes,sha256:$initrdSha},toplevel:$top}' \
      > "$out/manifest.json"
  '';
  routerRunner = pkgs.runCommand "overalls-antithesis-router-runner" {} ''
    mkdir -p "$out"
    cp ${../emulation/storage/runner.py} "$out/runner.py"
    cp ${../emulation/storage/smoke.py} "$out/smoke.py"
  '';
  routerConfig = pkgs.writeText "overalls-antithesis-router-config.json" (builtins.toJSON {
    image_dir = "/opt/overalls/routervm";
    state_dir = "/var/lib/routervm/state";
    runtime_dir = "/run/routervm";
    qemu = "${router.qemu}/bin/qemu-system-x86_64";
    qemu_img = "${router.qemu}/bin/qemu-img";
  });
  # @cc [owner:ghuntley,label:build;storage] host-image-exact-artifacts
  # The inner Lilly host image MUST carry the exact root, kernel, initrd and
  # toplevel selected at evaluation with checked byte/hash identity.
  hostImageFor = selectedHost: pkgs.runCommand "overalls-antithesis-lilly-host-image" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq ];
  } ''
    mkdir -p "$out"
    cp ${selectedHost.rootImage}/overalls-lilly-host.qcow2 "$out/root.qcow2"
    cp ${selectedHost.kernel}/bzImage "$out/kernel"
    cp ${selectedHost.initrd}/initrd "$out/initrd"
    rootBytes=$(stat -c %s "$out/root.qcow2")
    kernelBytes=$(stat -c %s "$out/kernel")
    initrdBytes=$(stat -c %s "$out/initrd")
    rootSha=$(sha256sum "$out/root.qcow2" | cut -d ' ' -f 1)
    kernelSha=$(sha256sum "$out/kernel" | cut -d ' ' -f 1)
    initrdSha=$(sha256sum "$out/initrd" | cut -d ' ' -f 1)
    jq -n --arg top "${selectedHost.toplevel}" \
      --arg rootSha "$rootSha" --arg kernelSha "$kernelSha" \
      --arg initrdSha "$initrdSha" --argjson rootBytes "$rootBytes" \
      --argjson kernelBytes "$kernelBytes" --argjson initrdBytes "$initrdBytes" \
      '{version:1,root:{bytes:$rootBytes,sha256:$rootSha},kernel:{bytes:$kernelBytes,sha256:$kernelSha},initrd:{bytes:$initrdBytes,sha256:$initrdSha},toplevel:$top}' \
      > "$out/manifest.json"
  '';
  hostImage = hostImageFor host;
  privateHostImage = hostImageFor privateHost;
  hostRunner = pkgs.runCommand "overalls-antithesis-lilly-host-runner" {} ''
    mkdir -p "$out"
    cp ${../emulation/host/runner.py} "$out/runner.py"
  '';
  hostConfig = pkgs.writeText "overalls-antithesis-lilly-host-config.json" (builtins.toJSON {
    image_dir = "/opt/overalls/lilly-hostvm";
    state_dir = "/var/lib/lilly-hostvm/state";
    runtime_dir = "/run/lilly-hostvm";
    secret_dir = "/run/overalls-secrets";
    observation_dir = "/run/overalls-host-observation";
    fault_dir = "/run/overalls-fault-control";
    qemu = "${host.qemu}/bin/qemu-system-x86_64";
    qemu_img = "${host.qemu}/bin/qemu-img";
  });
  # @cc [owner:ghuntley,label:build;verification] recorder-host-exact-artifacts
  # The recorder-host VM MUST carry the exact root, kernel, initrd and toplevel
  # selected at evaluation with a checked byte/hash manifest.
  recorderHostImage = pkgs.runCommand "overalls-antithesis-recorder-host-image" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.jq ];
  } ''
    mkdir -p "$out"
    cp ${recorderHost.rootImage}/overalls-recorder-host.qcow2 "$out/root.qcow2"
    cp ${recorderHost.kernel}/bzImage "$out/kernel"
    cp ${recorderHost.initrd}/initrd "$out/initrd"
    rootBytes=$(stat -c %s "$out/root.qcow2")
    kernelBytes=$(stat -c %s "$out/kernel")
    initrdBytes=$(stat -c %s "$out/initrd")
    rootSha=$(sha256sum "$out/root.qcow2" | cut -d ' ' -f 1)
    kernelSha=$(sha256sum "$out/kernel" | cut -d ' ' -f 1)
    initrdSha=$(sha256sum "$out/initrd" | cut -d ' ' -f 1)
    jq -n --arg top "${recorderHost.toplevel}" \
      --arg rootSha "$rootSha" --arg kernelSha "$kernelSha" \
      --arg initrdSha "$initrdSha" --argjson rootBytes "$rootBytes" \
      --argjson kernelBytes "$kernelBytes" --argjson initrdBytes "$initrdBytes" \
      '{version:1,root:{bytes:$rootBytes,sha256:$rootSha},kernel:{bytes:$kernelBytes,sha256:$kernelSha},initrd:{bytes:$initrdBytes,sha256:$initrdSha},toplevel:$top}' \
      > "$out/manifest.json"
  '';
  recorderHostRunner = pkgs.runCommand "overalls-antithesis-recorder-host-runner" {} ''
    mkdir -p "$out"
    cp ${../emulation/recorder/runner.py} "$out/runner.py"
  '';
  recorderHostConfig = pkgs.writeText "overalls-antithesis-recorder-host-config.json" (builtins.toJSON {
    image_dir = "/opt/overalls/recorder-hostvm";
    state_dir = "/var/lib/recorder-hostvm/state";
    runtime_dir = "/run/recorder-hostvm";
    request_dir = "/run/overalls-recorder-requests";
    result_dir = "/run/overalls-recorder-results";
    observation_dir = "/run/overalls-recorder-observation";
    qemu = "${recorderHost.qemu}/bin/qemu-system-x86_64";
    qemu_img = "${recorderHost.qemu}/bin/qemu-img";
    mkfs_ext4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
  });
  enricoGitOwner = pkgs.callPackage ../../nix/domains/artifacts/applications/enrico-git-owner.nix {};
  enricoTools = pkgs.buildEnv {
    name = "overalls-antithesis-enrico-tools";
    paths = [ pkgs.git enricoGitOwner ];
    pathsToLink = [ "/bin" ];
  };
  sdkWriter = pkgs.stdenv.mkDerivation {
    pname = "overalls-antithesis-sdk-writer";
    version = "1";
    src = ../sdk/native/sdk_writer.c;
    dontUnpack = true;
    dontConfigure = true;
    strictDeps = true;
    buildPhase = ''
      runHook preBuild
      cc -std=c11 -O2 -Wall -Wextra -Werror -o sdk_writer "$src"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm0755 sdk_writer "$out/bin/sdk_writer"
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
  pythonWheels = import ./python-wheels.nix { inherit pkgs; };
  controlPeerTools = pkgs.buildEnv {
    name = "overalls-antithesis-control-peer-tools";
    paths = [ packages.toolchain.elixir packages.toolchain.erlang ];
    pathsToLink = [ "/bin" ];
  };
  # @cc [owner:ghuntley,label:build] control-peer-protocol-runtime
  # The workload's real control peer MUST compile maintained protocol sources
  # with the pinned Elixir/OTP toolchain and ship only its compiled runtime.
  controlPeerProtocol = pkgs.runCommand "overalls-antithesis-control-peer-protocol" {
    nativeBuildInputs = [ packages.toolchain.elixir packages.toolchain.erlang pkgs.findutils ];
    env.ERL_FLAGS = "+S 4:4";
  } ''
    mkdir -p "$out/ebin"
    cd ${../../protocol}
    find lib -name '*.ex' -type f -print | sort | xargs elixirc -o "$out/ebin"
  '';
  backupModules = pkgs.runCommand "overalls-antithesis-backup-modules" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p "$out"
    cp ${../../nix/domains/system/backups}/*.py "$out/"
  '';
  # @cc [owner:ghuntley,label:build;verification] recorder-independent-images
  # The producer, durable recorder and trace spool MUST ship production
  # implementations. The container graph keeps separate images; the integrated
  # host runs separate NixOS services with real kernel UID/cgroup identity.
  # Packaging alone MUST NOT claim authenticated admission.
  requestAccounting = pkgs.runCommand "overalls-antithesis-request-accounting" {
    nativeBuildInputs = [ packages.toolchain.elixir packages.toolchain.erlang pkgs.findutils ];
    env.ERL_FLAGS = "+S 4:4";
  } ''
    mkdir -p "$out/ebin"
    cd ${../../elixir/request_accounting}
    find lib -name '*.ex' -type f -print | sort | xargs elixirc -o "$out/ebin"
  '';
  traceFixtures = pkgs.runCommand "overalls-antithesis-trace-fixtures" {} ''
    mkdir -p "$out"
    cp ${../../nix/verification/tests/fixtures/trace-spool/request.hex} "$out/request.hex"
    cp ${../../nix/verification/tests/fixtures/trace-spool/batch.hex} "$out/batch.hex"
  '';
  requestRecorder = pkgs.callPackage ../../nix/domains/system/otel-guest/receiver.nix {};
  traceSpool = pkgs.callPackage ../../nix/domains/artifacts/infrastructure/trace-spool.nix {};
  otpNames = [ "marshall" "lilly" "audi" "porsche" "ziggy" "galileo" "brady" "enrico" ];
  otpContext = name: closure.mkContext {
    inherit name;
    application = name;
    release = packages.${name};
    extraRoots = [ sdkWriter ] ++ lib.optionals (name == "enrico") [ enricoTools ]
      ++ lib.optionals (name == "porsche") [ pkgs.openssh ]
      ++ lib.optionals (name == "lilly") [ packages.hostTools pkgs.pkgsStatic.firecracker ];
    extraLinks = {
      "opt/antithesis/sdk_writer" = "${sdkWriter}/bin/sdk_writer";
    } // lib.optionalAttrs (name == "enrico") {
      "opt/overalls/enrico-tools" = toString enricoTools;
    } // lib.optionalAttrs (name == "porsche") {
      "opt/overalls/openssh" = toString pkgs.openssh;
    };
  };
  # @cc [owner:ghuntley,label:build] harness-release-variants
  # Container releases MUST use maintained source, production Mix mode and the
  # explicit harness selector. The guest executor has its own Lilly derivation.
  # The container guest variant uses STUB storage (no ZFS); it carries the same
  # immutable TCG guest image as guest-vmm so its catalog can verify and
  # advertise exactly that image ID.
  contexts = lib.genAttrs otpNames otpContext // {
    lilly-guest = closure.mkContext {
      name = "lilly-guest";
      application = "lilly";
      release = guestPackages.lilly;
      extraRoots = [ sdkWriter guestPackages.hostTools pkgs.pkgsStatic.firecracker guest.image ];
      extraLinks = {
        "opt/antithesis/sdk_writer" = "${sdkWriter}/bin/sdk_writer";
        "opt/overalls/guest-vmm/image" = toString guest.image;
      };
    };
    # The Python assertion catalog is not a Nix input: ``selection.py stage``
    # writes the selection-scoped tree under antithesis/build/selected-test and
    # the Dockerfile copies it to /opt/overalls-antithesis/catalog, so the hosted
    # instrumentor declares only assertions reachable from the selected commands.
    # /opt/antithesis/catalog is a single symlink to that tree's ``workload``
    # module: the instrumentor catalogs each item under /opt/antithesis/catalog
    # (or the resolved link target) as one root, and the Python SDK registers
    # one root's catalog per process. One resolved root therefore declares every
    # selected assertion in every workload process; a real directory holding
    # the packages was split into one root per package and only the voted
    # package's catalog registered (run 8e582f650dd7092cda983705eb7b0e05-65-0).
    workload = closure.mkContext {
      name = "workload";
      # STUB (harness): libfaketime is preloaded only into a workload-selected
      # backup coordinator run to step its wall clock backward; production
      # hosts and every other workload process never load it.
      extraRoots = [ pkgs.python313 pythonWheels pkgs.git controlPeerTools controlPeerProtocol pkgs.restic backupModules traceSpool pkgs.libfaketime ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/libfaketime" = toString pkgs.libfaketime;
        "opt/overalls/python-deps" = toString pythonWheels;
        "opt/overalls/control-peer-tools" = toString controlPeerTools;
        "opt/overalls/control-peer" = toString controlPeerProtocol;
        "opt/overalls/restic" = toString pkgs.restic;
        "opt/overalls/git" = toString pkgs.git;
        "opt/overalls/backup-modules" = toString backupModules;
        "opt/overalls/trace-spool" = toString traceSpool;
        "opt/antithesis/catalog" = "/opt/overalls-antithesis/catalog/workload";
      };
    };
    origin = closure.mkContext {
      name = "origin";
      extraRoots = [ pkgs.python313 pkgs.git ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/git" = toString pkgs.git;
      };
    };
    smtp = closure.mkContext {
      name = "smtp";
      extraRoots = [ pkgs.python313 ];
      extraLinks."opt/overalls/python" = toString pkgs.python313;
    };
    producer-peer = closure.mkContext {
      name = "producer-peer";
      extraRoots = [ controlPeerTools requestAccounting traceFixtures ];
      extraLinks = {
        "opt/overalls/producer-tools" = toString controlPeerTools;
        "opt/overalls/request-accounting" = toString requestAccounting;
        "opt/overalls/trace-fixtures" = toString traceFixtures;
      };
    };
    request-recorder = closure.mkContext {
      name = "request-recorder";
      extraRoots = [ requestRecorder ];
      extraLinks."opt/overalls/request-recorder" = toString requestRecorder;
    };
    trace-spool = closure.mkContext {
      name = "trace-spool";
      extraRoots = [ traceSpool ];
      extraLinks."opt/overalls/trace-spool" = toString traceSpool;
    };
    # OpenSSH generates the synthetic Marshall SSH host CA with the other secrets.
    pg = closure.mkContext {
      name = "pg";
      extraRoots = [ pkgs.postgresql_18 pkgs.openssh ];
      extraLinks = {
        "opt/overalls/postgresql" = toString pkgs.postgresql_18;
        "opt/overalls/openssh" = toString pkgs.openssh;
      };
    };
    guest-vmm = closure.mkContext {
      name = "guest-vmm";
      extraRoots = [ guest.image guest.runner guest.server guest.toolConfig guest.qemu guest.vsockBackend pkgs.python313 pkgs.iproute2 ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/guest-vmm/image" = toString guest.image;
        "opt/overalls/guest-vmm/runner" = "${guest.runner}/bin/overalls-tcg-guest";
        "opt/overalls/guest-vmm/runner.py" = "${guest.server}/libexec/runner.py";
        "opt/overalls/guest-vmm/server.py" = "${guest.server}/libexec/server.py";
        "opt/overalls/guest-vmm/tools.json" = toString guest.toolConfig;
      };
    };
    router-vmm = closure.mkContext {
      name = "router-vmm";
      extraRoots = [ routerImage routerRunner routerConfig router.qemu router.toplevel pkgs.python313 ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/routervm/root.qcow2" = "${routerImage}/root.qcow2";
        "opt/overalls/routervm/kernel" = "${routerImage}/kernel";
        "opt/overalls/routervm/initrd" = "${routerImage}/initrd";
        "opt/overalls/routervm/manifest.json" = "${routerImage}/manifest.json";
        "opt/overalls/routervm/runner.py" = "${routerRunner}/runner.py";
        "opt/overalls/routervm/smoke.py" = "${routerRunner}/smoke.py";
        "etc/routervm/config.json" = toString routerConfig;
      };
    };
    host-vmm = closure.mkContext {
      name = "host-vmm";
      extraRoots = [ hostImage hostRunner hostConfig host.qemu host.toplevel pkgs.python313 ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/lilly-hostvm/root.qcow2" = "${hostImage}/root.qcow2";
        "opt/overalls/lilly-hostvm/kernel" = "${hostImage}/kernel";
        "opt/overalls/lilly-hostvm/initrd" = "${hostImage}/initrd";
        "opt/overalls/lilly-hostvm/manifest.json" = "${hostImage}/manifest.json";
        "opt/overalls/lilly-hostvm/runner.py" = "${hostRunner}/runner.py";
        "etc/lilly-hostvm/config.json" = toString hostConfig;
      };
    };
    # @cc [owner:ghuntley,label:build;security] private-host-image-selection
    # The private host context MUST package the private host and guest image,
    # while retaining runtime-only credential generation and enrollment.
    private-host-vmm = closure.mkContext {
      name = "private-host-vmm";
      extraRoots = [ privateHostImage hostRunner hostConfig privateHost.qemu privateHost.toplevel pkgs.python313 ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/lilly-hostvm/root.qcow2" = "${privateHostImage}/root.qcow2";
        "opt/overalls/lilly-hostvm/kernel" = "${privateHostImage}/kernel";
        "opt/overalls/lilly-hostvm/initrd" = "${privateHostImage}/initrd";
        "opt/overalls/lilly-hostvm/manifest.json" = "${privateHostImage}/manifest.json";
        "opt/overalls/lilly-hostvm/runner.py" = "${hostRunner}/runner.py";
        "etc/lilly-hostvm/config.json" = toString hostConfig;
      };
    };
    recorder-host-vmm = closure.mkContext {
      name = "recorder-host-vmm";
      extraRoots = [ recorderHostImage recorderHostRunner recorderHostConfig recorderHost.qemu recorderHost.toplevel pkgs.python313 pkgs.e2fsprogs ];
      extraLinks = {
        "opt/overalls/python" = toString pkgs.python313;
        "opt/overalls/recorder-hostvm/root.qcow2" = "${recorderHostImage}/root.qcow2";
        "opt/overalls/recorder-hostvm/kernel" = "${recorderHostImage}/kernel";
        "opt/overalls/recorder-hostvm/initrd" = "${recorderHostImage}/initrd";
        "opt/overalls/recorder-hostvm/manifest.json" = "${recorderHostImage}/manifest.json";
        "opt/overalls/recorder-hostvm/runner.py" = "${recorderHostRunner}/runner.py";
        "etc/recorder-hostvm/config.json" = toString recorderHostConfig;
      };
    };
  };
in
{ inherit contexts packages guestPackages hostPackages sdkWriter pythonWheels guest privateGuest router routerImage host hostImage privateHost privateHostImage recorderHost recorderHostImage; }
