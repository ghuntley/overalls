{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsCloudWatch.management;
  paths = import ../types.nix { inherit lib; };
  python = pkgs.python3.withPackages (p: [ p.boto3 ]);
  descriptor = pkgs.writeText "overalls-cloudwatch-management.json" (builtins.toJSON {
    inherit (cfg) environment region accountId partition groups retentionDays kmsKeyArn
      expectedHosts alarmActions credentialsFile roleArn queueAlarmBytes;
  });
in {
  imports = [ (import ../logging/default.nix { inherit packages; }) ];
  options.services.overallsCloudWatch.management = {
    enable = mkEnableOption "CloudWatch resource reconciliation on the designated environment host";
    environment = mkOption { type = paths.identifier; default = config.services.overallsLogging.environment; };
    region = mkOption { type = types.strMatching "[a-z0-9-]+"; };
    accountId = mkOption { type = types.strMatching "[0-9]{12}"; };
    partition = mkOption { type = types.enum [ "aws" "aws-us-gov" "aws-cn" ]; default = "aws"; };
    groups = mkOption { type = types.attrsOf (types.strMatching "/[A-Za-z0-9_./-]+"); description = "Source to group mapping shared with writers; one manager per environment."; };
    retentionDays = mkOption { type = types.attrsOf (types.enum [ 1 3 5 7 14 30 60 90 120 150 180 365 400 545 731 1096 1827 2192 2557 2922 3288 3653 ]); default = {}; };
    kmsKeyArn = mkOption { type = types.nullOr types.str; default = null; };
    queueAlarmBytes = mkOption { type = types.ints.positive; default = 858993459; description = "Per-host queue alarm threshold; align with each writer budget."; };
    expectedHosts = mkOption { type = types.listOf (types.strMatching "[a-f0-9]{32}"); default = []; description = "Expected machine IDs for missing-heartbeat alarms."; };
    alarmActions = mkOption { type = types.listOf types.str; default = []; description = "Existing SNS topic ARNs; empty means no notifications."; };
    credentialsFile = mkOption { type = types.nullOr paths.privatePath; default = null; description = "Management-only AWS credentials. Null uses explicit EC2 role mode."; };
    roleArn = mkOption { type = types.nullOr types.str; default = null; };
    secretUnits = mkOption { type = types.listOf types.str; default = []; };
  };
  config = mkIf cfg.enable {
    assertions = [ { assertion = cfg.expectedHosts == [] || cfg.groups ? operations;
      message = "CloudWatch heartbeat alarms require the operations group."; } ];
    systemd.services.overalls-cloudwatch-management = {
      description = "Reconcile CloudWatch resources without receiving fleet logs";
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      wants = [ "network-online.target" ]; requires = cfg.secretUnits;
      environment.PYTHONPATH = "${../logging}";
      serviceConfig = {
        Type = "oneshot"; ExecStart = "${python}/bin/python ${./manage.py} ${descriptor}";
        UMask = "0077"; TimeoutStartSec = 120; NoNewPrivileges = true;
        ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        PrivateDevices = true; MemoryMax = "256M";
      };
    };
    systemd.timers.overalls-cloudwatch-management = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = "15min"; RandomizedDelaySec = "30s"; };
    };
  };
}
