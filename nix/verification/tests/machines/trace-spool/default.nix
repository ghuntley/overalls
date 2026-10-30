{ pkgs, packages }:
let
  lib = pkgs.lib;
  account = "ktr-${builtins.substring 0 16 (builtins.hashString "sha256" "galileo")}";
  spool = packages.traceSpool;
  fixture = ../../fixtures/trace-spool/request.hex;
  source = "/run/overalls-trace-galileo-source/metrics.prom";
  database = "/var/lib/overalls-trace-galileo/archive.sqlite";
in pkgs.testers.runNixOSTest {
  name = "overalls-independent-trace-custody";
  nodes.machine = { config, ... }: {
    imports = [ (import ../../../../domains/system/otel-fleet/trace-spool.nix { inherit packages; }) ];
    options.services = {
      overallsOtelFleet.enable = lib.mkOption { type = lib.types.bool; default = true; };
      galileo.enable = lib.mkOption { type = lib.types.bool; default = true; };
    };
    config = {
      networking.hostName = "trace-fixture";
      virtualisation.memorySize = 1024;
      services.overallsOtelFleet.traceSpool = {
        package = spool; quotaBytes = 8388608; pendingQuotaBytes = 4194304;
      };
      users.groups = { galileo = {}; overalls-otel-traces = {}; };
      users.users.galileo = { isSystemUser = true; group = "galileo"; };
      systemd.tmpfiles.rules = [
        "d /run/trace-results 0700 galileo galileo - -"
        "d /run/overalls-otel-traces 2770 root overalls-otel-traces - -"
      ];
      systemd.services.galileo = {
        serviceConfig = { Type = "oneshot"; User = "galileo"; Group = "galileo"; Slice = "fixture-producer.slice";
          ExecStart = "${pkgs.python3}/bin/python ${./client.py} /run/overalls-trace-galileo/ingest.sock ${fixture} /run/trace-results/accepted /run/trace-results/work"; };
      };
      systemd.services.wrong-unit = {
        serviceConfig = { Type = "oneshot"; User = "galileo"; Group = "galileo";
          SupplementaryGroups = config.systemd.services.galileo.serviceConfig.SupplementaryGroups;
          ExecStart = "${pkgs.python3}/bin/python ${./client.py} /run/overalls-trace-galileo/ingest.sock ${fixture} /run/trace-results/wrong-unit /run/trace-results/wrong-work"; };
      };
      systemd.services.wrong-uid = {
        serviceConfig = { Type = "oneshot";
          ExecStart = "${pkgs.python3}/bin/python ${./client.py} /run/overalls-trace-galileo/ingest.sock ${fixture} /run/trace-results/wrong-uid /run/trace-results/root-work"; };
      };
      systemd.services.trace-sink = {
        serviceConfig = { Type = "exec"; User = "root"; Group = "overalls-otel-traces";
          ExecStart = "${pkgs.python3}/bin/python ${./sink.py}"; };
      };
      # Use the production sink socket while the deliberately absent Collector
      # is represented by this independently controlled native fixture.
      environment.etc."trace-replay-command".text = config.systemd.services.overalls-trace-galileo.serviceConfig.ExecStart;
      environment.etc."trace-batch.hex".source = ../../fixtures/trace-spool/batch.hex;
      environment.systemPackages = [ pkgs.sqlite pkgs.util-linux ];
    };
  };
  testScript = ''
    import json

    def native_measurements(value: object) -> dict[str, int]:
        if not isinstance(value, dict):
            raise ValueError("invalid native measurements")
        fields: dict[str, object] = {}
        for field, item in value.items():
            if not isinstance(field, str):
                raise ValueError("invalid native measurement key")
            fields[field] = item
        result: dict[str, int] = {}
        for key in ("accepted", "refused", "spans_per_batch", "encoded_bytes", "total_us", "first_32_max_us", "last_32_max_us"):
            number: object = fields.get(key)
            if not isinstance(number, int) or isinstance(number, bool) or number < 0:
                raise ValueError("invalid native measurement field")
            result[key] = number
        return result

    start_all()
    machine.wait_for_unit("overalls-trace-galileo.service")
    machine.wait_until_succeeds("test -S /run/overalls-trace-galileo/ingest.sock")
    with subtest("exact unprivileged UID and systemd cgroup admit independent durable custody"):
        machine.succeed("systemctl start galileo.service")
        assert machine.succeed("cat /run/trace-results/accepted") == "200"
        assert machine.succeed("cat /run/trace-results/work") == "completed"
        machine.wait_until_succeeds("grep '^overalls_trace_spool_pending_batches 1$' ${source}")
        original = machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'")
        machine.succeed("systemctl start wrong-unit.service wrong-uid.service")
        wrong_unit = machine.succeed("cat /run/trace-results/wrong-unit")
        assert wrong_unit == "403", wrong_unit
        wrong_uid = machine.succeed("cat /run/trace-results/wrong-uid")
        assert wrong_uid == "403", wrong_uid
        assert machine.succeed("sqlite3 ${database} 'SELECT count(*) FROM batches'").strip() == "1"
    with subtest("VM reboot and duplicate stable batch preserve acknowledged custody"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("overalls-trace-galileo.service")
        machine.wait_until_succeeds("test -S /run/overalls-trace-galileo/ingest.sock")
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'") == original
        machine.wait_until_succeeds("grep '^overalls_trace_spool_pending_batches 1$' ${source}")
        machine.succeed("systemctl start galileo.service")
        assert machine.succeed("cat /run/trace-results/accepted") == "200"
        assert machine.succeed("sqlite3 ${database} 'SELECT count(*) FROM batches'").strip() == "1"
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'") == original
    with subtest("SIGKILL after custody and Collector outage preserve exact accepted archive"):
        machine.succeed("systemctl kill --kill-whom=main --signal=SIGKILL overalls-trace-galileo.service")
        machine.wait_for_unit("overalls-trace-galileo.service")
        machine.wait_until_succeeds("test -S /run/overalls-trace-galileo/ingest.sock")
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'") == original
    with subtest("upstream success retains immutable custody and explicit replay is independently durable"):
        machine.succeed("systemctl start trace-sink.service")
        machine.wait_until_succeeds("grep '^overalls_trace_spool_pending_batches 0$' ${source}")
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'") == original
        machine.succeed("systemctl stop trace-sink.service overalls-trace-galileo.service")
        command = machine.succeed("cat /etc/trace-replay-command").strip()
        machine.succeed(f"runuser -u ${account} -- {command} --replay")
        machine.succeed("systemctl start overalls-trace-galileo.service")
        machine.wait_until_succeeds("grep '^overalls_trace_spool_pending_batches 1$' ${source}")
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches'") == original
    with subtest("malformed OTLP refuses before custody and native batch traffic fills pending quota"):
        machine.succeed("touch /run/trace-results/malformed; systemctl start galileo.service")
        assert machine.succeed("cat /run/trace-results/accepted") == "400"
        assert machine.succeed("sqlite3 ${database} 'SELECT count(*) FROM batches'").strip() == "1"
        machine.succeed("rm /run/trace-results/malformed; touch /run/trace-results/stress; systemctl start galileo.service")
        measured = native_measurements(json.loads(machine.succeed("cat /run/trace-results/stress.json")))
        print("Native trace admission measurements: " + json.dumps(measured, sort_keys=True))
        assert measured["accepted"] >= 32, measured
        assert measured["refused"] > 0, measured
        assert measured["accepted"] + measured["refused"] == 256
        assert measured["first_32_max_us"] < 1000000, measured
        assert measured["last_32_max_us"] < 1000000, measured
        assert machine.succeed("sqlite3 ${database} 'SELECT count(*) FROM batches'").strip() == str(measured["accepted"] + 1)
        assert machine.succeed("sqlite3 ${database} 'SELECT id FROM batches ORDER BY accepted_ns LIMIT 1'") == original
        footprint = int(machine.succeed("du -sb /var/lib/overalls-trace-galileo | cut -f1").strip())
        print(f"Native trace archive physical footprint: {footprint} bytes")
        assert footprint < 12582912, footprint
        machine.succeed("rm /run/trace-results/stress")
    with subtest("observer outage leaves producer work running without receiver authority"):
        machine.succeed("systemctl stop overalls-trace-galileo.service")
        machine.succeed("systemctl start galileo.service")
        assert machine.succeed("cat /run/trace-results/work") == "completed"
        assert machine.succeed("cat /run/trace-results/accepted") == "unavailable"
        machine.fail("runuser -u galileo -- test -r ${database}")
    with subtest("corrupt immutable archive refuses startup and leaves producer work intact"):
        machine.succeed("sqlite3 ${database} \"UPDATE batches SET body=X'00' WHERE id=(SELECT id FROM batches LIMIT 1)\"")
        machine.succeed("systemctl start overalls-trace-galileo.service")
        machine.wait_until_succeeds("systemctl show overalls-trace-galileo.service -p ExecMainStatus --value | grep '^2$'")
        machine.succeed("systemctl start galileo.service")
        assert machine.succeed("cat /run/trace-results/accepted") == "unavailable"
        assert machine.succeed("cat /run/trace-results/work") == "completed"
        assert machine.succeed("sqlite3 ${database} 'SELECT count(*) FROM batches'").strip() == str(measured["accepted"] + 1)
  '';
}
