# ADR-0277: Mila native builds on Buck2 with Nix toolchains

- ID: ADR-0277
- Date: 2026-11-01
- Status: accepted
- Implementation: partial
- Components: Mila, Nix, Buck2
- Supersedes: ADR-0227
- Superseded by: none

## Context

[ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md) built Mila with
nixpkgs Flutter. It used a patched dartssh2 overlay, a pinned Hegel Dart
engine, offline pub caches, and the flake checks `mila-core`,
`mila-transport`, `mila-test` and `mila-lock-sync`.
[ADR-0249](0249-mila-rust-core-native-clients.md) replaced the Flutter client
with a shared Rust core (`mila/rust`, SSH through `russh`) and native
platform clients. [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)
made Buck2 the only build entry point; its M9 milestone moved the Mila
platform builds to Buck2 targets, and M11 removed the flake's packages and
checks.

Observed on trunk on 2026-11-01:

- `nix/platform/dartssh2.nix` and `nix/verification/hegel/libhegel-dart.nix`
  no longer exist.
- [mila/default.nix](../../../nix/domains/artifacts/mila/default.nix) states
  that the Flutter client has been retired.
- The only remaining Flutter input is `mila-release.yml`'s Windows
  compatibility job, which downloads a pinned Flutter archive on a Windows
  runner.

ADR-0227's decisions 1-5 therefore describe a build that no longer exists.

## Decision

1. Mila builds only through Buck2 targets in [mila/BUCK](../../../mila/BUCK)
   whose toolchains come from the Nix-pinned `buckCells`:
   - Linux: `//:package-tool-mila-linux-native`,
     `//:package-tool-mila-linux-release`, the source bundles and
     `//:check-mila-rust`, through `lib.assemble`.
   - Apple: `//mila:apple-ffi`, `//mila:apple-swift-test` and
     `//mila:<platform>-dev`, `-release` and `-unsigned`, on macOS runners
     over `buckCells.aarch64-darwin`.
   - Android: `//mila:android-debug` and `//mila:android-release`.
   - Windows: `//mila:windows-ffi-msvc`, `//mila:windows-dotnet` and
     `//mila:windows-smoke`, plus the hermetic Linux cross-check
     `//mila:windows-ffi-gnu`.
2. The shared Rust workspace builds with the single rust-overlay toolchain
   ([ADR-0273](0273-single-rust-workspace-and-toolchain.md)). SSH host
   certificates are implemented in Rust, not in a patched Dart library.
3. The dartssh2 overlay, the Hegel Dart engine pin, the pub lock JSON and the
   Flutter checks are retired. No Nix or Buck2 target builds Flutter or Dart.
4. The Windows Flutter compatibility job in `mila-release.yml` is the one
   remaining Flutter build. It is transitional: it stays until the native
   Windows client is the shipped Windows artifact, and it must not reach any
   Buck2 target or the native source bundles. The bundle checks in that
   workflow refuse Flutter and Dart files.

Authorization: the accepted Buck2 migration plan (ADR-0269, milestones M9
and M11), which names this superseding record, and ADR-0249's accepted move
to native clients.

## Alternatives

- **Amend ADR-0227 in place.** Rejected: its toolchain, overlay and check
  decisions are replaced, not corrected. Supersession keeps the Flutter-era
  rationale.
- **Keep a Nix-built Flutter check for the Windows job.** Rejected: the job
  is transitional, and a Flutter toolchain in the cells would bring Dart back
  into the graph.

## Consequences

- Mila's verification is the Buck2 targets above: Rust tests and Clippy,
  Swift tests, Android unit tests, Windows smoke tests and the hermetic
  journey fixture ([ADR-0264](0264-hermetic-mila-journey-fixture.md)).
- dartssh2 rebases and Dart engine pins are no longer maintenance work.
- Until the Windows compatibility job is retired, one release job fetches
  Flutter from the network on a Windows runner, outside the pin registry
  ([ADR-0267](0267-single-dependency-pin-registry.md)).

## Invariants and verification

- No Buck2 target or Nix output depends on Flutter or Dart. A Flutter path in
  a Mila target's closure would disprove this.
- The native Linux release, the Apple package and the native Windows source
  bundle contain no Flutter or Dart content. `mila-release.yml` checks each
  and fails otherwise.
- Host certificate handling keeps ADR-0228's strict semantics in the Rust
  transport.

## Implementation evidence

- [mila/BUCK](../../../mila/BUCK) and [buck/mila.bzl](../../../buck/mila.bzl)
  define the platform targets.
- [nix/assemble/outputs.nix](../../../nix/assemble/outputs.nix) defines the
  Linux packages and the `mila-rust` check.
- `mila-builds.yml` builds the Apple, Android and Windows targets; CI run
  41114668466 built every one of them (ADR-0269).
- `mila-release.yml` builds the release artifacts through Buck2 and checks
  that they contain no Flutter. Its unsigned Android and Apple builds run
  without a tag.

Gaps:

- The signed release path has not run; this is tracked in ADR-0269.
- The Windows Flutter compatibility job (decision 4) remains.

## Open questions

When the native Windows client replaces the Flutter Windows build, and so
when decision 4's job is deleted.

## Related decisions

- [ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md) (superseded).
- [ADR-0228](0228-strict-host-certificates-in-mila.md).
- [ADR-0235](0235-mila-desktop-clients.md).
- [ADR-0249](0249-mila-rust-core-native-clients.md).
- [ADR-0264](0264-hermetic-mila-journey-fixture.md).
- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md).
- [ADR-0273](0273-single-rust-workspace-and-toolchain.md).
