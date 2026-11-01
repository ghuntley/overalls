#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:build] release-runtime-closure
# Packaging MUST build and check the selected source release with the locked Nix
# runtime, then export every runtime prerequisite before publishing the final
# .nar and checksum. Local deps and _build MUST NOT supply release inputs.
application=${1:?Usage: package_release.sh marshall|lilly|audi|porsche|ziggy}
case "$application" in marshall|lilly|audi|porsche|ziggy) ;; *) exit 2 ;; esac
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"
mkdir -p -- "$repo_root/artifacts"
# Buck2 is the build entry point (ADR-0269): each nix_assemble target's output
# names the store path it built, and the wrapper keeps a GC root for it.
built() {
  local listing
  listing=$("$repo_root/tools/buck2" build --show-full-output "$1")
  cat -- "$(awk 'END { print $2 }' <<< "$listing")"
}
built "//:check-$application-release" > /dev/null
bundle=$(built "//:package-service-$application")
[[ $bundle == /nix/store/* && -e $bundle ]]
# The out-link stays an indirect GC root, as `nix build --out-link` made it.
rm -f -- "$repo_root/artifacts/$application"
nix-store --add-root "$repo_root/artifacts/$application" --realise "$bundle" > /dev/null
closure_paths=$(nix-store --query --requisites "$bundle")
mapfile -t closure <<< "$closure_paths"
[[ ${#closure[@]} -gt 0 && -n ${closure[0]} ]]
nix-store --export "${closure[@]}" > "$repo_root/artifacts/$application.nar.tmp"
mv -- "$repo_root/artifacts/$application.nar.tmp" "$repo_root/artifacts/$application.nar"
(cd -- "$repo_root/artifacts" && sha256sum "$application.nar" > "$application.nar.sha256")
printf '%s\n' "$bundle" > "$repo_root/artifacts/$application.store-path"
printf 'Release and complete Nix closure: %s/artifacts/%s\n' "$repo_root" "$application"
