#!/usr/bin/env bash
# Build the native Mila app for iOS or macOS (ADR-0235).
#
#   dev      macOS: Mila.app signed with MILA_APPLE_IDENTITY when set, otherwise
#            ad hoc. iOS: an ad-hoc signed iOS-simulator Mila.app.
#   release  macOS: Developer ID signed Mila.app in a notarized, stapled DMG.
#            iOS: a device IPA. Both are signed with the provisioning profile
#            named by MILA_APPLE_PROFILE_RUNNER.
#
# A release refuses any missing signing input rather than substituting one, and
# verifies every signature as its final step. Output goes to
# mila/build/<platform>-<mode>/.
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^(ios|macos)$ || ! "$2" =~ ^(dev|release)$ ]]; then
  echo "usage: mila/native/apple/build.sh <ios|macos> <dev|release>" >&2
  exit 2
fi
platform=$1
mode=$2

refuse() {
  echo "mila-build: $*" >&2
  exit 1
}
require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || refuse "$platform $mode requires $name"
  done
}

[[ "$(uname -s)" == Darwin ]] || refuse "Apple targets build only on macOS"

package_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$package_dir/../../.." && pwd)
out="$repo/mila/build/${platform}-${mode}"
bundle_id=dev.overalls.mila
version=${MILA_VERSION:-0.0.0}

if [[ "$mode" == release ]]; then
  require MILA_APPLE_TEAM MILA_APPLE_IDENTITY MILA_APPLE_PROFILE_RUNNER MILA_VERSION
  [[ "$platform" == ios ]] || require MILA_NOTARY_PROFILE
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "MILA_VERSION must be MAJOR.MINOR.PATCH"
fi

