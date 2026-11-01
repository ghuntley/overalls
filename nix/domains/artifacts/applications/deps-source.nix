{ lib }:
let
  root = ../../../..;
  # @cc [owner:ghuntley,label:build] test-dependency-source
  # Test-environment dependency fetches MUST read only the local Mix projects'
  # manifests, locks and configuration (plus the vendored SCIM manifest that
  # Marshall references by path); application code MUST stay out of the
  # fixed-output fetch, whose hash covers only what Hex and Git return.
  projects = [
    "marshall" "lilly" "audi" "porsche" "ziggy" "brady" "galileo" "enrico" "peach" "susan"
    "protocol" "elixir/diagnostics" "elixir/request_accounting"
  ];
  project = path: [
    (root + "/${path}/mix.exs")
    (lib.fileset.maybeMissing (root + "/${path}/mix.lock"))
    (lib.fileset.maybeMissing (root + "/${path}/config"))
  ];
in
lib.fileset.toSource {
  inherit root;
  fileset = lib.fileset.unions (lib.concatMap project projects ++ [ (root + "/vendor/ash_scim/mix.exs") ]);
}
