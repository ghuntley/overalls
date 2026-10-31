{ pkgs, module, packages, hostFixture, codingClis ? false, editor ? false, editorFamily ? null, hostReplacement ? false, runtimeReadiness ? false, observabilityRecovery ? false, porsche ? false, porscheLifecycleOnly ? false, porscheThreads ? false, relocation ? false, suspension ? false, audi ? false, sshBootstrap ? false, userSshJourney ? false, cloning ? false, ubuntu ? false, customerIsolation ? false, brady ? false, galileo ? false, terminal ? false, agent ? false, agentCli ? false, guestCliRecovery ? false, executorLoss ? false, defaultOss ? false, resize ? false, accountLifecycle ? false, guestTrust ? false, teamResources ? false, integrationRenewals ? false, privateWeb ? false, maintenanceEvacuation ? false, cloneCancellation ? false, repositoryLaunch ? false, githubIntegration ? false, githubFamily ? null, sharingSurfaces ? false, cloneDestinationLoss ? false, cloneMarshallRestart ? false, sshRosterMatrix ? false, otelGuest ? false, otelGalileo ? false, otelAudiSsh ? false, otelPorsche ? false, porscheTerminal ? false, milaTerminal ? false, artifactAgentPublish ? false, threadTool ? false, hegel ? null }:
let
  inherit (pkgs) lib;
  # @cc [owner:ghuntley,label:verification] editor-native-family-selection
  # An explicit editor family MUST select that distribution's real image
  # constructor and exact os-release ID throughout the browser journey. It MUST
  # NOT redirect another fleet scenario or substitute a NixOS guest for it.
  selectedEditorFamily = if editorFamily == null then (if ubuntu then "ubuntu" else "nixos") else editorFamily;
  foreignEditor = editor && builtins.elem selectedEditorFamily [ "arch" "almalinux" ];
  selectedGitHubFamily = if githubFamily == null then "nixos" else githubFamily;
  foreignGitHub = githubIntegration && builtins.elem selectedGitHubFamily [ "arch" "almalinux" ];
  foreignGuest = foreignEditor || foreignGitHub;
  selectedForeignFamily = if foreignGitHub then selectedGitHubFamily else selectedEditorFamily;
  # @cc [owner:ghuntley,label:verification] editor-native-packaged-runtime-probe
  # Native Node diagnostics MUST execute the selected editor package's own
  # runtime, never the separate NixOS fixture package set's Node installation.
  editorRuntimeNode = "${packages.vscodeWeb}/node";
  otelExporter = packages.otelReceiver;
  requestIdentities = import ../../../../domains/system/otel-fleet/request-identities.nix;
  # @cc [owner:ghuntley,label:verification;security] fixture-request-export-custody
  # Request fixtures MUST export production recorder snapshots with explicit
  # source selection and independent reader accounts, without producer RPC or
  # checkpoint access. The local collector is disposable fixture transport.
  requestExporter = name: source: collectorGroup: {
    wantedBy = [ "multi-user.target" ];
    wants = [ "overalls-request-${name}.service" ];
    after = [ "overalls-request-${name}.service" "opentelemetry-collector.service" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = lib.escapeShellArgs [ "${otelExporter}/bin/slo_exporter"
        "--recorder-group-source" source "/run/overalls-request-${name}-source/slo.json"
        "/run/${collectorGroup}/collector.sock" ];
      User = requestIdentities.exporterUser name;
      Group = requestIdentities.readerGroup name;
      SupplementaryGroups = [ collectorGroup ];
      Restart = "always"; RestartSec = 5;
      NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
      PrivateTmp = true; PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = [];
    };
  };
  otelAudiSshKeys = pkgs.runCommand "fleet-audi-ssh-disposable-wireguard-keys" {
    nativeBuildInputs = [ pkgs.wireguard-tools ];
  } ''
    mkdir -p "$out"
    for name in l1 l2; do
      wg genkey > "$out/$name.key"
      wg pubkey < "$out/$name.key" > "$out/$name.pub"
    done
  '';
  # @cc [owner:ghuntley,label:verification;security] otel-audi-ssh-native-source
  # The native Audi variant MUST use real WireGuard peers and the production
  # fleet collector module; the test MUST NOT inject a synthetic SSH snapshot.
  otelAudiSshHost = name: { config, nodes, lib, ... }:
    let other = if name == "l1" then "l2" else "l1";
        address = if name == "l1" then "10.90.0.1" else "10.90.0.2";
        peerAddress = if name == "l1" then "10.90.0.2" else "10.90.0.1";
    in {
      overalls.fleetNetwork = {
        enable = true;
        inherit address;
        endpointAddress = config.networking.primaryIPAddress;
        privateKeyFile = "/run/fleet-otel-audi-ssh/private";
        secretUnits = [ "fleet-otel-audi-ssh-key.service" ];
        # Match production's peer-scoped observability ports; the tunnel remains
        # untrusted and worker traces must reach the central Tempo over it.
        tcpPorts = if name == "l1" then [ 4317 9464 9467 ] else [ 9464 9467 ];
        peers.${other} = {
          address = peerAddress;
          endpointAddress = nodes.${other}.networking.primaryIPAddress;
          publicKey = lib.removeSuffix "\n" (builtins.readFile "${otelAudiSshKeys}/${other}.pub");
        };
      };
      systemd.services.fleet-otel-audi-ssh-key = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "fleet-otel-audi-ssh";
          RuntimeDirectoryMode = "0700";
        };
        script = "install -m 0600 ${otelAudiSshKeys}/${name}.key /run/fleet-otel-audi-ssh/private";
      };
    };
  audiScenario = builtins.readFile ./scenarios/audi.py;
  # @cc [owner:ghuntley,label:verification] porsche-native-ssh-source-scope
  # The focused source check MUST include real key approval and authorized SSH
  # dispatch before its durable-source assertions, then stop before VM creation.
  porscheScenarioParts = lib.splitString
    "\n    # @cc [owner:ghuntley,label:verification] porsche-native-source-after-authorized-dispatch"
    (builtins.readFile ./scenarios/porsche.py);
  # @cc [owner:ghuntley,label:verification] otel-audi-ssh-scoped-native-journey
  # The SLO variant MUST include the real guest SSH and both collector
  # assertions, then stop before separate sharing and recovery scenarios.
  # Removing or moving the marker across those boundaries MUST fail evaluation.
  otelAudiSshScenarioParts = lib.splitString
    "\n    # @cc [owner:ghuntley,label:verification] audi-native-slo-journey-boundary"
    audiScenario;
  suspensionAudiSshSetup =
    "with subtest(\"native OpenSSH reaches"
    + builtins.head (lib.splitString
      "\n    # @cc [owner:ghuntley,label:verification] audi-native-slo-journey-boundary"
      (lib.elemAt (lib.splitString "\nwith subtest(\"native OpenSSH reaches" audiScenario) 1));
  # Clone-matrix variants overlap several full-shape source, temporary copy and
  # destination reservations, so their sparse fixtures get a larger dataset quota.
  # Every fixture also retains a sealed template per configured image (ADR-0130);
  # with ADR-0146 standbys it measured about 1.4 GB of pool space before any guest
  # (12.10 GB free of 16 GiB, against 13.47 GB without them); standbys are
  # retired (ADR-0177). The plain fleet's capacity race needs fresh headroom
  # for two startup reservations but not three, so its pool is derived from the
  # real reservation rather than fixed: a fixed 16 GiB pool fit only rootfs
  # images up to 4 GiB, and the 4.29 GiB guest (6 GiB reservation, 11.08 GB
  # free) left the race waiting for two slots forever. The pool also holds the
  # host's installed system closure, so its free space cannot be pinned here:
  # it is sized for about three reservations and the race trims it at runtime
  # to two and a half (fleet-race-runtime-derived-slots in capacity.py).
  GiB = 1024 * 1024 * 1024;
  ceilDiv = a: b: (a + b - 1) / b;
  # @cc [owner:ghuntley,label:verification;build] fleet-guest-minima-from-pinned-manifest
  # A published image (Windows Server 2025) carries its reviewed manifest as
  # passthru, pinned with the image by its recursive NAR hash; its minima MUST
  # come from that pin. Reading its manifest.json at evaluation would realise
  # the 64 GiB disk during CI check selection (meta.ci forces these asserts)
  # and filled the selection runner's store. Built images have no pin, so
  # their manifest is read from the image (import-from-derivation). Numeric
  # minima only; the guest is already a closure input.
  guestManifest = guest.passthru.manifest or (builtins.fromJSON
    (builtins.unsafeDiscardStringContext (builtins.readFile "${guest}/manifest.json")));
  # Marshall.Compute.Image.default_shape root (at least 2 GiB) plus
  # OverallsProtocol.WorkloadBundle's 1 GiB bundle: VMShape.reservation/1.
  raceReservation = (lib.max 2 (ceilDiv guestManifest.minimum_disk_bytes GiB) + 1) * GiB;
  # Measured: the template, the first guest and pool metadata use the rootfs
  # plus about 0.9 GB; the enrolled overhead is 512 MiB.
  raceUsed = guestManifest.minimum_disk_bytes + GiB + GiB / 2;
  raceGiB = ceilDiv (raceUsed + raceReservation * 3) GiB;
  # @cc [owner:ghuntley,label:verification;capacity] fleet-guest-trust-derived-nixos-shape
  # The guest-trust NixOS root request MUST be the alternative image's minimum
  # disk rounded up to whole GiB (at least 4 GiB), and its pool MUST hold three
  # such root-plus-bundle reservations beside both images' rootfs, 1 GiB of
  # pool metadata and the 512 MiB enrolled overhead. Sizes come from the real
  # manifests, so image growth cannot silently make the three-guest admission
  # or the minimum-disk check impossible; admission still reads actual capacity.
  trustNixosManifest = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${nixosGuest}/manifest.json"));
  trustNixosDiskBytes = (lib.max 4 (ceilDiv trustNixosManifest.minimum_disk_bytes GiB)) * GiB;
  trustGiB = ceilDiv (guestManifest.minimum_disk_bytes + trustNixosManifest.minimum_disk_bytes
    + GiB + GiB / 2 + 3 * (trustNixosDiskBytes + GiB)) GiB;
  # @cc [owner:ghuntley,label:verification;capacity] suspension-fixture-checkpoint-headroom
  # Suspension scenarios MUST provide room for two full RAM checkpoints plus
  # destination disk/checkpoint transfer holds. Admission MUST still use actual
  # reported pool allocation; this budget MUST NOT fabricate free capacity.
  storageGiB = if suspension then lib.max 64 raceGiB else if codingClis || cloning || cloneDestinationLoss || cloneMarshallRestart then lib.max 32 raceGiB else if guestTrust then lib.max trustGiB raceGiB else raceGiB;
  storageBudget = storageGiB * 1024 * 1024 * 1024;
  # @cc [owner:ghuntley,label:verification;capacity] editor-native-default-memory-budget
  # Editor, suspension and coding-client fixtures MUST retain the real 1 GiB host overhead and 64 MiB VMM
  # allowance when admitting the default 2 GiB guest. Only their native guest
  # cgroup budget may grow; measured headroom still decides actual admission.
  fixtureGuestMemoryMiB = if editor || codingClis || suspension then 4096 else 3072;
  storage = import ./storage.nix { inherit pkgs hostFixture; imageSize = "${toString storageGiB}G"; };
  identity = builtins.fromJSON (builtins.readFile "${storage}/identity.json");
  # @cc [owner:ghuntley,label:verification] host-replacement-runtime-fresh-storage
  # The replacement provisioner MUST rebind its ZFS GUIDs at driver runtime (new
  # machine identity, name and storage identity), so its boot identity assertions
  # MUST NOT compare against the old fixture's prepared identity. Sharing identity
  # would fabricate fresh-GUID evidence.
  # The fleet script concatenates scenario files into one composed driver; the
  # NixOS framework type gate checks the complete composed script for every
  # variant. Runtime scenario assertions remain the authority for this suite.
  skipTypeCheck = false;
  hosts = {
    l1 = { host = "11111111-1111-4111-8111-111111111111"; pool = "11111111-1111-4111-8111-111111111112"; hostId = "11111111"; ip = "11.0.0.11"; };
    l2 = { host = "22222222-2222-4222-8222-222222222221"; pool = "22222222-2222-4222-8222-222222222222"; hostId = "22222222"; ip = "11.0.0.12"; };
  };
  root = "/var/lib/overalls-fleet";
  # @cc [owner:ghuntley,label:verification;security] repository-launch-isolated-providers
  # The repository-launch journey MUST clone and resolve change heads only from
  # four local provider origins and api.bitbucket.org served by the egress node
  # with a test-only CA delivered as a platform root;
  # no public network service may be contacted (nix-test-isolated-inputs).
  githubFixture = pkgs.runCommand "repository-launch-github-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=repository-launch-github-root -keyout root.key -out "$out/root.pem" 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=github.com -keyout "$out/github.key" -out github.csr 2>/dev/null
    printf 'subjectAltName=DNS:github.com,DNS:gitlab.com,DNS:codeberg.org,DNS:bitbucket.org,DNS:api.bitbucket.org,DNS:api.github.com,DNS:uploads.github.com,DNS:gist.github.com,DNS:raw.githubusercontent.com,DNS:gist.githubusercontent.com,DNS:release-assets.githubusercontent.com,DNS:github-cloud.githubusercontent.com,DNS:github-cloud.s3.amazonaws.com\nextendedKeyUsage=serverAuth\n' > ext.cnf
    openssl x509 -req -in github.csr -CA "$out/root.pem" -CAkey root.key -CAcreateserial \
      -days 3650 -extfile ext.cnf -out "$out/github.pem" 2>/dev/null
    openssl verify -CAfile "$out/root.pem" "$out/github.pem" >/dev/null
  '';
  githubProviderHosts = [ "github.com" "api.github.com" "uploads.github.com"
    "gist.github.com" "raw.githubusercontent.com" "gist.githubusercontent.com"
    "release-assets.githubusercontent.com" "github-cloud.githubusercontent.com"
    "github-cloud.s3.amazonaws.com" ];
  githubFleetArtifacts = pkgs.runCommand "github-integration-fleet-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../github-integration-fleet/browser.py} "$out/browser.py"
    cp ${../github-integration-fleet/provider.py} "$out/provider.py"
    cp ${../github-integration/fixture.py} "$out/provider_data.py"
    ty check --python ${python}/bin/python3 --extra-search-path "$out" "$out/browser.py" "$out/provider.py" "$out/provider_data.py"
  '';
  # The launch journey's default image is the selected guest, derived by the
  # shared manifest validator exactly like the production image catalog.
  guestImageId = builtins.readFile (pkgs.runCommand "repository-launch-default-image-id" {
    nativeBuildInputs = [ packages.toolchain.elixir ];
  } ''
    export ERL_FLAGS="+S 2:2"
    elixir -r ${../../../../../protocol/lib/overalls_protocol/editor_release.ex} -r ${../../../../../protocol/lib/overalls_protocol/guest_agents.ex} -r ${../../../../../protocol/lib/overalls_protocol/image_manifest.ex} -e '
      [source, output] = System.argv()
      {:ok, image} = source |> File.read!() |> JSON.decode!() |> OverallsProtocol.ImageManifest.validate()
      File.write!(output, image.id)
    ' ${guest}/manifest.json "$out"
  '');
  galileoFixture = import ./galileo.nix { inherit pkgs root; };
  # A runnable, older image seed makes the real host release an observable
  # update candidate without introducing another network-fetched build input.
  agentSeed = pkgs.runCommand "overalls-agent-old-seed" {} ''
    mkdir -p "$out/bin"
    cp ${packages.lyraLinux}/bin/overalls "$out/bin/overalls"
    cp ${packages.lyraLinux}/bin/overalls-ssh-authorize "$out/bin/overalls-ssh-authorize"
    cp ${packages.lyraLinux}/bin/overalls-host-certificate "$out/bin/overalls-host-certificate"
    cp ${packages.lyraLinux}/bin/overalls-trustd "$out/bin/overalls-trustd"
    cp ${packages.lyraLinux}/bin/overalls-workspaced "$out/bin/overalls-workspaced"
    chmod 0755 "$out/bin/overalls" "$out/bin/overalls-ssh-authorize" "$out/bin/overalls-host-certificate" "$out/bin/overalls-trustd" "$out/bin/overalls-workspaced"
    printf '\\nold-agent-seed\\n' >> "$out/bin/overalls"
  '';
  # @cc [owner:ghuntley,label:verification] fleet-image-trust-capability
  # The host MUST require trust delivery exactly when its selected guest image
  # enables the receiver. Every fleet journey MUST enable private services and
  # boot-bound trust delivery so personal-terminal roster readiness is usable.
  guestPrivateRoots = [ "${galileoFixture.pki}/root.pem" ];
  nativeEditorFixture = import ../vscode-web/native-extension.nix { inherit pkgs; editor = packages.vscodeWeb; };
  editorConflictingSettings = pkgs.writeText "fleet-editor-conflicting-settings.json" (builtins.toJSON {
    "security.workspace.trust.enabled" = true;
    "security.workspace.trust.startupPrompt" = "always";
    "security.workspace.trust.emptyWindow" = false;
    "chat.disableAIFeatures" = false;
    "workbench.disableAICustomizations" = false;
  });
  # @cc [owner:ghuntley,label:verification;security] fleet-boot-trust-compatible-images
  # Every primary and alternative fleet image MUST include boot trust and the
  # current roster integration required by Lilly's nonempty root set. Actual
  # private-service prerequisites MUST be independent of feature selection.
  nixosGuest = import ../../../../domains/artifacts/guest {
    inherit pkgs;
    inherit (packages) terminald;
    codingClis = packages.codingClis;
    vscodeWeb = if editor || suspension then packages.vscodeWeb else null;
    vscodeWebBroker = if editor || suspension then packages.vscodeWebBroker else null;
    lyraLinux = if agent && !(agentCli || guestCliRecovery || executorLoss) then agentSeed else packages.lyraLinux;
    privateServiceRoots = guestPrivateRoots;
    extraModules = [ ({ ... }: {
      # @cc [owner:ghuntley,label:verification] fleet-guest-readiness-diagnostics
      # A fleet guest that is not yet ready MUST print bounded unit state to its
      # serial console (the host's boot.log) at most three times, and print
      # nothing once multi-user.target and sshd are active. Output MUST be unit
      # state and guest service journal lines only, never credential files.
      systemd.services.fleet-readiness-diagnostics = {
        path = [ pkgs.systemd pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/ttyS0";
        };
        script = ''
          if systemctl is-active --quiet multi-user.target && systemctl is-active --quiet sshd.service; then
            exit 0
          fi
          count=$(( $(cat /run/fleet-readiness-diagnostics 2>/dev/null || echo 0) + 1 ))
          echo "$count" > /run/fleet-readiness-diagnostics
          [ "$count" -le 3 ] || exit 0
          echo "=== fleet-readiness-diagnostics $count uptime=$(cut -d' ' -f1 /proc/uptime)"
          systemctl --failed --no-pager --no-legend || true
          systemctl list-jobs --no-pager --no-legend || true
          for unit in multi-user.target lilly-network lilly-private-dns overalls-guest-trust \
            overalls-ssh-sync sshd lilly-readiness systemd-resolved; do
            echo "--- $unit: $(systemctl is-active "$unit" 2>&1)"
          done
          echo "--- /run/overalls-ssh-ready: $(test -e /run/overalls-ssh-ready && echo present || echo absent)"
          journalctl --no-pager -o short-monotonic -n 30 -u overalls-ssh-sync -u sshd -u lilly-private-dns || true
          echo "=== end fleet-readiness-diagnostics $count"
        '';
      };
      systemd.timers.fleet-readiness-diagnostics = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "45s"; OnUnitActiveSec = "25s"; AccuracySec = "1s"; };
      };
      networking.firewall.allowedTCPPorts = [ 8080 3000 ];
      environment.systemPackages = lib.optionals executorLoss [ executorLossHelper ];
      # @cc [owner:ghuntley,label:verification] fleet-editor-local-policy-fixture
      # Native extension test payloads MUST enter only isolated editor test
      # images. Personal installation/settings MUST follow account reconciliation
      # at runtime; images MUST NOT contain preseeded personal trust or homes.
      systemd.tmpfiles.rules = lib.optionals editor [
        "d /opt/overalls-editor-fixture 0755 root root -"
        "L /opt/overalls-editor-fixture/native-fixture.vsix - - - - ${nativeEditorFixture}/native-fixture.vsix"
        "L /opt/overalls-editor-fixture/conflicting-settings.json - - - - ${editorConflictingSettings}"
      ];
      systemd.services.fleet-executor-loss-observer = lib.mkIf executorLoss {
        path = [ pkgs.systemd ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${executorLossHelper}/bin/fleet-executor-loss observe";
          ExecStopPost = "${executorLossHelper}/bin/fleet-executor-loss cleanup";
          TimeoutStartSec = 360;
          TimeoutStopSec = 30;
          StandardOutput = "null";
        };
      };
    }) ];
  };
  ubuntuGuestBuilder = import ../../../../domains/artifacts/guest/ubuntu {
    inherit pkgs;
    inherit (packages) terminald;
    codingClis = packages.codingClis;
    vscodeWeb = if editor || suspension then packages.vscodeWeb else null;
    vscodeWebBroker = if editor || suspension then packages.vscodeWebBroker else null;
    lyraLinux = if agent && !guestCliRecovery then agentSeed else packages.lyraLinux;
  };
  editorFixtureFiles = lib.optionalAttrs editor {
    "/opt/overalls-editor-fixture/native-fixture.vsix" = { source = "${nativeEditorFixture}/native-fixture.vsix"; mode = "0444"; };
    "/opt/overalls-editor-fixture/conflicting-settings.json" = { source = editorConflictingSettings; mode = "0444"; };
  };
  foreignEditorBuilder = import
    (if selectedForeignFamily == "arch" then ../../../../domains/artifacts/guest/arch else ../../../../domains/artifacts/guest/alma)
    {
      inherit pkgs;
      inherit (packages) terminald lyraLinux;
      mkUbuntuGuest = ubuntuGuestBuilder;
      vscodeWeb = if editor then packages.vscodeWeb else null;
      vscodeWebBroker = if editor then packages.vscodeWebBroker else null;
    };
  guest = if githubIntegration && selectedGitHubFamily == "windows" then packages.windowsGuestPublished else if foreignGuest then foreignEditorBuilder {
    privateServiceRoots = guestPrivateRoots;
    files = editorFixtureFiles;
  } else if ubuntu || (githubIntegration && selectedGitHubFamily == "ubuntu") then ubuntuGuestBuilder {
    privateServiceRoots = guestPrivateRoots;
    files = editorFixtureFiles;
  }
  else nixosGuest;
  # Server-tool journeys (artifact, thread) reuse the agent fleet with their own
  # deterministic provider script and fixture operator.
  serverTool = artifactAgentPublish || threadTool;
  # Only the server-tool variants may select their reviewed operator script.
  serverToolOperatorExec = ''
    script=/etc/fleet-operator.exs
    if [ "''${FLEET_OPERATOR_SCRIPT:-}" = /etc/fleet-server-tool-operator.exs ]; then
      script=/etc/fleet-server-tool-operator.exs
    fi
    exec ${packages.marshall}/bin/marshall eval "Code.eval_file(\"$script\")" "$@"'';
  ziggyFixture = import ./ziggy.nix {
    inherit pkgs root agent executorLoss codingClis;
    serverToolMode = if artifactAgentPublish then "artifacts" else if threadTool then "thread-tool" else null;
  };
  # @cc [owner:ghuntley,label:verification] executor-loss-typed-artifacts
  # The exact guest observer and browser artifact MUST pass pinned Python typing.
  # They are installed only for this disposable fault fixture; the driver retains
  # the NixOS framework's composed strict type gate.
  executorLossHelper = pkgs.runCommand "executor-loss-observer-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.ruff ];
  } ''
    mkdir -p "$out/bin" "$out/lib" config
    cp ${../executor-loss/observer.py} "$out/lib/observer.py"
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    ruff check --config config/pyproject.toml "$out/lib/observer.py"
    ruff format --check --config config/pyproject.toml "$out/lib/observer.py"
    ty check --python ${pkgs.python3}/bin/python3 "$out/lib/observer.py"
    cat >"$out/bin/fleet-executor-loss" <<EOF
    #!${pkgs.runtimeShell}
    export PATH=${lib.makeBinPath [ pkgs.systemd ]}
    exec ${pkgs.python3}/bin/python3 "$out/lib/observer.py" "\$@"
    EOF
    chmod 0555 "$out/bin/fleet-executor-loss"
  '';
  executorLossBrowser = pkgs.runCommand "executor-loss-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../executor-loss/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # The update fixture distinguishes the candidate release by its catalogued
  # start-event message; the event name itself must stay catalogued.
  updatedLilly = packages.lilly.overrideAttrs (previous: {
    preBuild = (previous.preBuild or "") + ''
      substituteInPlace lib/lilly/events.ex --replace-fail 'message: "Lilly started"' 'message: "Lilly updated"'
    '';
  });
  # @cc [owner:ghuntley,label:verification;security] clone-exact-guid-context-fixture
  # Only this fixture release may capture the validated map passed to readiness.
  # Changed/duplicate source seams MUST fail the build; the observer's original
  # arguments, result, lock custody and cleanup authority MUST remain unchanged.
  observedCloneLilly = packages.lilly.overrideAttrs (previous: {
    preBuild = (previous.preBuild or "") + ''
      cp ${../clone-cancellation/observation.ex} lib/lilly/clone_observation_fixture.ex
      ${pkgs.python3}/bin/python3 ${cloneObservationRecorder}/instrument_clone_observation.py lib/lilly/host/zfs.ex
    '';
  });
  # @cc [owner:ghuntley,label:verification;security] clone-report-guard-fixture
  # Only cloneCancellation may instrument authenticated host-report validation.
  # Exact source hashes MUST fail closed on drift; original guards, rollback and
  # external refusals remain unchanged. The sink exports only finite stage/age.
  observedCloneMarshall = packages.marshall.overrideAttrs (previous: {
    preBuild = (previous.preBuild or "") + ''
      cp ${../clone-cancellation/report_rejection.ex} lib/marshall/clone_report_rejection_fixture.ex
      ${pkgs.python3}/bin/python3 ${cloneObservationRecorder}/instrument_clone_reports.py lib/marshall/compute/host_reports.ex lib/marshall/compute/provisioner_control.ex
    '';
  });
  updatedAudi = packages.audi.overrideAttrs (previous: {
    preBuild = (previous.preBuild or "") + ''
      substituteInPlace lib/audi/health.ex --replace-fail \
        'Point-in-time role readiness for private deployment health checks.' \
        'Updated role readiness for private deployment health checks.'
    '';
  });
  # A controlled release regression keeps listeners running but fails the real
  # private health response. The updater must not call this candidate healthy.
  unhealthyAudi = updatedAudi.overrideAttrs (previous: {
    preBuild = (previous.preBuild or "") + ''
      substituteInPlace lib/audi/health.ex --replace-fail \
        'System.monotonic_time(:millisecond) - started < 5000' \
        'System.monotonic_time(:millisecond) - started < 0'
    '';
  });
  # The failed-activation variant is built only for journeys that compose
  # scenarios/updates.py; every other composition keeps its variant set fixed.
  updatesFleet = customerIsolation || !(porsche || relocation || audi || sshBootstrap
    || userSshJourney || cloning || ubuntu || brady || galileo || terminal || agent
    || agentCli || guestCliRecovery || defaultOss || resize || accountLifecycle
    || guestTrust || teamResources || integrationRenewals || privateWeb || githubIntegration
    || maintenanceEvacuation || cloneCancellation || executorLoss || codingClis);
  lillyVariants = [ "updated" "secret-only" ]
    ++ lib.optionals audi [ "audi-updated" "audi-unhealthy" "audi-recovered" ]
    ++ lib.optionals updatesFleet [ "failing" ]
    ++ lib.optionals guestTrust [ "trust-invalid" ];
  # @cc [owner:ghuntley,label:verification;security] fleet-trust-invalid-root-fixture
  # Only the guest-trust composition may deliver this PEM-shaped, syntactically
  # corrupt public root: it MUST pass the host's shape-only root checks and every
  # size bound, and the guest receiver MUST reject it on every boot attempt.
  invalidTrustRoot = pkgs.writeText "fleet-invalid-trust-root.pem" ''
    -----BEGIN CERTIFICATE-----
    c3ludGhldGljLWludmFsaWQtZGVyLWJ5dGVzLW5vdC1hLWNlcnQ
    -----END CERTIFICATE-----
  '';
  bradyPython = pkgs.python3.withPackages (p: [ p.cryptography ]);
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] editor-fleet-shared-browser-artifact
  # Native acceptance MUST execute the same typed browser journey as the
  # recurring probe, with real ordinary-user browser storage and no auth bypass.
  editorBrowser = pkgs.runCommand "editor-fleet-browser-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.ruff ];
  } ''
    mkdir -p "$out" config
    cp ${../vscode-web/prepare.py} "$out/prepare.py"
    cp ${../vscode-web/authorization.py} "$out/authorization.py"
    cp ${../vscode-web/restart.py} "$out/restart.py"
    cp ${../vscode-web/fleet_policy.py} "$out/fleet_policy.py"
    cp ${../vscode-web/policy.py} "$out/policy.py"
    cp ${../vscode-web/browser.py} "$out/browser.py"
    cp ${../../../../domains/system/otel-guest/browser_journey.py} "$out/browser_journey.py"
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --python ${python}/bin/python3 --extra-search-path "$out" "$out"
  '';
  # @cc [owner:ghuntley,label:verification;security] clone-observation-recorder-typed
  # The clone-only recorder MUST pass pinned typing and disposable pass-through
  # checks before installation; it MUST never enter enrolled Lilly services.
  cloneObservationRecorder = pkgs.runCommand "clone-zfs-observation-recorder" {
    nativeBuildInputs = [ pkgs.python3 pkgs.ty pkgs.ruff ];
  } ''
    mkdir -p "$out"
    cp ${../../support/zfs_observation_recorder.py} "$out/zfs_observation_recorder.py"
    cp ${../../support/zfs_observation_recorder_test.py} "$out/zfs_observation_recorder_test.py"
    cp ${../../support/instrument_clone_observation.py} "$out/instrument_clone_observation.py"
    cp ${../../support/instrument_clone_reports.py} "$out/instrument_clone_reports.py"
    # Ruff selects the [tool.ruff] table by the literal pyproject.toml basename.
    mkdir config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    ruff check --config config/pyproject.toml "$out"
    ruff format --check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${pkgs.python3}/bin/python3 "$out"
    python3 "$out/zfs_observation_recorder_test.py"
  '';
  # @cc [owner:ghuntley,label:verification] audi-browser-subprocess-typing
  # The executed Audi browser helper MUST pass its own type check against the
  # same packaged Python and Playwright, independently of the composed driver gate.
  audiBrowser = pkgs.runCommand "fleet-audi-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./audi-browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] porsche-browser-subprocess-typing
  # The executed Porsche browser helper MUST pass its own type check against the
  # same packaged Python and Playwright, independently of the composed driver gate.
  porscheBrowser = pkgs.runCommand "fleet-porsche-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./porsche-browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] default-oss-browser-subprocess-typing
  # The executed default OSS helper MUST pass its own type check against the same
  # packaged Python and Playwright, independently of the composed driver gate.
  defaultOssBrowser = pkgs.runCommand "default-oss-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../default-oss/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] repository-launch-browser-subprocess-typing
  # The executed launch-link helper MUST pass its own type check against the
  # same packaged Python and Playwright, independently of the composed driver gate.
  repositoryLaunchBrowser = pkgs.runCommand "repository-launch-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../repository-launch/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] terminal-browser-subprocess-typing
  # The executed terminal helper MUST pass its own type check against the same
  # packaged Python and Playwright; this MUST NOT imply composed-driver typing.
  terminalBrowser = pkgs.runCommand "terminal-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # The Playwright helper is a separate process and needs its own type gate.
  resizeBrowser = pkgs.runCommand "resize-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../resize/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # Browser helpers run as separate processes, outside the composed driver.
  # Keep this journey's Playwright annotations checked against its real runtime.
  accountLifecycleBrowser = pkgs.runCommand "account-lifecycle-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    # Bound this fixture against the immutable image before native machines boot.
    ${pkgs.jq}/bin/jq -e '.minimum_disk_bytes <= 5368709120 and .minimum_memory_bytes <= 536870912' ${guest}/manifest.json >/dev/null
    mkdir -p "$out"
    cp ${../account-lifecycle/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  teamResourceBrowser = pkgs.runCommand "team-resource-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../team-resources/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] agent-cli-browser-artifact-typing
  # The executed approval helper MUST pass the pinned Playwright Python type
  # check; the complete dedicated driver MUST retain framework type checking.
  agentCliBrowser = pkgs.runCommand "agent-cli-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../agent-cli-journey/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] private-web-executed-artifact-typing
  # The executed browser, guest origin and browser JavaScript MUST pass strict
  # checks; the complete composed driver retains the NixOS framework type gate.
  privateWebArtifacts = pkgs.runCommand "private-web-artifacts-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.typescript ];
  } ''
    mkdir -p "$out"
    cp ${../private-web/browser.py} "$out/browser.py"
    cp ${../private-web/guest.py} "$out/guest.py"
    cp ${../private-web/browser.js} "$out/browser.js"
    ty check --python ${python}/bin/python3 "$out/browser.py" "$out/guest.py"
    tsc --allowJs --checkJs --noEmit --strict --target es2022 --lib es2022,dom "$out/browser.js"
  '';
  # @cc [owner:ghuntley,label:verification] evacuation-executed-artifact-typing
  # The separate browser Python and JavaScript MUST pass strict checks, and the
  # complete maintenance driver MUST retain the NixOS framework type checker.
  evacuationArtifacts = pkgs.runCommand "evacuation-browser-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.typescript ];
  } ''
    mkdir -p "$out"
    cp ${../maintenance-evacuation/browser.py} "$out/browser.py"
    cp ${../maintenance-evacuation/browser.js} "$out/browser.js"
    ty check --python ${python}/bin/python3 "$out/browser.py"
    tsc --allowJs --checkJs --noEmit --strict --target es2022 --lib es2022,dom "$out/browser.js"
  '';
  cloneCancellationBrowser = pkgs.runCommand "clone-cancellation-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${../clone-cancellation/browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  # @cc [owner:ghuntley,label:verification] sharing-surfaces-executed-artifact-typing
  # The executed combined browser helper and its JavaScript MUST pass strict
  # checks; the composed scenario fragment follows the fleet driver corpus.
  sharingSurfacesBrowser = pkgs.runCommand "sharing-surfaces-browser-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.typescript ];
  } ''
    mkdir -p "$out"
    cp ${../sharing-surfaces/browser.py} "$out/browser.py"
    cp ${../sharing-surfaces/browser.js} "$out/browser.js"
    ty check --python ${python}/bin/python3 "$out/browser.py"
    tsc --allowJs --checkJs --noEmit --strict --target es2022 --lib es2022,dom "$out/browser.js"
  '';
  common = { config, lib, nodes, ... }: {
    # Offline Buck2 fixture repositories for updater scenarios (ADR-0271).
    imports = [ module (import ../../support/update-fixture.nix { inherit pkgs; inherit (packages) buck2; }).module ];
    system.stateVersion = "26.05";
    networking.enableIPv6 = false;
    virtualisation.memorySize = lib.mkDefault 1024;
    virtualisation.cores = lib.mkDefault 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    networking.extraHosts = "${nodes.proxy.networking.primaryIPAddress} control.example.test\n";
    environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.iproute2 ]
      ++ [ pkgs.python3 pkgs.git pkgs.nix ];
    # @cc [owner:ghuntley,label:verification] fleet-local-clock-synchronization
    # Replica clocks MUST synchronize against the isolated database node before
    # authentication tests. Public time servers and relaxed JWT validation MUST
    # NOT substitute for synchronization in this offline fixture.
    services.timesyncd.enable = false;
    services.chrony = {
      enable = true;
      servers = [ ];
      makestep.threshold = 0.01;
      extraConfig = if config.networking.hostName == "db" then ''
        local stratum 10
        allow 192.168.1.0/24
      '' else ''
        server ${nodes.db.networking.primaryIPAddress} iburst minpoll 0 maxpoll 2
      '';
    };
    systemd.tmpfiles.rules = [ "d ${root} 0700 root root -" ];
    # Credentials arrive through the test driver's private temporary directory.
    # The driver explicitly migrates before releasing the Marshall startup gate.
    # Driver-delivery gates (this one and the Ziggy, Audi, Galileo, Porsche and
    # Brady gates) carry no boot-relative deadline: the driver releases hosts in
    # sequence, so on a loaded builder a fixed budget expired before a later
    # host's delivery. The driver's own unit waits bound every gate instead.
    systemd.services.fleet-credentials = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "infinity"; };
      script = ''
        while [ ! -f ${root}/ready ]; do sleep 1; done
      '';
    };
  };
  marshall = name: { config, nodes, ... }: {
    imports = lib.optional (name == "m1") ziggyFixture.provider
      ++ lib.optional (porsche && name == "m1") (import ./porsche.nix { inherit packages; })
      ++ lib.optional (otelPorsche && name == "m1") (import ../../support/request-source.nix {
        inherit pkgs packages; name = "porsche"; source = "porsche";
        producerUser = "porsche"; producerUnit = "porsche.service";
        deadlineSeconds = 3660; collectorGroup = "overalls-otel-porsche";
        collectorEnable = true;
      })
      ++ [ (import ./audi.nix { inherit pkgs ubuntu; role = if name == "m1" then "issuer" else "dns"; }) ];
    virtualisation.memorySize = 2048;
    system.switch.enable = lib.mkIf (audi && name != "m1") true;
    services.overallsAutoUpdate = lib.mkIf (audi && name != "m1") {
      enable = true;
      repository = "/var/lib/overalls-update-test/git";
      flakeAttr = "host";
      marshallHealth.${name} = { serverName = name; caFile = "${root}/ca.crt"; };
    };
    systemd.timers.overalls-auto-update.wantedBy = lib.mkIf (audi && name != "m1") (lib.mkForce []);
    environment.etc."overalls-update-candidates.json" = lib.mkIf (audi && name != "m1") {
      text = builtins.toJSON (lib.genAttrs [ "audi-updated" "audi-unhealthy" "audi-recovered" ]
        (variant: "${config.specialisation.${variant}.configuration.system.build.overallsDeployment}"));
    };
    specialisation = lib.optionalAttrs (audi && name != "m1")
      (lib.genAttrs [ "audi-updated" "audi-unhealthy" "audi-recovered" ] (variant: {
        configuration = {
          environment.etc."overalls-update-candidates.json".enable = lib.mkForce false;
          services.audiDns.package = lib.mkForce
            (if variant == "audi-unhealthy" then unhealthyAudi else updatedAudi);
        };
      }));
    networking.extraHosts = lib.mkIf githubIntegration
      "${nodes.egress.networking.primaryIPAddress} ${lib.concatStringsSep " " githubProviderHosts}";
    security.pki.certificateFiles = lib.optionals githubIntegration [ "${githubFixture}/root.pem" ];
    systemd.services."marshall-${name}".environment = {
      ERL_AFLAGS = lib.mkIf githubIntegration
        "-eval 'public_key:cacerts_load(\"/etc/ssl/certs/ca-bundle.crt\").'";
      MARSHALL_CONTROL_FAULT_GATE_FILE = lib.mkIf relocation "/run/marshall-fault-gate/ops";
    };
    systemd.services.fleet-credentials.preStart = ''
      ${lib.optionalString githubIntegration ''
        umask 077
        printf '%s' synthetic-fleet-client-secret >${root}/github-client-secret
      ''}
      install -m 0600 ${../../fixtures/ssh-host-ca/key} ${root}/ssh-host-ca
    '';
    # @cc [owner:ghuntley,label:verification;security] host-replacement-real-ssh-bridge
    # Only this variant enables the protected operator SSH bridge on m1; the
    # replacement's prepare MUST cross the pinned bridge so the SSH/SOPS custody
    # evidence is real, never a direct local database write.
    users.users = lib.mkIf (hostReplacement && name == "m1") {
      operator = { isNormalUser = true; extraGroups = [ "wheel" ]; };
    };
    security.sudo.wheelNeedsPassword = lib.mkIf (hostReplacement && name == "m1") false;
    services.openssh = lib.mkIf (hostReplacement && name == "m1") {
      enable = true;
      settings = { PermitRootLogin = "no"; PasswordAuthentication = false; KbdInteractiveAuthentication = false; };
    };
    services.marshall = {
      enable = true;
      package = lib.mkIf cloneCancellation observedCloneMarshall;
      publicHost = "control.example.test";
      editorPackages = lib.optionalAttrs (editor || suspension) { linux-x64 = packages.vscodeWeb; };
      ingress.zone = "apps.example.test";
      sshHostCa = {
        publicKey = lib.removeSuffix "\n" (builtins.readFile ../../fixtures/ssh-host-ca/key.pub);
        keyFile = "${root}/ssh-host-ca";
      };
      integrations.github = lib.mkIf githubIntegration {
        clientId = "synthetic-fleet-client";
        clientSecretFile = "${root}/github-client-secret";
        redirectUri = "https://control.example.test/auth/github-com/callback";
      };
      replicaCount = 3;
      defaultImageId = lib.mkIf (repositoryLaunch || editor || githubIntegration) guestImageId;
      # Keep the production pool size: a two-connection fixture pool regularly
      # exhausts under real host/console polling and correctly fails readiness.
      poolSize = 10;
      databaseConnectionBudget = 49;
      cpuCores = 1;
      memoryMiB = 1536;
      environmentFile = "${root}/marshall.env";
      serperKeyFile = lib.mkIf agent "${root}/serper.key";
      serperOrigin = lib.mkIf agent "http://127.0.0.1:18080";
      databaseCAFile = "${root}/ca.crt";
      secretUnits = [ "fleet-credentials.service" ];
      # The artifact journey fetches tickets from each replica's real content
      # listener (artifactPort 6443) with the replica's own backend certificate.
      artifactContent.host = lib.mkIf artifactAgentPublish "usercontent.example.test";
      instances.${name} = {
        terminalPeerUrl = "https://${name}:5443";
        terminalPeerCAFile = "${root}/ca.crt";
        port = 4443;
        bindAddress = "0.0.0.0";
        fleetBindAddress = config.networking.primaryIPAddress;
        certificateFile = "${root}/tls.crt";
        keyFile = "${root}/tls.key";
      };
    };
    systemd.services.fleet-serper = lib.mkIf agent {
      wantedBy = [ "multi-user.target" ];
      after = [ "fleet-credentials.service" ];
      requires = [ "fleet-credentials.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./serper.py}";
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
    # @cc [owner:ghuntley,label:verification;security] fleet-control-fault-gate
    # Relocation fault scenarios refuse listed control ops through Marshall's
    # test-only gate file (ADR-0142); only this fixture configures it.
    systemd.tmpfiles.rules = lib.mkIf relocation [
      "d /run/marshall-fault-gate 0755 root root -"
      "f /run/marshall-fault-gate/ops 0644 root root -"
    ];
    networking.firewall.allowedTCPPorts = [ 4443 ];
    networking.firewall.interfaces.eth1.allowedTCPPorts = [ 5443 ];
    environment.etc."fleet-operator.exs".source = ./operator.exs;
    environment.etc."fleet-account-lifecycle.exs".source = ../account-lifecycle/operator.exs;
    environment.etc."fleet-github-historical.exs".source = ../github-integration-fleet/historical.exs;
    environment.etc."fleet-server-tool-operator.exs" = lib.mkIf serverTool { source = ./server-tool-operator.exs; };
    environment.etc."fleet-artifact-fixture.exs" = lib.mkIf serverTool { source = ../../support/artifact_fixture.exs; };
    environment.etc."fleet-audi-ssh.conf.in".source = ./audi-ssh.conf.in;
    environment.systemPackages = [ (pkgs.writeShellScriptBin "fleet-op" ''
      set -euo pipefail
      set -a
      . ${root}/marshall.env
      set +a
      unset PORT
      export PHX_SERVER=false PHX_HOST=control.example.test RELEASE_DISTRIBUTION=none
      export RELEASE_COOKIE=isolated-fleet-operator RELEASE_TMP=/run/fleet-operator
      export MARSHALL_INSTANCE_ID=fleet-operator-${name} MARSHALL_REPLICA_COUNT=3
      export FLEET_GITHUB_HISTORICAL_WINDOWS=${if githubIntegration && selectedGitHubFamily == "windows" then "1" else "0"}
      export MARSHALL_DB_CONNECTION_BUDGET=43 POOL_SIZE=2 MARSHALL_DB_TLS=verify
      export MARSHALL_DB_CA_CERTFILE=${root}/ca.crt ERL_CRASH_DUMP=/dev/null ERL_FLAGS="+S 2:2"
      export FLEET_GUEST=${guest}
      ${lib.optionalString ubuntu "export FLEET_ALTERNATIVE_GUEST=${nixosGuest}"}
      export FLEET_GUEST_NAME=${lib.escapeShellArg (if foreignGuest then (if selectedForeignFamily == "arch" then "Arch Linux" else "AlmaLinux") else if ubuntu || (githubIntegration && selectedGitHubFamily == "ubuntu") then "Ubuntu 26.04 LTS" else "nixos-fleet")}
      export FLEET_NODE=${name}
      ${lib.optionalString suspension "export FLEET_SUSPENSION_RELAY=1"}
      ${lib.optionalString artifactAgentPublish "export MARSHALL_ARTIFACT_CONTENT_HOST=usercontent.example.test"}
      mkdir -p "$RELEASE_TMP"
      if [ "$#" = 1 ] && [ "$1" = migrate ]; then
        exec ${packages.marshall}/bin/marshall eval 'Marshall.Operations.Migrate.main()'
      fi
      if [[ "''${1:-}" = gateway-* || "''${1:-}" = ziggy-* || "''${1:-}" = galileo-* || "''${1:-}" = peach-* ]]; then
        exec ${packages.marshall}/bin/marshall eval 'Marshall.Operations.CLI.main()' "$@"
      fi
      ${if serverTool then serverToolOperatorExec else "exec ${packages.marshall}/bin/marshall eval 'Code.eval_file(\"/etc/fleet-operator.exs\")' \"$@\""}
    '') ];
  };
  # @cc [owner:ghuntley,label:verification;security] suspension-private-ssh-prerequisites
  # Suspension guests MUST use the same private certificate issuer and runtime
  # credential enrollment as other fleet guests. The fixture MUST NOT bypass
  # host-certificate readiness to reach checkpoint assertions.
  lilly = name: { config, nodes, lib, ... }:
    let host = hosts.${name}; in {
    imports = [ ziggyFixture.lilly ./image-store.nix ]
      ++ [ (import ./audi.nix { inherit pkgs ubuntu; role = "gateway"; hostId = host.host; }) ]
      ++ [ galileoFixture.lilly ]
      ++ lib.optional (otelAudiSsh || observabilityRecovery || suspension) (otelAudiSshHost name);
    security.pki.certificateFiles = lib.optionals githubIntegration [ "${githubFixture}/root.pem" ];
    services.audi.editorPackages = lib.optionalAttrs (editor || suspension) {
      linux-x64 = packages.vscodeWeb;
    };
    services.audi.relay = lib.mkIf suspension {
      enable = true;
      address = if name == "l1" then "10.90.0.1" else "10.90.0.2";
      port = 9445;
      peers = [ (if name == "l1" then "10.90.0.2" else "10.90.0.1") ];
    };
    # A public unrelated CA tests trust refusal; it is never a guest root.
    environment.etc."fleet-coding-clis-untrusted-ca.pem" = lib.mkIf codingClis {
      source = "${githubFixture}/root.pem";
    };
    services.overallsOtelFleet = lib.mkIf (otelAudiSsh || observabilityRecovery) {
      enable = true;
      role = if name == "l1" then "central" else "worker";
      hosts = { central = "l1"; worker = "l2"; };
    };
    # @cc [owner:ghuntley,label:verification;security] otel-native-guest-path
    # The dedicated variant MUST collect an actual Lyra tool metric and trace
    # through guest TLS, Audi's current Lilly binding and the Rust receiver.
    # The collector is local to this disposable host; no fixture may inject a
    # guest metric at the receiver or exporter in place of the VM execution.
    services.overallsOtelGuest.enable = lib.mkIf otelGuest true;
    # The native variant keeps a disposable local Tempo on each possible
    # provisioner, so the actual guest trace can be queried on its selected host.
    services.tempo = lib.mkIf otelGuest {
      enable = true;
      settings = {
        server = { http_listen_address = "127.0.0.1"; http_listen_port = 3200; };
        distributor.receivers.otlp.protocols.grpc.endpoint = "127.0.0.1:4317";
        storage.trace = {
          backend = "local";
          local.path = "/var/lib/tempo/traces";
          wal.path = "/var/lib/tempo/wal";
        };
      };
    };
    services.opentelemetry-collector = lib.mkIf (otelGuest || brady || otelGalileo) {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      validateConfigFile = true;
      settings = {
        receivers = (lib.optionalAttrs otelGuest {
          otlp.protocols.http.endpoint = "127.0.0.1:4318";
        }) // (lib.optionalAttrs brady {
          "otlp/application".protocols.http = {
            endpoint = "/run/overalls-otel-app/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
        }) // (lib.optionalAttrs otelGalileo {
          "otlp/application-galileo".protocols.http = {
            endpoint = "/run/overalls-otel-galileo/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
          "otlp/application-audi-private".protocols.http = {
            endpoint = "/run/overalls-otel-audi-private/collector.sock";
            transport = "unix";
            max_request_body_size = 4096;
          };
        });
        processors = (lib.optionalAttrs brady {
          "resource/application".attributes = [
            { key = "service.name"; value = "brady"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
          ];
        }) // (lib.optionalAttrs otelGalileo {
          "resource/application-galileo".attributes = [
            { key = "service.name"; value = "galileo"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
          ];
          "resource/application-audi-private".attributes = [
            { key = "service.name"; value = "audi_private"; action = "upsert"; }
            { key = "overalls.telemetry.origin"; value = "application"; action = "upsert"; }
          ];
        });
        exporters = {
          prometheus = {
            endpoint = "127.0.0.1:9464";
            resource_to_telemetry_conversion.enabled = true;
          };
        } // lib.optionalAttrs otelGuest {
          "otlp/tempo" = {
            endpoint = "127.0.0.1:4317";
            tls.insecure = true;
          };
        };
        service.pipelines = (lib.optionalAttrs otelGuest {
          metrics = { receivers = [ "otlp" ]; exporters = [ "prometheus" ]; };
          traces = { receivers = [ "otlp" ]; exporters = [ "otlp/tempo" ]; };
        }) // (lib.optionalAttrs brady {
          "metrics/application" = {
            receivers = [ "otlp/application" ];
            processors = [ "resource/application" ];
            exporters = [ "prometheus" ];
          };
        }) // (lib.optionalAttrs otelGalileo {
          "metrics/application-galileo" = {
            receivers = [ "otlp/application-galileo" ];
            processors = [ "resource/application-galileo" ];
            exporters = [ "prometheus" ];
          };
          "metrics/application-audi-private" = {
            receivers = [ "otlp/application-audi-private" ];
            processors = [ "resource/application-audi-private" ];
            exporters = [ "prometheus" ];
          };
        });
      };
    };
    users.groups.overalls-otel-app = lib.mkIf brady {};
    users.groups.overalls-otel-galileo = lib.mkIf otelGalileo {};
    users.groups.overalls-otel-audi-private = lib.mkIf otelGalileo {};
    systemd.services.opentelemetry-collector = lib.mkMerge [
      (lib.mkIf brady {
        serviceConfig = {
          Group = "overalls-otel-app";
          RuntimeDirectory = "overalls-otel-app";
          RuntimeDirectoryMode = "0750";
          StateDirectoryMode = "0700";
          UMask = "0007";
        };
      })
      (lib.mkIf otelGalileo {
        serviceConfig = {
          Group = "overalls-otel-galileo";
          SupplementaryGroups = [ "overalls-otel-audi-private" ];
          RuntimeDirectory = [ "overalls-otel-galileo" "overalls-otel-audi-private" ];
          RuntimeDirectoryMode = "0750";
          UMask = "0007";
        };
        postStart = ''
          for attempt in $(${pkgs.coreutils}/bin/seq 1 100); do
            if test -S /run/overalls-otel-audi-private/collector.sock; then
              ${pkgs.coreutils}/bin/chgrp overalls-otel-audi-private /run/overalls-otel-audi-private /run/overalls-otel-audi-private/collector.sock
              ${pkgs.coreutils}/bin/chmod 0750 /run/overalls-otel-audi-private
              ${pkgs.coreutils}/bin/chmod 0660 /run/overalls-otel-audi-private/collector.sock
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          exit 1
        '';
      })
    ];
    services.overallsRequestRecorder.instances = lib.mkMerge [
      (lib.mkIf brady { brady = {
        source = "brady"; producerUser = "brady";
        producerUnit = "brady.service"; deadlineSeconds = 86400;
      }; })
      (lib.mkIf otelGalileo {
        galileo = { source = "galileo"; producerUser = "galileo";
          producerUnit = "galileo.service"; deadlineSeconds = 86400; };
        audi-private = { source = "audi_private"; producerUser = "audi";
          producerUnit = "audi-private.service"; deadlineSeconds = 86400; };
      })
    ];
    users.users = lib.mkMerge (map (name: lib.mkIf
      (if name == "brady" then brady else otelGalileo) {
        ${requestIdentities.exporterUser name} = {
          isSystemUser = true; group = requestIdentities.readerGroup name;
        };
      }) [ "brady" "galileo" "audi-private" ]);
    systemd.services.overalls-request-brady-exporter = lib.mkIf brady
      (requestExporter "brady" "brady" "overalls-otel-app");
    systemd.services.overalls-request-galileo-exporter = lib.mkIf otelGalileo
      (requestExporter "galileo" "galileo" "overalls-otel-galileo");
    systemd.services.audi-private.environment.AUDI_SLO_SNAPSHOT = lib.mkIf otelGalileo "/run/audi-private/slo.json";
    systemd.services.overalls-request-audi-private-exporter = lib.mkIf otelGalileo
      (requestExporter "audi-private" "audi_private" "overalls-otel-audi-private");
    networking.extraHosts = lib.optionalString brady "11.0.0.1 origin.brady.test\n"
      + lib.optionalString githubIntegration
        "${nodes.egress.networking.primaryIPAddress} ${lib.concatStringsSep " " githubProviderHosts}";
    # @cc [owner:ghuntley,label:verification] brady-host-src-valid-mark
    # Production Lilly hosts are Tailscale exit nodes, which set host-wide
    # src_valid_mark=1. The Brady journey MUST run under that host setting so
    # Lilly's router namespace proves it pins its own source validation.
    boot.kernel.sysctl."net.ipv4.conf.all.src_valid_mark" = lib.mkIf brady 1;
    services.brady = lib.mkIf brady {
      enable = true;
      issuerCertificateFile = "${root}/brady-ca.pem";
      issuerKeyFile = "${root}/brady-ca.key";
      upstreamCAFile = "/etc/brady-upstream-ca.pem";
      httpPorts = [ 80 8080 ];
      dnsResolvers = [ "1.1.1.1" "9.9.9.9" ];
      secretUnits = [ "fleet-brady-credentials.service" ];
    };
    systemd.services.brady.environment.BRADY_SLO_EXPORT = lib.mkIf brady "1";
    services.overallsFleetExporter = lib.mkIf brady {
      enable = true;
    };
    systemd.services.fleet-brady-credentials = lib.mkIf brady {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "infinity"; };
      script = "while [ ! -f ${root}/brady-ready ]; do sleep 1; done";
    };
    services.lillyTransfer = lib.mkIf (relocation || porsche || cloneDestinationLoss || cloneMarshallRestart) {
      enable = true;
      openFirewall = true;
      port = 2223;
    };
    # @cc [owner:ghuntley,label:verification;recovery] clone-restoration-fault-is-fixture-only
    # Only the cloning test may refuse a native launch for its explicitly armed
    # placement. No outcome or database authority is injected; removing the marker
    # still requires the public retry action and all normal physical validation.

    # @cc [owner:ghuntley,label:verification;security] clone-observation-host-zfs-custody
    # Only cloneCancellation may interpose this dormant public-read recorder.
    # Its real executable MUST be the selected host kernel's ZFS userspace; the
    # existing Lilly lock owner and process group MUST retain native custody.
    systemd.services.lilly-hostd.path = lib.mkBefore (lib.optionals cloneCancellation [
      (pkgs.writeShellScriptBin "zfs" ''
        exec ${pkgs.python3}/bin/python3 ${cloneObservationRecorder}/zfs_observation_recorder.py ${config.boot.zfs.package}/bin/zfs "$@"
      '')
    ]);
    systemd.services.lilly.path = lib.mkBefore (lib.optionals runtimeReadiness [
      # @cc [owner:ghuntley,label:verification;recovery] native-submission-barrier-scope
      # Only the isolated readiness fixture may pause one explicitly armed unit
      # around real submission. Ordinary calls retain the pinned executable and
      # arguments; no launch, journal or authenticated outcome may be fabricated.
      (pkgs.writeShellScriptBin "systemd-run" ''
        exec ${pkgs.python3}/bin/python3 ${./submission-barrier.py} ${pkgs.systemd}/bin/systemd-run "$@"
      '')
    ] ++ lib.optionals cloning [
      (pkgs.writeShellScriptBin "systemd-run" ''
        if [ -f /run/clone-restart-fault ]; then
          target="$(${pkgs.coreutils}/bin/cat /run/clone-restart-fault)"
          for argument in "$@"; do
            if [ "$argument" = "lilly-vm-$target.service" ]; then
              ${pkgs.coreutils}/bin/touch /run/clone-restart-fault-fired
              exit 1
            fi
          done
        fi
        exec ${pkgs.systemd}/bin/systemd-run "$@"
      '')
    ]);
    systemd.services.lilly-transfer-sshd = lib.mkIf (relocation || porsche || cloneDestinationLoss || cloneMarshallRestart || githubIntegration) {
      after = [ "fleet-storage.service" ];
      requires = [ "fleet-storage.service" ];
    };
    networking.hostId = host.hostId;
    system.switch.enable = true;
    services.overallsAutoUpdate = {
      enable = true;
      repository = "/var/lib/overalls-update-test/git";
      flakeAttr = "host";
    };
    systemd.timers.overalls-auto-update.wantedBy = lib.mkForce [];
    environment.etc."overalls-update-candidates.json".text = builtins.toJSON
      (lib.genAttrs lillyVariants (variant:
        "${config.specialisation.${variant}.configuration.system.build.overallsDeployment}"));
    specialisation = lib.genAttrs lillyVariants (variant: {
      configuration = {
        environment.etc."overalls-update-candidates.json".enable = lib.mkForce false;
        environment.etc."overalls-update-generation".text = variant;
        services.lilly.package = lib.mkForce updatedLilly;
        services.audi.package = lib.mkIf audi (lib.mkForce
          (if variant == "audi-unhealthy" then unhealthyAudi else updatedAudi));
        # A real required oneshot fails switch activation; guests are transient
        # units outside the candidate consumer set and must never be touched.
        systemd.services.update-fixture = lib.mkIf (variant == "failing") {
          wantedBy = [ "multi-user.target" ];
          script = "exit 1";
          serviceConfig.Type = "oneshot";
        };
        # Terminal trust-delivery failure: this host's next boots receive a
        # bundle whose final root fails guest certificate validation.
        services.lilly.guestTrustRoots = lib.mkIf (variant == "trust-invalid") (lib.mkForce
          (guestPrivateRoots
            ++ [ ../../../../../secrets/private-services-root.pem ../../../../../secrets/brady-root.pem ]
            ++ lib.optionals (name != "l1") [ ../../fixtures/ubuntu/ca.crt ]
            ++ [ invalidTrustRoot ]));
      };
    });
    # @cc [owner:ghuntley,label:verification;security] host-replacement-unenrolled-at-boot
    # The replacement provisioner MUST NOT auto-start its private stack before
    # its credential is issued through the real protected bridge. Runtime configs
    # for the private services and audi-private MUST keep the default deployed
    # wiring; the indirection remains dormant on every other host.
    services.ziggy = lib.mkIf (hostReplacement && name == "l2") { configurationFile = "/run/ziggy/ziggy-config.json"; };
    systemd.services.lilly.wantedBy = lib.mkIf (hostReplacement && name == "l2") (lib.mkForce []);
    systemd.services.ziggy.wantedBy = lib.mkIf (hostReplacement && name == "l2") (lib.mkForce []);
    systemd.services.galileo.wantedBy = lib.mkIf (hostReplacement && name == "l2") (lib.mkForce []);
    systemd.services.audi-private.wantedBy = lib.mkIf (hostReplacement && name == "l2") (lib.mkForce []);
    services.galileo = lib.mkIf (hostReplacement && name == "l2") { configurationFile = "/run/galileo/galileo-config.json"; };
    services.audiPrivate = lib.mkIf (hostReplacement && name == "l2") { configurationFile = "/run/audi-private/audi-private-config.json"; };
    # The replacement binds its server-issued host identity into each runtime
    # configuration exactly once, from the protected operator bridge receipt.
    systemd.services.lilly.preStart = lib.mkIf (hostReplacement && name == "l2") (lib.mkAfter
      "${pkgs.python3}/bin/python3 /etc/lilly-replacement-config.py");
    environment.etc."lilly-replacement-config.py" = lib.mkIf (hostReplacement && name == "l2")
      { source = ../enrollment-operator/configure.py; };
    services.overallsSecrets = {
      enable = true;
      bundles.lilly = {
        encryptedFile = "${root}/lilly.enc.json";
        outputs."credential.json" = { format = "raw"; secrets = [ "LILLY_CREDENTIAL" ]; };
      };
    };
    systemd.services.overalls-secrets-lilly = {
      after = [ "fleet-credentials.service" ];
      requires = [ "fleet-credentials.service" ];
    };
    virtualisation.memorySize = 6144;
    # Six vCPUs per fleet host. In machine-test run 41111309494, cloning-fleet
    # had 35 lilly.control_unavailable cycles: seven 2-vCPU VMs (the three
    # Marshall nodes among them) plus two 8-vCPU hosts, 30 vCPUs, shared one
    # 8-vCPU runner and starved the control plane. Six makes it 26.
    # Six is the floor: Lilly advertises min(logical CPUs, guestCpuCores
    # quota = 6), and enrollment asserts 6 cores, so advertised capacity and
    # every capacity scenario stay unchanged.
    virtualisation.cores = 6;
    virtualisation.vlans = [ 1 2 ];
    virtualisation.qemu.drives = map (member: {
      name = "fleet-${member}";
      file = "fleet-${member}.qcow2";
      driveExtraOpts = { format = "qcow2"; cache = "writeback"; werror = "report"; };
    }) [ "primary" "secondary" ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [{ address = host.ip; prefixLength = 24; }];
    networking.interfaces.eth2.ipv4.routes = [
      { address = "1.1.1.1"; prefixLength = 32; via = "11.0.0.1"; }
      { address = "9.9.9.9"; prefixLength = 32; via = "11.0.0.1"; }
    ];
    boot.zfs.forceImportRoot = false;
    boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
    systemd.services.zfs-zed.enable = false;
    # @cc [owner:ghuntley,label:verification;recovery] fleet-reboot-restores-eligible-mounts
    # After importing without mounts, fixture boot MUST mount existing canmount=on
    # filesystems under its Lilly parent, as normal ZFS boot does. It MUST NOT mount
    # noauto/off receive staging, change dataset properties to enable mounting, or
    # fabricate VM execution or cleanup authority.
    systemd.services.fleet-storage = {
      wantedBy = [ "multi-user.target" ];
      # The imported fixture pool carries root-era .lilly-* metadata: the
      # ownership hand-over must see it mounted, as zfs-mount guarantees on a
      # real host, or every pool lock stays root-owned and busy.
      before = [ "lilly-ownership.service" "lilly.service" ];
      path = [ config.boot.zfs.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        zpool import -N zroot
        # Match the real prepared disk size; admission still uses measured free
        # space, including image data, ZFS overhead and portable boot bundles.
        zfs set quota=${toString storageBudget} zroot/lilly
        zfs mount zroot/lilly
        # A restarted fixture already has VM children. Import -N leaves those
        # unmounted; mounting only the parent makes their intact disks invisible.
        set -o pipefail
        zfs list -H -r -t filesystem -o name,canmount,mounted zroot/lilly |
          while read -r dataset canmount mounted; do
            if [ "$canmount" = on ] && [ "$mounted" = no ]; then
              zfs mount "$dataset"
            fi
          done
        ${lib.optionalString (!(hostReplacement && name == "l2")) ''
        test "$(zpool get -Hp -o value guid zroot)" = ${lib.escapeShellArg identity.zpool_guid}
        test "$(zfs get -Hp -o value guid zroot/lilly)" = ${lib.escapeShellArg identity.dataset_guid}''}
      '';
    };
    services.lilly = {
      enable = true;
      package = lib.mkIf cloneCancellation observedCloneLilly;
      guestTrustRoots = guestPrivateRoots ++ [
        ../../../../../secrets/private-services-root.pem
        ../../../../../secrets/brady-root.pem
      ] ++ lib.optionals (name != "l1") [ ../../fixtures/ubuntu/ca.crt ]
        ++ lib.optionals (repositoryLaunch || githubIntegration) [ "${githubFixture}/root.pem" ];
      # Leave a deterministic observation window for the real mid-stream fault.
      # Relocation scenarios need a long write-during-copy window; bootstrap
      # scenarios exercise readiness and retain the ordinary 64 MiB/s limit.
      transferBytesPerSecond = lib.mkIf (relocation || cloning) ((if sshBootstrap then 64 else if cloning then 32 else 16) * 1024 * 1024);
      # Nested test hosts once read the 1.7 GB guest image over the 9p-shared
      # store: in machine-test run 41111309494 on namespace xl runners the
      # template copy ran below about 5.7 MB/s and expired the 300 s production
      # default, and in run 41164441328 it ended unconfirmed after 918.9 s
      # even at 900 s. The source now comes from a local read-only virtio-blk
      # drive (./image-store.nix); 900 s is retained until CI prewarm durations
      # from that medium are recorded. It applies to these fixtures only; the
      # production default stays 300 s.
      imageIoTimeoutSeconds = 900;
      hostId = host.host;
      controlPlane = "https://control.example.test:5443";
      controlPlaneCAFile = "${root}/ca.crt";
      credentialFile = "${config.services.overallsSecrets.bundles.lilly.directory}/credential.json";
      secretUnits = [ "fleet-credentials.service" "fleet-storage.service" config.services.overallsSecrets.bundles.lilly.unit ];
      egressInterface = "eth2";
      protectedCidrs = [ "11.0.0.2/32" "${hosts.${if name == "l1" then "l2" else "l1"}.ip}/32" ];
      guestCpuCores = 6;
      guestMemoryMiB = fixtureGuestMemoryMiB;
      # Candidate admission is confined to these disposable memory-continuation,
      # relocation and evacuation tests, including the Porsche lifecycle's and
      # the GitHub integration fleet's running-VM relocate (ADR-0199 refuses a
      # running move as source_unavailable without it); it never promotes a
      # production image.
      checkpointImageIds = lib.optionals (suspension || relocation || maintenanceEvacuation || porsche || githubIntegration) [ guestImageId ];
      images = [ { path = "${guest}"; } ]
        ++ lib.optionals ubuntu [ { path = "${nixosGuest}"; } ];
      pools = [{
        id = host.pool;
        path = "/var/lib/lilly/pool";
        filesystem_id = "zfs:${identity.zpool_guid}:${identity.dataset_guid}";
        storage = identity;
      }];
    };
    environment.systemPackages = lib.optionals runtimeReadiness [
      (pkgs.writeShellScriptBin "fleet-readiness" ''
        exec ${pkgs.python313}/bin/python3 ${./readiness-probe.py} /run/lilly-release/status.sock "$@"
      '')
    ] ++ lib.optionals observabilityRecovery [ pkgs.sqlite ] ++ lib.optionals brady [
      pkgs.conntrack-tools
      (pkgs.writeShellScriptBin "fleet-brady-attribution" ''
        exec ${pkgs.python3}/bin/python3 ${./brady-attribution.py} "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-brady-watcher" ''
        exec ${pkgs.python3}/bin/python3 ${./brady-watcher.py} "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-brady-flow-label" ''
        exec ${packages.lilly}/host-tools/bin/lilly-flow-label "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-brady-guest" ''
        export RELEASE_COOKIE=isolated-brady-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./brady-guest.exs}")' "$@"
      '')
    ] ++ [ config.boot.zfs.package pkgs.util-linux pkgs.git pkgs.nix pkgs.python3
      packages.secretTools.sops packages.secretTools.ssh-to-age pkgs.openssh
      (pkgs.writeShellScriptBin "fleet-seal-lilly" ''
        exec ${pkgs.python3}/bin/python ${./seal-lilly.py}
      '')
      (pkgs.writeShellScriptBin "fleet-host-probe" ''
        export RELEASE_COOKIE=isolated-host-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("${./host-probe.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-seal-ziggy" ''
        exec ${pkgs.python3}/bin/python ${./seal-lilly.py} ziggy
      '')
      (pkgs.writeShellScriptBin "fleet-seal-galileo" ''
        exec ${pkgs.python3}/bin/python ${./seal-lilly.py} galileo
      '')
      (pkgs.writeShellScriptBin "fleet-seal-peach" ''
        exec ${pkgs.python3}/bin/python ${./seal-lilly.py} peach
      '')
      (pkgs.writeShellScriptBin "fleet-seal-audi-private" ''
        export FLEET_AUDI_PRIVATE_CERTIFICATE=${galileoFixture.pki}/private.pem
        export FLEET_AUDI_PRIVATE_KEY=${galileoFixture.pki}/private.key
        exec ${pkgs.python3}/bin/python ${./seal-lilly.py} audi-private
      '')
      (pkgs.writeShellScriptBin "fleet-network" ''
        export PATH="${config.boot.zfs.package}/bin:/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export RELEASE_COOKIE=isolated-network-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./network.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-relocation-guest" ''
        export PATH="${config.boot.zfs.package}/bin:/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export RELEASE_COOKIE=isolated-relocation-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./relocation-guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-resize-guest" ''
        export RELEASE_COOKIE=isolated-resize-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../resize/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-guest-trust" ''
        export PATH="${config.boot.zfs.package}/bin:/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export RELEASE_COOKIE=isolated-trust-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        # Config.load reads the control credential as lilly.service's systemd credential.
        export CREDENTIALS_DIRECTORY=/run/credentials/lilly.service
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../fleet-guest-trust/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-github-integration-guest" ''
        export RELEASE_COOKIE=isolated-github-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../github-integration-fleet/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-repository-launch-guest" ''
        export RELEASE_COOKIE=isolated-launch-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../repository-launch/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-default-oss-guest" ''
        export RELEASE_COOKIE=isolated-profile-probe RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../default-oss/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-editor-guest" ''
        export PATH="${config.boot.zfs.package}/bin:/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        ${lib.optionalString editor ''
          export FLEET_EDITOR_NODE="${editorRuntimeNode}" FLEET_EDITOR_COMMIT="${packages.vscodeWeb.sourceCommit}"
        ''}
        export ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none RELEASE_COOKIE=isolated-editor-guest
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        # Config.load reads the control credential as lilly.service's systemd credential.
        export CREDENTIALS_DIRECTORY=/run/credentials/lilly.service
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${../vscode-web/guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-galileo-guest" ''
        export FLEET_GUEST_PYTHON=${pkgs.python3}/bin/python3
        export RELEASE_COOKIE=isolated-galileo-guest RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./galileo-guest.exs}")' "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-processes" ''
        exec ${pkgs.python3}/bin/python ${../../support/vm-processes.py} "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-relocation-diagnostics" ''
        exec ${pkgs.python3}/bin/python ${./relocation-diagnostics.py} "$@"
      '')
      (pkgs.writeShellScriptBin "fleet-host-identity" ''
        set -euo pipefail
        export PATH="${config.boot.zfs.package}/bin:/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export RELEASE_COOKIE=isolated-host-observation RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval '
          {:ok, machine} = Lilly.Host.Identity.read()
          {:ok, pool} = Lilly.Host.ZFS.inspect_path("/var/lib/lilly/pool")
          IO.puts(JSON.encode!(%{machine_id: machine, storage: OverallsProtocol.Storage.encode(pool.storage)}))
        '
      '')
      # @cc [owner:ghuntley,label:verification;security] native-provisioning-exact-boot-proof
      # The disposable host probe MUST validate placement/host UUIDs and the
      # digest of the guest-observed boot UUID before reading host-local state,
      # load the production-validated journal and current running intent/boot,
      # and compare host, placement, execution and guest boot bindings.
      # It MUST emit only a fixed verdict, never the boot challenge or payload;
      # a journal read is evidence, not execution or cleanup authority.
      (pkgs.writeShellScriptBin "fleet-provisioning-verify" ''
        set -euo pipefail
        test "$#" -eq 3
        export PROBE_PLACEMENT="$1" PROBE_BOOT_SHA256="$2" PROBE_HOST="$3"
        export RELEASE_COOKIE=isolated-host-observation RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval '
          placement = System.fetch_env!("PROBE_PLACEMENT")
          boot_digest = System.fetch_env!("PROBE_BOOT_SHA256")
          host_id = System.fetch_env!("PROBE_HOST")

          with true <- OverallsProtocol.uuid?(placement) and OverallsProtocol.uuid?(host_id),
               true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, boot_digest),
               directory = Path.join("/var/lib/lilly/vms", placement),
               {:ok, intent} when is_map(intent) <- Lilly.VM.Intent.read(directory),
               {:ok, boot} when is_map(boot) <- Lilly.VM.Boot.read(directory),
               {:ok, record} when is_map(record) <-
                 Lilly.Lifecycle.Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json"),
               true <- intent.state == :running and intent.placement_id == placement,
               true <- boot.placement_id == placement and
                 boot.execution_epoch == intent.execution_epoch and
                 boot.generation == intent.generation,
               true <- record.state == :ready and
                 record.payload["host_id"] == host_id and
                 record.payload["placement_id"] == placement and
                 record.payload["execution_epoch"] == intent.execution_epoch and
                 record.payload["generation"] == intent.generation and
                 record.payload["boot_challenge"] == boot.boot_challenge and
                 Base.encode16(:crypto.hash(:sha256, record.payload["boot_id"]), case: :lower) == boot_digest and
                 record.payload["deadline"] - record.payload["launched_at"] == 120_000 do
            IO.puts("current-boot-ready")
          else
            _ -> System.halt(1)
          end
        '
      '')
    ] ++ lib.optionals codingClis [
      (pkgs.writeShellScriptBin "fleet-coding-clis-guest" ''
        export RELEASE_COOKIE=isolated-coding-clis-guest RELEASE_DISTRIBUTION=none ERL_FLAGS="+S 2:2"
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
        exec ${packages.lilly}/bin/lilly eval 'Code.require_file("${./terminal.exs}"); Code.eval_file("${./coding-clis-guest.exs}")' "$@"
      '')
    ] ++ lib.optionals editor [
      # @cc [owner:ghuntley,label:verification;security] editor-preflight-live-config-custody
      # The preflight MUST obtain only the configuration path from the current
      # service's environment as root and recheck its PID. Configuration and
      # listener validation MUST retain the Audi UID and service mount namespace;
      # environment entries and configuration contents MUST NOT be printed.
      (pkgs.writeShellScriptBin "fleet-editor-zone" ''
        set -euo pipefail
        umask 077
        editor_service_pid="$(${pkgs.systemd}/bin/systemctl show -p MainPID --value audi.service)"
        case "$editor_service_pid" in
          ""|*[!0-9]*) exit 1 ;;
        esac
        test "$editor_service_pid" -gt 0
        editor_runtime_path=""
        editor_runtime_count=0
        while IFS= read -r -d "" editor_runtime_entry; do
          case "$editor_runtime_entry" in
            AUDI_CONFIG_FILE=*)
              editor_runtime_count=$((editor_runtime_count + 1))
              editor_runtime_path="''${editor_runtime_entry#AUDI_CONFIG_FILE=}"
              ;;
          esac
        done < "/proc/$editor_service_pid/environ"
        unset editor_runtime_entry
        test "$editor_runtime_count" -eq 1
        case "$editor_runtime_path" in
          /nix/store/*) ;;
          *) exit 1 ;;
        esac
        test "$editor_service_pid" = "$(${pkgs.systemd}/bin/systemctl show -p MainPID --value audi.service)"
        ${pkgs.coreutils}/bin/install -d -m 0700 -o audi -g audi /run/audi/editor-zone-preflight
        exec ${pkgs.util-linux}/bin/nsenter --target "$editor_service_pid" --mount \
          ${pkgs.util-linux}/bin/runuser -u audi -- \
          ${pkgs.coreutils}/bin/env -u AUDI_CONFIG_FILE -u AUDI_SLO_SNAPSHOT \
          ERL_FLAGS="+S 2:2" RELEASE_DISTRIBUTION=none RELEASE_COOKIE=isolated-editor-zone \
          RELEASE_TMP=/run/audi/editor-zone-preflight ERL_CRASH_DUMP=/dev/null \
          ${packages.audi}/bin/audi eval 'Code.eval_file("${../vscode-web/zone.exs}")' \
          "$editor_runtime_path" "${packages.vscodeWeb.releaseId}"
      '')
    ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.fleet-host-listener = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        mkdir -p /run/fleet-host-listener
        exec ${pkgs.python3}/bin/python -m http.server 8080 --directory /run/fleet-host-listener
      '';
    };
  };
  runTest =
    if hegel != null && (runtimeReadiness || observabilityRecovery) then hegel.runTest
    else args: pkgs.testers.runNixOSTest (lib.removeAttrs args [ "properties" ]);
in
# @cc [owner:ghuntley,label:verification;security] default-profile-trust-prerequisites
# Default-profile, resize, account-lifecycle and team-resource journeys MUST use the trust-enabled Audi fleet image and
# private-service fixtures. Disabling host trust or guest readiness MUST NOT
# compensate for selecting a guest image without the boot trust receiver.
assert !(defaultOss || repositoryLaunch || githubIntegration || resize || accountLifecycle || teamResources || maintenanceEvacuation || cloneCancellation) || audi;
assert !otelPorsche || (porsche && builtins.length porscheScenarioParts == 2);
# @cc [owner:ghuntley,label:verification] porsche-threads-fleet-scope
# The porsche-threads journey MUST follow the complete Porsche scenario (real
# key approval, authorized SSH dispatch, guest lifecycle, sharing, relocation
# and cloning), whose client keys and helpers it reuses, then provision its own
# thread machine. It never runs in other reduced variants.
assert !porscheThreads || (porsche && !terminal && !userSshJourney && !otelPorsche && !porscheLifecycleOnly && builtins.length porscheScenarioParts == 2);
assert !repositoryLaunch || (porsche && !defaultOss);
assert !githubIntegration || (galileo && audi && !repositoryLaunch && !defaultOss && !ubuntu);
assert githubFamily == null || (githubIntegration && builtins.elem githubFamily [ "nixos" "ubuntu" "arch" "almalinux" "windows" ]);
assert !(defaultOss || resize || accountLifecycle || teamResources || maintenanceEvacuation || cloneCancellation) || audi;
# @cc [owner:ghuntley,label:verification] roster-matrix-real-stack
# The roster/identity matrix MUST run on the Audi fleet with real relocation
# support; selecting the journey cannot substitute synthetic rosters.
assert !sshRosterMatrix || (audi && relocation && !porsche && !cloning);
# @cc [owner:ghuntley,label:verification;capacity] fleet-race-pool-fits-reservation
# The plain fleet's pool MUST leave estimated free space, after the template,
# first guest and overhead, of at least three real startup reservations for the
# selected image, so image growth fails here rather than as a timeout. The race
# itself trims the reported free space at runtime to two and a half
# reservations; this bound only guarantees that there is room to trim.
# Guest trust runs no startup race; its pool is sized for three NixOS guests.
assert builtins.isInt guestManifest.minimum_disk_bytes
  && (let free = storageGiB * GiB - raceUsed;
      in suspension || cloning || codingClis || cloneDestinationLoss || cloneMarshallRestart || guestTrust
        || free >= 3 * raceReservation);
# @cc [owner:ghuntley,label:verification] resize-fixture-image-minima
# The selected real image's numeric disk/memory minima MUST fit the fixed
# initial resize/team-resource request before its scenario may run.
assert !(resize || teamResources || maintenanceEvacuation || cloneCancellation) || (let
  # This predicate uses numeric minima only; the guest is already a closure
  # input, and boot_args store references must not become JSON parser context.
  manifest = guestManifest;
  in builtins.isInt manifest.minimum_disk_bytes && builtins.isInt manifest.minimum_memory_bytes
    && manifest.minimum_disk_bytes <= 5368709120 && manifest.minimum_memory_bytes <= 536870912);
# @cc [owner:ghuntley,label:verification] integration-renewal-real-stack
# Renewal acceptance MUST compose the strictly typed ordinary-user team journey
# with packaged Galileo, Audi and Porsche; selecting the variant cannot skip it.
assert !integrationRenewals || (teamResources && galileo && audi && porsche);
assert !privateWeb || (teamResources && galileo && audi && porsche);
assert !agentCli || (agent && galileo && audi && !ubuntu);
assert !otelGuest || (agent && galileo && audi && !ubuntu);
assert !otelGalileo || (galileo && audi && !ubuntu && !brady);
assert !otelAudiSsh || (audi && !ubuntu && !otelGuest && !otelGalileo && !brady);
assert !otelAudiSsh || (builtins.length otelAudiSshScenarioParts == 2
  && lib.hasInfix "audi-ssh-native-collector-outcome" (builtins.head otelAudiSshScenarioParts)
  && lib.hasInfix "for metric in (\"requests\", \"successes\")" (builtins.head otelAudiSshScenarioParts)
  && !(lib.hasInfix "action=\"share\"" (builtins.head otelAudiSshScenarioParts))
  && !(lib.hasInfix "with subtest(\"Lilly process crash preserves live ingress" (builtins.head otelAudiSshScenarioParts)));
assert !guestCliRecovery || (agent && galileo && audi);
assert !executorLoss || (agent && galileo && audi && agentCli && !ubuntu);
assert !serverTool || (agent && galileo && audi && !ubuntu && !agentCli && !guestCliRecovery && !executorLoss && !otelGuest && !(artifactAgentPublish && threadTool));
# @cc [owner:ghuntley,label:verification] sharing-surfaces-real-stack
# The combined sharing journey MUST run on the Audi-enabled real guest image;
# the variant flag cannot stand alone.
assert !sharingSurfaces || audi;
# @cc [owner:ghuntley,label:verification] porsche-terminal-fleet-scope
# The SSH attach journey MUST compose real key approval and authorized Porsche
# dispatch, then a personal-terminal guest, and stop before VM lifecycle.
assert !porscheTerminal || (porsche && terminal && !otelPorsche && !porscheLifecycleOnly && !userSshJourney && builtins.length porscheScenarioParts == 2);
# @cc [owner:ghuntley,label:verification] mila-terminal-fleet-scope
# The Mila terminal journey (ADR-0264) MUST reuse the Porsche terminal
# prerequisites (real key approval, authorized dispatch, a running personal
# terminal guest) and replace only the OpenSSH attach fragment with the Mila
# Rust core driver.
assert !milaTerminal || porscheTerminal;
# @cc [owner:ghuntley,label:verification] porsche-lifecycle-native-scope
# The focused variant MUST retain the complete existing Porsche lifecycle,
# enrollment and real-guest prerequisites on two provisioners; it MAY omit only
# the unrelated browser/terminal scenarios after the Porsche fragment.
# NixOS and Ubuntu variants MUST have distinct driver identities.
assert !porscheLifecycleOnly || (porsche && !terminal && !userSshJourney && !cloning && !otelAudiSsh);
# @cc [owner:ghuntley,label:verification;security] coding-clis-native-stack
# Coding-client variants MUST exercise the production native guest packages
# through mandatory private services, with no substitute provider/configuration
# launcher. They MUST retain independent NixOS and Ubuntu driver identities.
assert !suspension || (relocation && !editor && audi);
assert !codingClis || (!editor && !audi && !porsche && !cloning && !agent && !relocation);
assert !editor || (audi && !porsche && !cloning && !agent && !relocation);
assert editorFamily == null || (editor && !ubuntu
  && builtins.elem editorFamily [ "arch" "almalinux" ]);
(runTest {
  properties = {
    enable = hegel != null && (runtimeReadiness || observabilityRecovery);
    profile = "ci";
    testCases = 4;
    redact = false;
  };
  hostPkgs = lib.mkForce (import ../../support/driver-pkgs.nix pkgs);
  name = if milaTerminal then "overalls-mila-journey-terminal" else if porscheTerminal then "overalls-porsche-terminal-fleet" else if suspension then "overalls-memory-suspension-fleet" else if codingClis then (if ubuntu then "overalls-coding-clis-ubuntu-fleet" else "overalls-coding-clis-nixos-fleet") else if editor then "overalls-vscode-web-${selectedEditorFamily}-fleet" else if observabilityRecovery then "overalls-lilly-observability-recovery" else if porscheThreads then "overalls-porsche-threads-fleet" else if porscheLifecycleOnly then (if ubuntu then "overalls-porsche-lifecycle-ubuntu-fleet" else "overalls-porsche-lifecycle-fleet") else if runtimeReadiness then "overalls-lilly-runtime-readiness" else if otelPorsche then "overalls-otel-porsche-native" else if otelAudiSsh then "overalls-otel-audi-ssh-native" else if otelGalileo then "overalls-otel-galileo-native" else if otelGuest then "overalls-otel-guest-native" else if cloneDestinationLoss then "overalls-clone-destination-loss" else if cloneMarshallRestart then "overalls-clone-marshall-restart" else if hostReplacement then "overalls-host-replacement" else if executorLoss then "overalls-executor-loss" else if sharingSurfaces then "overalls-sharing-surfaces" else if cloneCancellation then "overalls-clone-cancellation" else if guestCliRecovery then (if ubuntu then "overalls-guest-cli-recovery-ubuntu" else "overalls-guest-cli-recovery") else if maintenanceEvacuation then "overalls-maintenance-evacuation" else if agentCli then "overalls-agent-cli-journey" else if privateWeb then "overalls-private-web" else if integrationRenewals then "overalls-integration-renewals" else if teamResources then "overalls-team-resources" else if guestTrust then "overalls-fleet-guest-trust" else if accountLifecycle then "overalls-account-lifecycle" else if resize then "overalls-resize-browser" else if githubIntegration then "overalls-github-integration-${selectedGitHubFamily}-fleet" else if repositoryLaunch then (if ubuntu then "overalls-repository-launch-ubuntu-fleet" else "overalls-repository-launch") else if defaultOss then "overalls-default-oss-creation" else if userSshJourney then (if ubuntu then "overalls-user-ssh-journey-ubuntu-fleet" else "overalls-user-ssh-journey-fleet") else if artifactAgentPublish then "overalls-artifact-agent-publish" else if threadTool then "overalls-thread-tool" else if agent then (if ubuntu then "overalls-agent-ubuntu-fleet" else "overalls-agent-fleet") else if terminal then (if ubuntu then "overalls-terminal-ubuntu-fleet" else "overalls-terminal-fleet") else if galileo then "overalls-galileo-fleet" else if brady then "overalls-brady-fleet" else if sshRosterMatrix then (if ubuntu then "overalls-ssh-roster-matrix-ubuntu-fleet" else "overalls-ssh-roster-matrix-fleet") else if sshBootstrap then (if ubuntu then "overalls-ssh-bootstrap-ubuntu-fleet" else "overalls-ssh-bootstrap-fleet") else if ubuntu && audi then (if relocation then "overalls-audi-ubuntu-relocation-fleet" else "overalls-audi-ubuntu-fleet") else if ubuntu then "overalls-ubuntu-fleet" else if customerIsolation then "overalls-customer-isolation-fleet" else if cloning then "overalls-cloning-fleet" else if audi && relocation then "overalls-audi-relocation-fleet" else if audi then "overalls-audi-fleet" else if relocation then "overalls-relocation-fleet" else if porsche then "overalls-porsche-fleet" else "overalls-fleet";
  requiredFeatures.nested-kvm = true;
  inherit skipTypeCheck;
  globalTimeout = if githubIntegration && selectedGitHubFamily == "windows" then 14400 else if relocation then 10800 else 3600;
  defaults = common;
  nodes = {
    m1 = marshall "m1";
    m2 = marshall "m2";
    m3 = marshall "m3";
    l1 = lilly "l1";
    l2 = lilly "l2";
    db = { config, lib, ... }: {
      virtualisation.memorySize = 1536;
      networking.firewall.allowedUDPPorts = [ 123 ];
      imports = [ (import ../../support/fleet-database.nix {
        generationService = "fleet-generate";
        maxConnections = 64;
        allowedNetwork = "192.168.1.0/24";
      }) ];
    };
    proxy = { config, lib, nodes, ... }: {
      networking.firewall.interfaces.eth1.allowedTCPPorts = [ 5443 ];
      services.marshallProxy = {
        enable = true;
        publicHost = "control.example.test";
        certificateFile = "/var/lib/overalls-fleet-proxy/full.pem";
        backendCAFile = "/var/lib/overalls-fleet-proxy/ca.crt";
        secretUnits = [ "fleet-credentials.service" ];
        backends = lib.genAttrs [ "m1" "m2" "m3" ] (name: {
          address = nodes.${name}.networking.primaryIPAddress;
          port = 4443;
          serverName = name;
        });
      };
      # Root-only fixture control; no public administrative endpoint is added.

      # @cc [owner:ghuntley,label:verification] relocation-transport-faults-only
      # The disposable relocation fixture MAY reject selected control paths via
      # its root-only runtime socket. Faults MUST NOT forge responses or mutate
      # durable authority; ordinary host reports and unrelated paths stay live.
      services.haproxy.config = lib.mkMerge [ (lib.mkBefore ''
        global
          stats socket /run/haproxy/fleet.sock mode 600 level admin
      '') (lib.mkAfter ''
        frontend marshall_fleet
          bind ${config.networking.primaryIPAddress}:5443 ssl crt /var/lib/overalls-fleet-proxy/full.pem alpn h2,http/1.1
          http-request del-header Forwarded
          http-request del-header X-Forwarded-For
          http-request del-header X-Forwarded-Host
          http-request del-header X-Forwarded-Proto
          default_backend marshall_fleet_nodes

        backend marshall_fleet_nodes
          balance roundrobin
          option httpchk
          http-check send meth GET uri /health/ready ver HTTP/1.1 hdr Host control.example.test
          http-check expect status 200
          default-server inter 1s fall 2 rise 2
          ${lib.concatMapStringsSep "\n          " (name:
            "server ${name} ${nodes.${name}.networking.primaryIPAddress}:5443 resolve-prefer ipv4 ssl verify required verifyhost ${name} sni str(${name}) check check-ssl check-sni ${name} ca-file /var/lib/overalls-fleet-proxy/ca.crt"
          ) [ "m1" "m2" "m3" ]}
      '') ];
      environment.systemPackages = [ pkgs.socat ];
      # The Mila core reaches Porsche at the deployment's public host, as
      # production clients do; forward that host's SSH port to m1's Porsche.
      networking.firewall.allowedTCPPorts = lib.optionals milaTerminal [ 2222 ];
      systemd.services.fleet-mila-porsche-forward = lib.mkIf milaTerminal {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:2222,fork,reuseaddr TCP:${nodes.m1.networking.primaryIPAddress}:22";
          Restart = "always";
          DynamicUser = true;
        };
      };
    };
    egress = { lib, ... }: {
      imports = lib.optional (galileo && !githubIntegration) galileoFixture.origin;
      virtualisation.vlans = [ 1 2 ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        { address = "11.0.0.1"; prefixLength = 24; }
        { address = "11.0.0.2"; prefixLength = 24; }
        { address = "1.1.1.1"; prefixLength = 32; }
        { address = "9.9.9.9"; prefixLength = 32; }
      ];
      networking.firewall.allowedTCPPorts = [ 8080 53 ] ++ lib.optionals (brady || repositoryLaunch || githubIntegration) [ 80 443 ];
      systemd.services.fleet-github-provider = lib.mkIf githubIntegration {
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.git ];
        serviceConfig = {
          ExecStart = "${python}/bin/python3 ${githubFleetArtifacts}/provider.py ${githubFixture}/github.pem ${githubFixture}/github.key";
          RuntimeDirectory = "galileo-fixture";
          RuntimeDirectoryMode = "0700";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
        };
      };
      # Smart-HTTP Git and bounded provider APIs share the isolated TLS origin.
      systemd.services.fleet-git-backend = lib.mkIf repositoryLaunch {
        wantedBy = [ "multi-user.target" ];
        before = [ "nginx.service" ];
        serviceConfig = {
          User = "nginx";
          Group = "nginx";
          RuntimeDirectory = "fleet-git-backend";
          ExecStart = "${pkgs.fcgiwrap}/bin/fcgiwrap -c 4 -s unix:/run/fleet-git-backend/socket";
        };
      };
      services.nginx = lib.mkIf repositoryLaunch {
        enable = true;
        virtualHosts = lib.genAttrs [ "github.com" "gitlab.com" "codeberg.org" "bitbucket.org" "api.bitbucket.org" ] (host: {
          listen = [ { addr = "11.0.0.1"; port = 443; ssl = true; } ];
          onlySSL = true;
          sslCertificate = "${githubFixture}/github.pem";
          sslCertificateKey = "${githubFixture}/github.key";
          locations = {
            "/".extraConfig = if host == "api.bitbucket.org" then "return 404;" else ''
            fastcgi_pass unix:/run/fleet-git-backend/socket;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${pkgs.git}/libexec/git-core/git-http-backend;
            fastcgi_param GIT_PROJECT_ROOT /var/lib/git-fixture;
            fastcgi_param GIT_HTTP_EXPORT_ALL "";
            fastcgi_param PATH_INFO $uri;
          '';
          } // lib.optionalAttrs (host == "codeberg.org") {
            "= /api/v1/repos/overalls/fixture/pulls/7".extraConfig = ''
              default_type application/json;
              alias /var/lib/git-api/codeberg.json;
            '';
          } // lib.optionalAttrs (host == "api.bitbucket.org") {
            "= /2.0/repositories/overalls/fixture/pullrequests/7".extraConfig = ''
              default_type application/json;
              alias /var/lib/git-api/bitbucket.json;
            '';
          };
        });
      };
      systemd.tmpfiles.rules = lib.optionals repositoryLaunch [ "d /var/lib/git-fixture 0755 root root -" ];
      environment.systemPackages = lib.optionals repositoryLaunch [ pkgs.git ] ++ lib.optionals brady [
        (pkgs.writeShellScriptBin "fleet-brady-origin-prepare" ''
          exec ${bradyPython}/bin/python3 ${../brady-network/origin.py} prepare
        '')
      ];
      systemd.services.fleet-brady-origin = lib.mkIf brady {
        environment.BRADY_TEST_ADDRESS = "11.0.0.1";
        serviceConfig.ExecStart = "${bradyPython}/bin/python3 ${../brady-network/origin.py} serve";
      };
      networking.firewall.allowedUDPPorts = [ 53 ];
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          no-resolv = true;
          bind-interfaces = true;
          listen-address = [ "1.1.1.1" "9.9.9.9" ];
          address = [ "/fleet.example.test/11.0.0.1" ] ++ lib.optionals repositoryLaunch [ "/github.com/11.0.0.1" "/gitlab.com/11.0.0.1" "/codeberg.org/11.0.0.1" "/bitbucket.org/11.0.0.1" ];
          # @cc [owner:ghuntley,label:verification;security] repository-fixture-authoritative-dns
          # Fixed provider fixture domains MUST answer unmatched RR types locally rather
          # than forwarding them to an absent upstream. In particular, IPv6
          # NODATA MUST accompany the fixed IPv4 answer so the real musl client
          # can resolve provider APIs without weakening TLS or using public DNS.
          local = lib.optionals repositoryLaunch [ "/github.com/" "/gitlab.com/" "/codeberg.org/" "/bitbucket.org/" ];
        };
      };
      systemd.services.fleet-egress = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          mkdir -p /run/fleet-egress
          printf 'fixture-egress-ok\n' >/run/fleet-egress/index.html
          exec ${pkgs.python3}/bin/python -m http.server 8080 --directory /run/fleet-egress
        '';
      };
    };
    client = { nodes, ... }: {
      networking.nameservers = [ nodes.m2.networking.primaryIPAddress nodes.m3.networking.primaryIPAddress ];
      networking.extraHosts = lib.mkIf githubIntegration
        "${nodes.egress.networking.primaryIPAddress} ${lib.concatStringsSep " " githubProviderHosts}";
      virtualisation.memorySize = 2048;
      users.users.tester = { isNormalUser = true; home = "/home/tester"; };
      environment.systemPackages = lib.optionals milaTerminal [ packages.mila.rust pkgs.curl ]
        ++ [ python pkgs.chromium pkgs.nssTools pkgs.openssh pkgs.dig
        (pkgs.writeShellScriptBin "fleet-audi-browser" ''
          exec ${python}/bin/python ${audiBrowser}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-browser" ''
          exec ${python}/bin/python ${terminalBrowser}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-porsche-browser" ''
          exec ${python}/bin/python ${porscheBrowser}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-private-web-browser" ''
          exec ${python}/bin/python ${privateWebArtifacts}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-team-resource-browser" ''
          exec ${python}/bin/python ${teamResourceBrowser}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-evacuation-browser" ''
          exec ${python}/bin/python ${evacuationArtifacts}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-resize-browser" ''
          exec ${python}/bin/python ${resizeBrowser}/browser.py "$@"
        '')
        (pkgs.writeShellScriptBin "fleet-default-oss-browser" ''
          exec ${python}/bin/python ${defaultOssBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals githubIntegration [
        (pkgs.writeShellScriptBin "fleet-github-integration-browser" ''
          exec ${python}/bin/python ${githubFleetArtifacts}/browser.py "$@"
        '')
      ] ++ lib.optionals repositoryLaunch [
        (pkgs.writeShellScriptBin "fleet-repository-launch-browser" ''
          exec ${python}/bin/python ${repositoryLaunchBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals agentCli [
        (pkgs.writeShellScriptBin "fleet-agent-cli-browser" ''
          exec ${python}/bin/python ${if executorLoss then executorLossBrowser else agentCliBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals cloneCancellation [
        (pkgs.writeShellScriptBin "fleet-clone-cancellation-browser" ''
          exec ${python}/bin/python ${cloneCancellationBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals accountLifecycle [
        (pkgs.writeShellScriptBin "fleet-account-lifecycle-browser" ''
          exec ${python}/bin/python ${accountLifecycleBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals sharingSurfaces [
        (pkgs.writeShellScriptBin "fleet-sharing-browser" ''
          exec ${python}/bin/python ${sharingSurfacesBrowser}/browser.py "$@"
        '')
      ] ++ lib.optionals (audi || codingClis) [ packages.lyraLinux ];
    };
  };
  testScript = if codingClis then ''
    storage_budget = ${toString storageBudget}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    ubuntu_enabled = ${if ubuntu then "True" else "False"}
    porsche_enabled = False
    cloning_enabled = False
    relocation_enabled = False
    audi_enabled = True
    galileo_enabled = False
    ssh_private_enabled = True
    agent_enabled = False
    coding_cli_guest_image = "${guest}"
    coding_cli_provider_ca = "${ziggyFixture.tls}/ca.pem"
  '' + lib.concatMapStringsSep "\n" builtins.readFile [
    ./driver.py
    ../../support/transfer.py
    ../../support/guest-diagnostics.py
    ./helpers.py
    ./scenarios/bootstrap.py
    ./scenarios/enrollment.py
    ./scenarios/boot-trust-services.py
    ./scenarios/coding-clis.py
  ]
  else if editor then ''
    storage_budget = ${toString storageBudget}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    enroll_transfer_endpoints = False
    editor_guest_family = "${selectedEditorFamily}"
    editor_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    editor_browser_artifact = "${editorBrowser}"
    editor_python = "${python}/bin/python"
    editor_source_commit = "${packages.vscodeWeb.sourceCommit}"
    editor_release = "${packages.vscodeWeb.releaseId}"
  '' + builtins.readFile ../../support/transfer.py
     + builtins.readFile ../../support/guest-diagnostics.py
     + builtins.readFile ../default-oss/setup.py
     + builtins.readFile ../vscode-web/fleet.py
  else if agentCli || guestCliRecovery || executorLoss then ''
    storage_budget = ${toString storageBudget}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
  '' + builtins.readFile ../../support/transfer.py
     + builtins.readFile ../../support/guest-diagnostics.py
     + builtins.readFile (if executorLoss then ../executor-loss/driver.py else if guestCliRecovery then ../guest-cli-recovery/driver.py else ../agent-cli-journey/driver.py)
  else if hostReplacement then ''
    storage_budget = ${toString storageBudget}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    replacement_host = "l2"
    ubuntu_enabled = False
    porsche_enabled = False
    cloning_enabled = False
    relocation_enabled = False
    audi_enabled = True
    galileo_enabled = False
    ssh_private_enabled = True
    agent_enabled = False
  '' + lib.concatMapStringsSep "\n" builtins.readFile [
    ./driver.py
    ../../support/transfer.py
    ../../support/guest-diagnostics.py
    ./helpers.py
    ./scenarios/bootstrap.py
    ./scenarios/enrollment.py
    ./scenarios/host-replacement.py
  ]
  else if sharingSurfaces then ''
    storage_budget = ${toString storageBudget}
    ubuntu_enabled = False
    porsche_enabled = False
    cloning_enabled = False
    relocation_enabled = False
    audi_enabled = True
    galileo_enabled = False
    ssh_private_enabled = True
    agent_enabled = False
    storage_dataset = "${identity.dataset}"
    guest_image = "${guest}"
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    sharing_guest_origin = "${../private-web/guest.py}"
  '' + lib.concatMapStringsSep "\n" builtins.readFile [
    ./driver.py
    ../../support/transfer.py
    ../../support/guest-diagnostics.py
    ./helpers.py
    ./scenarios/bootstrap.py
    ./scenarios/enrollment.py
    ./scenarios/sharing-surfaces.py
  ]
  else if guestTrust then ''
    storage_budget = ${toString storageBudget}
    nixos_guest_disk_bytes = ${toString trustNixosDiskBytes}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
  '' + builtins.readFile ../../support/transfer.py
     + builtins.readFile ../../support/guest-diagnostics.py
     + builtins.readFile ../../support/update.py
     + builtins.readFile ../fleet-guest-trust/driver.py
  else if defaultOss || repositoryLaunch || githubIntegration || resize || accountLifecycle || teamResources || maintenanceEvacuation || cloneCancellation then ''
    storage_budget = ${toString storageBudget}
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
    enroll_transfer_endpoints = ${if githubIntegration then "True" else "False"}
  '' + builtins.readFile ../../support/transfer.py
     + builtins.readFile ../../support/guest-diagnostics.py
     + (if cloneCancellation then builtins.readFile ../clone-cancellation/driver.py
       else if maintenanceEvacuation then builtins.readFile ../maintenance-evacuation/driver.py
       else if teamResources then builtins.readFile ../team-resources/driver.py
       else if accountLifecycle then builtins.readFile ../account-lifecycle/driver.py
       else if resize then builtins.readFile ../resize/driver.py
       else if githubIntegration then ''
         github_fixture_root = "${githubFixture}/root.pem"
         github_guest_os = "${selectedGitHubFamily}"
       '' + builtins.readFile ../default-oss/setup.py + builtins.readFile ../github-integration-fleet/driver.py
       else if repositoryLaunch then ''
         github_fixture_root = "${githubFixture}/root.pem"
         overalls_zone = "apps.example.test"
       '' + builtins.readFile ../default-oss/setup.py + builtins.readFile ../repository-launch/driver.py
       else builtins.readFile ../default-oss/setup.py + builtins.readFile ../default-oss/driver.py)
     + lib.optionalString integrationRenewals (builtins.readFile ../integration-renewals/driver.py)
     + lib.optionalString privateWeb (''
       private_web_origin = "${privateWebArtifacts}/guest.py"
     '' + builtins.readFile ../private-web/driver.py)
  else if cloneDestinationLoss || cloneMarshallRestart then ''
    storage_budget = ${toString storageBudget}
    ubuntu_enabled = False
    porsche_enabled = True
    cloning_enabled = True
    relocation_enabled = False
    audi_enabled = True
    galileo_enabled = False
    ssh_private_enabled = True
    agent_enabled = False
    storage_dataset = "${identity.dataset}"
    guest_image = "${guest}"
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
  '' + lib.concatMapStringsSep "\n" builtins.readFile [
    ./driver.py
    ../../support/transfer.py
    ../../support/guest-diagnostics.py
    ./helpers.py
    ./scenarios/bootstrap.py
    ./scenarios/enrollment.py
    ]
    + builtins.readFile ./scenarios/boot-trust-services.py
    + (if cloneDestinationLoss then builtins.readFile ../clone-permutations/destination-loss.py else builtins.readFile ../clone-permutations/marshall-restart.py)
  else ''
    storage_budget = ${toString storageBudget}
    ubuntu_enabled = ${if ubuntu then "True" else "False"}
    porsche_enabled = ${if porsche then "True" else "False"}
    cloning_enabled = ${if cloning then "True" else "False"}
    relocation_enabled = ${if relocation then "True" else "False"}
    audi_enabled = True
    galileo_enabled = ${if galileo then "True" else "False"}
    ssh_private_enabled = True
    agent_enabled = ${if agent then "True" else "False"}
    otel_guest_enabled = ${if otelGuest then "True" else "False"}
    otel_galileo_enabled = ${if otelGalileo then "True" else "False"}
    otel_audi_ssh_enabled = ${if otelAudiSsh then "True" else "False"}
    ${lib.optionalString agent ''agent_release_digest = "${(builtins.fromJSON (builtins.readFile "${packages.lyra}/manifest.json")).artifacts.linux-amd64.sha256}"''}
    storage_dataset = "${identity.dataset}"
    guest_image = "${guest}"
    storage_images = "${storage}"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    host_bindings = ${builtins.toJSON hosts}
    fixture_guest_memory_bytes = ${toString (fixtureGuestMemoryMiB * 1024 * 1024)}
  '' + lib.concatMapStringsSep "\n" builtins.readFile [
    ./driver.py
    ../../support/transfer.py
    ../../support/guest-diagnostics.py
    ../../support/update.py
    ./helpers.py
    ./browser-coordination.py
    ./request-slo-faults.py
    ./scenarios/bootstrap.py
    ./scenarios/enrollment.py
    ] + lib.optionalString (!audi) (builtins.readFile ./scenarios/boot-trust-services.py)
    + lib.optionalString relocation (builtins.readFile ./relocation-helpers.py)
    + lib.optionalString (porsche && !userSshJourney)
      (if porscheTerminal then builtins.head porscheScenarioParts
      else if porscheThreads then builtins.readFile ./scenarios/porsche.py + "\n" + builtins.readFile ./scenarios/porsche-threads.py
      else if otelPorsche then builtins.head porscheScenarioParts + "\n" + ''
        m1.wait_for_unit("overalls-request-porsche-exporter.service")
        m1.wait_until_succeeds("jq -e '.service == \"porsche\" and .requests >= 1 and .successes >= 1 and .requests == (.successes + .failures)' /run/overalls-request-porsche-source/slo.json")
        m1.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep -E 'overalls_outer_porsche_successes_total.* [1-9][0-9]*$'")
      '' + builtins.readFile ./porsche-slo-faults.py else builtins.readFile ./scenarios/porsche.py)
    + (if otelPorsche || porscheLifecycleOnly || porscheThreads then "" else if porscheTerminal then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/terminal-setup.py
      (if milaTerminal then ./scenarios/mila-terminal.py else ./scenarios/porsche-terminal.py)
    ] else if sshBootstrap then builtins.readFile ./scenarios/ssh-bootstrap.py
      else if sshRosterMatrix then builtins.readFile ./scenarios/ssh-roster-matrix.py
      else if userSshJourney then builtins.readFile ./scenarios/user-ssh-journey.py
      else if terminal then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/terminal-setup.py
      ./scenarios/terminal.py
    ] else if observabilityRecovery then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/observability-setup.py
      ./scenarios/observability-recovery.py
      ./scenarios/submission-recovery.py
    ] else if runtimeReadiness then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/customer-setup.py
      ./scenarios/runtime-readiness.py
      ./scenarios/submission-recovery.py
    ] else if brady then builtins.readFile ./brady-slo-faults.py + "\n" + builtins.readFile ./scenarios/brady.py else if customerIsolation then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/customer-setup.py
      ./scenarios/network.py
      ./scenarios/updates.py
      ./scenarios/provisioner-recovery.py
      ./scenarios/customer-recovery.py
    ] else if serverTool then
      # Host services from the agent scenario's first subtest, then the shared
      # server-tool guest setup and the selected journey.
      # (its hashlib import serves only the omitted agent subtests).
      lib.replaceStrings [ "\nimport hashlib\n" ] [ "\n" ]
        (builtins.head (lib.splitString "\nwith subtest(\"shared operator prompt wakes guest" (builtins.readFile ./scenarios/agent.py)))
      + "\n" + builtins.readFile ./scenarios/server-tool-setup.py
      + "\n" + builtins.readFile (if artifactAgentPublish then ../artifact-agent-publish/scenario.py else ../thread-tool/scenario.py)
      else if agent then builtins.readFile ./scenarios/agent.py
      else if otelAudiSsh then builtins.head otelAudiSshScenarioParts + "\n" + ''
        def audi_slo_ready() -> None:
            eventually(lambda: audi_ready(host, "gateway"), timeout=60)

        def audi_slo_probe() -> None:
            assert client.succeed(
                ssh_environment + shlex.join([*ssh_arguments, "cat /proc/sys/kernel/hostname"]),
                timeout=30,
            ).strip() == "lilly-guest"

        audi_slo_guest_before = process_snapshot(vm)
        transport_restart_faults(host, "audi_ssh", audi_slo_ready, audi_slo_probe)

        def audi_slo_start_held_request() -> None:
            # Hold the actual Lilly connector before SSH establishment completes.
            host.succeed("systemctl kill --signal=SIGSTOP --kill-whom=main lilly.service")
            held_command = ssh_environment + shlex.join([
                *ssh_arguments, "cat /proc/sys/kernel/hostname",
            ])
            client.succeed(
                "systemd-run --quiet --no-block --unit=audi-slo-held "
                "--property=Type=oneshot --property=TimeoutStartSec=90 "
                "--property=Environment=PATH=/run/current-system/sw/bin "
                "--property=StandardOutput=null --property=StandardError=null "
                + shlex.join([
                    "/run/current-system/sw/bin/bash", "-c",
                    held_command,
                ])
            )

        def audi_slo_held_disconnected() -> None:
            host.succeed("systemctl kill --signal=SIGCONT --kill-whom=main lilly.service")
            client.wait_until_succeeds(
                "test $(systemctl show audi-slo-held.service -p Result --value) = exit-code"
            )
            assert int(client.succeed(
                "systemctl show audi-slo-held.service -p ExecMainStatus --value"
            ).strip()) != 0

        try:
            transport_inflight_fault(
                host, "audi_ssh", audi_slo_ready, audi_slo_start_held_request,
                audi_slo_held_disconnected, audi_slo_probe,
            )
        finally:
            host.execute("systemctl kill --signal=SIGCONT --kill-whom=main lilly.service")
            client.execute("systemctl stop audi-slo-held.service")
            client.execute("systemctl reset-failed audi-slo-held.service")
        assert process_snapshot(vm) == audi_slo_guest_before
      ''
      else if suspension then
        builtins.head (lib.splitString "\nwith subtest(\"real guest HTTP reaches" audiScenario)
          + "\n" + ''
            vm = provision_when_available(m1, "standard")
            await_running(vm["vm_id"])
            route = operator(
                m1,
                dict(action="audi-policy", owner_id=users["owner_id"], vm_id=vm["vm_id"], visibility="public"),
            )
            hostname = str(route["label"]) + ".apps.example.test"
          ''
          + suspensionAudiSshSetup
        + "\n" + builtins.readFile ./scenarios/suspension.py
      else if ubuntu && audi then builtins.readFile ./scenarios/audi.py
        + lib.optionalString relocation (builtins.readFile ./scenarios/audi-relocation.py)
      else if ubuntu then builtins.readFile ./scenarios/relocation.py
      else if cloning then ""
      else if galileo then builtins.readFile ./scenarios/galileo.py
      else if audi then builtins.readFile ./scenarios/audi.py
      + lib.optionalString relocation (builtins.readFile ./scenarios/audi-relocation.py)
      else if relocation then lib.concatMapStringsSep "\n" builtins.readFile [
      ./scenarios/relocation.py
      ./scenarios/relocation-failures.py
    ]
       else lib.concatMapStringsSep "\n" builtins.readFile [
    ./scenarios/storage-failures.py
    ./scenarios/idempotency.py
    ./scenarios/capacity.py
    ./scenarios/network.py
    ./scenarios/updates.py
    ./scenarios/terminal.py
    ./scenarios/socket-custody.py
    ./scenarios/control-plane-recovery.py
    ./scenarios/provisioner-recovery.py
    ./scenarios/lifecycle.py
    ./scenarios/staleness.py
    ./scenarios/credential-revocation.py
  ]);
}) // { inherit defaultOssBrowser repositoryLaunchBrowser githubFleetArtifacts terminalBrowser audiBrowser porscheBrowser editorBrowser; }