# Use the system Xcode rather than the Nix apple-sdk that devenv exports, and
# keep the Nix compiler wrappers out of the Rust and Swift link steps.
if [[ -z "${DEVELOPER_DIR:-}" || "$DEVELOPER_DIR" == /nix/store/* ]]; then
  DEVELOPER_DIR=$(env -u DEVELOPER_DIR xcode-select -p)
  if [[ "$DEVELOPER_DIR" != *.app/Contents/Developer && -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
export DEVELOPER_DIR
[[ "$DEVELOPER_DIR" == *.app/Contents/Developer ]] || refuse "Xcode is required; found $DEVELOPER_DIR"
unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_CC NIX_BINTOOLS CFLAGS LDFLAGS RUSTFLAGS
CC=$(xcrun --find clang)
AR=$(xcrun --find ar)
export CC AR
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=$CC
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$CC
export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER=$CC
export MACOSX_DEPLOYMENT_TARGET=15.0 IPHONEOS_DEPLOYMENT_TARGET=18.0

case "$platform-$mode" in
  macos-*) rust_target=aarch64-apple-darwin swift_triple=arm64-apple-macosx15.0 sdk=macosx ;;
  ios-dev) rust_target=aarch64-apple-ios-sim swift_triple=arm64-apple-ios18.0-simulator sdk=iphonesimulator ;;
  ios-release) rust_target=aarch64-apple-ios swift_triple=arm64-apple-ios18.0 sdk=iphoneos ;;
esac

# The devenv Nix Rust toolchain carries only the host standard library.
rustc=${RUSTC:-rustc}
libdir=$("$rustc" --print target-libdir --target "$rust_target")
compgen -G "$libdir/libcore-*.rlib" > /dev/null ||
  refuse "the Rust standard library for $rust_target is missing; use a rustup toolchain with 'rustup target add $rust_target'"
RUSTC=$rustc "${CARGO:-cargo}" build --locked --release \
  --manifest-path "$repo/mila/rust/mila-ffi/Cargo.toml" --target-dir "$repo/mila/rust/target" \
  -p mila-ffi --target "$rust_target"
export MILA_FFI_LIB_DIR="$repo/mila/rust/target/$rust_target/release"

# Bundle every shared locale catalog (mila-apple-bundled-catalogs).
python3 "$repo/mila/localization/generate_catalogs.py" \
  --source "$repo/mila/localization/catalogs" --output "$package_dir/Sources/MilaNativeUI/Resources"

swift_config=debug
[[ "$mode" == release ]] && swift_config=release
swift_args=(--package-path "$package_dir/App" --scratch-path "$package_dir/App/.build/$platform-$mode"
  --configuration "$swift_config" --triple "$swift_triple" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)")
xcrun swift build "${swift_args[@]}"
bin=$(xcrun swift build "${swift_args[@]}" --show-bin-path)

rm -rf "$out"
mkdir -p "$out"
app="$out/Mila.app"
if [[ "$platform" == macos ]]; then
  executable_dir="$app/Contents/MacOS" resources="$app/Contents/Resources" plist="$app/Contents/Info.plist"
  profile_path="$app/Contents/embedded.provisionprofile"
else
  executable_dir="$app" resources="$app" plist="$app/Info.plist"
  profile_path="$app/embedded.mobileprovision"
fi
mkdir -p "$executable_dir" "$resources"
cp "$bin/Mila" "$executable_dir/Mila"
cp -R "$bin/MilaNativeUI_MilaNativeUI.bundle" "$resources/"
cp "$package_dir/App/Info-$platform.plist" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
if [[ "$platform" == ios ]]; then
  supported=iPhoneOS
  [[ "$sdk" == iphonesimulator ]] && supported=iPhoneSimulator
  plutil -replace CFBundleSupportedPlatforms -json "[\"$supported\"]" "$plist"
fi
python3 "$repo/mila/localization/apple_infoplist_strings.py" \
  --source "$repo/mila/localization/catalogs" --resources "$resources"

keychain_args=()
[[ -n "${MILA_KEYCHAIN:-}" ]] && keychain_args=(--keychain "$MILA_KEYCHAIN")

# Find the installed profile by name and check that it belongs to this team and
# bundle identifier before its entitlements are used.
use_profile() {
  local dir file name decoded="$out/profile.plist" found=""
  for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
             "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    for file in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
      [[ -f "$file" ]] || continue
      security cms -D -i "$file" > "$decoded" 2> /dev/null || continue
      name=$(plutil -extract Name raw -o - "$decoded")
      if [[ "$name" == "$MILA_APPLE_PROFILE_RUNNER" ]]; then
        found=$file
        break 2
      fi
    done
  done
  [[ -n "$found" ]] || refuse "provisioning profile '$MILA_APPLE_PROFILE_RUNNER' is not installed"
  [[ "$(plutil -extract TeamIdentifier.0 raw -o - "$decoded")" == "$MILA_APPLE_TEAM" ]] ||
    refuse "provisioning profile '$MILA_APPLE_PROFILE_RUNNER' belongs to another team"
  plutil -extract Entitlements xml1 -o "$out/entitlements.plist" "$decoded"
  local app_id
  app_id=$(plutil -extract application-identifier raw -o - "$out/entitlements.plist" 2> /dev/null ||
    plutil -extract com\\.apple\\.application-identifier raw -o - "$out/entitlements.plist")
  [[ "$app_id" == "$MILA_APPLE_TEAM.$bundle_id" ]] ||
    refuse "provisioning profile '$MILA_APPLE_PROFILE_RUNNER' is for $app_id, not $MILA_APPLE_TEAM.$bundle_id"
  cp "$found" "$profile_path"
  rm -f "$decoded"
}

if [[ "$mode" == release ]]; then
  use_profile
  sign_args=(--sign "$MILA_APPLE_IDENTITY" --entitlements "$out/entitlements.plist" --timestamp)
  [[ "$platform" == macos ]] && sign_args+=(--options runtime)
elif [[ "$platform" == macos && -n "${MILA_APPLE_IDENTITY:-}" ]]; then
  sign_args=(--sign "$MILA_APPLE_IDENTITY")
  if [[ -n "${MILA_APPLE_PROFILE_RUNNER:-}" ]]; then
    require MILA_APPLE_TEAM
    use_profile
    sign_args+=(--entitlements "$out/entitlements.plist")
  fi
else
  # Ad hoc: no Secure Enclave keys or push, so sign-in is unavailable.
  sign_args=(--sign -)
fi
codesign --force ${keychain_args[@]+"${keychain_args[@]}"} "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"

if [[ "$mode" == dev ]]; then
  echo "mila-build: built $app"
  exit 0
fi

verify_team() {
  codesign -dv "$1" 2>&1 | grep -qx "TeamIdentifier=$MILA_APPLE_TEAM" ||
    refuse "$1 is not signed by team $MILA_APPLE_TEAM"
}
verify_team "$app"

if [[ "$platform" == macos ]]; then
  artifact="Mila-$version.dmg"
  hdiutil create -quiet -volname Mila -srcfolder "$app" -format UDZO -ov "$out/$artifact"
  codesign --force ${keychain_args[@]+"${keychain_args[@]}"} --sign "$MILA_APPLE_IDENTITY" --timestamp "$out/$artifact"
  status=$(xcrun notarytool submit "$out/$artifact" --keychain-profile "$MILA_NOTARY_PROFILE" \
    ${keychain_args[@]+"${keychain_args[@]}"} --wait --output-format json | plutil -extract status raw -o - -)
  [[ "$status" == Accepted ]] || refuse "notarization finished with status $status"
  xcrun stapler staple "$out/$artifact"
  xcrun stapler validate "$out/$artifact"
  spctl --assess --type open --context context:primary-signature --verbose "$out/$artifact"
  verify_team "$out/$artifact"
else
  artifact="Mila-$version.ipa"
  mkdir "$out/Payload"
  cp -R "$app" "$out/Payload/"
  (cd "$out" && zip -qry "$artifact" Payload)
  rm -rf "$out/Payload"
fi
(cd "$out" && shasum -a 256 "$artifact" > SHA256SUMS)
echo "mila-build: built $out/$artifact"
