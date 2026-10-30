# Deployment secrets

## SSH host CA

[`ssh-host-ca.pub`](ssh-host-ca.pub) is the dedicated Ed25519 SSH host authority.
It is independent of the fleet hosts and the TLS CAs. The private key is stored
in [`ssh-host-ca-recovery.enc.json`](ssh-host-ca-recovery.enc.json) for recovery
and [`panterloons-ssh-host-ca.enc.json`](panterloons-ssh-host-ca.enc.json) for Marshall.
Both contain `overalls-ssh-host-ca.production.SSH_HOST_CA_KEY`; the runtime bundle
adds the authenticated Panterloons recipient to the recovery recipient. Dungarees,
gateways and guests receive no CA private material. Physical host SSH keys remain
SOPS decryption identities only.

The operational retirement is 2046-09-25 (20 years). OpenSSH CA public keys have
no embedded expiry; Marshall and the client enforce the published retirement.
Host certificates expire after 3650 days or at retirement, whichever is earlier.
The existing secret inventory commands check, decrypt and rekey these documents.
Keep decrypted data in private runtime storage outside the checkout and Nix store;
rotation must update both encrypted copies, the public key and client trust.
It must also reissue cached server certificates; a gateway restart retains its
still-valid certificate. See the [rotation boundary](../docs/operations/porsche-operations.md#installer-host-trust).
The committed `nix/verification/tests/fixtures/ssh-host-ca` authority is disposable test data
and must never be selected by production configuration.

## Brady fleet CA

`brady-root.pem` is the public P-256 trust anchor installed in fleet hosts and
NixOS/Ubuntu guest images. Its SHA-256 fingerprint is
`E9:B9:55:0E:39:AC:07:B9:3D:3C:34:08:27:64:D1:B6:03:AA:6D:5E:F4:26:C2:6F:24:2F:C4:A9:A5:A7:F5:7A`;
it expires 2046-10-11 (regenerated 2026-10-16 with the product rename). `brady-ca-recovery.enc.json` is recovery-only and holds
the root key and certificate. `panterloons-brady.enc.json` and
`dungarees-brady.enc.json` hold distinct root-signed P-256 signer certificates
and keys expiring in 2036. The host bundles publish only the local signer to
Brady. Brady sends its signer with each leaf, so a guest trusting the root can
move between hosts without receiving a new image. Keep all decrypted signing
material outside the repository and Nix store. Rotate each host signer through
the inventory `encrypt --replace` flow and verify the chain against the retained
public root before activation.

Only SOPS ciphertext and public documentation belong here. Keep private SSH keys,
converted age identities and decrypted files outside the checkout and Nix store.

## Internal service CA

[`fleet/roles/control-plane/service-ca.crt`](../fleet/roles/control-plane/service-ca.crt)
holds one P-256 CA, "ghuntley.dev internal service CA" (regenerated with the
product rename on 2026-10-16). It signs
Marshall's backend certificate (`panterloons-backend-tls.enc.json`, SAN
`ghuntley.dev`) and the local PostgreSQL certificate (`panterloons-database.enc.json`
`DB_CERT`/`DB_KEY`, SANs `localhost`, `127.0.0.1`, `::1`); both leaves expire
in 2031. The CA key and certificate are recovery-only in
`service-ca-recovery.enc.json` under
`overalls-service-ca.production.{SERVICE_CA_KEY,SERVICE_CA_CERTIFICATE}`. The
earlier "overalls internal service CA" and the interim 2026-10-16 CA are
retired. To rotate, decrypt the recovery document with a recovery identity,
issue new leaves, replace the host documents with `encrypt --replace` while
preserving other fields (such as `DB_PASSWORD`), and update the bundle in the
same change. Without a recovery identity, generate a fresh CA and replace all
three documents together.

## Buck2 remote cache identities

