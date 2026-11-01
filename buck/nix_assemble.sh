#!/usr/bin/env bash
# Evaluates lib.assemble over a copied tree of declared sources only, under
# restrict-eval, so an undeclared Nix input is an evaluation error (ADR-0269).
set -euo pipefail
nix=$1 jq=$2 manifest=$3 names=$4 artifacts=$5 params=$6 attr=$7 revision=$8 gcroot=$9 out=${10} mode=${11:-build}
# GC roots stay outside the repository so file watchers never follow them.
roots=${OVERALLS_GCROOT_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/overalls-buck2/gcroots}
mkdir -p "$roots"
# Actions run in the project root; its hash keeps checkouts from sharing roots.
link="$roots/$(pwd | sha256sum | cut -c1-12)-$gcroot"
# The copy lives in this action's own Buck2 scratch directory, never a shared
# temp dir: one CI evaluation lost files mid-`chmod -R` ("fts_read failed")
# while sibling evaluations were being OOM-killed (run 41130542439).
if [[ -n "${BUCK_SCRATCH_PATH:-}" ]]; then
  mkdir -p "$BUCK_SCRATCH_PATH"
  tree=$(mktemp -d "$(cd "$BUCK_SCRATCH_PATH" && pwd)/assemble.XXXXXX")
else
  tree=$(mktemp -d "${TMPDIR:-/tmp}/overalls-assemble.XXXXXX")
fi
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
  # Contract nix-store-import-gc-rooted: see buck/CONTRACTS.
  [[ -e $(cat "$file") ]] || { echo "nix_assemble: artifact $name names $(cat "$file"), which is no longer in the Nix store (collected after import); rebuild its import, e.g. after tools/buck2 clean" >&2; exit 1; }
  "$jq" -c --arg name "$name" --arg path "$(cat "$file")" '{($name): (.value | .path = $path)}' <<<"$entry"
done | "$jq" -s 'add // {}' > "$tree/.buck-artifacts.json"
# The target's parameters (fleet_host(params = ...)); lib.assemble validates
# each key and type (contract assembly-params-validated).
"$jq" -e 'type == "object"' "$params" > /dev/null || { echo "nix_assemble: params is not a JSON object" >&2; exit 1; }
cp "$params" "$tree/.buck-params.json"
[[ -f "$tree/flake.nix" && -f "$tree/flake.lock" ]] || { echo "nix_assemble: flake.nix/flake.lock not declared" >&2; exit 1; }
expr="let flake = builtins.getFlake \"path:$tree\"; a = flake.lib.assemble {
      revision = \"$revision\";
      artifacts = builtins.fromJSON (builtins.readFile (flake.outPath + \"/.buck-artifacts.json\"));
      params = builtins.fromJSON (builtins.readFile (flake.outPath + \"/.buck-params.json\"));
    }; in a.$attr"
# getFlake takes a path and flake.lock pins every input, so assembly needs
# no flake registry. Restrict-eval resolves each lookup-path entry up front,
# and a `flake:` entry (NixOS's `nixpkgs=flake:nixpkgs`) would read the global
# registry, which fails without a route to channels.nixos.org (host
# enrollment inside a test VM). An empty flake-registry leaves such entries
# unresolved instead. nix-path itself stays: clearing it also drops
# extra-nix-path, through which an offline host (the enrollment fixture)
# grants restrict-eval its pinned sources.
restrict=(--impure --option restrict-eval true --option flake-registry ""
  --option allowed-uris "github: https://github.com/ git+https://github.com/ https://api.github.com/")
if [[ $mode == drv ]]; then
  # Evaluation only: the same declared tree and restrictions, no build and no
  # GC root (the derivation files stay unrooted).
  "$nix" eval --raw "${restrict[@]}" --expr "($expr).drvPath" > "$out"
else
  "$nix" build "${restrict[@]}" --out-link "$link" --print-out-paths --expr "$expr" > "$out"
fi
