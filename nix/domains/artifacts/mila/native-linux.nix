{ pkgs, lib, journey ? false }:
let
  workspace = import ../infrastructure/cargo-workspace.nix { inherit pkgs; };
  source = workspace.source {
    name = "mila-native-linux-source";
    # The GTK client and the Mila Rust crates it links by path.
    crates = [ "mila/native/linux" ] ++ builtins.filter (lib.hasPrefix "mila/rust/") workspace.members;
    crateFile = _name: _rel: true;
    # build.rs bundles the shared catalogs; tests read protocol vectors.
    extraFiles = [ "mila/localization" "protocol/test/fixtures" ];
  };
in
workspace.rustPlatform.buildRustPackage {
  pname = if journey then "mila-linux-journeys" else "mila-native-linux";
  version = "0.1.0";
  src = source;
  inherit (workspace) cargoLock;
  buildAndTestSubdir = "mila/native/linux";
  # The fixture-only entry point must never enter the normal desktop release.
  buildFeatures = lib.optional journey "gtk-journey";
  # Both variants retain the ordinary tests followed by the opt-in GTK tests.
  checkFeatures = [ ];
  nativeBuildInputs = [ pkgs.pkg-config pkgs.python3 workspace.rustTools ];
  buildInputs = [ pkgs.gtk4 pkgs.libadwaita ];
  # @cc [owner:ghuntley,label:verification] mila-linux-package-required-gtk
  # Package verification MUST execute the GTK widget lifecycle test on a live
  # headless display in both feature configurations; unavailable display MUST fail.
  preCheck = ''
    export GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 GSETTINGS_BACKEND=memory
    export MILA_GTK_TESTS_REQUIRED=1
    ${pkgs.gtk4}/bin/gtk4-broadwayd :5 > "$TMPDIR/mila-broadway.log" 2>&1 &
    mila_broadway_pid=$!
    mila_broadway_cleanup() {
      kill "$mila_broadway_pid" 2>/dev/null || true
    }
    exitHooks+=(mila_broadway_cleanup)
    failureHooks+=(mila_broadway_cleanup)
    python3 - <<'PY'
    import socket
    import time

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", 8085), timeout=0.1):
                break
        except OSError:
            time.sleep(0.1)
    else:
        raise SystemExit("Mila GTK display did not start within ten seconds")
    PY
  '';
  # ADR-0265 gates: formatting and clippy over both feature sets.
  postCheck = ''
    pushd "$buildAndTestSubdir"
    cargo test --locked --offline --features gtk-journey
    cargo fmt --check
    cargo clippy --all-targets --locked --offline -- -D warnings
    cargo clippy --all-targets --locked --offline --features gtk-journey -- -D warnings
    popd
  '';
  # @cc [owner:ghuntley,label:build;verification] mila-linux-release-install
  # Installation MUST use the target platform's release executable, never a
  # host/test binary found by traversal. Only the explicit journey variant may
  # enable gtk-journey or install a fixture driver beside bin/mila.
  installPhase = ''
    runHook preInstall
    release=target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release
    test -x "$release/mila-native-linux"
    mkdir -p "$out/bin" "$out/share/applications"
    install -m755 "$release/mila-native-linux" "$out/bin/mila"
    ${lib.optionalString journey ''
      test -x "$release/mila-linux-journey"
      install -m755 "$release/mila-linux-journey" "$out/bin/mila-linux-journey"
      ln -s ${pkgs.gtk4}/bin/gtk4-broadwayd "$out/bin/mila-broadwayd"
    ''}
    cp "$buildAndTestSubdir/data/dev.overalls.Mila.desktop" "$out/share/applications/"
    test -x "$out/bin/mila"
    ${lib.optionalString (!journey) ''test ! -e "$out/bin/mila-linux-journey"''}
    runHook postInstall
  '';
  meta = {
    description = "Mila native GTK4/libadwaita Linux client";
    mainProgram = "mila";
    platforms = [ "x86_64-linux" ];
  };
}
