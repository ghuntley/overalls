# @cc [owner:ghuntley,label:build;security] single-pin-registry
# Every third-party fixed-output hash MUST be read from dependency-hashes.json
# through this file (or be derived from a reviewed ecosystem lock file); Nix
# files MUST NOT carry their own inline copies. Exemptions are listed in the
# `pins` check.
builtins.fromJSON (builtins.readFile ./dependency-hashes.json)
