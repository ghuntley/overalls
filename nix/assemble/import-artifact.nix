{ pkgs }:
# @cc [owner:ghuntley,label:build] imported-artifacts-keep-runtime-references
# A Buck2-built artifact imported with nix-store --add-fixed has no recorded
# references. importArtifact MUST copy it into a derivation whose inputs are
# exactly its declared runtime references, so Nix rediscovers them by scanning
# and the closure keeps every store path the artifact needs at runtime
# (ADR-0269). An undeclared reference is absent from the closure, which the
# closure-parity test detects.
{ name, path, runtimeRefs ? [ ] }:
let
  # JSON strings carry no store context; storePath restores it, so each
  # reference becomes a derivation input that Nix scans the copy for.
  storeRoot = ref: builtins.concatStringsSep "/" (pkgs.lib.take 4 (pkgs.lib.splitString "/" ref));
  imported = builtins.storePath path;
  refs = map (ref: builtins.storePath (storeRoot ref)) runtimeRefs;
in
pkgs.runCommand name {
  runtimeRefs = refs;
  passthru = { inherit imported; runtimeRefs = refs; };
} ''
  cp -a ${imported} "$out"
  chmod -R u+w "$out"
''
