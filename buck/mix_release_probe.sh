#!/usr/bin/env bash
# Release probe for a Buck2 mix_release, mirroring the Nix release check
# (nix/verification/tests/release/default.nix). The release is copied to its
# placeholder store path inside a sandbox's /nix/store overlay, so it runs
# unmodified, then evaluates release/probe.exs without starting services.
# Contract mix-release-probe: see buck/CONTRACTS.
#
# usage: mix_release_probe.sh BWRAP STATE RELEASE APP SELF PROBE TOOL_VERSIONS CHECK ELIXIR OTP CA
set -euo pipefail
bwrap=$1 state=$2 release=$3 app=$4 self=$5 probe=$6 tool_versions=$7 check=$8 elixir=$9 otp=${10} ca=${11}
work=$(mktemp -d "${TMPDIR:-/tmp}/overalls-release-probe.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/in/scripts" "$work/build"
cp "$probe" "$work/in/probe.exs"
cp "$tool_versions" "$work/in/.tool-versions"
cp "$check" "$work/in/scripts/check_toolchain.exs"
cat > "$work/in/run.sh" <<'RUN'
set -euo pipefail
source "$STATE"
set -euo pipefail
cp -a /release "$SELF"
export TMPDIR=/build HOME=/homeless-shelter
export OVERALLS_RELEASE_APPLICATION="$APP" OVERALLS_RELEASE_ROOT="$SELF" OVERALLS_RELEASE_ELIXIR="$ELIXIR"
export OVERALLS_RELEASE_OTP="$OTP" RELEASE_DISTRIBUTION=none RELEASE_COOKIE=isolated-nix-release-test
export ELIXIR_ERL_OPTIONS="+S 2:2" BRADY_CONFIG_FILE=/missing-isolated-brady-config PHX_SERVER=false
export PHX_HOST=control.example.test DATABASE_URL=postgresql://fixture:fixture@database.example.test/fixture
export MARSHALL_DB_CA_CERTFILE="$CA" MARSHALL_REPLICA_COUNT=3 MARSHALL_INSTANCE_ID=release-check
export MARSHALL_DB_CONNECTION_BUDGET=43
export SECRET_KEY_BASE=isolated-release-check-0000000000000000000000000000000000000000000000
export TOKEN_SIGNING_SECRET=isolated-release-signing-test-000000000000000000000000000000000000
export MARSHALL_SMTP_HOST=smtp.example.test MARSHALL_SMTP_USERNAME=fixture
export MARSHALL_SMTP_PASSWORD=isolated-test-fixture MARSHALL_SMTP_CA_CERTFILE="$CA"
export MARSHALL_MAIL_FROM=fixture@example.test RELEASE_TMP=/build/release
mkdir -p "$RELEASE_TMP"
cd /in
elixir scripts/check_toolchain.exs
OVERALLS_RELEASE_ERTS="$(erl +S 2:2 -noshell -eval 'io:format("~s", [erlang:system_info(version)]), halt().')"
export OVERALLS_RELEASE_ERTS
"$SELF/bin/$APP" eval 'Code.eval_file("/in/probe.exs")'
if [[ $APP == marshall ]]; then
  if env -u DATABASE_URL "$SELF/bin/marshall" eval ':ok' > /build/rejected.log 2>&1; then
    echo "Marshall accepted missing production database configuration" >&2
    exit 1
  fi
  grep -q 'Invalid production deployment configuration' /build/rejected.log
  if MARSHALL_DEFAULT_IMAGE_ID=invalid "$SELF/bin/marshall" eval ':ok' > /build/rejected-image.log 2>&1; then
    echo "Marshall accepted an invalid default image identity" >&2
    exit 1
  fi
  grep -q 'Invalid MARSHALL_DEFAULT_IMAGE_ID' /build/rejected-image.log
fi
RUN
env -i STATE="$state" SELF="$self" APP="$app" ELIXIR="$elixir" OTP="$otp" CA="$ca" \
  "$bwrap" --unshare-all --die-with-parent --hostname localhost \
  --tmpfs / --dev /dev --proc /proc --tmpfs /tmp \
  --ro-bind /nix /nix --overlay-src /nix/store --tmp-overlay /nix/store \
  --ro-bind "$(realpath "$release")" /release --ro-bind "$work/in" /in --bind "$work/build" /build \
  --symlink "$(dirname "$BASH")/sh" /bin/sh --chdir /build \
  "$BASH" --noprofile --norc /in/run.sh
