{ pkgs }:
# @cc [owner:ghuntley,label:build] imported-artifacts-keep-runtime-references
# A Buck2-built artifact imported with nix-store --add-fixed has no recorded
# references. importArtifact MUST copy it into a derivation whose inputs are
# exactly its declared runtime references, so Nix rediscovers them by scanning
# and the closure keeps every store path the artifact needs at runtime
# (ADR-0269). An undeclared reference is absent from the closure, which the
# closure-parity test detects.
# selfReference is the placeholder store path an artifact was built against
# (Mix releases embed their own $out in bin/<app> and erts start scripts).
# It is rewritten to this derivation's $out; it has the same length as a real
# store path, so the rewrite is safe in any file.
{ name, path, runtimeRefs ? [ ], selfReference ? null }:
let
  # JSON strings carry no store context; storePath restores it, so each
  # reference becomes a derivation input that Nix scans the copy for.
  storeRoot = ref: builtins.concatStringsSep "/" (pkgs.lib.take 4 (pkgs.lib.splitString "/" ref));
  imported = builtins.storePath path;
  refs = map (ref: builtins.storePath (storeRoot ref)) runtimeRefs;
in
# With a self-reference, the import takes the placeholder's name so $out has
# the same length and the rewrite cannot shift offsets.
pkgs.runCommand (if selfReference != null then builtins.substring 44 (-1) selfReference else name) {
  runtimeRefs = refs;
  passthru = { inherit imported; runtimeRefs = refs; };
} (''
  cp -a ${imported} "$out"
  chmod -R u+w "$out"
'' + pkgs.lib.optionalString (selfReference != null) ''
  [[ ''${#out} -eq ${toString (builtins.stringLength selfReference)} ]] \
    || { echo "importArtifact: selfReference length differs from $out" >&2; exit 1; }
  grep -rlF -- ${pkgs.lib.escapeShellArg selfReference} "$out" \
    | xargs -r sed -i "s|${selfReference}|$out|g"
  ! grep -rqF -- ${pkgs.lib.escapeShellArg selfReference} "$out"
'')
