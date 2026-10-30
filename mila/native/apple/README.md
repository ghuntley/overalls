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

`mila-build <ios|macos> <dev|release>` (`build.sh`) builds `mila-ffi` for the
target, builds `App/`, assembles `Mila.app` under `mila/build/<platform>-<mode>/`
and signs it. It uses the system Xcode, not the Nix apple-sdk that devenv exports.

| Target | Output | Signing |
| --- | --- | --- |
| `macos dev` | `Mila.app` | `MILA_APPLE_IDENTITY` (plus `MILA_APPLE_PROFILE_RUNNER` and `MILA_APPLE_TEAM` for entitlements) when set, otherwise ad hoc |
| `ios dev` | iOS-simulator `Mila.app` | ad hoc |
| `macos release` | notarized, stapled `Mila-<version>.dmg` | Developer ID, hardened runtime, profile entitlements |
| `ios release` | device `Mila-<version>.ipa` | distribution identity, embedded profile |

A release needs `MILA_APPLE_TEAM`, `MILA_APPLE_IDENTITY`,
`MILA_APPLE_PROFILE_RUNNER` (an installed profile's name), `MILA_VERSION`
(`MAJOR.MINOR.PATCH`) and, for macOS, `MILA_NOTARY_PROFILE` (a `notarytool`
keychain profile). `MILA_KEYCHAIN` selects the signing keychain. A missing
input, or a profile for another team or bundle identifier, is refused.

Ad-hoc builds have no keychain entitlements, so `MilaDeviceSigner` cannot
create a Secure Enclave key and sign-in is unavailable. Signing in needs a
team-signed build with a provisioning profile.

## Tests

```sh
cargo build --manifest-path mila/rust/mila-ffi/Cargo.toml -p mila-ffi --release
MILA_FFI_LIB_DIR=$PWD/target/release swift test --package-path mila/native/apple
```

Inside `devenv shell`, run `swift` with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `mila-build` sets
this itself.
