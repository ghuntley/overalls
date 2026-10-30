#!/usr/bin/env bash
# Contract ci-buck-re-optional: see .github/CONTRACTS.
# Writes the untracked .buckconfig.local that sends CI's Buck2 actions to the
# NativeLink workers and uploads local results, with the uploader identity
# from BUCK_RE_UPLOADER_IDENTITY (ADR-0272). Without the identity, or when
# the upload listener does not answer, it writes nothing and Buck2 stays local.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# The service's address and port come from the fleet roster.
endpoint=$(nix eval --raw --impure --expr "
  let flake = builtins.getFlake (toString $root);
      roster = import $root/nix/policy/fleet/hosts.nix { inherit (flake.inputs.nixpkgs) lib; };
      ports = import $root/nix/policy/fleet/ports.nix {};
      server = (roster.deploymentOf \"panterloons\").buildCache.server;
  in \"\${roster.hosts.\${server}.tailnetAddress} \${toString ports.buckCacheUpload}\"" 2>/dev/null || true)
read -r address port <<<"$endpoint" || true
if [[ -z "${BUCK_RE_UPLOADER_IDENTITY:-}" || ! "${address:-}" =~ ^[0-9.]+$ || ! "${port:-}" =~ ^[0-9]+$ ]]; then
  echo "buck-re: no identity or service address; Buck2 stays local"
  exit 0
fi
if ! timeout 15 bash -c "</dev/tcp/$address/$port" 2>/dev/null; then
  echo "buck-re: $address:$port does not answer; Buck2 stays local"
  exit 0
fi
identity="${RUNNER_TEMP:?}/buck-re-client.pem"
(umask 077 && printf '%s\n' "$BUCK_RE_UPLOADER_IDENTITY" > "$identity")
cat > "$root/.buckconfig.local" <<CONFIG
[buck2_re_client]
  address = grpc://$address:$port
  tls = true
  instance_name = main
  tls_ca_certs = $root/fleet/buck-re/ca.crt
  tls_client_cert = $identity
[buck2]
  default_allow_cache_upload = true
[overalls]
  remote_execution = true
CONFIG
echo "buck-re: remote cache and execution at $address:$port"
