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
# allowedReferences, when the artifact declares it, constrains the copy as it
# constrained the Nix build it replaces (the Windows agents embed no store
# path), so the constraint binds the artifact that ships.
#
# @cc [owner:ghuntley,label:build;verification] imported-artifacts-reject-build-hooks
# An import is a copy, so build hooks set on it (preBuild, postInstall, a
# *Phase, patches or src through overrideAttrs) would be ignored and the
# "patched" release would be the unpatched one. Such an override MUST be an
# evaluation error; a fixture that changes a Buck2 leaf uses a Buck2
# `release_variants` entry instead. Overrides of meta, passthru or reference
# constraints (swapLeaf) stay allowed, and their results stay sealed.
#
# @cc [owner:ghuntley,label:build;deployment] mix-release-package-references
# packageReferences maps a placeholder store path the artifact embeds (in file
# contents or symlink targets) to a package-set attribute, such as Lilly's
# release naming `hostTools`. The import MUST rewrite every placeholder to
# that attribute of the package set it is used in, so a release runs the same
# host tools as the system it ships in. Each rewritten path becomes a
# runtime reference. An import with package references used outside a
# package set, or a placeholder whose length differs from the real path, MUST
# fail rather than leave the placeholder.
{ name, path, runtimeRefs ? [ ], selfReference ? null, allowedReferences ? null, packageReferences ? { }, packageSet ? null }:
let
  inherit (pkgs) lib;
  ignoredHook = attr: builtins.match "(pre|post)[A-Z].*|.*Phase|.*Phases|patches|src|srcs|sourceRoot|buildCommand" attr != null;
  seal = drv: drv // {
    overrideAttrs = f:
      let
        next = drv.overrideAttrs f;
        changed = lib.filter (attr: ignoredHook attr
          && (!(drv.drvAttrs ? ${attr}) || drv.drvAttrs.${attr} != next.drvAttrs.${attr}))
          (lib.attrNames next.drvAttrs);
      in
      if changed == [ ] then seal next
      else throw "importArtifact: ${name} is a Buck2 import (a copy); overrideAttrs setting ${lib.concatStringsSep ", " changed} would be ignored. Use a Buck2 release_variants entry (ADR-0269).";
  };
  # JSON strings carry no store context; storePath restores it, so each
  # reference becomes a derivation input that Nix scans the copy for.
  storeRoot = ref: builtins.concatStringsSep "/" (pkgs.lib.take 4 (pkgs.lib.splitString "/" ref));
  imported = builtins.storePath path;
  refs = map (ref: builtins.storePath (storeRoot ref)) runtimeRefs;
  resolved = lib.mapAttrs (placeholder: attr:
    if packageSet == null
    then throw "importArtifact: ${name} names package-set attribute ${attr}; import it through a package set (passthru.inPackageSet)"
    else packageSet.${attr}) packageReferences;
  # Rewrites a placeholder in file contents and in symlink targets. The
  # leftover checks look for its base name, so a partly rewritten path fails.
  rewrite = placeholder: target: ''
    placeholder=${lib.escapeShellArg placeholder}
    leftover=${lib.escapeShellArg (baseNameOf placeholder)}
    [[ ''${#target} -eq ''${#placeholder} ]] \
      || { echo "importArtifact: $placeholder and $target differ in length" >&2; exit 1; }
    { grep -rlF -- "$placeholder" "$out" || true; } | xargs -r sed -i "s|$placeholder|$target|g"
    while IFS= read -r -d "" link; do
      dest=$(readlink "$link")
      if [[ $dest == *"$placeholder"* ]]; then
        ln -sfn "''${dest//"$placeholder"/"$target"}" "$link"
      fi
    done < <(find "$out" -type l -print0)
    # `!` would be exempt from errexit, so each check exits explicitly.
    if grep -rqF -- "$leftover" "$out" || [[ -n $(find "$out" -type l -lname "*$leftover*") ]]; then
      echo "importArtifact: $placeholder remains in ${name}" >&2; exit 1
    fi
  '';
in
# With a self-reference, the import takes the placeholder's name so $out has
# the same length and the rewrite cannot shift offsets.
seal (pkgs.runCommand (if selfReference != null then builtins.substring 44 (-1) selfReference else name) ({
  runtimeRefs = refs ++ lib.attrValues resolved;
  passthru = {
    inherit imported;
    runtimeRefs = refs ++ lib.attrValues resolved;
    needsPackageSet = packageReferences != { } && packageSet == null;
    # The same import with its package references resolved against `set`.
    inPackageSet = set: import ./import-artifact.nix { inherit pkgs; } {
      inherit name path runtimeRefs selfReference allowedReferences packageReferences;
      packageSet = set;
    };
  };
} // lib.optionalAttrs (allowedReferences != null) {
  allowedReferences = map (ref: builtins.storePath (storeRoot ref)) allowedReferences;
}) (''
  cp -a ${imported} "$out"
  chmod -R u+w "$out"
'' + pkgs.lib.optionalString (selfReference != null) ''
  [[ ''${#out} -eq ${toString (builtins.stringLength selfReference)} ]] \
    || { echo "importArtifact: selfReference length differs from $out" >&2; exit 1; }
  grep -rlF -- ${pkgs.lib.escapeShellArg selfReference} "$out" \
    | xargs -r sed -i "s|${selfReference}|$out|g"
  if grep -rqF -- ${pkgs.lib.escapeShellArg selfReference} "$out"; then
    echo "importArtifact: selfReference remains in ${name}" >&2; exit 1
  fi
'' + lib.concatStrings (lib.mapAttrsToList (placeholder: drv: ''
  target=${drv}
'' + rewrite placeholder "$target") resolved)))
