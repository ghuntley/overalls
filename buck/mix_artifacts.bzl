# Buck2-built Mix releases that replace their Nix builds in assembly (ADR-0269):
# artifact name -> nix_store_import target. Owned by the M6 Elixir migration.
# Contract assembly-artifact-names: see nix/domains/artifacts/default.nix.
# Contract mix-variant-imports: see buck/CONTRACTS.

MIX_APPLICATIONS = ["marshall", "lilly", "audi", "porsche", "ziggy", "brady", "galileo", "enrico", "peach", "susan"]

# Every assembly: each release and its encrypted-crash-dump variant, which a
# host or test that enables crash dumps runs (host-params-match-artifacts).
MIX_ARTIFACTS = {
    app: "root//{}:{}_import".format(app, app)
    for app in MIX_APPLICATIONS
} | {
    "encrypted-" + app: "root//{}:{}_import_encrypted".format(app, app)
    for app in MIX_APPLICATIONS
}

# The Antithesis contexts' package sets (lib.assemble routes them). The guest
# and integrated-host flags change only Lilly's build, so the other
# applications in those sets take the harness release.
MIX_ANTITHESIS_ARTIFACTS = {
    "antithesis-harness-" + app: "root//{}:{}_import_antithesis_harness".format(app, app)
    for app in MIX_APPLICATIONS
} | {
    "antithesis-guest-lilly": "root//lilly:lilly_import_antithesis_guest",
    "antithesis-integrated-host-lilly": "root//lilly:lilly_import_antithesis_integrated_host",
}

# Fixture releases (each project's release_variants) for the suites that run
# them: `fixture-<app>-<variant>`. Only those suites build them.
MIX_FIXTURE_ARTIFACTS = {
    "fixture-{}-{}".format(app, variant.replace("_", "-")): "root//{}:{}_import_{}".format(app, app, variant)
    for app, variants in {
        "audi": ["updated", "unhealthy"],
        "lilly": ["updated", "observed_clone"],
        "marshall": ["observed_clone", "update_success", "update_failure"],
    }.items()
    for variant in variants
}

# Machine-test suites whose assemblies receive MIX_FIXTURE_ARTIFACTS.
MIX_FIXTURE_SUITES = ["fleet", "credential-rotation"]
