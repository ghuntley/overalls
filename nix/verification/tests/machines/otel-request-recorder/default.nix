# @cc [owner:ghuntley,label:verification;security] request-recorder-native-crash-boundary
# The native fixture MUST use the production Rust recorder and Nix module with
# real Unix peer/cgroup attribution and SIGKILL recovery. No application outcome
# or production seven-day compliance claim follows from this isolated fixture.
{ pkgs, packages, hegel, commitReplyLoss ? false }:
let
  inherit (packages) toolchain;
  identities = import ../../../../domains/system/otel-fleet/request-identities.nix;
  driverSource = builtins.readFile ./driver.py;
  corruptionBoundary = "with subtest(\"corrupt producer storage cannot confer complete coverage through old completions\"):";
  producer = pkgs.runCommand "overalls-request-accounting-producer" {
    nativeBuildInputs = [ toolchain.elixir ];
    LC_ALL = "C.UTF-8";
  } ''
    mkdir -p "$out/lib"
    elixirc --warnings-as-errors -o "$out/lib" \
      ${../../../../../elixir/request_accounting/lib/overalls/request_accounting}/*.ex \
      ${../../../../../elixir/request_accounting/lib/overalls/request_accounting}/producer/*.ex
  '';
  recorder = packages.otelReceiver;
  # The fixtures patch and rebuild the source, so they derive from the Nix
  # build even when the recorder itself is the Buck2 leaf.
  recorderSource = recorder.nixBuild or recorder;
  fixture = recorderSource.overrideAttrs (previous: {
    pname = "overalls-request-recorder-native-fixture";
    postPatch = (previous.postPatch or "") + pkgs.lib.optionalString commitReplyLoss ''
      substituteInPlace nix/domains/system/otel-guest/receiver/examples/request_fixture.rs --replace-fail \
        'Duration::from_secs(3)' 'Duration::from_secs(8)'
    '';
    postBuild = (previous.postBuild or "") + ''
      cargo build --offline --release -p overalls-otel-guest-receiver --example request_fixture
    '';
    postInstall = (previous.postInstall or "") + ''
      install -m 0755 target/*/release/examples/request_fixture "$out/bin/request_fixture" 2>/dev/null \
        || install -m 0755 target/release/examples/request_fixture "$out/bin/request_fixture"
    '';
  });
  cutRecorder = recorderSource.overrideAttrs (previous: {
    pname = "overalls-request-recorder-commit-reply-fixture";
    nativeBuildInputs = (previous.nativeBuildInputs or []) ++ [ packages.cargoWorkspace.rustTools ];
    postPatch = (previous.postPatch or "") + ''
      substituteInPlace nix/domains/system/otel-guest/receiver/src/request_recorder.rs --replace-fail \
        'Ok(envelope) => runtime.apply(producer, envelope.command, now_ns()?),' \
        ${pkgs.lib.escapeShellArg (builtins.readFile ./commit-reply-cut.rs)}
    '';
    # The inserted fault expression is not rustfmt-formatted and lengthens
    # run past too_many_lines, so this variant replaces the inherited gate with
    # clippy alone and allows only that length lint for the patched function.
    postCheck = ''
      pushd "$buildAndTestSubdir"
      cargo clippy --offline --all-targets -- -D warnings -A clippy::too_many_lines
      popd
    '';
  });
# @cc [owner:ghuntley,label:verification] recorder-cut-history-insertion-required
# The fault variant MUST refuse evaluation if its insertion boundary disappears;
# it MUST NOT silently run only the original histories.
in assert !commitReplyLoss || pkgs.lib.hasInfix corruptionBoundary driverSource;
hegel.runTest {
  name = if commitReplyLoss then "overalls-otel-request-recorder-commit-reply-loss" else "overalls-otel-request-recorder";
  properties = {
    enable = true;
    profile = "ci";
    testCases = 4;
    derandomize = true;
  };
  nodes.machine = { ... }: {
    imports = [ (import ../../../../domains/system/otel-fleet/request-recorder.nix { inherit packages; }) ];
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    environment.systemPackages = [ fixture pkgs.jq ];
    users.groups.request-producer = {};
    users.users.request-reader = {
      isSystemUser = true; group = identities.readerGroup "primary";
    };
    users.users.request-producer = { isSystemUser = true; group = "request-producer"; };
    services.overallsRequestRecorder.instances = {
      primary = { source = "galileo"; producerUser = "request-producer";
        producerUnit = "request-producer.service"; deadlineSeconds = 60; };
      deadline = { source = "audi_dns"; producerUser = "request-producer";
        producerUnit = "deadline-producer.service"; deadlineSeconds = 1; };
      sdk = { source = "brady"; producerUser = "request-producer";
        producerUnit = "sdk-producer.service"; deadlineSeconds = 60;
        package = if commitReplyLoss then cutRecorder else recorder; };
      marshall-overalls = { source = "marshall_web"; producerUser = "dynamic-producer";
        producerUnit = "dynamic-producer.service"; deadlineSeconds = 60; };
    };
    systemd.services.request-producer.serviceConfig = {
      ExecStart = "${fixture}/bin/request_fixture serve /run/overalls-request-primary/recorder.sock /run/request-producer/control.sock";
      User = "request-producer"; Group = "request-producer";
      RuntimeDirectory = "request-producer"; RuntimeDirectoryMode = "0750";
      RuntimeDirectoryPreserve = "yes"; Restart = "no";
    };
    systemd.services.sdk-producer = {
      environment = {
        FIXTURE_RECORDER = "/run/overalls-request-sdk/recorder.sock";
        FIXTURE_MARKER = "/var/lib/request-sdk-marker";
        FIXTURE_CONTROL = "/run/sdk-producer/control.sock";
        ERL_FLAGS = "+S 2:2";
      };
      serviceConfig = {
        ExecStart = "${toolchain.elixir}/bin/elixir --no-halt -pa ${producer}/lib ${./producer_fixture.exs}";
        User = "request-producer"; Group = "request-producer";
        StateDirectory = "request-sdk-marker"; StateDirectoryMode = "0700";
        RuntimeDirectory = "sdk-producer"; RuntimeDirectoryMode = "0750";
        Restart = "no";
      };
    };
    systemd.services.deadline-producer.serviceConfig = {
      ExecStart = "${fixture}/bin/request_fixture serve /run/overalls-request-deadline/recorder.sock /run/deadline-producer/control.sock";
      User = "request-producer"; Group = "request-producer";
      RuntimeDirectory = "deadline-producer"; RuntimeDirectoryMode = "0750";
      Restart = "no";
    };
    systemd.services.dynamic-producer = {
      environment = { FIXTURE_CONTROL = "/run/dynamic-producer/control.sock"; ERL_FLAGS = "+S 2:2"; };
      serviceConfig = {
        ExecStart = "${toolchain.elixir}/bin/elixir --no-halt -pa ${producer}/lib ${./producer_fixture.exs}";
        DynamicUser = true; User = "dynamic-producer";
        RuntimeDirectory = "dynamic-producer"; RuntimeDirectoryMode = "0750";
        Restart = "no";
      };
    };
    systemd.services.request-wrong = {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${fixture}/bin/request_fixture probe /run/overalls-request-primary/recorder.sock hello";
        User = "request-producer"; Group = "request-producer";
        SupplementaryGroups = [ (identities.rpcGroup "primary") ];
      };
    };
  };
  testScript = if commitReplyLoss then builtins.replaceStrings
    [ corruptionBoundary ]
    [ ((builtins.readFile ./commit-reply-loss.py) + "\n" + corruptionBoundary) ]
    driverSource
    else driverSource;
}
