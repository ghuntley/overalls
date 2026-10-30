{ pkgs, application, package, toolchain, cargoVendor }:
pkgs.runCommand "${application}-source-release-check" {
  env = {
    OVERALLS_RELEASE_APPLICATION = application;
    OVERALLS_RELEASE_ROOT = "${package}";
    OVERALLS_RELEASE_ELIXIR = toolchain.elixir.version;
    OVERALLS_RELEASE_OTP = toolchain.erlang.version;
    RELEASE_DISTRIBUTION = "none";
    RELEASE_COOKIE = "isolated-nix-release-test";
    ELIXIR_ERL_OPTIONS = "+S 2:2";
    BRADY_CONFIG_FILE = "/missing-isolated-brady-config";
    PHX_SERVER = "false";
    PHX_HOST = "control.example.test";
    DATABASE_URL = "postgresql://fixture:fixture@database.example.test/fixture";
    MARSHALL_DB_CA_CERTFILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    MARSHALL_REPLICA_COUNT = "3";
    MARSHALL_INSTANCE_ID = "release-check";
    MARSHALL_DB_CONNECTION_BUDGET = "43";
    SECRET_KEY_BASE = "isolated-release-check-0000000000000000000000000000000000000000000000";
    TOKEN_SIGNING_SECRET = "isolated-release-signing-test-000000000000000000000000000000000000";
    MARSHALL_SMTP_HOST = "smtp.example.test";
    MARSHALL_SMTP_USERNAME = "fixture";
    MARSHALL_SMTP_PASSWORD = "isolated-test-fixture";
    MARSHALL_SMTP_CA_CERTFILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    MARSHALL_MAIL_FROM = "fixture@example.test";
  };
} ''
  # @cc [owner:ghuntley,label:verification] release-eval-no-service-start
  # Payload checks MUST use release eval without starting application services;
  # no database, mail connection or privileged host action is needed here.
  export RELEASE_TMP="$TMPDIR/release"
  mkdir -p "$RELEASE_TMP"
  mkdir -p scripts
  cp ${../../../../.tool-versions} .tool-versions
  cp ${../../../../scripts/check_toolchain.exs} scripts/check_toolchain.exs
  ${toolchain.elixir}/bin/elixir scripts/check_toolchain.exs
  export OVERALLS_RELEASE_ERTS
  OVERALLS_RELEASE_ERTS="$(${toolchain.erlang}/bin/erl +S 2:2 -noshell \
    -eval 'io:format("~s", [erlang:system_info(version)]), halt().')"
  ${package}/bin/${application} eval 'Code.eval_file("${./probe.exs}")'
  # @cc [owner:ghuntley,label:deployment] release-closure-excludes-cargo-vendor
  # The runtime closure MUST NOT retain the root workspace's vendored crates;
  # they are build inputs only (ADR-0273).
  find ${cargoVendor}/ -mindepth 1 -maxdepth 1 -type l -exec readlink -f {} + |
    sed -E 's|^(/nix/store/[^/]+).*|\1|' | sort -u > vendor-paths
  echo ${cargoVendor} >> vendor-paths
  if grep -Fxf vendor-paths ${pkgs.closureInfo { rootPaths = [ package ]; }}/store-paths; then
    echo "${application} release retains vendored Cargo crates at runtime" >&2
    exit 1
  fi
  ${pkgs.lib.optionalString (application == "marshall") ''
    if env -u DATABASE_URL ${package}/bin/marshall eval ':ok' > rejected.log 2>&1; then
      echo "Marshall accepted missing production database configuration" >&2
      exit 1
    fi
    grep -q 'Invalid production deployment configuration' rejected.log
    if MARSHALL_DEFAULT_IMAGE_ID=invalid ${package}/bin/marshall eval ':ok' > rejected-image.log 2>&1; then
      echo "Marshall accepted an invalid default image identity" >&2
      exit 1
    fi
    grep -q 'Invalid MARSHALL_DEFAULT_IMAGE_ID' rejected-image.log
  ''}
  touch "$out"
''
