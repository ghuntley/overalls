#!/usr/bin/env bash
# Evaluates lib.assemble over a copied tree of declared sources only, under
# restrict-eval, so an undeclared Nix input is an evaluation error (ADR-0269).
set -euo pipefail
nix=$1 jq=$2 manifest=$3 names=$4 artifacts=$5 attr=$6 revision=$7 gcroot=$8 out=$9 mode=${10:-build}
# GC roots stay outside the repository so file watchers never follow them.
roots=${OVERALLS_GCROOT_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/overalls-buck2/gcroots}
mkdir -p "$roots"
# Actions run in the project root; its hash keeps checkouts from sharing roots.
link="$roots/$(pwd | sha256sum | cut -c1-12)-$gcroot"
tree=$(mktemp -d "${TMPDIR:-/tmp}/overalls-assemble.XXXXXX")
trap 'rm -rf "$tree"' EXIT
# Each line pairs an owned source directory with its package path.
paste -d '\t' "$manifest" "$names" | while IFS=$'\t' read -r src package; do
  mkdir -p "$tree/$package"
  cp -RL "$src/." "$tree/$package/"
done
# Keep executable bits: Nix source hashes include them, so dropping them
# would fork assembled systems from the flake build.
chmod -R u+w "$tree"
# Replace each import's store-path file with the store path it names.
"$jq" -c 'to_entries[]' "$artifacts" | while read -r entry; do
  name=$("$jq" -r .key <<<"$entry"); file=$("$jq" -r .value.path <<<"$entry")
  "$jq" -c --arg name "$name" --arg path "$(cat "$file")" '{($name): (.value | .path = $path)}' <<<"$entry"
done | "$jq" -s 'add // {}' > "$tree/.buck-artifacts.json"
[[ -f "$tree/flake.nix" && -f "$tree/flake.lock" ]] || { echo "nix_assemble: flake.nix/flake.lock not declared" >&2; exit 1; }
expr="let flake = builtins.getFlake \"path:$tree\"; a = flake.lib.assemble {
      revision = \"$revision\";
      artifacts = builtins.fromJSON (builtins.readFile (flake.outPath + \"/.buck-artifacts.json\"));
    }; in a.$attr"
restrict=(--impure --option restrict-eval true
  --option allowed-uris "github: https://github.com/ git+https://github.com/ https://api.github.com/")
if [[ $mode == drv ]]; then
  # Evaluation only: the same declared tree and restrictions, no build and no
  # GC root (the derivation files stay unrooted).
  "$nix" eval --raw "${restrict[@]}" --expr "($expr).drvPath" > "$out"
else
  "$nix" build "${restrict[@]}" --out-link "$link" --print-out-paths --expr "$expr" > "$out"
fi
