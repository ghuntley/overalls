# Mila for iOS and macOS

`MilaNativeUI` is the SwiftUI client over the shared Rust core (`mila-ffi`).
`App/` is the host app: its only code is the entry point, `MilaNativeApp.main()`,
plus the Info.plist for each platform. Swift tools 6.1, iOS 18 and macOS 15 are
the floor; builds need Xcode on an Apple silicon Mac.

The adapter has a typed request/response boundary. Do not expose raw pointers,
key material, authentication tokens or terminal bytes through this module.

## Run it

From `devenv shell` at the repository root:

```sh
mila-run macos   # build the dev app and open it
mila-run ios     # build for the iOS simulator, install and launch it
```

`MILA_SIMULATOR` picks a simulator by name or UDID; the default is the first
available iPhone. On Darwin the devenv Rust toolchain comes from rust-overlay
with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` standard libraries.

## Build targets

`mila-build <ios|macos> <dev|release|unsigned>` (`build.sh`) builds `mila-ffi` for the
target, builds `App/`, assembles `Mila.app` under `mila/build/<platform>-<mode>/`
and signs it. It uses the system Xcode, not the Nix apple-sdk that devenv exports.

| Target | Output | Signing |
| --- | --- | --- |
| `macos dev` | `Mila.app` | `MILA_APPLE_IDENTITY` (plus `MILA_APPLE_PROFILE_RUNNER` and `MILA_APPLE_TEAM` for entitlements) when set, otherwise ad hoc |
| `ios dev` | iOS-simulator `Mila.app` | ad hoc |
| `macos release` | notarized, stapled `Mila-<version>.dmg` | Developer ID, hardened runtime, profile entitlements |
| `ios release` | device `Mila-<version>.ipa` | distribution identity, embedded profile |
| `macos unsigned` | `Mila-<version>-unsigned.dmg`, release configuration | ad hoc; no notarization |
| `ios unsigned` | device `Mila-<version>-unsigned.ipa`, release configuration | ad hoc |

A release needs `MILA_APPLE_TEAM`, `MILA_APPLE_IDENTITY`,
`MILA_APPLE_PROFILE_RUNNER` (an installed profile's name), `MILA_VERSION`
(`MAJOR.MINOR.PATCH`) and, for macOS, `MILA_NOTARY_PROFILE` (a `notarytool`
keychain profile). `MILA_KEYCHAIN` selects the signing keychain. A missing
input, or a profile for another team or bundle identifier, is refused. An
`unsigned` build needs only `MILA_VERSION` and reads no signing input;
`mila-release.yml` builds it on runs without a `mila-v*` tag.

An ad-hoc macOS `dev` build compiles the `MILA_SOFTWARE_KEYS` development
condition. It stores one owner-only, deployment-scoped software P-256 key in
`Application Support/Mila/dev-software-keys` and disables push registration; release,
`unsigned`, and all iOS builds never compile that condition. A team-signed
macOS build with a provisioning profile uses the Secure Enclave instead.
Setting `MILA_APPLE_IDENTITY` for macOS development requires
`MILA_APPLE_TEAM` and `MILA_APPLE_PROFILE_RUNNER`; an incomplete signed build is
refused before compilation.
Software key filenames use a digest of the canonical deployment hostname;
unsafe permissions, symlinks, hard links and malformed files are refused.
The Secure Enclave key namespace remains unchanged across development builds.

## Tests

```sh
tools/buck2 build -c overalls.non_hermetic=true //mila:apple-swift-test
tools/buck2 build -c overalls.non_hermetic=true //mila:apple-software-keys-test
```

These targets require macOS and Xcode. The software-key target runs the enabled
DEBUG custody and push-refusal tests separately and verifies that a non-DEBUG
compile refuses the development condition. Inside `devenv shell`, set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `mila-build` sets this
itself.
