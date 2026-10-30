# Reciprocal builders and caches

Dungarees and Panterloons use [one registry](../../fleet/remote-builders.nix) through
`nixosModules.platform.remote-builders`. Import that module and set
`overalls.remoteBuilders.enable`, `localName`, and `machines` to opt in elsewhere.
The default aggregate module exposes the same options without enabling them.

Each machine declares an address, administrative SSH port, supported systems and
features, measured logical CPU count, client public keys, pinned host public key
and encrypted document path. The registry excludes the local entry from builders,
substituters, known hosts and authorized client keys. Tailnet addresses,
the administrative SSH port and measured CPU counts come from the
[fleet host roster](../../nix/policy/fleet/hosts.nix) and
[port roster](../../nix/policy/fleet/ports.nix). Both production hosts have
96 logical CPUs (authenticated `nproc --all`, 2026-10-20) and advertise that many
remote jobs; local jobs are automatic and each build can use all cores. This can oversubscribe CPU and memory; it does not alter
Lilly's guest resource budget.

Both hosts use administrative port 2222 over Tailscale. Host pins derive from
`host.json`, never unauthenticated `ssh-keyscan`. A bare hostname's saved key is
not a substitute for authenticating the intended administrative endpoint.

The restricted `nix-ssh` account accepts only Nix daemon protocol traffic.
Nevertheless, trusted Nix users have substantial store/build authority. Each
peer trusts outputs fetched over its pinned SSH endpoint without a separate
signature. Other caches still require their normal signatures; existing cache
URLs and signing keys remain configured. Only mutually trusted administrative
hosts belong in this registry.

## Credentials and rotation

The inventory-managed documents `dungarees-remote-builders` and
`panterloons-remote-builders` contain distinct client keys under
`overalls-remote-builders.production.SSH_PRIVATE_KEY`. The owning host and all
recovery-enabled users are recipients. At runtime the secret preparer publishes
`/run/overalls-secrets/remote-builders/id_ed25519` with root-only access.

1. Generate the replacement Ed25519 key in a mode-0700 temporary directory
   outside the checkout and store. Keep key and payload files mode 0600.
2. Add its public key alongside the old key in the owning host's
   `clientPublicKeys` list. Publish and verify that the peer authorizes both.
3. Wrap the new private key in the SecretSpec JSON shape above. Run
   `nix run .#secrets -- encrypt HOST-remote-builders --input /private/payload.json`.
   Run `nix run .#secrets -- check`; privately decrypt with a retained recovery
   identity and verify the derived public key matches before deleting plaintext.
4. Commit the ciphertext and publish. The updater stages and validates the
   bundle, stops identified consumers, prepares the candidate and restores Nix.
   Confirm new SSH connections work from the rotated host.
5. Remove the retired public key, publish again, and verify that a new connection
   with the old identity fails. This does not revoke already authenticated SSH
   sessions; drain/terminate those explicitly if immediate revocation is needed.

The initial JSON public-key file contains one key per host; during overlap extend
the registry's `clientPublicKeys` list explicitly, then retain only the new key.
Changing recovery recipients instead uses the existing repository-wide `secrets
rekey` workflow. Preserve host SSH identities. Recovery identities never belong
on production hosts. See [secret custody](../../secrets/README.md).

## Checks and failure handling

Run:

```sh
nix build .#checks.x86_64-linux.remote-builders-configuration \
  .#checks.x86_64-linux.remote-builders
```

The machine check uses runtime-generated synthetic keys and actual
SOPS/Nix/OpenSSH on two VMs.

On each production host inspect `/etc/nix/machines`, `nix config show`, and
`systemctl status overalls-secrets-remote-builders`. As root, run
`nix store ping --store ssh-ng://nix-ssh@overalls-builder-PEER` to verify the peer.
Do not print the runtime private key or decrypted documents.

A missing peer or failed key preparation leaves local builds enabled. SSH has
bounded connection/liveness timeouts and Nix allows substitution fallback. A
failed in-flight remote build can still fail its request; retry it locally with
`--option builders '' --option substitute false` when necessary. `max-jobs=0`
explicitly disables local fallback and is only appropriate for a diagnostic.
