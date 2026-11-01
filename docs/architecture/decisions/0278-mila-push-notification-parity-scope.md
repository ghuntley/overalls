# ADR-0278: Mila push-notification parity scope

- ID: ADR-0278
- Date: 2026-11-01
- Status: accepted
- Implementation: partial
- Components: Mila, Susan, verification
- Supersedes: none
- Superseded by: none

## Context

The native parity matrix (`mila/native/PARITY_MATRIX.md`) gates Mila's native
builds: the `Native parity` job in `.github/workflows/mila-builds.yml` fails
while any row contains `partial` or `open`. Rows close with journey evidence
against the hermetic fixture of [ADR-0264](0264-hermetic-mila-journey-fixture.md).

The "Push notifications/devices" row mixed two different things:

- **Client behaviour.** Asking the OS for notification permission (or, on
  Linux, local desktop enablement), registering the device with Marshall
  ([ADR-0225](0225-marshall-notifications-domain.md)) after Susan issues a
  push key, and listing, enabling, disabling and removing devices.
- **Provider delivery.** Susan ([ADR-0224](0224-susan-push-relay.md),
  [ADR-0236](0236-susan-wns-provider.md)) sending a content-free poke through
  APNs, FCM or WNS to a real device.

Observed facts:

- The fixture has no Susan and no provider credentials. ADR-0264 records that
  it does not prove push delivery. Its journeys stand in for Susan's
  key-issuance reply so the Rust core's reply validation and push-key path
  still run.
- Live delivery needs a real provider token from a signed app on a real
  device or emulator image, and the store publisher's APNs key, Firebase
  service account or Entra ID app registration. None of these can be held by
  a hermetic fixture.
- Susan's provider modules (`susan/lib/susan/provider/{apns,fcm,wns}.ex`)
  send through an injectable transport (`Susan.Provider.HTTP`); its tests use
  `Susan.FakeProvider`, which records every request and scripts responses.
- Susan has no Linux provider and the device-platform enum has no `linux`
  value (ADR-0235): Linux shows local desktop notifications only.

## Decision

The user decided this on 2026-11-01, choosing the ADR-recorded scope option of
the Mila parity triage (`ts.md` §4, "Things the fixture cannot prove").

1. For the push row, client parity means, per platform:
   - OS notification permission or enablement, gated before registration,
     proven by that platform's tests; and
   - device register, list, preferences (disable and enable) and remove,
     proven by that platform's journey against the ADR-0264 fixture through
     the Rust core.
2. Delivery through APNs, FCM and WNS is proven by Susan's own provider tests
   against `Susan.FakeProvider`: request URL and headers, provider
   credential (JWT or OAuth exchange), content-free payload, and the
   unregistered, expired-credential and retry answers. Client journeys do not
   prove delivery.
3. Live delivery with real provider credentials is out of scope for the
   parity gate. It remains release and fleet evidence.
4. Linux has no push provider by design. Its scope is local desktop
   enablement, plus listing, preference changes and removal of the account's
   other devices against the fixture. Linux registers no device.
5. A cell may say `implemented` only when its platform meets item 1, or item 4
   for Linux. Missing evidence stays `open` or `partial`, even if that keeps
   the gate red.

## Alternatives

- **Real push credentials for a CI-only app registration.** This would prove
  live delivery, but CI would hold publisher credentials (APNs `.p8`, Firebase
  service account, Entra ID secret) and need signed builds and real provider
  tokens. Runs would depend on Apple, Google and Microsoft. That breaks the
  hermetic, secret-free property of ADR-0264 and widens credential custody
  beyond Susan's deployment ([ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md)).
  Rejected.
- **Leave the row `partial`.** This is honest, but the gate stays red forever:
  no client change can close a gap that only provider credentials could
  close. It also hides which client work is actually missing. Rejected.
- **This scope.** Each requirement is proven where it can be proven
  hermetically: client behaviour in the journeys, delivery construction and
  outcome handling in Susan. Chosen.

## Consequences

- The push row can close without secrets in CI, and the remaining client gaps
  are visible per cell.
- Nothing in the gate proves that Apple, Google or Microsoft accept Susan's
  requests, or that a device shows a notification. A provider API change, a
  wrong team or project id, or a bad entitlement would pass every gate check.
  Release smoke and production monitoring (`susan.provider_outcome` events)
  must catch those.
- Susan's provider tests become parity evidence, so they must keep covering
  every provider Susan supports.

## Invariants and verification

- Each Susan provider has `Susan.FakeProvider` tests for the send URL,
  credential, payload and unregistered answer:
  [`poke_test.exs`](../../../susan/test/susan/poke_test.exs),
  [`provider_delivery_test.exs`](../../../susan/test/susan/provider_delivery_test.exs),
  [`poke_pipeline_contract_test.exs`](../../../susan/test/contract/susan/poke_pipeline_contract_test.exs)
  and [`push_keys_contract_test.exs`](../../../susan/test/contract/susan/push_keys_contract_test.exs).
- Each platform journey that claims the row registers a device, sees it
  listed, disables and enables it, and removes it. The headless fixture
  driver also asserts the effect in PostgreSQL (`notification_devices.enabled`,
  then `state = revoked`).
- Registration happens only after permission or enablement. Each platform's
  tests show that registration is refused without it.
- No client journey or matrix cell cites delivery as proven by the fixture.

## Implementation evidence

Susan delivery, all against `Susan.FakeProvider` (BEAM only, no network):

