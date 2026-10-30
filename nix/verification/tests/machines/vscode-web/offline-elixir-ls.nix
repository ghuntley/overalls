{ pkgs, toolchain }:
let
  beamOverrides = _final: _previous: { inherit (toolchain) elixir erlang; };
  beam = if pkgs.beamPackages ? overrideScope then pkgs.beamPackages.overrideScope beamOverrides
    else pkgs.beamPackages.extend beamOverrides;
  source = pkgs.fetchFromGitHub {
    owner = "elixir-lsp";
    repo = "elixir-ls";
    rev = "v0.31.1";
    hash = (import ../../../../domains/artifacts/pins.nix).elixirLsSource;
  };
  dependencies = beam.fetchMixDeps {
    pname = "editor-fixture-elixir-ls-dependencies";
    version = "0.31.1";
    src = source;
    hash = (import ../../../../domains/artifacts/pins.nix).elixirLsMixDeps;
    env.MIX_ENV = "prod";
    env.ERL_FLAGS = "+S 4:4";
  };
in
# @cc [owner:ghuntley,label:verification] offline-elixir-language-fixture
# The fixture MUST compile the real pinned server and dependencies offline.
# Its launcher MUST load that immutable compilation without Mix.install or fetches.
# Hex and clean Mix state MUST be pinned runtime inputs; the fixture MUST NOT
# depend on archives previously bootstrapped in the caller's personal HOME.
# This test-only closure MUST NOT become a default guest language toolchain.
pkgs.stdenv.mkDerivation {
  pname = "editor-fixture-offline-elixir-ls";
  version = "0.31.1";
  src = source;
  nativeBuildInputs = [ toolchain.elixir toolchain.erlang beam.hex pkgs.makeWrapper ];
  env = {
    MIX_ENV = "prod";
    HEX_OFFLINE = "1";
    ERL_FLAGS = "+S 4:4";
    LC_ALL = "C.UTF-8";
  };
  configurePhase = ''
    runHook preConfigure
    export MIX_HOME="$TMPDIR/mix"
    export HEX_HOME="$TMPDIR/hex"
    export MIX_BUILD_PATH="$PWD/.fixture-build"
    mkdir -p "$MIX_HOME" "$HEX_HOME"
    export MIX_DEPS_PATH="$TMPDIR/deps"
    cp --no-preserve=mode -R ${dependencies} "$MIX_DEPS_PATH"
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    mix deps.compile --no-deps-check --skip-umbrella-children
    mix compile --no-deps-check
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin" "$out/share/mix-home" "$out/share/hex-home"
    cp -R .fixture-build/lib/. "$out/lib/"
    makeWrapper ${toolchain.elixir}/bin/elixir "$out/bin/elixir-ls" \
      --add-flags "-pa '$out/lib/*/ebin' -e 'ElixirLS.LanguageServer.main()'" \
      --set MIX_ENV prod --set HEX_OFFLINE 1 --set ERL_FLAGS '+S 4:4' \
      --prefix ERL_LIBS : '${beam.hex}/lib/erlang/lib' \
      --set MIX_HOME "$out/share/mix-home" --set HEX_HOME "$out/share/hex-home"
    runHook postInstall
  '';
}
