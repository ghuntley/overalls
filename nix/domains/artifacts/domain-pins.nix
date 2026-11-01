# @cc [owner:ghuntley,label:build;security] domain-lock-registry
# Every guest domain lock (ADR-0267's third pin location) MUST be registered
# here with how it is regenerated: `updater`, the repository tool that writes
# it, or null when no tool exists; and `procedure`, the reviewed document
# that says how to run that tool or update the lock by hand. `build` names the
# output that MUST build after the lock changes. Updaters need network access
# (and Windows for the Visual Studio layout), so no scheduled job runs them;
# their output is reviewed like any other pin. scripts/fetch_pins.exs refuses
# a tracked `*.lock.json` under nix/ that no entry names, and a lock, updater
# or procedure path that does not exist.
{ pkgs, packages, tests }:
let
  guest = "nix/domains/artifacts/guest";
  nativeGit = import ./guest/native-git.nix { inherit pkgs; };
in
{
  ubuntu-packages = {
    locks = [ "${guest}/ubuntu/packages.lock.json" ];
    updater = "${guest}/ubuntu/update-lock.py";
    procedure = "docs/guests/ubuntu-guests.md";
    build = packages.ubuntuGuest;
  };
  # The lock tool resolves every package lock against this base, so a base
  # change regenerates each Ubuntu lock as well.
  ubuntu-base = {
    locks = [ "${guest}/ubuntu/base.json" ];
    updater = null;
    procedure = "docs/guests/ubuntu-guests.md";
    build = packages.ubuntuGuest;
  };
  ubuntu-test-fixture = {
    locks = [ "nix/verification/tests/fixtures/ubuntu/packages.lock.json" ];
    updater = "${guest}/ubuntu/update-lock.py";
    procedure = "docs/guests/ubuntu-guests.md";
    # //nix/verification/tests/machines/zfs-guest:ubuntu-guest
    build = import ../../verification/tests/machines/zfs-guest (tests.storage // {
      ubuntu = true;
      guest = import ../../verification/tests/fixtures/ubuntu { inherit packages; };
    });
  };
  windows-iso = {
    locks = [ "${guest}/windows/iso.json" ];
    updater = null;
    procedure = "docs/guests/windows-guests.md";
    build = packages.windowsGuest;
  };
  windows-winget = {
    locks = [ "${guest}/windows/winget.json" ];
    updater = "${guest}/windows/update-winget-pins.py";
    procedure = "docs/guests/windows-guests.md";
    build = packages.windowsGuestAgents;
  };
  windows-vs-layout = {
    locks = [ "${guest}/windows/vs-layout.json" ];
    updater = "${guest}/windows/update-vs-layout.ps1";
    procedure = "docs/guests/windows-guests.md";
    build = packages.windowsGuestAgents;
  };
  native-git = {
    locks = [ "${guest}/native_git/freebsd-packages.json" "${guest}/native_git/illumos-packages.json" ];
    updater = null;
    procedure = "${guest}/native_git/README.md";
    build = pkgs.linkFarmFromDrvs "native-git-domain-pins" [ nativeGit.freebsd nativeGit.illumos ];
  };
  vscode-extensions = {
    locks = [ "nix/domains/artifacts/vscode-web/extensions.lock.json" ];
    updater = "nix/domains/artifacts/vscode-web/update-extensions.py";
    procedure = "nix/domains/artifacts/vscode-web/README.md";
    build = packages.vscodeWeb;
  };
}
