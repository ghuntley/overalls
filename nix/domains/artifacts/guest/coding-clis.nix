{ pkgs }:
let
  inherit (pkgs) lib;
  # Codex is pinned independently from the host package set.  Guest images
  # may evaluate against a newer nixpkgs input while the accepted guest CLI
  # contract remains on the reviewed 0.149.0 application package.
  codexPkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c8f90650c15282fa8656a041bfbbd2403997a9a7.tar.gz";
    sha256 = (import ../pins.nix).codingClisNixpkgs;
  }) {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  bundle = "/etc/ssl/certs/ca-certificates.crt";
  # @cc [owner:ghuntley,label:build] guest-coding-cli-pinned-packages
  # Both clients MUST come from the supplied pinned package source. Allowing
  # Claude Code's license MUST NOT permit other unfree packages or replace the
  # supplied package overlays. Their image defaults MUST disable automatic
  # client update checks, binary updates and forced plugin updates.
  claudePkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c8f90650c15282fa8656a041bfbbd2403997a9a7.tar.gz";
    sha256 = (import ../pins.nix).codingClisNixpkgs;
  }) {
    localSystem = pkgs.stdenv.hostPlatform;
    overlays = pkgs.overlays;
    config = pkgs.config // {
      allowUnfree = false;
      allowUnfreePackages = [ ];
      allowUnfreePredicate = package: lib.getName package == "claude-code";
    };
  };
  # Nixpkgs disables binary updates but separately forces plugin updates. Keep
  # the guest from forcing network plugin work when client updates are disabled.
  claudeCode = claudePkgs.claude-code.overrideAttrs (previous: {
    installPhase = assert lib.assertMsg (lib.hasInfix "--set-default FORCE_AUTOUPDATE_PLUGINS 1" previous.installPhase)
      "Claude Code packaging changed; review automatic plugin update behavior";
      builtins.replaceStrings
      [ "--set-default FORCE_AUTOUPDATE_PLUGINS 1" ]
      [ "" ]
      previous.installPhase;
  });
  codexSettings = {
    model_provider = "ziggy";
    check_for_update_on_startup = false;
    approval_policy = "never";
    sandbox_mode = "danger-full-access";
    model_providers.ziggy = {
      name = "Ziggy";
      base_url = "https://llm.internal/openai/v1";
      wire_api = "responses";
      requires_openai_auth = false;
      supports_websockets = false;
    };
  };
  # @cc [owner:ghuntley,label:security] guest-coding-cli-native-trust
  # Native client configuration MUST use verified guest CA trust and Ziggy's
  # private inference URLs, without provider secrets, login-token custody,
  # custom launchers or modifications to user homes and saved model choices.
  claudeSettings.permissions.defaultMode = "bypassPermissions";
  claudeSettings.skipDangerousModePermissionPrompt = true;
  claudeSettings.sandbox.enabled = false;
  claudeSettings.env = {
    ANTHROPIC_BASE_URL = "https://llm.internal/anthropic";
    ANTHROPIC_AUTH_TOKEN = "ziggy";
    DISABLE_AUTOUPDATER = "1";
    FORCE_AUTOUPDATE_PLUGINS = "0";
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    NODE_EXTRA_CA_CERTS = bundle;
    SSL_CERT_FILE = bundle;
  };
  environmentVariables = {
    CODEX_CA_CERTIFICATE = bundle;
    NODE_EXTRA_CA_CERTS = bundle;
    REQUESTS_CA_BUNDLE = bundle;
    SSL_CERT_FILE = bundle;
    NIX_SSL_CERT_FILE = bundle;
  };
in
assert (lib.types.attrsOf lib.types.str).check environmentVariables;
{
  inherit codexSettings claudeSettings environmentVariables;
  packages = [
    (assert lib.assertMsg (codexPkgs.codex.version == "0.149.0")
      "Guest Codex version changed; supply the pinned application package when evaluating another host package set";
      codexPkgs.codex)
    (assert lib.assertMsg (claudeCode.version == "2.1.238")
      "Guest Claude Code version changed; supply the pinned application package when evaluating another host package set";
      claudeCode)
  ];
  codexConfiguration = (pkgs.formats.toml { }).generate "guest-codex-config.toml" codexSettings;
  claudeConfiguration = (pkgs.formats.json { }).generate "guest-claude-managed-settings.json" claudeSettings;
  loginEnvironment = pkgs.writeText "guest-coding-cli-environment.sh"
    (lib.concatStringsSep "\n" (lib.mapAttrsToList
      (name: value: "export ${name}=${lib.escapeShellArg value}") environmentVariables) + "\n");
  pamEnvironment = pkgs.writeText "guest-coding-cli-environment"
    (lib.concatStringsSep "\n" (lib.mapAttrsToList
      (name: value: ''${name}="${value}"'') environmentVariables) + "\n");
}
