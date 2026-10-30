load("//buck:nix.bzl", "nix_owned")
load("//nix/buck:bootstrap_attrs.bzl", "BOOTSTRAP_CHECKS", "BOOTSTRAP_PACKAGES")
load("//buck:nix.bzl", "nix_flake_attr", "owned_set")

# Repository-root files: flake, lock files, configuration.
nix_owned()

# Owned sources that the flake reads. Bootstrap targets depend on all of them
# until per-component rules replace them (ADR-0269).
owned_set(
    name = "flake_srcs",
    deps = [":srcs"] + [
        "//.agents:srcs",
        "//antithesis:srcs",
        "//audi:srcs",
        "//brady:srcs",
        "//.claude:srcs",
        "//docs:srcs",
        "//elixir:srcs",
        "//enrico:srcs",
        "//fleet:srcs",
        "//galileo:srcs",
        "//.github:srcs",
        "//lilly:srcs",
        "//lyra:srcs",
        "//marshall:srcs",
        "//marvin:srcs",
        "//mila:srcs",
        "//nix:srcs",
        "//.oss-scanner:srcs",
        "//peach:srcs",
        "//porsche:srcs",
        "//protocol:srcs",
        "//scripts:srcs",
        "//secrets:srcs",
        "//susan:srcs",
        "//tools:srcs",
        "//vendor:srcs",
        "//ziggy:srcs",
        "//buck:srcs",
    ],
    visibility = ["PUBLIC"],
)

[nix_flake_attr(name = "package-" + attr, attr = "packages.x86_64-linux." + attr, labels = ["bootstrap"]) for attr in BOOTSTRAP_PACKAGES]

[nix_flake_attr(name = "check-" + attr, attr = "checks.x86_64-linux." + attr, labels = ["bootstrap", "check"]) for attr in BOOTSTRAP_CHECKS]