[`fleet/buck-re`](../fleet/buck-re) holds the public certificates of the
NativeLink cache ([ADR-0272](../docs/architecture/decisions/0272-nativelink-remote-cache-and-execution.md)).
`ca.crt` issues the Panterloons server certificate and the read-only host
client certificates. `uploader-ca.crt` issues only the CI uploader
certificate. Both CAs were issued on 2026-10-30, expire in 2036, and had their
private keys discarded after issuance. Leaves expire in 2028.
`panterloons-buck-re.enc.json` holds `SERVER_KEY` and `CLIENT_IDENTITY`, and
`dungarees-buck-re.enc.json` holds `CLIENT_IDENTITY`, under
`overalls-buck-re.production`. A client identity is the PEM certificate
followed by its key. `buck-re-uploader-recovery.enc.json` is recovery-only. It
holds `overalls-buck-re-uploader.production.UPLOADER_IDENTITY` for loading into
CI, and is never delivered to a host. To rotate, or to add a host, issue new
CAs and every leaf in private storage, replace all three documents with
`encrypt --replace`, and commit the certificates in the same change.

## Tailscale auto-join key

[`fleet-tailscale.enc.json`](fleet-tailscale.enc.json) holds the shared
Tailscale authentication key as `overalls-tailscale.production.TAILSCALE_AUTH_KEY`
(ADR-0241). Enrolled hosts that name the `fleet-tailscale` credential decrypt it
to `/run/overalls-secrets/tailscale/auth-key` and join automatically while their
daemon needs a login. Rotate it with `encrypt fleet-tailscale --replace` after
revoking the old key in the Tailscale console. The document is still sealed to
the retired Overalls host's recipient; `secrets check` reports that drift until
an operator with a recovery identity runs `secrets rekey`.

## Git deploy key

[`git-bootstrap.enc.json`](git-bootstrap.enc.json) is the recovery copy of the
read-only deploy key for the former source repository, GitHub deploy key ID `163570048`.
Its authorization for the new `antithesishq/overalls` repository has not been verified;
check repository access before enrollment or activation. Its SSH fingerprint is
`SHA256:51Pby3vkKXtk2Otxj9eYIZlO3t+WUn6Ib2p3rKg14oY`.
The SecretSpec payload is `overalls-git.production.GIT_DEPLOY_KEY`.

The current recipient is ghuntley's recovery key from
[`nix/policy/identity/users.nix`](../nix/policy/identity/users.nix), converted to
`age1905rqwspmj7v2gw8yvtl0esw7u44yev5v0hcxt3jlyjx463ztv2q3vqdl4`.
Repository access alone does not permit decryption. This bootstrap document
remains recovery-only. Each host's `HOST-git.enc.json` separately delivers the shared
key to that authenticated host and the ghuntley recovery recipient.

## Marshall application keys

`panterloons-github-oauth.enc.json` contains a SOPS-encrypted
nonfunctional GitHub OAuth client-secret placeholder for the Overalls fleet.
The fleet wires it through the `github-oauth` secret bundle and
uses a placeholder client ID; replace both the client ID and secret before
enabling GitHub OAuth in production.

[`marshall-bootstrap.enc.json`](marshall-bootstrap.enc.json) contains the shared
`SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and `MARSHALL_CLOAK_KEYS` values under
`overalls-marshall.production`. The two signing secrets each contain 64 random
bytes encoded as base64. The Cloak value is an ordered JSON keyring string with
one tagged, base64-encoded 32-byte AES key (`marshall-20260917-v1`).

`marshall-bootstrap` is registered as a recovery-only document, so the same
inventory check, decrypt and rekey commands manage it. Decrypt it with:

```sh
nix run .#secrets -- decrypt marshall-bootstrap \
  --ssh-key /private/recovery_id_ed25519 --output /private/marshall.json
