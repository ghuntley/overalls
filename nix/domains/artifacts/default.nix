{ pkgs, encryptedCrashDumps ? false, privateServiceRoots ? [ ], antithesisSdk ? false, antithesisGuest ? false, antithesisIntegratedHost ? false
  # @cc [owner:ghuntley,label:build] buck2-artifacts-replace-leaves
  # Buck2-built first-party artifacts imported by lib.assemble. A present key
  # MUST replace the Nix build of that leaf for every consumer in this set, so
  # no output mixes a Buck2 build with a Nix build of the same component
  # (ADR-0269). Absent keys keep the Nix build until their rule lands.
, artifacts ? { }
}:
assert !antithesisGuest || antithesisSdk;
assert !antithesisIntegratedHost || antithesisGuest;
let
  secretPackages = import ./secrets { inherit pkgs; };
  inherit (pkgs) lib;
  toolchain = import ./infrastructure/toolchain.nix { inherit pkgs encryptedCrashDumps; };
  # Build tools use the same pinned OTP without requiring a diagnostic key.
  # Only the shipped runtime needs encryption; Rebar never becomes release ERTS.
  plainToolchain = import ./infrastructure/toolchain.nix { inherit pkgs; };
  plainBeam = pkgs.beamMinimal29Packages.overrideScope (_final: _previous: {
    inherit (plainToolchain) erlang elixir;
  });
  beam = pkgs.beamMinimal29Packages.overrideScope (_final: _previous: {
    inherit (toolchain) erlang elixir;
  } // lib.optionalAttrs encryptedCrashDumps {
    inherit (plainBeam) rebar rebar3 hex;
  });
  hashes = builtins.fromJSON (builtins.readFile ./dependency-hashes.json);
  source = application: import ./applications/source.nix { inherit lib application antithesisSdk; };
  version = "0.1.0";
  hostLock = import ./hosts/host-tools.nix { inherit pkgs; };
  terminald = import ./infrastructure/terminald.nix { inherit pkgs; };
  terminaldChecks = import ./infrastructure/terminald-checks.nix { inherit pkgs; };
  # Hash-pinned Windows native runtime inputs. This is a staging closure only:
  # it does not contain the Code OSS bundle or broker and cannot widen
  # windows-v1 editor capability (ADR-0171).
  windowsEditorRuntime = import ./vscode-web/windows-runtime.nix { inherit pkgs; };
  windowsEditorSource = import ./vscode-web/windows-source.nix { inherit pkgs; };
  mkWindowsEditorBundle = import ./vscode-web/windows-bundle.nix { inherit pkgs; source = windowsEditorSource; };
  windowsEditorBroker = import ./vscode-web-broker/windows.nix { inherit pkgs; inherit (lyra) toolchain; };
  # @cc [owner:ghuntley,label:build;security] windows-editor-candidate-constructor
  # The Windows editor candidate MUST be assembled only from a caller-supplied
  # native bundle directory and its reviewed recursive NAR hash. The helper
  # selects the separate v7 windows-editor-v1 contract and keeps the image's
  # editor capability false; it MUST NOT alter the selected fleet catalog.
  mkWindowsEditorCandidate = { nativeBuild, narHash, imageName ? "lilly-windows-editor-candidate-x86_64" }:
    assert builtins.match "sha256-[A-Za-z0-9+/]{43}=" narHash != null;
    let editorBundle = mkWindowsEditorBundle { inherit nativeBuild narHash; };
    in mkWindowsGuest {
      inherit imageName editorBundle;
      agents = lyraWindows;
      terminald = terminaldWindows;
      editorBroker = windowsEditorBroker;
    };
  codingClis = import ./guest/coding-clis.nix { inherit pkgs; };
  # Google emulator/system-image inputs are accepted explicitly here so the
  # Android guest remains reproducible and does not depend on host SDK state.
  # Android SDK components are unfree in nixpkgs. Re-import the same pinned
  # input with only the package-level license policy changed; no channel or
  # host SDK is consulted.
  androidPkgs = import pkgs.path {
    system = pkgs.system;
    config.allowUnfree = true;
  };
  androidEnvironment = androidPkgs.callPackage (pkgs.path + "/pkgs/development/mobile/androidenv") {
    licenseAccepted = true;
  };
  androidSdk = (androidEnvironment.composeAndroidPackages {
    cmdLineToolsVersion = "latest";
    includeEmulator = true;
    includeSystemImages = true;
    platformVersions = [ "34" "35" "36" ];
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ "x86_64" ];
  }).androidsdk;
  githubTools = import ./guest/github { inherit pkgs; };
  # Patched static Firecracker/jailer pair (ADR-0169); the only VMM Lilly runs.
  inherit (import ./infrastructure/firecracker.nix { inherit pkgs; }) vmm;
  # UEFI firmware Firecracker loads as its PVH "kernel" for Windows guests.
  windowsFirmware = import ./guest/windows/firmware.nix { inherit pkgs; };
  # DEBUG build with firmware tracing on the serial console, for boot diagnosis.
  windowsFirmwareDebug = import ./guest/windows/firmware.nix { inherit pkgs; debug = true; };
  mkWindowsGuest = import ./guest/windows { inherit pkgs; firmware = windowsFirmware; };
  # Agentless image (ADR-0170) carrying the vsock transport probe (ADR-0171 gate 1).
  windowsGuest = mkWindowsGuest { agents = lyraWindows; };
  # The windows-v1 image: the same installation with the readiness and trust
  # daemons declared in its manifest (ADR-0171 gate 2).
  windowsGuestAgents = mkWindowsGuest { agents = lyraWindows; terminald = terminaldWindows; guestAgents = "windows-v1"; };
  # Windows editor runtime bring-up image. The runtime is staged for native
  # diagnostics only; this remains a windows-v1 manifest with editor=false.
  windowsGuestRuntime = mkWindowsGuest {
    agents = lyraWindows;
    terminald = terminaldWindows;
    editorRuntime = windowsEditorRuntime;
    guestAgents = "windows-v1";
  };
  windowsGuestPublished = import ./guest/windows/published.nix { inherit pkgs; };
  # Variant that loads the virtio storage driver with drvload instead of the
  # answer file's DriverPaths; kept for diagnosing Setup's WinPE initialization.
  windowsGuestDrvload = mkWindowsGuest { winpeDriverLoad = "drvload"; };
  windowsBoot = import ./guest/windows/boot.nix { inherit pkgs vmm; };
  lyra = import ./infrastructure/lyra.nix { inherit pkgs; };
  lyraWindows = lyra.windows;
  githubBootstrapRelease = import ./infrastructure/executor-bootstrap.nix { inherit pkgs lyra; };
  nativeAgentPayload = import ./guest/native-agents.nix { inherit pkgs lyra terminald; };
  # Native guest daemons use each OS's reviewed vsock ABI and are shipped
  # separately from the workstation CLI for native image assembly.
  lyraNative = pkgs.runCommand "overalls-native-agents" {} ''
    mkdir -p "$out/freebsd" "$out/illumos"
    cp -a ${nativeAgentPayload.freebsd}/. "$out/freebsd/"
    cp -a ${nativeAgentPayload.illumos}/. "$out/illumos/"
    cp ${lyra.native}/manifest.json "$out/lyra-manifest.json"
    cp ${terminald.native}/manifest.json "$out/terminald-manifest.json"
  '';
  # ConPTY terminal daemon for windows-v1 guests (ADR-0171 gate 4).
  terminaldWindows = import ./infrastructure/terminald-windows.nix { inherit pkgs; inherit (lyra) toolchain; };
  lyraLinux = pkgs.runCommand "overalls-linux-cli" {} ''
    mkdir -p "$out/bin"
    cp ${lyra}/bin/linux-amd64 "$out/bin/overalls"
    cp ${lyra}/bin/overalls-ssh-authorize "$out/bin/overalls-ssh-authorize"
    cp ${lyra}/bin/overalls-host-certificate "$out/bin/overalls-host-certificate"
    cp ${lyra}/bin/overalls-trustd "$out/bin/overalls-trustd"
    cp ${lyra}/bin/overalls-workspaced "$out/bin/overalls-workspaced"
    chmod 0755 "$out/bin/overalls" "$out/bin/overalls-ssh-authorize" "$out/bin/overalls-trustd" "$out/bin/overalls-host-certificate" "$out/bin/overalls-workspaced"
  '';
  hostTools = pkgs.buildEnv {
    name = "lilly-host-tools";
    paths = [
      pkgs.coreutils pkgs.diffutils pkgs.util-linux pkgs.iproute2 pkgs.nftables pkgs.procps
      pkgs.zfs pkgs.openssh toolchain.elixir toolchain.erlang hostLock
    ];
  };

  nestingProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis;
    privateServiceRoots = [ ];
    imageName = "inception-inner-nesting-probe-x86_64";
    minimumMemoryBytes = 536870912;
    extraModules = [ ./guest/nesting-probe/minimal.nix ];
  };

  # @cc [owner:ghuntley,label:build] release-dependency-hashes
  # Mix dependency fetches MUST be fixed-output derivations checked against
  # reviewed hashes; the normal release build MUST run with Hex offline.

  # @cc [owner:ghuntley,label:build] harness-dependency-selection
  # Fixed-output Mix dependency fetches and release compilation MUST use the
  # same explicit harness/guest/integrated-host selectors and production Mix
  # environment.
  dependencies = lib.genAttrs [ "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" "peach" "susan" ] (application:
    beam.fetchMixDeps {
      pname = "overalls-${application}-deps";
      inherit version;
      src = source application;
      sourceRoot = "source/${application}";
      hash = hashes.${application};
      env = {
        ERL_FLAGS = "+S 4:4";
        ERL_CRASH_DUMP_PUBLIC_KEY = if encryptedCrashDumps then "${./build-crash-dump-public.pem}" else "";
      } // lib.optionalAttrs antithesisSdk {
        ANTITHESIS_HARNESS = "1";
        MIX_ENV = "prod";
      } // lib.optionalAttrs (antithesisGuest && application == "lilly") {
        ANTITHESIS_GUEST = "1";
      } // lib.optionalAttrs (antithesisIntegratedHost && application == "lilly") {
        ANTITHESIS_INTEGRATED_HOST = "1";
      };
      postInstall = ''
        cp mix.lock "$out/.overalls-mix.lock"
      '';
    });

  cedarCargo = pkgs.rustPlatform.fetchCargoVendor {
    name = "marshall-cedar";
    src = ../../../marshall/native/marshall_cedar;
    hash = hashes.cedarCargo;
  };
  cedarLints = import ./applications/marshall-cedar-lints.nix { inherit pkgs cedarCargo; };

  # Every Mix application with fixed-output dependencies, keyed like
  # dependency-hashes.json; adding one to `dependencies` adds it here.
  mixReleases = lib.genAttrs (lib.attrNames dependencies) (application: artifacts.${application} or (release application));

  # @cc [owner:ghuntley,label:build;security] dependency-pin-registry
  # Each entry names the lock files it builds from, the derivation that MUST
  # build after those locks change, and the dependency-hashes.json keys of its
  # fixed-output fetches. scripts/mix_security_upgrades.exs and
  # scripts/cargo_security_upgrades.exs refresh hashes and build only through
  # this registry; the Cargo script refuses a tracked Cargo.lock missing here.
  dependencyPins = {
    mix = lib.mapAttrs (application: build: {
      locks = [ "${application}/mix.lock" ];
      inherit build;
      hashes = { ${application} = dependencies.${application}; }
        // lib.optionalAttrs (application == "marshall") { inherit cedarCargo; };
    }) mixReleases;
    cargo = let
      nativeCrates = lib.attrNames (lib.filterAttrs (name: type:
        type == "directory" && builtins.pathExists (../../../lilly/native + "/${name}/Cargo.lock"))
        (builtins.readDir ../../../lilly/native));
    in {
      lyra = { locks = [ "lyra/Cargo.lock" ]; build = lyra; hashes = { }; };
      terminald = {
        locks = [ "nix/domains/artifacts/terminald/Cargo.lock" ];
        build = pkgs.linkFarmFromDrvs "terminald-pins" [ terminald terminaldWindows ];
        hashes = { };
      };
      lilly-native = {
        locks = map (name: "lilly/native/${name}/Cargo.lock") nativeCrates;
        build = hostLock;
        hashes = { };
      };
      enrico-git-owner = {
        locks = [ "enrico/native/git-owner/Cargo.lock" ];
        build = import ./applications/enrico-git-owner.nix { inherit pkgs; };
        hashes = { };
      };
      trace-spool = {
        locks = [ "elixir/diagnostics/native/spool/Cargo.lock" ];
        build = import ./infrastructure/trace-spool.nix { inherit pkgs; };
        hashes = { };
      };
      vscode-web-broker = {
        locks = [ "nix/domains/artifacts/vscode-web-broker/Cargo.lock" ];
        build = import ./vscode-web-broker { inherit pkgs; };
        hashes = { };
      };
      mila-rust = {
        locks = [ "mila/rust/Cargo.lock" ];
        build = (import ./mila/rust.nix { inherit pkgs; }).package;
        hashes = { };
      };
      otel-guest-receiver = {
        locks = [ "nix/domains/system/otel-guest/receiver/Cargo.lock" ];
        build = pkgs.callPackage ../system/otel-guest/receiver.nix { };
        hashes = { };
      };
      mila-linux-native = {
        locks = [ "mila/native/linux/Cargo.lock" ];
        build = (import ./mila { inherit pkgs; }).linuxNative;
        hashes = { };
      };
      observability-runtimes = {
        locks = [ "nix/domains/system/observability-runtimes/Cargo.lock" ];
        build = import ../system/observability-runtimes.nix { inherit pkgs; };
        hashes = { };
      };
    };
  };

  release = application:
    let
      isMarshall = application == "marshall";
      isLilly = application == "lilly";
      metadata = pkgs.writeText "${application}-release.json" (builtins.toJSON ({
        format = 1;
        inherit application;
        platform = pkgs.stdenv.hostPlatform.system;
        elixir = toolchain.elixir.version;
        otp = toolchain.erlang.version;
        build = "nix-source";
        encrypted_crash_dumps = encryptedCrashDumps;
      } // lib.optionalAttrs antithesisSdk {
        antithesis_sdk = true;
        antithesis_guest = antithesisGuest && isLilly;
        antithesis_integrated_host = antithesisIntegratedHost && isLilly;
      } // lib.optionalAttrs isLilly {
        host_tools = "${hostTools}";
        firecracker = "${vmm}/bin/firecracker";
        jailer = "${vmm}/bin/jailer";
        unshare = "${pkgs.util-linux.bin}/bin/unshare";
      }));
    in
    beam.mixRelease {
      pname = "overalls-${application}";
      inherit version;
      src = source application;
      sourceRoot = "source/${application}";
      mixFodDeps = dependencies.${application};
      compileFlags = [ "--warnings-as-errors" ];
      nativeBuildInputs = lib.optionals isMarshall [ pkgs.cargo pkgs.rustc pkgs.pkg-config ];
      env = {
        ERL_CRASH_DUMP_PUBLIC_KEY = if encryptedCrashDumps then "${./build-crash-dump-public.pem}" else "";
        ERL_FLAGS = "+S 4:4";
      } // lib.optionalAttrs antithesisSdk {
        ANTITHESIS_HARNESS = "1";
        MIX_ENV = "prod";
      } // lib.optionalAttrs (antithesisGuest && application == "lilly") {
        ANTITHESIS_GUEST = "1";
      } // lib.optionalAttrs (antithesisIntegratedHost && application == "lilly") {
        ANTITHESIS_INTEGRATED_HOST = "1";
      } // lib.optionalAttrs isMarshall {
        CARGO_NET_OFFLINE = "true";
        CARGO_BUILD_JOBS = "4";
      };

      # @cc [owner:ghuntley,label:build] cedar-and-assets-prefetched
      # Compilation MUST use the vendored Cedar lockfile and pinned Nix asset
      # executables, with no Rustler precompiled or Mix asset downloads.
      preConfigure = ''
        # A fixed-output fetch can be reused from cache after inputs change.
        # Reject a stale hash rather than compiling old deps against a new lock.
        cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"
      '' + lib.optionalString isMarshall ''
        export CARGO_HOME="$TMPDIR/cargo-home"
        mkdir -p "$CARGO_HOME"
        substitute ${cedarCargo}/.cargo/config.toml "$CARGO_HOME/config.toml" \
          --subst-var-by vendor "${cedarCargo}"
        cat >> config/prod.exs <<'CONFIG'
        config :esbuild, path: "${lib.getExe pkgs.esbuild}", version: "${pkgs.esbuild.version}"
        CONFIG
      '';

      postBuild = lib.optionalString isMarshall ''
        # fetchMixDeps removes Git internals; the hash and lock snapshot above
        # authenticate inputs. Mark dependency loading complete before the
        # asset alias invokes compile again without the builder's flags.
        mix do deps.loadpaths --no-deps-check + assets.deploy
      '';

      # @cc [owner:ghuntley,label:deployment] source-release-runtime-metadata
      # Metadata MUST retain the canonical runtime tool paths used by Lilly;
      # exporting a release closure MUST include every referenced executable.
      postInstall = ''
        cp ${metadata} "$out/overalls-release.json"
        ${lib.optionalString isLilly ''ln -s ${hostTools} "$out/host-tools"''}
      '';
      meta = {
        description = "Overalls ${application} source-built OTP release";
        mainProgram = application;
        platforms = [ "x86_64-linux" ];
      };
    };
  # Builds that modules used to make for themselves; modules take them from
  # this set so every system and test shares one build (ADR-0269).
  otelReceiver = pkgs.callPackage ../system/otel-guest/receiver.nix { };
  enricoGitOwner = import ./applications/enrico-git-owner.nix { inherit pkgs; };
