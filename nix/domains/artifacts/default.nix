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
  # The root Cargo workspace (ADR-0273): one lock, one vendored crate set.
  cargoWorkspace = import ./infrastructure/cargo-workspace.nix { inherit pkgs; };
  # The fixed-output Mix fetches read manifests, locks and configuration only
  # (contract test-dependency-source); the releases build in Buck2 (ADR-0269).
  depsSource = import ./applications/deps-source.nix { inherit lib; };
  # Marshall's Cedar NIF crate and the workspace overlay it compiles in; the
  # cells hand it to Marshall's Buck2 release and checks.
  cedarSource = cargoWorkspace.source {
    name = "marshall-cedar-source";
    crates = [ "marshall/native/marshall_cedar" ];
  };
  version = "0.1.0";
  hostLock = import ./hosts/host-tools.nix { inherit pkgs; buck = artifacts.lilly-host-helpers or null; };
  terminald = swapLeaf "terminald" (import ./infrastructure/terminald.nix { inherit pkgs; });
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
    system = pkgs.stdenv.hostPlatform.system;
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
  githubTools = import ./guest/github { inherit pkgs; release = artifacts.github-tools or null; };
  # Patched static Firecracker/jailer pair (ADR-0169); the only VMM Lilly runs.
  inherit (import ./infrastructure/firecracker.nix { inherit pkgs; }) vmm;
  # UEFI firmware Firecracker loads as its PVH "kernel" for Windows guests.
  windowsFirmware = import ./guest/windows/firmware.nix { inherit pkgs; };
  # DEBUG build with firmware tracing on the serial console, for boot diagnosis.
  windowsFirmwareDebug = import ./guest/windows/firmware.nix { inherit pkgs; debug = true; };
  mkWindowsGuest = import ./guest/windows { inherit pkgs githubTools; firmware = windowsFirmware; };
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
  # Lyra's three builds are Buck2 leaves (buck/lyra.bzl) when assembly passes
  # them; the client keeps Nix's passthru and carries the swapped Windows and
  # native builds, so `lyra.windows` and `lyra.native(.probes)` follow suit.
  lyraNix = import ./infrastructure/lyra.nix { inherit pkgs; };
  lyraNativeBuild =
    if artifacts ? "lyra-native" then
      (swapLeaf "lyra-native" lyraNix.native).overrideAttrs (previous: {
        passthru = previous.passthru // { probes = swapLeaf "lyra-native-probes" lyraNix.native.probes; };
      })
    else lyraNix.native;
  lyra = (swapLeaf "lyra" lyraNix).overrideAttrs (previous: {
    passthru = previous.passthru // {
      windows = swapLeaf "lyra-windows" lyraNix.windows;
      native = lyraNativeBuild;
    };
  });
  lyraWindows = lyra.windows;
  githubBootstrapRelease = import ./infrastructure/executor-bootstrap.nix { inherit pkgs lyra; };
  nativeAgentPayload = import ./guest/native-agents.nix { inherit pkgs lyra terminald githubTools; };
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
  hostSystemPackages = [
    pkgs.coreutils pkgs.diffutils pkgs.util-linux pkgs.iproute2 pkgs.nftables pkgs.procps
    pkgs.zfs pkgs.openssh toolchain.elixir toolchain.erlang
  ];
  hostTools = pkgs.buildEnv {
    name = "lilly-host-tools";
    paths = hostSystemPackages ++ [ hostLock ];
  };
  # hostTools without the Rust helpers: Buck2's Mix suites put these on PATH
  # and take the helpers from //lilly:host-helpers (ADR-0273).
  hostSystemTools = pkgs.buildEnv {
    name = "lilly-host-system-tools";
    paths = hostSystemPackages;
  };

  nestingProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis githubTools;
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
  mixApplications = [ "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" "peach" "susan" ];
  # Buck2 Rust leaves this set consumes as `artifacts.<name>` (buck/rust_artifacts.bzl).
  rustArtifactNames = [ "enrico-git-owner" "lilly-host-helpers" "lyra" "lyra-native" "lyra-native-probes" "lyra-windows" "observability-runtimes" "otel-guest-receiver" "terminald" "trace-spool" "vscode-web-broker" ]
    # Test-only fixtures (buck/rust_artifacts.bzl TEST_ARTIFACTS).
    ++ [ "otel-request-fixture" "otel-request-recorder-cut" ];
  # Other Buck2 packages (buck/artifacts.bzl PACKAGE_ARTIFACTS).
  packageArtifactNames = [ "github-tools" "marvin" ];
  # @cc [owner:ghuntley,label:build] assembly-artifact-names
  # Every artifact key MUST name a leaf this set consumes: a Mix application
  # release (`<app>`), its encrypted variant (`encrypted-<app>`), a fixture
  # release (`fixture-<app>-<variant>`, read through releaseFixture), or a
  # Buck2 Rust leaf in `rustArtifactNames` or package in
  # `packageArtifactNames`. A misspelt key would otherwise be ignored and the
  # Nix build used silently (ADR-0269).
  unknownArtifacts = builtins.filter
    (name: !(builtins.elem name (mixApplications ++ map (name: "encrypted-${name}") mixApplications ++ rustArtifactNames ++ packageArtifactNames)
      || lib.any (application: lib.hasPrefix "fixture-${application}-" name) mixApplications))
    (builtins.attrNames artifacts);

  # @cc [owner:ghuntley,label:build;verification] release-fixtures-from-buck2
  # A fixture release (a patched update candidate or an instrumented build)
  # MUST come from its Buck2 `release_variants` artifact; an override of the
  # import would be ignored (imported-artifacts-reject-build-hooks). A suite
  # whose assembly lacks the artifact fails to evaluate.
  releaseFixture = application: variant:
    let key = "fixture-${application}-${variant}"; in
    artifacts.${key} or (throw "${key}: no Buck2 fixture release artifact (buck/mix_artifacts.bzl MIX_FIXTURE_ARTIFACTS, MIX_FIXTURE_SUITES)");
  dependencies = lib.genAttrs mixApplications (application:
    beam.fetchMixDeps {
      pname = "overalls-${application}-deps";
      inherit version;
      src = depsSource;
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

  # @cc [owner:ghuntley,label:build] test-dependency-hashes
  # Buck2 compile, check and test actions (ADR-0269) MUST read test-environment
  # Mix dependencies only from these fixed-output fetches, keyed in
  # dependency-hashes.json, so `mix test` and Dialyzer run with Hex offline.
  # Precompiled NIF artefacts that elixir_make would download at compile time
  # are fetched here too and verified again by each package's checksum.exs.
  testDependencyProjects = {
    marshall = { path = "marshall"; key = "marshallTest"; };
    lilly = { path = "lilly"; key = "lillyTest"; };
    audi = { path = "audi"; key = "audiTest"; };
    porsche = { path = "porsche"; key = "porscheTest"; };
    ziggy = { path = "ziggy"; key = "ziggyTest"; };
    brady = { path = "brady"; key = "bradyTest"; };
    galileo = { path = "galileo"; key = "galileoTest"; };
    enrico = { path = "enrico"; key = "enricoTest"; };
    peach = { path = "peach"; key = "peachTest"; };
    susan = { path = "susan"; key = "susanTest"; };
    protocol = { path = "protocol"; key = "protocolTest"; };
    diagnostics = { path = "elixir/diagnostics"; key = "diagnosticsTest"; };
    request_accounting = { path = "elixir/request_accounting"; key = "requestAccountingTest"; };
  };
  testDependencies = lib.mapAttrs (name: project: plainBeam.fetchMixDeps {
    pname = "overalls-${name}-test-deps";
    inherit version;
    src = import ./applications/deps-source.nix { inherit lib; };
    sourceRoot = "source/${project.path}";
    mixEnv = "test";
    hash = hashes.${project.key};
    env.ERL_FLAGS = "+S 4:4";
    postInstall = ''
      cp mix.lock "$out/.overalls-mix.lock"
      if [ -f "$out/lazy_html/checksum.exs" ]; then
        lazyHtml=$(sed -n 's/^ *@version "\(.*\)"$/\1/p' "$out/lazy_html/mix.exs")
        artefact="lazy_html-nif-2.16-x86_64-linux-gnu-$lazyHtml.tar.gz"
        mkdir -p "$out/.overalls-elixir-make"
        ${pkgs.curl}/bin/curl -fsSL --retry 3 --cacert ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
          -o "$out/.overalls-elixir-make/$artefact" \
          "https://github.com/dashbitco/lazy_html/releases/download/v$lazyHtml/$artefact"
      fi
    '';
  }) testDependencyProjects;

  # @cc [owner:ghuntley,label:build;verification] hegel-nif-offline
  # The hegel_ex property-test NIF MUST be built here from the pinned Git
  # dependency's own Cargo.lock with vendored crates, and reach Mix through
  # HEGEL_NIF_PATH, so no test compile runs cargo against the network.
  # The single rust-overlay toolchain (ADR-0273 decision 2), like every leaf.
  hegelNif = cargoWorkspace.rustPlatform.buildRustPackage {
    pname = "hegel-nif";
    version = "0.1.0";
    src = "${testDependencies.protocol}/hegel_ex/native/hegel_nif";
    cargoHash = hashes.hegelNifCargo;
    doCheck = false;
    installPhase = ''
      runHook preInstall
      install -D -m 0555 target/*/release/libhegel_nif.so "$out/lib/hegel_nif.so" 2>/dev/null \
        || install -D -m 0555 target/release/libhegel_nif.so "$out/lib/hegel_nif.so"
      runHook postInstall
    '';
  };


  # @cc [owner:ghuntley,label:build] mix-releases-from-buck2
  # Every Mix release in this set MUST be its Buck2 `<app>_import` artifact
  # (buck/mix_artifacts.bzl MIX_ARTIFACTS); there is no Nix build to fall back
  # on. An assembly without the artifact fails when a consumer reads the
  # release, never builds a different one (ADR-0269).
  mixReleases = lib.genAttrs mixApplications (application:
    artifacts.${application} or (throw "${application}: no Buck2 release artifact; build through a nix_assemble target (buck/mix_artifacts.bzl MIX_ARTIFACTS)"));

  # @cc [owner:ghuntley,label:build;security] dependency-pin-registry
  # Each entry names the lock files it builds from, the fixed-output fetches
  # that MUST build after those locks change (`build`), the Buck2 targets that
  # MUST then build against them (`buckTargets`), and the
  # dependency-hashes.json keys of its fixed-output fetches. scripts/mix_security_upgrades.exs and
  # scripts/cargo_security_upgrades.exs refresh hashes and build only through
  # this registry; the Cargo script refuses a tracked Cargo.lock missing here.
  dependencyPins = {
    mix = lib.genAttrs mixApplications (application: {
      locks = [ "${application}/mix.lock" ];
      build = pkgs.linkFarmFromDrvs "${application}-pins" [ dependencies.${application} testDependencies.${application} ];
      buckTargets = [ "root//${application}:release" "root//${application}:check" "root//${application}:test" ];
      hashes = {
        ${application} = dependencies.${application};
        ${testDependencyProjects.${application}.key} = testDependencies.${application};
      };
    }) // lib.genAttrs [ "protocol" "diagnostics" "request_accounting" ] (library: {
      locks = [ "${testDependencyProjects.${library}.path}/mix.lock" ];
      build = if library == "protocol"
        then pkgs.linkFarmFromDrvs "protocol-pins" [ testDependencies.protocol hegelNif ]
        else testDependencies.${library};
      buckTargets = if library == "protocol"
        then [ "root//protocol:check" "root//protocol:test" ]
        else [ "root//elixir:${library}_check" "root//elixir:${library}_test" ];
      hashes = { ${testDependencyProjects.${library}.key} = testDependencies.${library}; }
        // lib.optionalAttrs (library == "protocol") { hegelNifCargo = hegelNif.cargoDeps; };
    });
    # ADR-0273: the root workspace has the only Cargo.lock. Its build links
    # every Nix output that compiles a first-party crate, so a lock refresh
    # MUST rebuild them all.
    cargo = {
      workspace = {
        locks = [ "Cargo.lock" ];
        build = pkgs.linkFarmFromDrvs "cargo-workspace-pins" [
          lyra
          lyra.windows
          lyra.native
          terminald
          terminaldWindows
          terminald.native
          hostLock
          enricoGitOwner
          traceSpool
          (import ./vscode-web-broker { inherit pkgs; })
          windowsEditorBroker
          (import ./mila/rust.nix { inherit pkgs; }).package
          (import ./mila { inherit pkgs; }).linuxNative
          otelReceiver
          observabilityRuntimes
        ];
        # The Buck2 Rust leaves (buck/rust_artifacts.bzl RUST_ARTIFACTS), the
        # Cedar NIF that Rustler compiles inside Marshall's Buck2 release, and
        # the clippy gates over the crates with their own lints.
        buckTargets = [
          "root//lyra:client-import"
          "root//lyra:windows-import"
          "root//lyra:native-import"
          "root//lyra:native-probes-import"
          "root//nix:terminald-import"
          "root//nix:vscode-web-broker-import"
          "root//nix:otel-guest-receiver-import"
          "root//nix:observability-runtimes-import"
          "root//lilly:host-helpers-import"
          "root//enrico:git-owner-import"
          "root//elixir:trace-spool-import"
          "root//marshall:release"
          "root//nix:overalls-otel-guest-receiver-clippy"
          "root//marshall:marshall_cedar-clippy"
        ];
        hashes = { };
      };
    };
  };

  # Builds that modules used to make for themselves; modules take them from
  # this set so every system and test shares one build (ADR-0269).

  # @cc [owner:ghuntley,label:build] swapped-leaf-keeps-nix-interface
  # A Buck2 leaf that replaces a Nix build MUST keep that build's meta (so
  # lib.getExe finds mainProgram) and passthru (terminald's `native`), and
  # expose it as passthru.nixBuild, so a fixture that patches or rebuilds the
  # source overrides the Nix build rather than silently overriding the
  # import's copy step (ADR-0269, ADR-0273). A reference constraint (the
  # Windows agents embed no store path) MUST bind the artifact that ships: the
  # import carries it (nix_store_import allowed_references), not this recipe.
  swapLeaf = name: nixBuild:
    if artifacts ? ${name} then
      artifacts.${name}.overrideAttrs (previous: {
        meta = nixBuild.meta or { };
        passthru = (previous.passthru or { }) // (nixBuild.passthru or { }) // { inherit nixBuild; };
      })
    else nixBuild;

  # @cc [owner:ghuntley,label:build] package-set-first-party-builds
  # NixOS modules, machine tests and the antithesis harness MUST take these
  # first-party builds from this set, never build their own copy. Patched
  # third-party nixpkgs packages (Fluent Bit) stay on the system's nixpkgs so
  # a host keeps the version its configuration was reviewed against.
  otelReceiverNix = pkgs.callPackage ../system/otel-guest/receiver.nix {
    inherit (cargoWorkspace) rustPlatform;
    clippy = cargoWorkspace.rustTools;
    rustfmt = cargoWorkspace.rustTools;
  };
  otelReceiver = swapLeaf "otel-guest-receiver" otelReceiverNix;
  # The otel-request-recorder suite's fixtures (nix/BUCK): the receiver's
  # request_fixture example, and the recorder with the commit-reply cut
  # inserted at its apply/reply boundary.
  otelRequestFixture = swapLeaf "otel-request-fixture" (otelReceiverNix.overrideAttrs (previous: {
    pname = "overalls-request-recorder-native-fixture";
    postBuild = (previous.postBuild or "") + ''
      cargo build --offline --release -p overalls-otel-guest-receiver --example request_fixture
    '';
    postInstall = ''
      mkdir -p "$out/bin"
      install -m 0755 target/*/release/examples/request_fixture "$out/bin/request_fixture" 2>/dev/null \
        || install -m 0755 target/release/examples/request_fixture "$out/bin/request_fixture"
      find "$out/bin" -mindepth 1 ! -name request_fixture -delete
    '';
  }));
  otelRequestRecorderCut = swapLeaf "otel-request-recorder-cut" (otelReceiverNix.overrideAttrs (previous: {
    pname = "overalls-request-recorder-commit-reply-fixture";
    nativeBuildInputs = (previous.nativeBuildInputs or []) ++ [ cargoWorkspace.rustTools ];
    postPatch = (previous.postPatch or "") + ''
      substituteInPlace nix/domains/system/otel-guest/receiver/src/request_recorder.rs --replace-fail \
        'Ok(envelope) => runtime.apply(producer, envelope.command, now_ns()?),' \
        ${lib.escapeShellArg (builtins.readFile ../../verification/tests/machines/otel-request-recorder/commit-reply-cut.rs)}
    '';
    # The inserted fault expression is not rustfmt-formatted and lengthens
    # run past too_many_lines, so this variant replaces the inherited gate with
    # clippy alone and allows only that length lint for the patched function.
    postCheck = ''
      pushd "$buildAndTestSubdir"
      cargo clippy --offline --all-targets -- -D warnings -A clippy::too_many_lines
      popd
    '';
  }));
  enricoGitOwner = swapLeaf "enrico-git-owner" (import ./applications/enrico-git-owner.nix { inherit pkgs; });
  observabilityRuntimes = swapLeaf "observability-runtimes" (import ../system/observability-runtimes.nix { inherit pkgs; });
  traceSpool = swapLeaf "trace-spool" (import ./infrastructure/trace-spool.nix { inherit pkgs; });