```

All Marshall instances must use these same application keys. When provisioning,
combine the recovered values with the deployment's database and mail settings
in private storage, then encrypt for the authenticated host recipients through
the inventory tool. These three values alone are not a complete runtime bundle.
Keep the Cloak key ID and bytes stable while any stored ciphertext uses them;
re-encrypting SOPS documents changes recipients, not application key values.

`panterloons-marshall.enc.json` also contains the production `SERPER_API_KEY`.
The host bundle publishes it as raw `serper.key`, and systemd gives each
Marshall instance a private credential copy. Rotate this field through private
decrypt/edit/encrypt custody while preserving the other Marshall secrets.

## Crash-dump recovery key

[`crash-dump-public.pem`](crash-dump-public.pem) is the 4096-bit RSA public key
for encrypted OTP crash dumps. Hosts may install this public file and point
`services.marshall.crashDumps.publicKeyFile` and/or
`services.lilly.crashDumps.publicKeyFile` at it when enabling crash dumps.

The matching private PEM is stored only as SOPS ciphertext in
[`crash-dump-bootstrap.enc.json`](crash-dump-bootstrap.enc.json), under
`overalls-crash-dump-recovery.production.CRASH_DUMP_PRIVATE_KEY`. Its inventory
entry is recovery-only and participates in the same checks and rekeying:

```sh
nix run .#secrets -- decrypt crash-dump-bootstrap \
  --ssh-key /private/recovery_id_ed25519 --output /private/crash-dump-recovery.json
```

Extract the PEM from the recovered JSON into a mode-0600 file outside Git, then
use OTP's `crashdump:pem_decrypt(EncryptedPath, PrivateKeyPath, OutputPath)` in the
operator's environment. Never deliver this private key in a host secret bundle.
Retain it while any dump encrypted to its public key must remain recoverable.
See the [crash-dump guide](../docs/operations/observability.md#encrypted-erlang-crash-dumps).

## Recovery and host enrollment

`git-bootstrap` is registered in [`nix/policy/secrets/secret-documents.nix`](../nix/policy/secrets/secret-documents.nix) with
`hosts = []; recoveryOnly = true;`. The standard inventory commands include it:

```sh
nix run .#secrets -- check
nix run .#secrets -- decrypt git-bootstrap \
  --ssh-key /private/recovery_id_ed25519 --output /private/git.json
