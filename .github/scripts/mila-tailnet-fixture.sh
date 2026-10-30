#!/usr/bin/env bash
# Reach the tunnelled Mila journey fixture (ADR-0264) from a macOS or Windows
# journey job that has joined the tailnet. Waits for this run's fixture node,
# downloads its descriptor (owner-only) to $1, masks its bearer and forwards
# 127.0.0.1:8443/2222/8444 to the fixture so `localhost` names still match.
set -euo pipefail

# @cc [owner:ghuntley,label:verification;security] mila-tailnet-fixture-localhost
# The descriptor MUST keep deployment.host `localhost`: the fixture's TLS SAN,
# trust management host and Porsche certificate principal are `localhost`.
# Only loopback listeners are opened; the bearer MUST NOT be echoed unmasked.
descriptor=${1:?usage: mila-tailnet-fixture.sh DESCRIPTOR_PATH}
python=$(command -v python3 || command -v python)
address_file="${RUNNER_TEMP:-/tmp}/mila-tailnet-fixture-address"
umask 077
# Resolves the fixture via `tailscale status --json`, prints a diagnostic
# every minute and fails fast when this node is not tagged tag:mila-ci.
"$python" -I .github/scripts/mila-tailnet-join.py "$descriptor" "$address_file"
address=$(cat "$address_file")
token=$("$python" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["approver"]["bearer_token"])' "$descriptor")
echo "::add-mask::$token"
nohup "$python" -I .github/scripts/mila-tailnet-forward.py "$address" 8443 2222 8444 \
  > "${RUNNER_TEMP:-/tmp}/mila-tailnet-forward.log" 2>&1 &
"$python" -I -c 'import json,sys; open(sys.argv[2], "w").write(json.load(open(sys.argv[1]))["tls"]["ca_pem"])' \
  "$descriptor" "$descriptor.ca.pem"
error=""
for attempt in $(seq 1 60); do
  if error=$(curl -fsS --max-time 5 -o /dev/null --cacert "$descriptor.ca.pem" \
    "https://localhost:8443/health/ready" 2>&1); then
    echo "tunnelled fixture reachable on localhost"
    exit 0
  fi
  if [ $((attempt % 15)) -eq 0 ]; then
    echo "localhost:8443 not ready yet: $error" >&2
    cat "${RUNNER_TEMP:-/tmp}/mila-tailnet-forward.log" >&2 || true
  fi
  sleep 2
done
echo "tunnelled fixture did not answer on localhost:8443: $error" >&2
exit 1
