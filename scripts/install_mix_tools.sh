#!/usr/bin/env bash
set -euo pipefail

# @cc [owner:ghuntley,label:build;security] mix-tool-pins
# Automation that needs Hex or Rebar in MIX_HOME MUST install these exact
# releases and refuse any download whose SHA-512 differs (ADR-0267); it MUST
# NOT run an unpinned `mix local.hex` or `mix local.rebar`. Each digest is the
# one builds.hex.pm lists for the pinned Elixir 1.20 / OTP 29 runtime
# (installs/hex.csv and installs/rebar.csv). Bump a version and its digest
# together, and only with the dev shell's Elixir and OTP releases.
hex_version=2.6.0
hex_url="https://builds.hex.pm/installs/1.20.0/hex-${hex_version}-otp-29.ez"
hex_sha512=686188a060e9919e478baffc331c6481e684ce70993daf410c2517f6d2517b3d3bf6bdab7c1fd927b2e2147f6223276ad9770c2a24613d5eee403ac794f5e134
rebar3_version=3.28.0
rebar3_url="https://builds.hex.pm/installs/1.18.4/rebar3-${rebar3_version}-otp-29"
rebar3_sha512=b51946058fbe4aa823185bfe27204be59be439982ac3a3e1dbd9f8260b9af046fcfdfbd9066283c3fbba5a2a45dc3570550c12a9a548daf223b80cac222a6d0f

mix archive.install "$hex_url" --sha512 "$hex_sha512" --force
mix local.rebar rebar3 "$rebar3_url" --sha512 "$rebar3_sha512" --force
