{ pkgs, vscodeWeb, vscodeWebBroker, lyraLinux, privateServiceRoots }:
{ lib, ... }:
let
  configuration = pkgs.writeText "overalls-vscode-web-broker.json" (builtins.toJSON {
    descriptor = {
      protocol = vscodeWeb.editorProtocol;
      commit = vscodeWeb.sourceCommit;
      release = vscodeWeb.releaseId;
    };
    editor_executable = "${vscodeWeb}/bin/overalls-code";
    systemd_run = "${pkgs.systemd}/bin/systemd-run";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    account_authorizer = "${lyraLinux}/bin/overalls-ssh-authorize";
    worker_path = "/usr/local/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
  });
in
{
  environment.systemPackages = [ vscodeWeb vscodeWebBroker ];
  # @cc [owner:ghuntley,label:security;recovery] guest-editor-gateway-broker
  # The root broker MUST accept only the current boot's exact guest address and
  # profile gateway. Each editor MUST run under its reconciled personal UID;
  # restarting the broker MUST preserve systemd-owned workers and their sockets.
  systemd.services.overalls-vscode-web = lib.mkIf (privateServiceRoots != [ ]) {
    description = "Overalls account-bound browser editor broker";
    wantedBy = [ "multi-user.target" ];
    requires = [ "lilly-network.service" "lilly-private-dns.service" ];
    wants = [ "overalls-ssh-sync.service" ];
    after = [ "lilly-network.service" "lilly-private-dns.service" "overalls-ssh-sync.service" ];
    path = [ pkgs.shadow pkgs.coreutils pkgs.glibc.getent pkgs.util-linux pkgs.openssh ];
    environment.OVERALLS_SSH_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    unitConfig.ConditionKernelCommandLine = [ "lilly.ipv4" "lilly.placement" "lilly.execution_epoch" ];
    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = "${vscodeWebBroker}/bin/overalls-vscode-web-broker ${configuration}";
      Restart = "on-failure";
      RestartSec = 2;
      RuntimeDirectory = "overalls-vscode";
      RuntimeDirectoryMode = "0711";
      RuntimeDirectoryPreserve = "yes";
      StateDirectory = "overalls-ssh";
      StateDirectoryMode = "0700";
      UMask = "0077";
      TasksMax = 256;
      StandardOutput = "null";
      # stderr carries only the closed-schema broker events
      # (editor-broker-closed-diagnostics); without this it inherits null.
      StandardError = "journal";
    };
  };
  networking.firewall.allowedTCPPorts = [ 4444 ];
}
