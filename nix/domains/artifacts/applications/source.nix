{ lib, application, antithesisSdk ? false }:
let
  root = ../../../..;
  project = root + "/${application}";
  # @cc [owner:ghuntley,label:build] release-source-allowlist
  # Only application build inputs, the shared protocol (including its compile-time
  # priv data) and the explicit local
  # request-accounting and observability libraries MUST enter the source closure. Local builds, fetched
  # deps and generated assets MUST remain excluded.

  # @cc [owner:ghuntley,label:build] harness-source-isolation
  # The fallback SDK source MUST enter only explicitly selected harness
  # releases; ordinary production source closures MUST exclude antithesis/.
  inputs = [
    (project + "/mix.exs")
    (project + "/mix.lock")
    (project + "/lib")
    (project + "/config")
    ../../../../protocol/mix.exs
    ../../../../protocol/mix.lock
    ../../../../protocol/lib
    ../../../../protocol/priv
    ../../../../elixir/diagnostics/mix.exs
    ../../../../elixir/diagnostics/mix.lock
    ../../../../elixir/diagnostics/lib
    ../../../../elixir/diagnostics/priv
  ] ++ lib.optionals antithesisSdk [
    ../../../../antithesis/sdk/mix.exs
    ../../../../antithesis/sdk/mix.lock
    ../../../../antithesis/sdk/lib
    ../../../../antithesis/sdk/native
  ] ++ lib.optionals (antithesisSdk && application == "lilly") [
    ../../../../antithesis/lilly/lib
  ] ++ lib.optionals (antithesisSdk && application == "marshall") [
    ../../../../antithesis/marshall/lib
  ] ++ lib.optionals (builtins.elem application [ "marshall" "audi" "porsche" "brady" "galileo" "enrico" "ziggy" "peach" ]) [
    ../../../../elixir/request_accounting/mix.exs
    ../../../../elixir/request_accounting/mix.lock
    ../../../../elixir/request_accounting/lib
  ] ++ lib.optionals (application == "marshall") [
    ../../../../marshall/assets
    ../../../../marshall/priv
    # Marshall's own Cedar NIF crate, compiled by Rustler at build time.
    ../../../../marshall/native/marshall_cedar/Cargo.toml
    ../../../../marshall/native/marshall_cedar/Cargo.lock
    ../../../../marshall/native/marshall_cedar/src
    # Marshall's SCIM integration is vendored in-tree and referenced by path
    # from mix.exs; retain the source in release closures.
    ../../../../vendor/ash_scim
  ] ++ lib.optionals (application == "audi") [ ../../../../audi/priv ]
    ++ lib.optionals (application == "susan") [ ../../../../susan/priv ]
    ++ lib.optionals (application == "porsche") [ ../../../../porsche/priv ];
  selected = lib.fileset.unions inputs;
  generated = lib.fileset.unions [
    (lib.fileset.maybeMissing ../../../../marshall/priv/static/assets)
    (lib.fileset.maybeMissing ../../../../marshall/priv/static/cache_manifest.json)
    (lib.fileset.maybeMissing ../../../../marshall/assets/node_modules)
    (lib.fileset.maybeMissing ../../../../marshall/priv/native)
    (lib.fileset.fileFilter
      (file: file.hasExt "gz" || builtins.match ".*-[0-9a-f]{32}\\.[^.]+" file.name != null)
      ../../../../marshall/priv/static)
  ];
in
assert builtins.elem application [ "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" "peach" "susan" ];
lib.fileset.toSource {
  inherit root;
  fileset = lib.fileset.difference selected generated;
}
