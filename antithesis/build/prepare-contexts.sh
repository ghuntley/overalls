#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:build] staged-image-contexts
# Only exact, built Nix closure contexts may enter Docker's local build context.
# Refreshing one stage MUST preserve every other staged context.
# Each staged rootfs MUST embed its exact Nix output path for image identity
# verification, without changing the copied Nix tree's directory modes.
repository=$(git rev-parse --show-toplevel)
cd "$repository"

if [ "$#" -eq 0 ]; then
  set -- pg marshall lilly audi porsche ziggy galileo brady enrico workload origin smtp producer-peer request-recorder trace-spool
fi

mkdir -p antithesis/build/contexts
for stage in "$@"; do
  case "$stage" in
    pg|marshall|lilly|lilly-guest|audi|porsche|ziggy|galileo|brady|enrico|workload|origin|smtp|producer-peer|request-recorder|trace-spool|guest-vmm|router-vmm|host-vmm|private-host-vmm|recorder-host-vmm) ;;
    *) echo "unknown Antithesis image stage: $stage" >&2; exit 2 ;;
  esac

  # Buck2 builds the context (ADR-0269); its output file names the store path.
  # verification/identity.py checks staged contexts against the same target.
  target="//:package-antithesis-${stage}-context"
  # Nix closures can contain literal backslashes in example filenames.  The
  # default fs-hash crawler rejects those names while rescanning the checkout
  # after the first context is staged; notify accepts them and the explicit
  # source glob in antithesis/BUCK still keeps generated contexts out of Nix
  # assembly inputs.
  listing=$(tools/buck2 build -c buck2.file_watcher=notify --show-full-output "$target")
  mapfile -t outputs < "$(awk 'END { print $2 }' <<< "$listing")"
  if [ "${#outputs[@]}" -ne 1 ] || [ ! -d "${outputs[0]}/rootfs" ]; then
    echo "missing Nix context output for $stage" >&2
    exit 1
  fi

  staged=$(mktemp -d "antithesis/build/.context-${stage}.XXXXXX")
  cp -a --no-preserve=ownership "${outputs[0]}/." "$staged/"
  identity_dir="$staged/rootfs/opt/overalls"
  identity_mode=$(stat -c %a "$identity_dir")
  chmod u+w "$identity_dir"
  printf '%s\n' "${outputs[0]}" > "$identity_dir/context-output.txt"
  chmod "$identity_mode" "$identity_dir"
  if [ -d "antithesis/build/contexts/$stage" ]; then
    find "antithesis/build/contexts/$stage" -type d -exec chmod u+w {} +
    rm -rf "antithesis/build/contexts/$stage"
  fi
  # ZFS refuses renaming a read-only directory even when its parent is writable.
  chmod u+w "$staged"
  mv "$staged" "antithesis/build/contexts/$stage"
done