- **APNs.** [`poke_test.exs`](../../../susan/test/susan/poke_test.exs)
  covers the production URL, `apns-topic`, `apns-collapse-id`,
  `apns-push-type`, the bearer header, `mutable-content` with fixed
  loc-keys and an opaque ciphertext. It also covers the 410 unregistered
  answer with negative caching, 503 `Retry-After`, the in-request transport
  retry and delivery-id dedupe.
  [`provider_delivery_test.exs`](../../../susan/test/susan/provider_delivery_test.exs)
  verifies the ES256 provider JWT under the configured key (`kid`, `iss`,
  `iat`). It also covers the sandbox origin, `BadDeviceToken` as
  unregistered, and an `ExpiredProviderToken` replaced and retried once.
- **FCM.** `poke_test.exs` covers one OAuth exchange shared by two sends, the
  v1 `messages:send` URL, the token and a data-only message with the
  collapse key. `provider_delivery_test.exs` verifies the RS256 assertion
  under the service-account key (`iss`, scope, `aud`, one-hour `exp`). It
  covers 404, 400 `UNREGISTERED` and 403 `SENDER_ID_MISMATCH` as
  unregistered, and a 401 that leads to a fresh exchange and one resend.
- **WNS.** `poke_test.exs` covers the Entra client-credentials exchange
  (tenant URL, scope), the post to the sealed channel URI, `x-wns-type:
  wns/raw`, the raw body and 410 as unregistered.
  `provider_delivery_test.exs` covers 404 as unregistered and a 401 that
  leads to a fresh Entra exchange and one resend.
  [`wns_channel_property_test.exs`](../../../susan/test/susan/wns_channel_property_test.exs)
  and `push_keys_contract_test.exs` prove the channel-host restriction.

Client evidence:

- **Android: meets the scope.**
  [`MilaJourneyTest`](../../../mila/native/android/app/src/androidTest/java/dev/overalls/mila/nativeui/MilaJourneyTest.kt)
  `j10_notificationDeviceCrud` registers, lists, disables, enables and
  removes a device on the API 35 emulator against the fixture (mila-builds
  run 41014925339). The `POST_NOTIFICATIONS` gate is proven by JVM tests in
  [`MilaNotificationsTest`](../../../mila/native/android/app/src/test/java/dev/overalls/mila/nativeui/MilaNotificationsTest.kt)
  (`registrationRequiresOsPermissionAndProviderId`,
  `registrationPersistsProviderIdentifierOnlyAfterOsPermission`), not by an
  on-device permission grant.
- **Rust core.** The fixture's headless driver
  ([`driver.py`](../../../nix/verification/tests/machines/mila-journey/driver.py),
  subtest "notification device register, list, preferences and remove")
  drives `mila-journey` `device-register`/`device-ls`/`device-prefs`/`device-rm`
  and asserts each effect in PostgreSQL. It registers as the `android`
  platform; it is core evidence, not a platform client.
- **Apple: open.** [`MilaNotificationsTests`](../../../mila/native/apple/Tests/MilaNativeUITests/MilaNotificationsTests.swift)
  covers the token encoding, registration through the Rust boundary, refusal
  of invalid tokens and signed-out sessions. [`MilaJourneyTests`](../../../mila/native/apple/Tests/MilaNativeUITests/MilaJourneyTests.swift)
  `testNotificationDeviceRegisterListPreferencesAndRemoveAgainstFixture`
  registers through `MilaApplePushRegistration` (APNs-shaped token and
  Susan stand-ins), lists, disables, enables and removes a device against the
  fixture, reading each back. `MilaNotificationsTests`
  `testRegistrationIsRefusedWithoutUserNotificationsAuthorization` denies the
  injected authorization source and shows that neither Susan nor the core's
  register call is reached. Neither has compiled or passed in the
  apple-native job yet, so the cell stays open. The job's journey step
  previously filtered on `MilaJourneyTests`, which matches no test case name,
  so the Apple fixture journey had not run; the filter now names the classes.
- **Linux: open.** [`notifications.rs`](../../../mila/native/linux/src/notifications.rs)
  tests the explicit local desktop enablement and that push registration is
  refused (no provider). The GTK settings page has list, remove and
  enable/disable controls, but neither Linux journey
  ([`journey.rs`](../../../mila/native/linux/src/journey.rs), the
  `gtk-journey` window) drives them against the fixture.
- **Windows: open.**
  [`JourneySmoke.cs`](../../../mila/windows-dotnet-smoke/JourneySmoke.cs)
  lists devices against the fixture ("notification device listing").
  [`WindowsNotificationsSmoke.cs`](../../../mila/windows-dotnet-smoke/WindowsNotificationsSmoke.cs)
  covers WNS channel metadata validation and the signed-out refusal.
  Journey steps for register, preferences and remove are pending (being
  added separately).

## Open questions

- The Linux journey needs notification-device steps. The Apple steps and
  refusal test await a passing apple-native run. Until then those cells stay
  open.
- Windows register, preferences and remove journey steps are pending.
- Susan's `susan-fixed-provider-egress` contract (`susan/CONTRACTS`) still
  names only the APNs, Google OAuth and FCM origins. ADR-0236 added
  Entra ID and per-device WNS channel hosts, so the contract text should be
  reconciled with ADR-0236 separately.
- Susan's provider tests use the fake transport, so they cannot detect a
  provider API change or a credential that the provider rejects.

## Related decisions

Scopes the push row of the gate defined with
[ADR-0264](0264-hermetic-mila-journey-fixture.md). Delivery evidence:
[ADR-0224](0224-susan-push-relay.md) (APNs, FCM) and
[ADR-0236](0236-susan-wns-provider.md) (WNS). Device model:
[ADR-0225](0225-marshall-notifications-domain.md). Platforms:
[ADR-0235](0235-mila-desktop-clients.md),
[ADR-0249](0249-mila-rust-core-native-clients.md). Credential placement:
[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md).