```

Supply the operator's matching recovery SSH identity. Private inputs and outputs
must remain outside the checkout and Nix store; decryption refuses an existing
output and creates the recovered JSON with mode `0600`. Never copy the recovery
identity to a machine or print the recovered JSON, which contains the deploy key.

Before provisioning a host, register its authenticated public SSH host key and a
host document in the inventory, using a distinct path such as
`secrets/HOST-git.enc.json`. Encrypt the recovered JSON for that document:

```sh
nix run .#secrets -- encrypt HOST-git --input /private/git.json
nix run .#secrets -- check
```

For an existing document, authorize an atomic payload replacement explicitly:

```sh
nix run .#secrets -- encrypt HOST-git --input /private/git.json --replace
```

The command verifies recipients and replaces the ciphertext only if the document
has not changed since it was read. The default create path still refuses an
existing output.

Replace `HOST` with the actual host name. The host document includes its selected
hosts and all recovery-enabled users. Keep the bootstrap document recovery-only.
Publish the host declaration and ciphertext together before activating its Git
bundle. Remove the recovered JSON after use. The Git bundle must select
`GIT_DEPLOY_KEY` from project `overalls-git`, profile `production`, as a raw file.

## Rekeying

After changing recovery membership or authenticated host recipients, reconcile
**all** inventoried documents, including `git-bootstrap`, `marshall-bootstrap`
and `crash-dump-bootstrap`:

```sh
nix run .#secrets -- rekey --ssh-key /private/retained_recovery_id_ed25519
nix run .#secrets -- check
```

The supplied operator must remain a recovery recipient and decrypt every changed
document. Rekeying stages changes, rotates data keys and verifies payload and
recipient equality before publication. Unchanged documents are left untouched.
Commit the resulting ciphertext changes with the public policy update. See the
[fleet recovery guide](../docs/operations/fleet-users.md#local-commands). Changing SOPS
recipients does not rotate the GitHub deploy key or revoke historical plaintext.

Rotating a stored *value* is a payload replacement through `encrypt --replace`:
the new payload is sealed to the current recipient set. When the value unlocks
an external credential store — notably the Restic repository password in a
`HOST-backup` document — follow the matching ceremony in the
[backup guide](../docs/operations/backups.md#repository-password-rotation) so the external
store learns the new value first. Deploying the replaced document alone wedges
every scheduled backup with the documented `repository` failure label until the
repository key adopts the published value through the documented recovery.

Plan recovery-user removals around retained ciphertext. Restic points captured
before a turnover keep the historical recipient envelope for their whole
twelve-point retention window, and Git history keeps it indefinitely: restoring
from such a point requires the retired identity to decrypt its embedded
documents. Neither `check` nor Restic retention warns about stranded historical
generations; keep the retiring identity's private key available until every
pre-turnover point has aged out.

GitHub read access and the bootstrap ciphertext's recipient metadata were
verified. Recovery-only encryption, decryption and rekeying are tested with
synthetic identities; production Git bootstrap decryption and overalls consumption now passed
(see the [deployment review](../docs/architecture/reviews/2026-09-17-overalls-provisioning.md)). [ADR-0044](../docs/architecture/decisions/0044-recovery-only-secret-documents.md)
records the explicit recovery-only document policy.

The Marshall key formats were validated against the actual Vault parser, and
the crash-dump RSA keypair passed a private-key check and RSA-OAEP roundtrip
before temporary plaintext was removed. The inventory check validates all three
documents' recipient metadata. Production SOPS recovery and an actual OTP dump
roundtrip with this new RSA key have not been performed.

## Private inference services

`private-ca-recovery.enc.json` is recovery-only and contains the private-service
root and intermediate signing material. `private-services-root.pem` is its public
guest trust anchor. The current root (regenerated 2026-10-16) expires 2046-10-11; its SHA-256 fingerprint is
`E0:F1:76:66:70:76:E5:76:C5:27:39:55:28:35:DD:F6:14:8B:DC:DD:DD:0D:D3:CC:7F:9C:0D:FB:F3:A1:8C:E5`.

`panterloons-audi-private.enc.json` and `dungarees-audi-private.enc.json` contain the
offline-issued fleet wildcard certificate chain and key.

`panterloons-audi.enc.json`, `dungarees-audi.enc.json`, `panterloons-audi-dns.enc.json`
and `dungarees-audi-dns.enc.json` contain **nonfunctional placeholder gateway
and DNS service tokens** under `overalls-audi.production.AUDI_GATEWAY_TOKEN` and
`overalls-audi-dns.production.AUDI_DNS_TOKEN`. Before activating the Audi public
plane, issue real credentials on Panterloons with the
`audi-gateway-rotate` / `audi-dns-rotate` operator CLI actions into private
storage, then replace these documents through private decrypt/encrypt custody
following the [rollout runbook](../docs/operations/fleet-network.md#audi-public-plane-rollout).
Audi services fail closed and never report readiness while a placeholder is
installed.

`panterloons-ziggy.enc.json` contains a real, verified Ziggy control credential and
**nonfunctional placeholder OpenAI and Anthropic API keys**, as requested.
Replace those two fields through private decrypt/edit/encrypt custody before
expecting provider readiness. Preserve the existing internal credentials.

Only each selected host and configured recovery users receive its host document.
The root and intermediate recovery document has no host recipient. Recovery and
both host documents were decrypted with the recovery identity after rotation;
recipient policy, certificate chain, shared leaf key and preserved Audi credentials
were verified. Activation with the existing provider placeholders is explicitly
authorized. Provider readiness remains false until real keys replace them.

## Susan push relay

`overalls-susan.enc.json` contains **placeholder values only**, under
`overalls-susan.production`. They must be rotated before any real deployment:
no APNs or FCM provider will accept them. The document has no WNS entries:
`services.susan.wnsAppIds` is empty on salopettes, so none are expected. Each value still passes Susan's own
startup validation, so a test deployment could boot with them:

- `APNS_KEY_P8` and the FCM `private_key` are throwaway P-256 and RSA-2048
  PKCS#8 keys, generated for this document and never stored elsewhere.
- `APNS_KEY_ID` is `PLACEHOLD1` and `APNS_TEAM_ID` is `PLACEHOLD2`.
- The service account names `project_id` `placeholder` and
  `client_email` `placeholder@placeholder.invalid`.
- The keyring holds one random id-1 key.
- `DATABASE_URL` is the local peer-authenticated socket database that
  `services.susan.database.createLocally` creates.

The plaintext marker `PLACEHOLDER_unencrypted` (excluded from encryption by
SOPS' `_unencrypted` suffix, ignored by SecretSpec) shows this status without
decryption. Remove it when the real values are installed.

Susan runs on the Hetzner Cloud host salopettes (ADR-0231). Its
[`host.json`](../fleet/hosts/salopettes/host.json) claims the document, so the
recovery-only entry in
[`secret-documents.nix`](../nix/policy/secrets/secret-documents.nix) steps aside
and the document is encrypted to the recovery recipients plus salopettes, whose
[configuration](../fleet/hosts/salopettes/configuration.nix) points
`services.susan.secretsFile` at it. To move Susan to another host:

1. Add `{ "name": "overalls-susan", "path": "secrets/overalls-susan.enc.json" }`
   to the chosen host's `host.json` `credentials`. The recovery-only entry steps
   aside automatically.
2. Run `nix run .#secrets -- rekey --ssh-key /private/recovery_id_ed25519` to
   add the host recipient, then `nix run .#secrets -- check`.
