# Buck2-built Rust leaves that replace their Nix builds in assembly (ADR-0273,
# ADR-0269): name -> nix_store_import target. Owned by the M5 Rust migration.
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.
RUST_ARTIFACTS = {
    "enrico-git-owner": "root//enrico:git-owner-import",
    # `hardened` (abort on panic), as the Nix helpers are built (ADR-0273).
    "lilly-host-helpers": "root//lilly:host-helpers-import",
    # Lyra's client, Windows agents and native agents (buck/lyra.bzl), each
    # byte-identical to its Nix build apart from the masked Mach-O UUID.
    "lyra": "root//lyra:client-import",
    "lyra-native": "root//lyra:native-import",
    "lyra-native-probes": "root//lyra:native-probes-import",
    "lyra-windows": "root//lyra:windows-import",
    "observability-runtimes": "root//nix:observability-runtimes-import",
    "otel-guest-receiver": "root//nix:otel-guest-receiver-import",
    "terminald": "root//nix:terminald-import",
    "trace-spool": "root//elixir:trace-spool-import",
    "vscode-web-broker": "root//nix:vscode-web-broker-import",
}

# Test-only Buck2 fixtures that machine tests (buck/nixos.bzl), but no host
# deployment, receive: name -> nix_store_import target. They replace fixtures
# a suite used to build from a leaf's Nix build, so they have no parity test.
TEST_ARTIFACTS = {
    # The otel-request-recorder suite's control fixture and its
    # commit-reply-loss recorder (nix/BUCK).
    "otel-request-fixture": "root//nix:otel-request-fixture-import",
    "otel-request-recorder-cut": "root//nix:otel-request-recorder-cut-import",
}
