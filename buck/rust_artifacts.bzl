# Buck2-built Rust leaves that replace their Nix builds in assembly (ADR-0273,
# ADR-0269): name -> nix_store_import target. Owned by the M5 Rust migration.
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.
RUST_ARTIFACTS = {
    "enrico-git-owner": "root//enrico:git-owner-import",
    # lilly-host-helpers is held back while real guest launches failing in
    # machine run 41094831662 are triaged against its Nix build; hosts keep the
    # Nix helpers until that A/B clears the Buck2 build.
    "observability-runtimes": "root//nix:observability-runtimes-import",
    "otel-guest-receiver": "root//nix:otel-guest-receiver-import",
    "trace-spool": "root//elixir:trace-spool-import",
}
