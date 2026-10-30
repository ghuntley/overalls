# `nix run .#mila-journey-fixture` (ADR-0264): boot the hermetic Mila journey
# backend as a KVM QEMU VM with the same fixture module the machine test uses,
# forward its unprivileged ports to the host's loopback (or a chosen address)
# and publish the v1 descriptor for platform journey tests.
{ nixpkgs, pkgs, module, packages }:
let
  inherit (pkgs) lib;
  vm = (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      (import ./fixture.nix { inherit module packages; })
      ({ config, ... }: {
        networking.hostName = "control";
        virtualisation.graphics = false;
        virtualisation.diskSize = 8192;
        # Same-numbered forwards keep approval links and the trust origin valid
        # on the host: https://localhost:8443 is the deployment origin there too.
        virtualisation.forwardPorts = map (port: {
          from = "host"; host.address = "@MILA_FIXTURE_BIND@"; host.port = port; guest.port = port;
        }) [ 8443 2222 8444 ];
        virtualisation.sharedDirectories.mila-fixture = {
          source = ''"$MILA_FIXTURE_SHARE"'';
          target = "/mnt/mila-fixture";
        };
        systemd.services.mila-fixture.wantedBy = [ "multi-user.target" ];
        systemd.services.mila-fixture-publish = {
          description = "Publish the Mila journey descriptor to the host";
          wantedBy = [ "multi-user.target" ];
          after = [ "mila-fixture.service" ];
          requires = [ "mila-fixture.service" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
          script = "install -m 0600 /run/mila-fixture/descriptor.json /mnt/mila-fixture/descriptor.json";
        };
        # Serial-console diagnostics for the launcher's log file.
        boot.kernelParams = [ "console=ttyS0" ];
        services.getty.autologinUser = lib.mkForce null;
        system.stateVersion = lib.mkForce "26.05";
      })
    ];
  }).config.system.build.vm;
in
pkgs.writeShellApplication {
  name = "mila-journey-fixture";
  runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.gnused ];
  text = ''
    usage() {
      cat <<'USAGE'
    Usage: mila-journey-fixture [--descriptor PATH] [--bind ADDRESS] [--state DIR] [--detach]

    Boots the hermetic Mila journey backend (Marshall, PostgreSQL, Porsche and
    the browser approver) in a KVM QEMU VM, forwards ports 8443 (HTTPS),
    2222 (Porsche SSH) and 8444 (approver) to ADDRESS (default 127.0.0.1) and
    prints the v1 descriptor JSON once the backend is ready. The descriptor is
    also written owner-only to PATH. Without --detach the VM runs until this
    process is interrupted; with --detach the VM keeps running and its PID is
    written to DIR/qemu.pid.
    USAGE
    }
    descriptor=""
    bind="127.0.0.1"
    state=""
    detach=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --descriptor) descriptor="$2"; shift 2 ;;
        --bind) bind="$2"; shift 2 ;;
        --state) state="$2"; shift 2 ;;
        --detach) detach=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
      echo "mila-journey-fixture: /dev/kvm is required (the fixture never falls back to TCG)" >&2
      exit 1
    fi
    if [ -z "$state" ]; then state=$(mktemp -d -t mila-journey-fixture.XXXXXX); fi
    mkdir -p "$state/share"
    chmod 700 "$state" "$state/share"
    rm -f "$state/share/descriptor.json"
    # The forward address is substituted into a private copy of the run script.
    sed "s|@MILA_FIXTURE_BIND@|$bind|g" ${vm}/bin/run-control-vm > "$state/run-control-vm"
    chmod 700 "$state/run-control-vm"
    export MILA_FIXTURE_SHARE="$state/share"
    export NIX_DISK_IMAGE="$state/control.qcow2"
    export QEMU_OPTS="-pidfile $state/qemu.pid"
    (cd "$state" && exec "$state/run-control-vm") > "$state/console.log" 2>&1 < /dev/null &
    qemu=$!
    if [ "$detach" = 0 ]; then
      trap 'kill "$qemu" 2>/dev/null || true; wait "$qemu" 2>/dev/null || true' EXIT INT TERM
    fi
    deadline=$(( $(date +%s) + 1200 ))
    until [ -s "$state/share/descriptor.json" ]; do
      if ! kill -0 "$qemu" 2>/dev/null; then
        echo "mila-journey-fixture: the VM exited; see $state/console.log" >&2
        exit 1
      fi
      if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "mila-journey-fixture: backend not ready after 20 minutes; see $state/console.log" >&2
        exit 1
      fi
      sleep 2
    done
    out=$(jq -c --arg bind "$bind" '. + {launcher: {bind: $bind}}' "$state/share/descriptor.json")
    if [ -n "$descriptor" ]; then
      mkdir -p "$(dirname "$descriptor")"
      (umask 077; printf '%s\n' "$out" > "$descriptor")
    fi
    printf '%s\n' "$out"
    if [ "$detach" = 1 ]; then
      echo "mila-journey-fixture: detached; VM state in $state" >&2
      exit 0
    fi
    wait "$qemu"
  '';
}