3. Replace the placeholders through private decrypt/edit/encrypt custody,
   using `encrypt overalls-susan --input /private/susan.json --replace`. Keep
   the plaintext outside the checkout.
4. Set `services.susan.secretsFile` to the document in the host configuration.

The `services.overallsSecrets.bundles.susan` bundle publishes each value as a
raw file, and systemd passes them to Susan as `LoadCredential=` files.

| Key | Content | Checked at startup | Committed value |
| --- | --- | --- | --- |
| `APNS_KEY_P8` | APNs token-signing key (`.p8`, PKCS#8 EC P-256 PEM) | required when `apnsTopics` is set | placeholder: throwaway key |
| `APNS_KEY_ID` | 10-character key id of that `.p8` key | `[A-Z0-9]{10}` | placeholder: `PLACEHOLD1` |
| `APNS_TEAM_ID` | 10-character Apple developer team id | `[A-Z0-9]{10}` | placeholder: `PLACEHOLD2` |
| `FCM_SERVICE_ACCOUNT_JSON` | Google service-account JSON for FCM v1 | required when `fcmAppIds` is set; `token_uri` must be `https://oauth2.googleapis.com/token`; RSA ≥ 2048 | placeholder: project `placeholder`, throwaway RSA key |
| `WNS_TENANT_ID` | Entra ID tenant of the WNS application | required when `wnsAppIds` is set; UUID; names the fixed `login.microsoftonline.com` token path | absent |
| `WNS_CLIENT_ID` | Entra ID application (client) id | required when `wnsAppIds` is set; UUID | absent |
| `WNS_CLIENT_SECRET` | Entra ID client secret for the client-credentials flow | required when `wnsAppIds` is set; 16–256 printable ASCII | absent |
| `SUSAN_PUSH_KEY_SIGNING_KEY` | Push-key keyring JSON `{"active":N,"keys":{"N":"<base64url 32 bytes>"}}` | 1–16 distinct keys, ids 1–255, active id present | placeholder: one random id-1 key |
| `DATABASE_URL` | `postgres://`/`ecto://` URL of Susan's own database | database name `[a-z_][a-z0-9_]*` | local socket database `susan` |

Rotation:

- **Push-key keyring.** Add a new id with fresh random bytes, make it `active`,
  keep the previous ids for at least 90 days (the push-key lifetime), then
  republish and restart Susan. The boot appends a `key_rotated` audit entry.
  Removing an old id invalidates every push key sealed under it: Mila devices
  re-register on their next launch. Rotation also resets the token-digest
  negative cache, because the digest key is derived from the active key.
- **APNs `.p8` / FCM service account.** Replace the values and restart; cached
  provider tokens are dropped on restart. Revoke the old key in the Apple or
  Google console after the restart.
- **WNS client secret.** Add a new secret to the Entra application, replace
  `WNS_CLIENT_SECRET` and restart (the cached access token is dropped), then
  delete the old secret in Entra.
- **Database URL.** Rotate the role password in PostgreSQL first, then the
  document.
- **Placeholders.** Replace every field in one `encrypt --replace` and remove
  `PLACEHOLDER_unencrypted`. Do not carry the placeholder keyring bytes into
  the real keyring.

All values are runtime-only: never put them in Nix expressions, the OCI image or
logs. The container form mounts the same file names at `/run/secrets/susan`
(owned by uid 65532, mode 0400).

## Fleet addresses

`fleet-addresses.enc.json` holds every fleet public address under
`overalls-fleet-addresses.production`
([ADR-0233](../docs/architecture/decisions/0233-fleet-addresses-from-sops.md)):

| Secret | Use |
| --- | --- |
| `PANTERLOONS_PRIMARY_IPV4`, `DUNGAREES_PRIMARY_IPV4` | control, administration, WireGuard endpoints and reviewed-source grants |
| `PANTERLOONS_SERVICE_IPV4`, `DUNGAREES_SERVICE_IPV4` | Audi and Audi DNS listeners |
| `PANTERLOONS_PREFIX`, `PANTERLOONS_GATEWAY_IPV4`, `DUNGAREES_PREFIX`, `DUNGAREES_GATEWAY_IPV4` | each dedicated host's own uplink prefix and gateway |
| `SALOPETTES_IPV4` | the Susan listener and the Salopettes WireGuard endpoint |
| `GEOFFREY_HUNTLEY_IPV4`, `GEOFFREY_HUNTLEY_SECONDARY_IPV4`, `GEOFFREY_HUNTLEY_TERTIARY_IPV4` | the operator's reviewed source grants to every fleet host (ADR-0247) |

The document still holds four unused `OVERALLS_*` names from the retired
Overalls host (`OVERALLS_PRIMARY_IPV4`, `OVERALLS_SERVICE_IPV4`,
`OVERALLS_PREFIX`, `OVERALLS_GATEWAY_IPV4`). No configuration selects them;
an operator with a recovery identity should delete them with the rotation flow
below.

Its recipients are the recovery users, Panterloons, Dungarees and Salopettes; each
host selects only the names its configuration uses. The repository holds no
address literal. `overalls.fleetAddresses` validates every value at runtime
before any listener, firewall rule, WireGuard endpoint or uplink uses it, and a
malformed value keeps them closed. A dedicated host's uplink falls back to its
root-only recovery copy (`/var/lib/overalls-host/uplink.conf`), so a decryption
failure never strands it.

To rotate, decrypt to a private 0600 file outside the checkout, edit it and run
`nix run .#secrets -- encrypt fleet-addresses --input FILE --replace`, then
`nix run .#secrets -- check`. Update DNS for any published name in the same
change window. Rotating a Lilly-protected address changes Lilly's network claim
and needs the deliberate rebind flow, not an ordinary update.
