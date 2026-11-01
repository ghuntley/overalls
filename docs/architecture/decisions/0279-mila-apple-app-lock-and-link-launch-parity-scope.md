# ADR-0279: Mila Apple app-lock and link-launch parity scope

- ID: ADR-0279
- Date: 2026-11-01
- Status: proposed
- Implementation: planned
- Components: Mila, verification
- Supersedes: none
- Superseded by: none

## Context

The native parity matrix (`mila/native/PARITY_MATRIX.md`) gates Mila's native
builds. The `Native parity` job in `.github/workflows/mila-builds.yml` fails
while any row contains `partial` or `open`. Rows close with CI evidence, mostly
journeys against the hermetic fixture of
[ADR-0264](0264-hermetic-mila-journey-fixture.md).
[ADR-0278](0278-mila-push-notification-parity-scope.md) scoped the push row
because part of it cannot be proven hermetically. Two Apple cells have the same
problem:

- **App lock.** "platform authenticator integration remains unverified".
- **Deep links.** "launching from a link on a device remains unverified".

Observed facts:

- `MilaAppLockController` (`mila/native/apple/Sources/MilaNativeUI/MilaAppLock.swift`)
  depends on an injected `MilaBiometricEvaluator`. Production uses
  `LocalAuthenticationEvaluator`, which calls `LAContext.canEvaluatePolicy` and
  `evaluatePolicy(.deviceOwnerAuthentication)`. `MilaAppLockTests` cover
  enablement, unlock, background lock, foreground re-authentication and
  in-flight prompts, but only with a scripted evaluator. No CI step calls
  `LAContext`.
- The `App` host registers the `overalls` URL scheme (`App/Info-ios.plist`,
  `App/Info-macos.plist`). `onOpenURL` in `MilaNativeUI.swift` decides links
  through `MilaDeepLinkRouter`. `MilaDeepLinkRouterTests` and `MilaRouteTests`
  cover the decisions. The apple-native job builds the macOS and
  iOS-simulator apps but never launches them, so no CI step proves the scheme
  registration or the `onOpenURL` wiring.
- GitHub's macOS runners have no enrolled Touch ID and no attached iPhone. The
  iOS simulator can simulate an enrolled Face ID or Touch ID and a match or
  non-match. It can also open a URL in an installed app (`xcrun simctl
  openurl`). Neither involves the Secure Enclave or a real sensor.
- The other platforms close these rows at the same depth: Android with
  BiometricPrompt unavailable and enrolled states on the API 35 emulator
  (`MilaAppLockDeviceTest`), Windows with CI smoke coverage of its Windows
  Hello broker, and Linux with an explicit unavailable state. No platform
  launches the app from a link on a physical device.

## Decision

Proposed. The user must accept, amend or reject it.

1. For the app-lock row, Apple parity means:
   - the lock lifecycle proven by package tests with an injected evaluator
     (`MilaAppLockTests`); and
   - `LocalAuthenticationEvaluator` driven through the real
     LocalAuthentication framework in CI on the iOS simulator: unavailable
     without enrollment (enablement refused), then enrolled, with a simulated
     match that unlocks and a simulated non-match that stays locked.
2. For the deep-link row, Apple parity means:
   - the route decisions proven by package tests; and
   - the built app launched in CI from an `overalls://` link (`xcrun simctl
     openurl` on the iOS simulator, LaunchServices `open` on macOS), with a
     UI test asserting that the routed page, or the signed-out refusal, is
     shown.
3. A real Touch ID or Face ID sensor, Secure Enclave-backed evaluation, and a
   link tapped on a physical device are outside the parity gate. They remain
   release evidence on signed builds.
4. A cell may say its gap is closed only when item 1 or item 2 has passed in
   CI. Until then the gap phrase stays, even if that keeps the gate red.

## Alternatives

- **A real-device farm in CI.** This would prove sensor and link launch on
  hardware, but it needs signed builds, provisioning profiles and an external
  service in CI. Runs would depend on a third party. That breaks the hermetic,
  secret-free property of ADR-0264. Not proposed.
- **Package tests only.** These already pass. They cannot catch a missing URL
  scheme, broken `onOpenURL` wiring or a wrong `LAContext` policy, so they
  would close the cells without any evidence of the integrations named in the
  gaps. Not proposed.
- **Leave both cells open.** This is honest, but no client change can close
  them, and the gate stays red forever. It is the current state until the user
  decides.
- **This scope.** Each requirement is proven by real OS frameworks where CI
  can run them, with hardware left to release evidence. Proposed.

## Consequences

- Closing the cells requires new CI work: an XCUITest target for the dev app,
  run on a booted iOS simulator, plus simulator biometric enrollment and match
  control. None of it exists yet.
- Nothing in the gate would prove that a real sensor or the Secure Enclave
  behaves as the simulator does, or that a link opens the app from Messages or
  Safari on a device. Release smoke on signed builds must catch those.
- The scope matches the depth Android and Windows already reach, so the rows
  mean the same thing across platforms.

## Invariants and verification

- Enabling app lock is refused while LocalAuthentication reports no usable
  authenticator; a non-match never unlocks.
- A link launch on a signed-out app opens no authenticated page; an
  authenticated launch opens only a page `MilaDeepLinkRouter` accepts.
- No matrix cell cites simulator evidence as proof of real hardware.

## Implementation evidence

No implementation yet. The package tests named above exist and pass in the
`//mila:apple-swift-test` step (mila-builds run 41361180998). The simulator UI
test, biometric simulation and link launch are planned.

## Open questions

- Whether the user accepts simulator evidence for these rows, or wants the
  cells left open until real-device evidence exists.
- Whether simulator biometric control (the `notifyutil` enrollment and match
  notifications) is stable enough on hosted runners to gate on.
- Whether the macOS LaunchServices launch is needed in addition to the iOS
  simulator, given the shared `onOpenURL` code.

## Related decisions

Scopes two rows of the gate defined with
[ADR-0264](0264-hermetic-mila-journey-fixture.md), in the manner of
[ADR-0278](0278-mila-push-notification-parity-scope.md). Platforms:
[ADR-0235](0235-mila-desktop-clients.md),
[ADR-0249](0249-mila-rust-core-native-clients.md),
[ADR-0277](0277-mila-native-builds-on-buck2.md).
