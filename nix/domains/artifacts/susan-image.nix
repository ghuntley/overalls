# OCI image for the Susan push relay (ADR-0224). Hosting, registry and TLS
# placement are deliberately open; TLS terminates at the fronting proxy.
{ pkgs, release, revision ? "source" }:
let
  # From the name, which both the Nix release and a Buck2 import carry
  # (overalls-susan-<version>); an import has no `version` attribute.
  version = (builtins.parseDrvName release.name).version;
  # Fixed so identical inputs produce an identical image manifest.
  created = "2026-10-18T00:00:00Z";
in
# @cc [owner:ghuntley,label:deployment;security] susan-image-shape
# The image MUST contain only the release closure, CA certificates, tzdata and
# fixed identity files: no shell or package manager on PATH or at /bin, no
# secrets, a non-root numeric user and a fixed creation time. Migrations are a
# separate release command; secrets arrive at runtime as files.
pkgs.dockerTools.streamLayeredImage {
  name = "overalls-susan";
  tag = version;
  inherit created;
  # cacert and tzdata enter the closure through these references; nothing
  # else (no shell, no coreutils) is linked into the root.
  extraCommands = ''
    mkdir -p etc/ssl/certs etc/susan run/secrets/susan tmp usr/share
    ln -s ${pkgs.tzdata}/share/zoneinfo usr/share/zoneinfo
    chmod 1777 tmp
    echo 'susan:x:65532:65532:Susan:/var/empty:/var/empty/nologin' > etc/passwd
    echo 'susan:x:65532:' > etc/group
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
  '';
  config = {
    User = "65532:65532";
    WorkingDir = "${release}";
    Entrypoint = [ "${release}/bin/susan" ];
    Cmd = [ "start" ];
    Env = [
      "LANG=C.UTF-8"
      "TZDIR=${pkgs.tzdata}/share/zoneinfo"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
      "RELEASE_TMP=/tmp"
      "RELEASE_DISTRIBUTION=name"
      "RELEASE_NODE=susan@127.0.0.1"
      "ERL_EPMD_ADDRESS=127.0.0.1"
      "ERL_CRASH_DUMP=/dev/null"
      # No shell exists to spawn epmd; Susan.Epmd maps the fixed loopback port.
      "ERL_FLAGS=-start_epmd false -epmd_module Elixir.Susan.Epmd -kernel inet_dist_use_interface {127,0,0,1}"
      "SUSAN_DIST_PORT=4370"
      "SUSAN_CONFIG_FILE=/etc/susan/config.json"
      "CREDENTIALS_DIRECTORY=/run/secrets/susan"
    ];
    ExposedPorts = { "4100/tcp" = { }; };
    Labels = {
      "org.opencontainers.image.title" = "overalls-susan";
      "org.opencontainers.image.description" = "Susan push relay for content-free Mila notifications";
      "org.opencontainers.image.version" = version;
      "org.opencontainers.image.revision" = revision;
      "org.opencontainers.image.created" = created;
      "org.opencontainers.image.licenses" = "MIT";
      "dev.overalls.migrate" = "${release}/bin/susan eval Susan.Release.migrate()";
    };
  };
}
