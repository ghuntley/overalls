#!/usr/bin/env bash
# Replaces the one occurrence of BOUNDARY in SOURCE with REPLACEMENT's text,
# writing OUT, for test-only fault-injection variants of first-party sources
# (nix/BUCK :otel-request-recorder-cut-source). Fails when BOUNDARY is absent
# or repeated, so a moved boundary cannot silently build the unpatched code.
#
# usage: replace_boundary.sh SOURCE BOUNDARY REPLACEMENT OUT
set -euo pipefail
source_file=$1 boundary=$2 replacement_file=$3 out=$4
# Bash 5.2 expands & in a replacement; the fragment is literal Rust.
shopt -u patsub_replacement 2>/dev/null || true
text=$(<"$source_file")
replacement=$(<"$replacement_file")
rest=${text#*"$boundary"}
if [[ $rest == "$text" ]]; then
  echo "replace_boundary.sh: boundary not found in $source_file" >&2
  exit 1
fi
if [[ $rest == *"$boundary"* ]]; then
  echo "replace_boundary.sh: boundary repeated in $source_file" >&2
  exit 1
fi
printf '%s\n' "${text/"$boundary"/"$replacement"}" >"$out"
