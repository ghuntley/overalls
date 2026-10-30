{ pkgs, packages }:
let
  package = import ../../../domains/artifacts/fluent-bit { inherit pkgs; };
  # @cc [owner:ghuntley,label:verification] brady-health-real-formatter
  # Numeric projection MUST exercise the actual source-built Brady catalog and
  # formatter output; a synthetic nested health message cannot satisfy it.
  bradyHealth = pkgs.runCommand "overalls-brady-health-log-fixture" {} ''
    mkdir compiled
    ELIXIR_ERL_OPTIONS=+fnu ${packages.toolchain.elixir}/bin/elixirc --warnings-as-errors \
      -pa "${packages.brady}/lib/*/ebin" -o compiled ${./logging-brady-health.exs} > "$out"
  '';
  eval = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ (import ../../../domains/system/logging { inherit packages; }) { system.stateVersion = "26.05"; } extra ];
  }).config;
  local = eval { services.overallsLogging.enable = true; };
  overflow = eval { services.overallsLogging = {
    enable = true; queueBudgetBytes = 1024;
    outputs.fixture = { type = "native"; plugin = "stdout"; sources = [ "system" ]; queueBytes = 2048; };
  }; };
  invalid = eval { services.overallsLogging = {
    enable = true;
    outputs.fixture = { type = "otlp"; endpoint = "example.test"; sources = [ "system" ]; queueBytes = 2048; settings."TLS.Verify" = false; };
  }; };
  metrics = eval { services.overallsLogging = {
    enable = true;
    outputs.fixture = { type = "native"; plugin = "stdout";
      sources = [ "metrics" "marshall" "lilly" "porsche" ]; queueBytes = 8388608; };
  }; };
  health = eval {
    options.services.overallsOtelFleet.enable = pkgs.lib.mkOption { type = pkgs.lib.types.bool; default = true; };
    config.services.overallsLogging = {
      enable = true;
      outputs.fixture = { type = "native"; plugin = "stdout";
        sources = [ "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" ];
        queueBytes = 8388608;
      };
    };
  };
  numericOnly = eval {
    options.services.overallsOtelFleet.enable = pkgs.lib.mkOption { type = pkgs.lib.types.bool; default = true; };
    config.services.overallsLogging.enable = true;
  };
  allSources = eval { services.overallsLogging = {
    enable = true;
    outputs.fixture = { type = "native"; plugin = "stdout";
      sources = [ "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" "underclass"
        "haproxy" "auth" "kernel" "storage" "mail" "operations" "system" ];
      queueBytes = 8388608;
    };
    outputs.restricted = { type = "native"; plugin = "stdout";
      sources = [ "system" ]; queueBytes = 8388608;
    };
  }; };
  descriptor = pkgs.lib.last (pkgs.lib.splitString " " metrics.systemd.services.overalls-logging.serviceConfig.ExecStart);
  healthDescriptor = pkgs.lib.last (pkgs.lib.splitString " " health.systemd.services.overalls-logging.serviceConfig.ExecStart);
  numericOnlyDescriptor = pkgs.lib.last (pkgs.lib.splitString " " numericOnly.systemd.services.overalls-logging.serviceConfig.ExecStart);
  allDescriptor = pkgs.lib.last (pkgs.lib.splitString " " allSources.systemd.services.overalls-logging.serviceConfig.ExecStart);
  messages = config: map (item: item.message) (pkgs.lib.filter (item: !item.assertion) config.assertions);
in
assert local.services.overallsLogging.outputs == {};
assert builtins.elem "Logging destination queues exceed the host queue budget." (messages overflow);
assert builtins.elem "Managed OTLP requires verified TLS and disabled response-body logging." (messages invalid);
assert health.services.overallsLogging.outputs.sdk-metrics.plugin == "prometheus_exporter";
assert health.services.overallsLogging.outputs.sdk-metrics.settings.host == "127.0.0.1";
assert health.services.overallsLogging.outputs.sdk-metrics.settings.port == health.services.overallsLogging.sdkMetricsPort;
assert health.services.overallsLogging.outputs.sdk-metrics.sources == [ "metrics" ];
assert health.services.overallsLogging.outputs.sdk-metrics.queueBytes == 4194304;
pkgs.runCommand "overalls-logging-transports" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python3 ${./logging-transports.py} ${package}/bin/fluent-bit
  python3 ${./logging-metrics.py} ${descriptor}
  python3 ${./logging-metrics.py} ${descriptor} porsche
  python3 ${./logging-metrics.py} ${descriptor} marshall
  python3 ${./logging-metrics.py} ${healthDescriptor} --health ${bradyHealth}
  python3 ${./logging-metrics.py} ${numericOnlyDescriptor} --numeric-only ${bradyHealth}
  python3 ${./logging-management.py} ${../../../domains/system/cloudwatch/manage.py}
  python3 ${./logging-health.py} ${../../../domains/system/logging}
  python3 ${./logging-shards.py} ${allDescriptor}
  touch $out
''