in
assert unknownArtifacts == [ ] || throw "assembly artifacts not consumed by the package set: ${toString unknownArtifacts}";
rec {
  inherit otelReceiver otelRequestFixture otelRequestRecorderCut enricoGitOwner observabilityRuntimes traceSpool hostLock;
  inherit dependencies testDependencies hegelNif cargoWorkspace cedarSource hostTools hostSystemTools toolchain beam vmm windowsFirmware windowsFirmwareDebug mkWindowsGuest mkWindowsEditorCandidate windowsGuest windowsGuestAgents windowsGuestRuntime windowsGuestPublished windowsGuestDrvload windowsBoot windowsEditorRuntime windowsEditorSource windowsEditorBroker mkWindowsEditorBundle androidSdk;
  inherit terminald terminaldWindows;
  inherit codingClis githubTools;
  inherit lyra lyraLinux lyraWindows lyraNative githubBootstrapRelease;
  # Marvin's Buck2 build (//marvin:marvin, the `marvin` artifact) when assembly
  # supplies it; npm-lock-node-modules keeps both builds on package-lock.json.
  marvin = swapLeaf "marvin" (import ./marvin { inherit pkgs; });
  mila = import ./mila { inherit pkgs; };
  vscodeWeb = import ./vscode-web { inherit pkgs; };
  updateVscodeExtensions = import ./vscode-web/updater.nix { inherit pkgs vscodeWeb; };
  vscodeWebBroker = swapLeaf "vscode-web-broker" (import ./vscode-web-broker { inherit pkgs; });
  smtprelay = pkgs.callPackage ./smtprelay {};
  underclass = pkgs.callPackage ./underclass {};
  secretTools = { inherit (pkgs) secretspec sops ssh-to-age age; };
  # The buck2 that buckCells pins, for offline updater fixtures (ADR-0271).
  inherit (pkgs) buck2;
  userRecipients = secretPackages.recipients;
  secrets = secretPackages.command;
  inherit mixReleases dependencyPins mixApplications releaseFixture;
  inherit (mixReleases) marshall lilly audi brady porsche ziggy galileo enrico peach susan;
  # Susan's OCI image (ADR-0224); flake.nix passes the source revision.
  mkSusanImage = revision: import ./susan-image.nix { inherit pkgs revision; release = mixReleases.susan; };
  susanImage = import ./susan-image.nix { inherit pkgs; release = mixReleases.susan; };
  guest = import ./guest {
    inherit pkgs privateServiceRoots terminald lyraLinux vscodeWeb vscodeWebBroker codingClis githubTools;
    minimumMemoryBytes = 2147483648;
  };
  mkAndroidGuest = import ./guest/android {
    inherit pkgs terminald lyraLinux codingClis githubTools androidSdk;
  };
  androidGuest = mkAndroidGuest { inherit privateServiceRoots; };
  mkUbuntuGuest = import ./guest/ubuntu { inherit pkgs terminald lyraLinux vscodeWeb vscodeWebBroker codingClis githubTools; };
  ubuntuGuest = mkUbuntuGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  # Foreign Linux variants share the reviewed kernel/initrd boot contract while
  # their builders assemble roots from separately pinned distribution inputs.
  # The builders install the generic Linux guest runtime and keep image
  # identities separate in the fleet catalog by distribution and source pin.
  mkArchGuest = import ./guest/arch { inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker githubTools; };
  archGuest = mkArchGuest { inherit privateServiceRoots; minimumMemoryBytes = 2147483648; };
  mkArchLinuxGuest = mkArchGuest;
  archLinuxGuest = archGuest;
  mkAlmaLinuxGuest = import ./guest/alma { inherit pkgs mkUbuntuGuest terminald lyraLinux vscodeWeb vscodeWebBroker githubTools; };
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
    inherit terminald lyraLinux codingClis githubTools;
    gitIdentityVersion = 1;
    imageName = "inception-nixos-x86_64";
    minimumMemoryBytes = 34359738368;
    minimumDiskBytes = 68719476736;
    extraModules = [ (import ./guest/inception {
      packages = { inherit marshall lilly audi porsche ziggy guest smtprelay toolchain secretTools imageBuilder lyra; };
    }) ];
  };
  inceptionProbeGuest = import ./guest {
    inherit pkgs terminald lyraLinux codingClis githubTools;
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
