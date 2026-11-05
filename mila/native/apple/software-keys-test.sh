#!/usr/bin/env bash
# Exercise the compile-gated macOS development custody policy (ADR-0235).
set -euo pipefail

[[ $# -eq 0 ]] || { echo "usage: software-keys-test.sh" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "software-key tests require macOS" >&2; exit 1; }

package_dir=$(cd "$(dirname "$0")" && pwd)
scratch="$package_dir/.build/software-keys"
mkdir -p "$scratch"

# @cc [owner:ghuntley,label:security;verification] apple-software-key-build-verification
# The enabled macOS DEBUG branch MUST run the custody and APNs-refusal tests
# in an isolated build directory. A non-DEBUG compile with the same define
# MUST fail with the policy diagnostic, not merely an unrelated tool error.
debug_log="$scratch/debug-tests.log"
xcrun swift test --package-path "$package_dir" --scratch-path "$scratch/debug" \
  --configuration debug -Xswiftc -DMILA_SOFTWARE_KEYS \
  --filter 'MilaNativeUITests\.(MilaSoftwareDeviceKeyTests|MilaDeviceSignerTests)/|MilaNativeUITests\.MilaApplePushTests/testAdHocMacOSSoftwareKeyBuildNeverRequestsAPNs' \
  2>&1 | tee "$debug_log"
# Swift test succeeds when a filter matches zero tests. Require the custody
# suite and the direct APNs-refusal case in the actual XCTest execution log.
grep -Eq "Test Suite '(MilaNativeUITests\\.)?MilaSoftwareDeviceKeyTests' passed" "$debug_log" || {
  echo "software-key custody tests did not execute successfully" >&2
  exit 1
}
grep -Eq 'Test Case .*testAdHocMacOSSoftwareKeyBuildNeverRequestsAPNs.*passed' "$debug_log" || {
  echo "software-key APNs-refusal test did not execute successfully" >&2
  exit 1
}

refusal_log="$scratch/release-refusal.log"
if xcrun swiftc -typecheck -D MILA_SOFTWARE_KEYS \
  "$package_dir/Sources/MilaNativeUI/MilaDeviceSigner.swift" > "$refusal_log" 2>&1; then
  echo "software keys unexpectedly compiled without DEBUG" >&2
  exit 1
fi
if ! grep -Fq 'MILA_SOFTWARE_KEYS requires a macOS DEBUG build' "$refusal_log"; then
  cat "$refusal_log" >&2
  echo "software-key release check failed without its policy diagnostic" >&2
  exit 1
fi
echo "software-key DEBUG tests and non-DEBUG refusal passed"
