# Compact Nix build logs

The native implementation now lives in the public
[ghuntley/nix-compact](https://github.com/ghuntley/nix-compact) repository.
This repository consumes its pinned flake through `flake.lock` and `devenv.lock`.

- [Standalone usage and flake interfaces](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/README.md)
- [Logging, retrieval, retention and replay manual](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/MANUAL.md)
- [Implementation design and verification boundaries](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/DESIGN.md)

`devenv shell` uses the standalone package factory with this repository's pinned
development package set. The fleet's NixOS adapter uses the stable host package
set. Both require the supported Nix version rather than silently using another
toolchain. Hosts enable compact output through the public
`programs.nix-compact.enable` option. Explicit NixOS package choices retain
ordinary precedence.

The packages and checks are Buck2 targets:

```sh
tools/buck2 build //:package-tool-nix-compact //:package-tool-nix-compact-host
tools/buck2 build //:check-nix-compact-core \
  //:check-nix-compact-native \
  //:check-nix-compact-native-host \
  //:check-nix-compact-configuration
```

The first three checks delegate to the standalone factories; configuration
checks remain here to verify this repository's compatibility adapter. Direct
imports used by existing NixOS fixtures resolve the external source from the root
flake lock through `nix/domains/artifacts/nix-compact/source.nix`, without another source
pin. Update the flake and devenv inputs together when upgrading the dependency.

Native compact logging, stable `L#`/`D#` references, bounded retrieval, Hegel
properties and build-result guarantees are maintained upstream. No implementation
copy is retained here. See [ADR-0087](../architecture/decisions/0087-compact-nix-build-logs.md).
