# ADR-0224: Susan, the push relay at notifications.overalls.dev

- ID: ADR-0224
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Susan, Marshall, Mila
- Supersedes: none
- Superseded by: none

## Context

APNs and FCM accept pushes only with the store app publisher's credentials, so
self-hosted Marshalls cannot notify the store-distributed Mila directly. The
relay must not learn what the agent is asking or whom it is asking, and it is
operated independently of every Marshall.

## Decision

1. Susan is a new Elixir/OTP service (`susan/`) with its own Ash domain and
   PostgreSQL, deployed independently at the fixed origin
   `https://notifications.overalls.dev`, packaged as a Nix-built OCI image
   (non-root, read-only root, no shell). Hosting placement is left open.
2. `POST /api/push/v1/keys` (from Mila) issues an AEAD-sealed push key binding
   the provider token, deployment and issue time, with key-id rotation and a
   90-day expiry. `POST /api/push/v1/poke` (from Marshall) accepts at most
   1 KiB: push key, deployment, ciphertext, kind, collapse and delivery ids,
   nonce and issue time, signed by the Marshall install identity.
3. Pokes are content-free to Susan: the payload is end-to-end encrypted to the
   device's X25519 key; Susan sees only ciphertext, push key and collapse id.
   Titles come from fixed kind-to-localization keys.
4. Anti-abuse: issued keys only, deployment binding, a ±5-minute nonce window
   plus delivery-id dedupe, token buckets per key, install, source IP and
   globally, a key-id deny-list and a negative cache for unregistered tokens.
5. Privacy: no IP logging (at most a daily-salted HMAC); no tokens, keys,
   ciphertext or routes in logs or the database; no third parties beyond
   APNs/FCM. An append-only, hash-chained audit trail is kept for 90 days.
6. Secrets come from `secrets/overalls-susan.enc.json` through the existing
   SOPS `overallsSecrets` bundles.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Each operator registers their own push credentials.** Rejected: the store
  app has one bundle identity; operators cannot sign for it.
- **UnifiedPush.** Deferred: useful for Android without Google services, but
  not v1.
- **Plaintext pokes.** Rejected: the relay would learn agent activity.

## Consequences

Overalls operates one shared service whose outage only delays notifications;
Mila's `watch` stream still works while the app is open.

## Invariants and verification

- Pokes are content-free: provider payloads carry only the ciphertext, the
  collapse id and fixed localization keys (`susan-content-free-relay`).
- Retries never double-notify: a sent delivery id answers 204 without a
  second provider send; a failed one may be retried once it is reclaimed.
- 400 and 404 share one body; unauthenticated pokes write nothing.
- No source addresses, provider tokens, push keys or ciphertext in the
  database dump, the journal or audit exports.
- The audit trail is append-only in PostgreSQL and hash chained.

Machine tests `susan-service`, `susan-secrets` and `susan-image` exercise these
against the packaged release; unit, Hegel property and Covenant tests cover the
BEAM-observable pipeline.

## Implementation evidence

Implemented in this change, with these refinements of the decision text:

- Service: [`susan/`](../../../susan/README.md) with Ash domains
  [`Susan.Relay`](../../../susan/lib/susan/relay.ex) and
  [`Susan.Audit`](../../../susan/lib/susan/audit.ex); the pure poke FSM
  [`Susan.Poke.Machine`](../../../susan/lib/susan/poke/machine.ex), the HTTP
  surface [`Susan.HTTP`](../../../susan/lib/susan/http.ex), push-key envelopes
  [`Susan.PushKey`](../../../susan/lib/susan/push_key.ex) (AES-256-GCM, keyring
  ids, 90-day expiry) and providers under
  [`susan/lib/susan/provider/`](../../../susan/lib/susan/provider.ex).
- The body and signature follow the shared
  [`OverallsProtocol.SusanPoke`](../../../protocol/lib/overalls_protocol/susan_poke.ex):
  a canonical eight-member JSON body, and an Ed25519 install signature over
  `"overalls-susan-poke-v1" || 0x00 || body` verified on the received bytes,
  carried in the
  `overalls-install-key` and `overalls-install-signature` headers (base64url,
  no padding); the wire example is
  [`protocol/test/fixtures/susan_poke_request.json`](../../../protocol/test/fixtures/susan_poke_request.json).
- Key issuance accepts `environment` `production` or `development` (the APNs
  sandbox gateway); FCM accepts only `production`. `expires_at` is ISO-8601 UTC
  ending in `Z`.
- Response codes: 204 delivered or duplicate; 400 malformed, replayed, stale or
  provider-rejected; 404 unknown/expired/denied/mismatched key, bad signature
  or blocked install (same body as 400); 410 unregistered token; 429 with
  `Retry-After` for rate limits and in-flight duplicates; 503 with
  `Retry-After` when the provider is unavailable after one in-request retry.
- Audit: append-only trigger and REVOKE in
  [`priv/repo/migrations`](../../../susan/priv/repo/migrations/20261018231800_audit_append_only.exs),
  operator access in [`Susan.Operator`](../../../susan/lib/susan/operator.ex)
  through `bin/susan rpc` only, audited 90-day prune in
  [`Susan.Maintenance.Prune`](../../../susan/lib/susan/maintenance/prune.ex).
- Deployment: NixOS module
  [`nix/domains/system/susan.nix`](../../../nix/domains/system/susan.nix) with
  the `overallsSecrets` bundle `susan`, and the OCI image
  [`nix/domains/artifacts/susan-image.nix`](../../../nix/domains/artifacts/susan-image.nix)
  (`packages.x86_64-linux.image-susan`).
- Tests: [`susan/test/`](../../../susan/test/test_helper.exs), Covenant
  obligations under [`susan/contracts/`](../../../susan/contracts/README.md), and
  machine tests [`susan-service`](../../../nix/verification/tests/machines/susan-service/driver.py),
  [`susan-secrets`](../../../nix/verification/tests/machines/susan-secrets/driver.py)
  and [`susan-image`](../../../nix/verification/tests/machines/susan-image/driver.py).
- Secrets: [`secrets/overalls-susan.enc.json`](../../../secrets/overalls-susan.enc.json)
  exists with all six keys holding **placeholder** values (throwaway keys of
  the right shape, a `placeholder` service account and the local socket
  database URL), registered recovery-only in
  [`secret-documents.nix`](../../../nix/policy/secrets/secret-documents.nix)
  and passing `nix run .#secrets -- check`. No host enables Susan, so no
  `services.susan.secretsFile` points at it yet; see
  [secret custody](../../../secrets/README.md#susan-push-relay).

Remaining for `implemented`: real APNs/FCM credentials and acceptance (the
machine tests use local fake origins behind a private CA, and the committed
document holds placeholders only), a host recipient for that document, and
hosting and TLS placement. Marshall's
[poke client](../../../marshall/lib/marshall/notifications/susan.ex) is now
present under ADR-0225; historical fake-relay execution does not establish
real provider acceptance or the latest integrated relay verifier.

## Open questions

- Registry, host and TLS placement for the image. Host and TLS placement are
  resolved by [ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md):
  the enrolled `hcloud` host salopettes with ACME TLS; no registry is used.
- Android delivery without Google services.

## Related decisions

[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0225](0225-marshall-notifications-domain.md),
[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) (placement),
[ADR-0236](0236-susan-wns-provider.md) (amends egress and third parties for WNS),
[ADR-0278](0278-mila-push-notification-parity-scope.md) (provider tests are the parity gate's delivery evidence).
