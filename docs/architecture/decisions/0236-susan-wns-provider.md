# ADR-0236: Susan WNS provider and channel-host egress

- ID: ADR-0236
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: Susan, Mila, Susan NixOS module
- Supersedes: none
- Superseded by: none

## Context

[ADR-0224](0224-susan-push-relay.md) limits Susan's egress to compiled provider
origins (APNs and Google), and its privacy rule names no third parties beyond
APNs and FCM. Mila on Windows ([ADR-0235](0235-mila-desktop-clients.md)) needs
push through the Windows Push Notification Services.

WNS differs from APNs and FCM in two ways:

- **Per-device hosts.** The device's token *is* the URL to post to: a channel
  URI whose host varies by region and device (for example
  `https://wns2-par02p.notify.windows.com/w/?token=…`), so a fixed origin list
  cannot cover it.
- **Different credentials.** Access tokens come from Microsoft Entra ID
  through the OAuth 2.0 client-credentials flow, with scope
  `https://wns.windows.com/.default`.

## Decision

Authorization: the approved Mila desktop plan (2026-10-20), with the user's
choice of macOS APNs plus Windows WNS.

1. Susan gains provider `wns` with sealed provider code 3. The push-key
   request, AEAD envelope, deny-list and negative cache are unchanged. WNS keys
   are production-only.
2. **Channel shape.** A WNS token is admitted only as an `https` URI on port
   443 to a lower-case DNS host under `.notify.windows.com`. It must have a path
   and no userinfo or fragment, and be at most 1024 bytes
   (`susan-wns-channel-shape`).
   - The shape is checked when the key is issued and again before every send.
   - The URI is sealed inside the push key and is never supplied at poke time,
     so a poke cannot redirect Susan.
   - Mila applies the same check before it sends a token.
3. **Egress.** Egress adds the compiled origin `https://login.microsoftonline.com`
   (tenant path from configuration) and channel hosts in the shape above. No
   configurable origin is added.
4. **Delivery.**
   - A raw notification (`X-WNS-Type: wns/raw`) carries only `overalls_v`,
     `overalls_k` and `overalls_c`; the Windows app shows its own fixed text.
   - WNS 404 or 410 marks the token unregistered.
   - 401 drops the cached Entra token and retries.
   - 406, 429 and 5xx are retried.
   - 400 and 413 are rejected.
5. **Configuration.** `wns_app_ids` and the secrets `WNS_TENANT_ID`,
   `WNS_CLIENT_ID` (both UUIDs) and `WNS_CLIENT_SECRET` (bounded printable
   ASCII) are required only when WNS is configured. The NixOS option
   `services.susan.wnsAppIds` delivers them; while it is empty, no WNS secret is
   expected.
6. **Amendment.** This amends ADR-0224's egress and third-party rules to include
   Microsoft for WNS only. All other ADR-0224 decisions stand.

## Alternatives

- **A configurable list of WNS hosts.** Rejected: ADR-0224 forbids configurable
  egress, and WNS does not publish a stable host list.
- **Proxying WNS through Marshall.** Rejected: it would give each deployment the
  device's channel URI and Entra credentials.
- **Toast (visible) notifications from Susan.** Rejected: Susan would choose
  display text, and the app could not refuse a poke that fails to decrypt.

## Consequences

- Windows devices get pokes through the same push-key model. Microsoft learns
  that some Overalls deployment notified a Windows device, as Apple and Google
  do for theirs.
- Susan's egress is no longer a finite list of origins. It is bounded by a DNS
  suffix that Microsoft controls.
- Deployed Susan needs an Entra application registered against the MSIX
  package identity before `wnsAppIds` can be set.

## Invariants and verification

- Every accepted channel posts to a `notify.windows.com` host on port 443 (Hegel
  property in Elixir, mirrored in Dart).
- Near-miss hosts, ports, schemes, userinfo, fragments and over-long URIs are
  refused with the fixed 400 and write nothing (unit and Covenant
  `susan.push_keys.I5`; the `susan-service` machine test).
- A sealed key with a non-WNS channel is rejected before any provider request
  (Covenant `susan.push_keys.I5`).
- The poke body contains only version, kind and ciphertext (unit test and the
  `susan-service` machine test against a fake WNS origin behind its private CA).

## Implementation evidence

- [`provider.ex`](../../../susan/lib/susan/provider.ex) (`wns_channel?/1`,
  `microsoft_token_url/1`, `allowed_url?/1`),
  [`wns.ex`](../../../susan/lib/susan/provider/wns.ex),
  [`tokens.ex`](../../../susan/lib/susan/provider/tokens.ex),
  [`push_key.ex`](../../../susan/lib/susan/push_key.ex),
  [`keys.ex`](../../../susan/lib/susan/keys.ex) and
  [`config.ex`](../../../susan/lib/susan/config.ex).
- Tests: [`wns_channel_property_test.exs`](../../../susan/test/susan/wns_channel_property_test.exs),
  [`poke_test.exs`](../../../susan/test/susan/poke_test.exs),
  [`keys_test.exs`](../../../susan/test/susan/keys_test.exs) and
  [`push_keys_contract_test.exs`](../../../susan/test/contract/susan/push_keys_contract_test.exs).
- NixOS: [`susan.nix`](../../../nix/domains/system/susan.nix) (`wnsAppIds`), the
  [`susan-service`](../../../nix/verification/tests/machines/susan-service/driver.py)
  WNS subtests and the [`susan-secrets`](../../../nix/verification/tests/machines/susan-secrets/driver.py)
  custody list.
- Mila: [`susan.dart`](../../../mila/packages/mila_transport/lib/src/susan.dart)
  (`wnsChannel`) and [`wns_channel_test.dart`](../../../mila/packages/mila_transport/test/wns_channel_test.dart).

Remaining gaps:

- The machine tests have not been run in this change, because there was no
  x86_64-linux builder.
- Susan's config-loading tests are Linux-only, because they read `/proc/self`.
- No real Entra application exists, and the deployed salopettes does not set
  `wnsAppIds`.

## Open questions

- The Entra application and its MSIX package identity binding.

## Related decisions

Amends [ADR-0224](0224-susan-push-relay.md) (egress and third parties).
Serves [ADR-0235](0235-mila-desktop-clients.md). Placement:
[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md). WNS delivery evidence for the
Mila parity gate: [ADR-0278](0278-mila-push-notification-parity-scope.md).
