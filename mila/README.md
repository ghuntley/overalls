# Mila

Mila is the native Overalls client for iOS, Android, macOS, Windows and Linux.
Each platform UI is a thin wrapper around the shared Rust workspace under
[`rust/`](rust/), which owns transport, validation, persistence and protocol
behavior.

```sh
devenv shell
mila-rust-check
mila-rust-build
tools/buck2 build //:package-tool-mila-linux-native
tools/buck2 build //:package-tool-mila-rust
```

The native clients live under `native/`: Swift packages for Apple, a Jetpack
Compose application for Android, GTK/libadwaita for Linux and WinUI/.NET 10
for Windows. Release workflows build each native target and verify checksums.
Shared localization catalogs are under `localization/catalogs` and are
validated before packaging.

See [AGENTS.md](AGENTS.md) for repository guidance and the architecture
records under [`../docs/architecture/decisions/`](../docs/architecture/decisions/).
