#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner once the emulator has booted.
#
# MILA_ANDROID_APK_DIR names a directory holding app-debug.apk and app-debug-androidTest.apk from
# `//mila:android-debug` (CI builds them on macOS and runs this on Linux). Each run reinstalls both
# APKs with runtime permissions granted, as Gradle's connectedDebugAndroidTest does, and drives
# AndroidJUnitRunner with `am instrument`.
#
# 1. The packaged instrumentation suite always runs. MilaJourneyTest is skipped there because no
#    fixture descriptor is passed.
# 2. When MILA_JOURNEY_DESCRIPTOR names a mila-journey-fixture descriptor (v1), the fixture's
#    unprivileged ports are exposed to the emulator with `adb reverse` and MilaJourneyTest runs
#    against it with the descriptor as the base64 `milaJourneyDescriptor` instrumentation argument.
set -euo pipefail

# The opt-in local Buck2 target runs only packaged tests on the caller's explicit disposable
# emulator. Its bounded runner emits a typed report and never dumps device or terminal logs.
if [ -n "${MILA_ANDROID_DEVICE_REPORT:-}" ]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  exec python3 "$script_dir/packaged_instrumentation.py" \
    --serial "${MILA_ANDROID_SERIAL:?set mila.android_serial explicitly}" \
    --run-id "${MILA_ANDROID_TEST_RUN:?set a fresh mila.android_test_run explicitly}" \
    --apk-dir "${MILA_ANDROID_APK_DIR:?MILA_ANDROID_APK_DIR must name the APK artifact}" \
    --report "$MILA_ANDROID_DEVICE_REPORT"
fi

# A packaged-suite failure still lets the journey run, so one CI run reports both; the script
# fails at the end if either did.
# On failure, print the crash and main log buffers and any native tombstones. The approver bearer
# and the encoded descriptor are registered with ::add-mask:: before the journey starts.
dump_device_logs() {
  echo "::group::adb logcat (crash, main) after $1"
  adb logcat -d -b crash -b main -v threadtime | tail -n 1500 || true
  echo "::endgroup::"
  echo "::group::tombstones after $1"
  adb root >/dev/null 2>&1 && adb wait-for-device || true
  for tombstone in $(adb shell 'ls /data/tombstones/tombstone_* 2>/dev/null' | tr -d '\r' | grep -v '\.pb$' || true); do
    echo "== $tombstone"
    adb shell cat "$tombstone" | head -n 200 || true
  done
  echo "::endgroup::"
}

apk_dir="${MILA_ANDROID_APK_DIR:?MILA_ANDROID_APK_DIR must name the //mila:android-debug output}"
app_apk="$apk_dir/app-debug.apk"
test_apk="$apk_dir/app-debug-androidTest.apk"
test -s "$app_apk"
test -s "$test_apk"
app_package=dev.overalls.mila.nativeui
runner="$app_package.test/androidx.test.runner.AndroidJUnitRunner"

# `am instrument` exits 0 whatever the result, so the summary decides: AndroidJUnitRunner prints
# "OK (N tests)" only when every test passed, and FAILURES!!! or INSTRUMENTATION_FAILED otherwise.
# Extra arguments are `-e key value` instrumentation arguments.
instrument() {
  adb uninstall "$app_package.test" >/dev/null 2>&1 || true
  adb uninstall "$app_package" >/dev/null 2>&1 || true
  adb install -r -t -g "$app_apk" || return 1
  adb install -r -t -g "$test_apk" || return 1
  local output
  output="$(adb shell am instrument -w "$@" "$runner" | tr -d '\r')" || return 1
  printf '%s\n' "$output"
  if grep -qE 'FAILURES!!!|INSTRUMENTATION_FAILED|INSTRUMENTATION_RESULT: shortMsg=|Process crashed' <<<"$output"; then
    return 1
  fi
  grep -qE '^OK \([1-9][0-9]* tests?\)$' <<<"$output"
}

packaged=0
adb logcat -c || true
instrument || packaged=$?
if [ "$packaged" -ne 0 ]; then dump_device_logs "packaged suite"; fi

descriptor="${MILA_JOURNEY_DESCRIPTOR:-}"
if [ -z "$descriptor" ]; then
  echo "mila-journey-fixture not running; hermetic journey skipped"
  exit "$packaged"
fi
test -s "$descriptor"

# Print the ports to reverse: the deployment ports and the approver hook's port when it is
# served from the same loopback host. Validation of the remaining fields happens in the test.
mapfile -t ports < <(python3 -I - "$descriptor" <<'PY'
import json
import sys
from urllib.parse import urlsplit

with open(sys.argv[1], encoding="utf-8") as handle:
    document: object = json.load(handle)
if not isinstance(document, dict) or document.get("version") != 1:
    raise SystemExit("unsupported journey descriptor")
deployment = document.get("deployment")
approver = document.get("approver")
if not isinstance(deployment, dict) or not isinstance(approver, dict):
    raise SystemExit("descriptor lacks deployment or approver")
host = deployment.get("host")
ports: set[int] = set()
for key in ("ssh_port", "https_port"):
    value = deployment.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not 1024 <= value <= 65535:
        raise SystemExit(f"invalid deployment.{key}")
    ports.add(value)
url = approver.get("url")
if not isinstance(url, str):
    raise SystemExit("invalid approver.url")
parts = urlsplit(url)
if parts.scheme != "https" or parts.port is None:
    raise SystemExit("approver.url must be HTTPS with an explicit port")
if parts.hostname == host:
    ports.add(parts.port)
for port in sorted(ports):
    print(port)
PY
)

for port in "${ports[@]}"; do
  adb reverse "tcp:$port" "tcp:$port"
done
adb reverse --list

encoded="$(base64 -w0 "$descriptor")"
# The encoded descriptor embeds the approver bearer; mask it like the raw token.
echo "::add-mask::$encoded"
adb logcat -c || true
journey=0
instrument -e class "$app_package.MilaJourneyTest" -e milaJourneyDescriptor "$encoded" || journey=$?
if [ "$journey" -ne 0 ]; then
  dump_device_logs "journey"
  exit "$journey"
fi
exit "$packaged"
