#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:build] staged-image-contexts
# Only exact, built Nix closure contexts may enter Docker's local build context.
# Refreshing one stage MUST preserve every other staged context.
# Each staged rootfs MUST embed its exact Nix output path for image identity
# verification, without changing the copied Nix tree's directory modes.
# The rootfs MUST remain a tar archive in the checkout, so closure filenames
# cannot enter Buck2's source crawler.
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
  listing=$(tools/buck2 build --show-full-output "$target")
  mapfile -t outputs < "$(awk 'END { print $2 }' <<< "$listing")"
  if [ "${#outputs[@]}" -ne 1 ] || [ ! -d "${outputs[0]}/rootfs" ]; then
    echo "missing Nix context output for $stage" >&2
    exit 1
  fi

  staged=$(mktemp -d "antithesis/build/.context-${stage}.XXXXXX")
  cp --preserve=mode "${outputs[0]}/identity.json" "${outputs[0]}/closure-store-paths.txt" "$staged/"
  # ADD unpacks the archive in Docker. Hardlinks are written as independent
  # regular files so every member has one unambiguous identity record.
  tar --sort=name --hard-dereference --numeric-owner --owner=0 --group=0 \
    -cf "$staged/rootfs.tar" -C "${outputs[0]}/rootfs" .
  printf '%s\n' "${outputs[0]}" > "$staged/context-output.txt"
  tar --numeric-owner --owner=0 --group=0 --mode=0644 \
    -rf "$staged/rootfs.tar" -C "$staged" \
    --transform='s,^context-output.txt$,./opt/overalls/context-output.txt,' context-output.txt
  if [ -d "antithesis/build/contexts/$stage" ]; then
    find "antithesis/build/contexts/$stage" -type d -exec chmod u+w {} +
    rm -rf "antithesis/build/contexts/$stage"
  fi
  # ZFS refuses renaming a read-only directory even when its parent is writable.
  chmod u+w "$staged"
  mv "$staged" "antithesis/build/contexts/$stage"
done
