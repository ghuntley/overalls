# @cc [owner:ghuntley,label:verification;security] recorder-host-real-identity
# The focused recorder graph MUST run its producer, request recorder and trace
# spool as distinct NixOS services. The Rust intake MUST check the producer's
# real kernel UID and exact systemd cgroup; an outer container identity cannot
# substitute for either proof.
{ nixpkgs, packages }:
let
  lib = nixpkgs.lib;
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ({ config, pkgs, ... }:
      let
        requestAccounting = pkgs.runCommand "overalls-recorder-peer-accounting" {
          nativeBuildInputs = [ packages.toolchain.elixir packages.toolchain.erlang pkgs.findutils ];
          env.ERL_FLAGS = "+S 2:2";
        } ''
          mkdir -p "$out/ebin"
          cd ${../../elixir/request_accounting}
          find lib -name '*.ex' -type f -print | sort | xargs elixirc --warnings-as-errors -o "$out/ebin"
        '';
        spool = packages.traceSpool;
        traceAccount = "ktr-${builtins.substring 0 16 (builtins.hashString "sha256" "recorder-peer")}";
        traceGroup = "ktp-${builtins.substring 0 16 (builtins.hashString "sha256" "recorder-peer")}";
        requestIdentities = import ../../nix/domains/system/otel-fleet/request-identities.nix;
        traceSettings = {
          service = "galileo";
          host = "recorder-host";
          revision = "antithesis";
          producer_user = "recorder-peer";
          producer_unit = "recorder-peer.service";
          producer_cgroup = "/fixture.slice/recorder-peer.service";
          state = "/archive/state";
          socket = "/run/overalls-trace-recorder/ingest.sock";
          sink = "/run/overalls-otel-traces/collector.sock";
          metrics = "/run/overalls-trace-recorder-source/metrics.prom";
          schema = ../../elixir/diagnostics/priv/trace-schema.json;
          quota_bytes = 62914560;
          pending_quota_bytes = 33554432;
          retention_seconds = 7776000;
        };
        traceRuntime = pkgs.writeText "overalls-recorder-peer-trace.json" (builtins.toJSON traceSettings);
        # Pending-quota window: the same spool configuration with the minimum
        # pending quota (one body limit), selected only for a bounded window at
        # the end of a traces command so the real 429 path is reachable.
        tracePressureRuntime = pkgs.writeText "overalls-recorder-peer-trace-pressure.json"
          (builtins.toJSON (traceSettings // { pending_quota_bytes = 262144; }));
      in {
        imports = [ (import ../../nix/domains/system/otel-fleet/request-recorder.nix { inherit packages; }) ];
        system.stateVersion = "26.05";
        networking.hostName = "recorder-host";
        networking.useDHCP = true;
        networking.firewall.enable = false;
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "9p" "9pnet_virtio" "ext4" ];
        boot.kernelParams = [ "console=ttyS0" "reboot=k" "panic=1" "net.ifnames=0" ];
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        # A separate fixed-size block device makes ENOSPC physical to this
        # guest's archive. The overlay-backed root cannot satisfy that proof.
        fileSystems."/archive" = {
          device = "/dev/disk/by-label/KTRACE-ARCHIVE"; fsType = "ext4";
          options = [ "noatime" ];
        };
        fileSystems."/run/overalls-requests" = {
          device = "overalls-requests"; fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
        };
        fileSystems."/run/overalls-observation" = {
          device = "overalls-observation"; fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
        };
        fileSystems."/run/overalls-results" = {
          device = "overalls-results"; fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
        };
        environment.systemPackages = [ pkgs.python313 pkgs.coreutils pkgs.util-linux pkgs.sqlite spool ];
        environment.etc."overalls-recorder-trace-config".source = traceRuntime;
        environment.etc."overalls-recorder-trace-config-pressure".source = tracePressureRuntime;
        users.groups.recorder-peer = {};
        users.users.recorder-peer = {
          isSystemUser = true; group = "recorder-peer";
          extraGroups = [ (requestIdentities.rpcGroup "sdk") traceGroup ];
        };
        users.groups.${traceAccount} = {};
        users.groups.${traceGroup} = {};
        users.users.${traceAccount} = {
          isSystemUser = true; group = traceAccount;
          extraGroups = [ traceGroup ];
        };
        services.overallsRequestRecorder.instances.sdk = {
          source = "brady";
          producerUser = "recorder-peer";
          producerUnit = "recorder-peer.service";
          deadlineSeconds = 600;
        };
        systemd.slices.fixture.description = "Real producer identity boundary";
        # Recovery commands restart these units back to back; systemd's default
        # five-starts-per-ten-seconds limit would leave them failed (fixture only).
        systemd.services.overalls-request-sdk.unitConfig.StartLimitIntervalSec = 0;
        systemd.tmpfiles.rules = [
          "d /run/overalls-trace-recorder 2750 ${traceAccount} ${traceGroup} -"
          "d /run/overalls-trace-recorder-source 0750 ${traceAccount} ${traceAccount} -"
          "d /archive 0755 root root -"
          "d /archive/state 0700 ${traceAccount} ${traceAccount} -"
          "d /archive/pressure 0700 root root -"
          # Root-owned selector the bridge retargets; it boots on the default.
          "d /run/overalls-trace-recorder-profile 0755 root root -"
          "L+ /run/overalls-trace-recorder-profile/config.json - - - - /etc/overalls-recorder-trace-config"
        ];
        # @cc [owner:ghuntley,label:verification;recovery] recorder-peer-independent-effects
        # The BEAM producer MUST own the attempted-effect ledger and survive
        # recorder and spool replacement. Its real service cgroup is the sole
        # admitted source for both production Rust receivers.
        systemd.services.recorder-peer = {
          description = "Fixture BEAM producer in a real systemd cgroup";
          wantedBy = [ "multi-user.target" ];
          after = [ "overalls-request-sdk.service" "overalls-trace-recorder.service" ];
          wants = [ "overalls-request-sdk.service" "overalls-trace-recorder.service" ];
          environment = {
            FIXTURE_CONTROL = "/run/recorder-peer/control.sock";
            FIXTURE_RECORDER = "/run/overalls-request-sdk/recorder.sock";
            FIXTURE_MARKER = "/var/lib/recorder-peer/marker";
            FIXTURE_EFFECTS = "/var/lib/recorder-peer/effects.log";
            FIXTURE_TRACE_SOCKET = "/run/overalls-trace-recorder/ingest.sock";
            FIXTURE_TRACE_SMALL = "${../../nix/verification/tests/fixtures/trace-spool/request.hex}";
            FIXTURE_TRACE_LARGE = "${../../nix/verification/tests/fixtures/trace-spool/batch.hex}";
            ERL_FLAGS = "+S 2:2";
          };
          serviceConfig = {
            Type = "exec";
            User = "recorder-peer"; Group = "recorder-peer";
            Slice = "fixture.slice";
            StateDirectory = "recorder-peer"; StateDirectoryMode = "0700";
            RuntimeDirectory = "recorder-peer"; RuntimeDirectoryMode = "0700";
            ExecStart = "${packages.toolchain.elixir}/bin/elixir --no-halt -pa ${requestAccounting}/ebin ${../recorder_peer/peer.exs}";
            Restart = "always"; RestartSec = 1;
            UMask = "0077"; NoNewPrivileges = true;
          };
        };
        # @cc [owner:ghuntley,label:storage;security] recorder-spool-physical-archive
        # Trace custody MUST write SQLite and retained batches on the dedicated
        # bounded ext4 filesystem; the producer and request checkpoint stay on
        # independent root storage. A full archive MUST not stop the producer.
        systemd.services.overalls-trace-recorder = {
          description = "Independent production Rust trace spool";
          unitConfig.StartLimitIntervalSec = 0;
          wantedBy = [ "multi-user.target" ];
          after = [ "archive.mount" "systemd-tmpfiles-setup.service" ];
          requires = [ "archive.mount" ];
          serviceConfig = {
            Type = "exec";
            ExecStart = "${spool}/bin/overalls-trace-spool /run/overalls-trace-recorder-profile/config.json";
            User = traceAccount; Group = traceAccount;
            SupplementaryGroups = [ traceGroup ];
            ReadWritePaths = [ "/archive" "/run/overalls-trace-recorder" "/run/overalls-trace-recorder-source" ];
            Restart = "on-failure"; RestartSec = 1;
            UMask = "0077"; NoNewPrivileges = true;
            ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
            ProtectControlGroups = true; RestrictAddressFamilies = [ "AF_UNIX" ];
            CapabilityBoundingSet = []; MemoryMax = "128M"; TasksMax = 16;
          };
        };
        systemd.services.recorder-fixture-bridge = {
          description = "Closed private fixture requests and independent observations";
          wantedBy = [ "multi-user.target" ];
          after = [ "run-overalls\\x2drequests.mount" "run-overalls\\x2dresults.mount" "run-overalls\\x2dobservation.mount" "archive.mount" ];
          requires = [ "run-overalls\\x2drequests.mount" "run-overalls\\x2dresults.mount" "run-overalls\\x2dobservation.mount" "archive.mount" ];
          serviceConfig = {
            Type = "exec";
            ExecStart = "${pkgs.python313}/bin/python3 ${../emulation/recorder/bridge.py}";
            Restart = "always"; RestartSec = 1;
            UMask = "0077"; NoNewPrivileges = true;
          };
        };
      }) ];
  };
  pkgs = system.pkgs;
  rootImage = import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
    inherit pkgs lib;
    config = system.config;
    format = "qcow2";
    partitionTableType = "none";
    installBootLoader = false;
    copyChannel = false;
    additionalSpace = "256M";
    baseName = "overalls-recorder-host";
  };
in {
  inherit system rootImage;
  qemu = pkgs.qemu;
  kernel = system.config.system.build.kernel;
  initrd = system.config.system.build.initialRamdisk;
  toplevel = system.config.system.build.toplevel;
}