in
rec {
  inherit otelReceiver enricoGitOwner;
  inherit dependencies cedarCargo cedarLints hostTools toolchain vmm windowsFirmware windowsFirmwareDebug mkWindowsGuest mkWindowsEditorCandidate windowsGuest windowsGuestAgents windowsGuestRuntime windowsGuestPublished windowsGuestDrvload windowsBoot windowsEditorRuntime windowsEditorSource windowsEditorBroker mkWindowsEditorBundle androidSdk;
  inherit terminald terminaldChecks terminaldWindows;
  inherit codingClis githubTools;
  inherit lyra lyraLinux lyraWindows lyraNative githubBootstrapRelease;
  marvin = import ./marvin { inherit pkgs; };
  mila = import ./mila { inherit pkgs; };
  vscodeWeb = import ./vscode-web { inherit pkgs; };
  updateVscodeExtensions = import ./vscode-web/updater.nix { inherit pkgs vscodeWeb; };
  vscodeWebBroker = import ./vscode-web-broker { inherit pkgs; };
  smtprelay = pkgs.callPackage ./smtprelay {};
  underclass = pkgs.callPackage ./underclass {};
  secretTools = { inherit (pkgs) secretspec sops ssh-to-age age; };
  userRecipients = secretPackages.recipients;
  secrets = secretPackages.command;
  inherit mixReleases dependencyPins;
  inherit (mixReleases) marshall lilly audi brady porsche ziggy galileo enrico peach susan;
  # Susan's OCI image (ADR-0224); flake.nix passes the source revision.
  mkSusanImage = revision: import ./susan-image.nix { inherit pkgs revision; release = mixReleases.susan; };
  susanImage = import ./susan-image.nix { inherit pkgs; release = mixReleases.susan; };
  guest = import ./guest {
    inherit pkgs privateServiceRoots terminald lyraLinux vscodeWeb vscodeWebBroker codingClis;
    minimumMemoryBytes = 2147483648;
  };
  mkAndroidGuest = import ./guest/android {
    inherit pkgs terminald lyraLinux codingClis androidSdk;
  };
  androidGuest = mkAndroidGuest { inherit privateServiceRoots; };
  mkUbuntuGuest = import ./guest/ubuntu { inherit pkgs terminald lyraLinux vscodeWeb vscodeWebBroker codingClis; };
  ubuntuGuest = mkUbuntuGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  # Foreign Linux variants share the reviewed kernel/initrd boot contract while
  # their builders assemble roots from separately pinned distribution inputs.
  # The builders install the generic Linux guest runtime and keep image
  # identities separate in the fleet catalog by distribution and source pin.
  mkArchGuest = import ./guest/arch { inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker; };
  archGuest = mkArchGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  mkArchLinuxGuest = mkArchGuest;
  archLinuxGuest = archGuest;
  mkAlmaLinuxGuest = import ./guest/alma { inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker; };
  almaLinuxGuest = mkAlmaLinuxGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  # Short aliases follow the catalog's display name and preserve discoverability
  # for callers that use the conventional Alma naming.
  mkAlmaGuest = mkAlmaLinuxGuest;
  almaGuest = almaLinuxGuest;
  # Native non-Linux guests use the v6 manifest and never reuse the Linux
  # rootfs assembly. The CloudHv firmware is the same pinned PVH artifact used
  # by the firmware launcher, so OmniOS receives the identical PCI contract.
  nativeGuestAgents = nativeAgentPayload;
  nativeKernels = nativeGuests.nativeKernels;
  nativeGuests = import ./guest/native.nix { inherit pkgs lyra; firmware = windowsFirmware.fd; };
  nativeImagePromotion = import ./guest/native-promotion { inherit pkgs; elixir = toolchain.elixir; };
  mkPromotedNativeGuest = nativeImagePromotion.promote;
  mkPublishedNativeCandidate = nativeImagePromotion.publishedCandidate;
  nativeImagePromotionChecks = nativeImagePromotion.checks;
  mkFreeBSDGuest = import ./guest/freebsd { inherit pkgs; firmware = windowsFirmware.fd; nativeAgents = lyraNative; };
  legacyFreebsdGuest = import ./guest/native-promotion/freebsd.nix { inherit pkgs; elixir = toolchain.elixir; };
  freebsdGuest = import ./guest/native-promotion/freebsd-14.3-db752667-f0d9275b.nix { inherit pkgs; elixir = toolchain.elixir; };
  # Candidate assembly is an explicit build target. The staging constructor
  # stays closed; the catalog consumes only the separately promoted identity.
  mkFreeBSDImageCandidate = { kernel ? nativeKernels.freebsdCandidate, ... }@extraArgs:
    import ./guest/freebsd/candidate.nix ({
      inherit pkgs kernel;
      agentNames = nativeAgentPayload.manifest.agents;
      stagedImage = mkFreeBSDGuest {
        imageName = "overalls-freebsd-native-staging";
        gitIdentityVersion = 1;
        inherit kernel;
        stagingOnly = true;
      };
    } // builtins.removeAttrs extraArgs [ "kernel" ]);
  freebsdImageCandidate = mkFreeBSDImageCandidate { };
  omniosImageCandidateKit = import ./guest/omnios/candidate.nix {
    inherit pkgs;
    kernel = nativeKernels.illumosCandidate;
    agents = nativeAgentPayload.illumos;
    git = (import ./guest/native-git.nix { inherit pkgs; }).illumos;
    source = nativeGuests.mkOmniOSSource;
  };
  # KVM-backed assembly of that kit inside a pinned stock administration guest.
  # It is a test-only candidate: catalog selection stays on the promotion.
  omniosImageCandidate = import ./guest/omnios/assembly.nix {
    inherit pkgs;
    kit = omniosImageCandidateKit;
    source = nativeGuests.mkOmniOSSource;
    firmware = windowsFirmware.fd;
  };
  freebsdTransportProbeImage = mkFreeBSDImageCandidate {
    extraRoot = pkgs.runCommand "overalls-freebsd-transport-probe-root" {} ''
      install -D -m 0555 \
        ${lyra.native.probes}/bin/x86_64-unknown-freebsd-overalls-native-transport-probe \
        "$out/usr/local/libexec/overalls-native-transport-probe"
    '';
    runtimeRcLocal = pkgs.writeText "overalls-freebsd-transport-probe-rc.local" ''
      #!/bin/sh
      exec /usr/local/libexec/overalls-native-transport-probe
    '';
  };
  # Test-only: the fault-injection kernel with the same probe. Its distinct
  # build identity keeps it out of every promoted or catalog image.
  freebsdFaultProbeImage = mkFreeBSDImageCandidate {
    kernel = nativeKernels.freebsdFaultCandidate;
    extraRoot = pkgs.runCommand "overalls-freebsd-fault-probe-root" {} ''
      install -D -m 0555 \
        ${lyra.native.probes}/bin/x86_64-unknown-freebsd-overalls-native-transport-probe \
        "$out/usr/local/libexec/overalls-native-transport-probe"
    '';
    runtimeRcLocal = pkgs.writeText "overalls-freebsd-fault-probe-rc.local" ''
      #!/bin/sh
      exec /usr/local/libexec/overalls-native-transport-probe --require-fault-injection
    '';
  };
  # Stock constructors remain closed. Only the separately reviewed immutable
  # OmniOS promotion selects an admitted image for fleet staging and catalog.
  mkOmniOSGuest = import ./guest/omnios { inherit pkgs; firmware = windowsFirmware.fd; };
  legacyOmniosGuest = import ./guest/native-promotion/omnios.nix {
    inherit pkgs;
    elixir = toolchain.elixir;
  };
  omniosGuest = import ./guest/native-promotion/omnios-r151050-a96f291b.nix {
    inherit pkgs;
    elixir = toolchain.elixir;
  };
  # illumos.org is the upstream project; its installable downstream image is
  # exposed through an explicit constructor so callers do not mistake the
  # OmniOS distribution name for a second image source.
  mkIllumosGuest = import ./guest/illumos { inherit pkgs; firmware = windowsFirmware.fd; };
  illumosGuest = omniosGuest;
  ubuntuLock = import ./guest/ubuntu/lock-tool.nix { inherit pkgs; };
  imageBuilder = import ./guest/inception/image-builder.nix { inherit pkgs terminald lyraLinux; };
  # @cc [owner:ghuntley,label:security;deployment] inception-boot-trust-receiver
  # Every Inception image MUST include the boot-bound trust receiver, even for
  # standalone builds whose caller supplies no private roots. Lilly replaces
  # the image-time bundle with the current host CA before guest networking;
  # omitting the receiver leaves a trust-enabled Inception workload unable to
  # reach readiness.
  inceptionGuest = import ./guest {
    inherit pkgs;
    # Inception workloads are development guests: advertise the Git identity
    # capability required by profile admission while retaining the guest-owned
    # first-boot checkout (it is not the generic workspace receiver).
    # Inception always needs the boot-bound trust receiver: its nested host
    # delivers the current control-plane CA before networking and readiness.
    # Production callers provide their private roots; the standalone test
    # package has none, so use the pinned public bundle as the image-time
    # receiver input while Lilly still replaces it for each boot.
    privateServiceRoots = if privateServiceRoots == []
      then [ "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ]
      else privateServiceRoots;
    inherit terminald lyraLinux codingClis;
    gitIdentityVersion = 1;
    imageName = "inception-nixos-x86_64";
    minimumMemoryBytes = 34359738368;
    minimumDiskBytes = 68719476736;
    extraModules = [ (import ./guest/inception {
      packages = { inherit marshall lilly audi porsche ziggy guest smtprelay toolchain secretTools imageBuilder lyra; };
    }) ];
  };
  inceptionProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis;
    privateServiceRoots = [ ];
    imageName = "inception-nesting-probe-x86_64";
    minimumMemoryBytes = 2147483648;
    extraModules = [
      ./guest/nesting-probe/minimal.nix
      (import ./guest/nesting-probe { image = nestingProbeGuest; })
    ];
  };
} // lib.optionalAttrs (!encryptedCrashDumps) {
  # Buck2's encrypted-crash-dump releases arrive as `encrypted-<app>`.
  encrypted = import ./. {
    inherit pkgs privateServiceRoots; encryptedCrashDumps = true;
    artifacts = lib.mapAttrs' (name: value: lib.nameValuePair (lib.removePrefix "encrypted-" name) value)
      (lib.filterAttrs (name: _: lib.hasPrefix "encrypted-" name) artifacts);
  };
}
