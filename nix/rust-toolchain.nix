{ pkgs }:
# @cc [owner:ghuntley,label:build] single-rust-toolchain
# Buck2's Rust toolchain, the Nix cross and native Rust builds and the devenv
# shell MUST use this one rust-overlay toolchain. Its release, components and
# target standard libraries are defined only here, and rust-overlay MUST be
# read from the flake.lock `rust-overlay` entry so no second pin exists
# (ADR-0273, ADR-0267). Remaining nixpkgs rustPlatform leaves move to
# `rustPlatform` below or to Buck2 (M5).
let
  inherit (pkgs) lib;
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  overlaySource = builtins.fetchTree lock.nodes.${lock.nodes.root.inputs.rust-overlay}.locked;
  # rust-overlay's flake.nix only uses its nixpkgs input for `lib`.
  rustBin = ((import "${overlaySource}/flake.nix").outputs {
    self = null;
    nixpkgs = { inherit lib; };
  }).lib.mkRustBin { } pkgs;

  version = "1.97.1";
  # No rust-src: when it is installed, rustc maps std's virtual /rustc/<hash>
  # paths to the real sources, so panic locations would embed this store path
  # in every binary. Editors get the sources through `rustSrc` instead.
  components = [ "rustc" "cargo" "clippy" "rustfmt" "rust-std" ];
  # Every target the repository builds: Linux gnu and musl, Windows (gnu),
  # macOS, FreeBSD, illumos, iOS and the Android ABIs Mila ships.
  targets = [
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "x86_64-unknown-linux-musl"
    "aarch64-unknown-linux-musl"
    "x86_64-pc-windows-gnu"
    "x86_64-apple-darwin"
    "aarch64-apple-darwin"
    "x86_64-unknown-freebsd"
    "x86_64-unknown-illumos"
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "aarch64-linux-android"
    "armv7-linux-androideabi"
    "x86_64-linux-android"
  ];
  # The illumos standard library is ELFOSABI_ILLUMOS and links the guest's
  # libc family, which does not exist on the Linux builder. rustc only reads
  # its metadata, so keep the foreign ABI intact instead of patching it.
  illumosLibraries = [
    "libsocket.so.1" "libpthread.so.1" "libumem.so.1" "libm.so.2"
    "libsendfile.so.1" "liblgrp.so.1" "libc.so.1"
  ];
  release = rustBin.stable.${version};
  illumosStd = release._components.x86_64-unknown-illumos.rust-std.overrideAttrs {
    autoPatchelfIgnoreMissingDeps = illumosLibraries;
  };
  toolchain = (release.minimal.override {
    extensions = lib.subtractLists [ "rustc" "cargo" "rust-std" ] components;
    targets = lib.remove "x86_64-unknown-illumos" targets;
  }).overrideAttrs (previous: { paths = previous.paths ++ [ illumosStd ]; });
in
{
  inherit version components targets toolchain;
  # Standard-library sources for rust-analyzer (RUST_SRC_PATH), kept out of
  # the compiler's sysroot.
  rustSrc = "${release.rust-src}/lib/rustlib/src/rust/library";
  # nixpkgs Rust builders (buildRustPackage, cargo-based mkDerivation) over
  # the same toolchain.
  rustPlatform = pkgs.makeRustPlatform { cargo = toolchain; rustc = toolchain; };
}
