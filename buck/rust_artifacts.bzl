# Buck2-built Rust leaves that replace their Nix builds in assembly (ADR-0273,
# ADR-0269): name -> nix_store_import target. Owned by the M5 Rust migration.
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.
RUST_ARTIFACTS = {
    "enrico-git-owner": "root//enrico:git-owner-import",
    # `release`, as the Nix helpers are really built: the `hardened` (abort)
    # build failed real guest launches in machine run 41094831662.
    "lilly-host-helpers": "root//lilly:host-helpers-import",
    "observability-runtimes": "root//nix:observability-runtimes-import",
    "otel-guest-receiver": "root//nix:otel-guest-receiver-import",
    "terminald": "root//nix:terminald-import",
    "trace-spool": "root//elixir:trace-spool-import",
    "vscode-web-broker": "root//nix:vscode-web-broker-import",
}
