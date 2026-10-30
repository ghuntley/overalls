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
fixture="mila-fixture-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
python=$(command -v python3 || command -v python)
address=""
for _ in $(seq 1 360); do
  if address=$(tailscale ip -4 "$fixture" 2>/dev/null) && [ -n "$address" ]; then
    if curl -fsS --max-time 5 "http://$address:8445/descriptor.json" -o "$descriptor.tmp" 2>/dev/null; then
      break
    fi
  fi
  address=""
  sleep 5
done
if [ -z "$address" ]; then
  echo "tunnelled fixture $fixture did not publish a descriptor within 30 minutes" >&2
  exit 1
fi
umask 077
mv "$descriptor.tmp" "$descriptor"
chmod 600 "$descriptor"
token=$("$python" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["approver"]["bearer_token"])' "$descriptor")
echo "::add-mask::$token"
nohup "$python" -I .github/scripts/mila-tailnet-forward.py "$address" 8443 2222 8444 \
  > "${RUNNER_TEMP:-/tmp}/mila-tailnet-forward.log" 2>&1 &
"$python" -I -c 'import json,sys; open(sys.argv[2], "w").write(json.load(open(sys.argv[1]))["tls"]["ca_pem"])' \
  "$descriptor" "$descriptor.ca.pem"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 -o /dev/null --cacert "$descriptor.ca.pem" "https://localhost:8443/health/ready" 2>/dev/null; then
    echo "tunnelled fixture reachable on localhost"
    exit 0
  fi
  sleep 2
done
echo "tunnelled fixture did not answer on localhost:8443" >&2
exit 1
