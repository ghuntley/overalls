# Buck2-built Mix releases that replace their Nix builds in assembly (ADR-0269):
# `<app>` or `encrypted-<app>` -> nix_store_import target. Owned by the M6
# Elixir migration.
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.
MIX_ARTIFACTS = {}
