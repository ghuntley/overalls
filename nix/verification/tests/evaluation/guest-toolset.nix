{ pkgs }:
let
  inherit (pkgs) lib;
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ ../../../domains/artifacts/guest/configuration.nix ];
  };
  config = guest.config;
  codingClis = import ../../../domains/artifacts/guest/coding-clis.nix { inherit pkgs; };
  # The evaluated image uses eval-config's package set; compare by derivation
  # name so the assertion does not depend on package-set identity.
  present = name: builtins.any (p: lib.getName p == name) config.environment.systemPackages;
  toolset = with pkgs; [
    curl iproute2 iputils dnsutils wget tmux vim neovim less lsof jq ripgrep
    mercurial git atop btop iotop ncdu sqlite podman-compose direnv devenv starship
  ] ++ codingClis.packages;
  # gh is the managed client (ADR-0202): an unpatched nixpkgs gh earlier in
  # systemPackages wins the buildEnv collision for bin/gh and bypasses Galileo.
  managedGh = present "overalls-managed-gh-linux-amd64";
  unmanagedGh = builtins.any (p: lib.getName p == "gh") config.environment.systemPackages;
  missing = lib.filter (package: !(present (lib.getName package))) toolset;
  dockerAlias = builtins.any (p: lib.hasPrefix "podman-docker-compat" (lib.getName p))
    config.environment.systemPackages;
in
# @cc [owner:ghuntley,label:verification] guest-toolset-evaluation
# The default guest MUST enable Podman with the Docker CLI alias and Docker
# socket compatibility, and MUST ship the reviewed default toolset. Evaluation
# MUST fail when any default tool is missing from the image's system packages.
assert lib.assertMsg (config.virtualisation.podman.enable
  && config.virtualisation.podman.dockerCompat
  && config.virtualisation.podman.dockerSocket.enable)
  "guest podman Docker compatibility is not fully enabled";
assert lib.assertMsg (builtins.elem "/run/docker.sock"
  (config.systemd.sockets.podman.socketConfig.Symlinks or [ ]))
  "guest podman socket does not alias /run/docker.sock";
assert lib.assertMsg dockerAlias "guest image lacks the docker CLI compatibility alias";
assert lib.assertMsg (missing == [ ]) "guest image is missing default tools: ${toString missing}";
assert lib.assertMsg (managedGh && !unmanagedGh)
  "guest gh must be the managed client only; an unmanaged gh shadows it";
assert lib.assertMsg (config.environment.etc."codex/config.toml".source == codingClis.codexConfiguration
  && config.environment.etc."claude-code/managed-settings.json".source == codingClis.claudeConfiguration)
  "guest native coding CLI configuration is absent or differs from the shared image settings";
assert lib.assertMsg (lib.all (name: config.environment.variables.${name} == "/etc/ssl/certs/ca-certificates.crt")
  [ "CODEX_CA_CERTIFICATE" "SSL_CERT_FILE" "NODE_EXTRA_CA_CERTS" ])
  "guest native coding CLIs do not inherit the verified guest CA bundle";
assert lib.assertMsg (config.programs.starship.enable && config.programs.starship.interactiveOnly
  && lib.hasInfix "starship init bash" config.programs.bash.promptInit)
  "guest image does not initialize Starship for interactive Bash";
assert lib.assertMsg (lib.elem "nix-command" config.nix.settings.experimental-features
  && lib.elem "flakes" config.nix.settings.experimental-features)
  "NixOS guest does not enable the Nix command and flakes features";
assert lib.assertMsg (lib.getName config.users.defaultUserShell == lib.getName pkgs.bashInteractive)
  "guest default user shell is not interactive Bash";
pkgs.runCommand "guest-toolset-config" { } "touch $out"
