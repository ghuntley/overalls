{ pkgs, lib, config, inputs, ... }:

let
  # @cc [owner:ghuntley,label:build] development-toolchain-source
  # The development shell MUST import the same pinned runtime derivation used
  # by release packaging; enabling Elixir MUST NOT select a second OTP build.
  toolchain = import ./nix/domains/artifacts/infrastructure/toolchain.nix { inherit pkgs; };
  hostLock = import ./nix/domains/artifacts/hosts/host-tools.nix { inherit pkgs; };
  compactNix = inputs.nix-compact.lib.mkPackage { inherit pkgs; };
  # The same patched Firecracker the release metadata points Lilly at.
  inherit (import ./nix/domains/artifacts/infrastructure/firecracker.nix { inherit pkgs; }) vmm;

  # Contract python-static-toolchain: see nix/buck/python.nix.
  pythonStatic = import ./nix/buck/python.nix { inherit pkgs; };
  # Firecracker, Lilly host helpers, network tools and Chromium are Linux-only; a
  # darwin shell omits them instead of refusing to evaluate.
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
{
  # @cc [owner:ghuntley,label:isolation] jailed-vmm-static-runtime
  # outputs.vmm MUST supply a static Firecracker/jailer pair that can run inside
  # the prepared chroot without copying host dynamic libraries into each jail.
  outputs.vmm = vmm;
  outputs.hostTools = pkgs.buildEnv {
    name = "lilly-host-tools";
    paths = [ pkgs.coreutils pkgs.util-linux pkgs.iproute2 pkgs.nftables
      pkgs.procps pkgs.dtach pkgs.openssh toolchain.elixir toolchain.erlang hostLock ];
  };

  # https://devenv.sh/basics/
  env = {
    GREET = "devenv";
    OVERALLS_NIXPKGS_PATH = "${pkgs.path}";
  } // lib.optionalAttrs isLinux {
    OVERALLS_TEST_VMM_DIR = "${vmm}/bin";
  };

  # Pull the repository's shared binary cache before evaluating the shell.
  cachix.pull = [ "overalls" ];
  cachix.push = "overalls";

  # https://devenv.sh/packages/
  packages = [
    compactNix
    pkgs.dtach
    pkgs.openssh
    pkgs.openssl
    pkgs.git
    pkgs.coreutils
    pkgs.util-linux
    pkgs.procps
    pkgs.prek
    pkgs.nodejs
    pkgs.watchexec
    # Regenerates Mila's pubspec.lock.json files (`yq -o=json pubspec.lock`).
    pkgs.yq-go
    pkgs.python3
    pythonStatic.ruff
    pythonStatic.ty
    toolchain.erlang
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    # Mila's macOS and iOS Xcode projects are edited with the xcodeproj gem
    # rather than by hand (ADR-0235).
    (pkgs.ruby.withPackages (gems: [ gems.xcodeproj ]))
    # Native Apple targets: macOS's openrsync drops the --chmod flag when it copies
    # passes when it copies its read-only Nix-store framework.
    pkgs.rsync
  ] ++ lib.optionals isLinux [
    hostLock
    vmm
    # Mila's native GTK4/libadwaita client and its Rust pkg-config probes.
    pkgs.gtk4
    pkgs.libadwaita
    pkgs.pkg-config
    pkgs.iproute2
    pkgs.nftables
    pkgs.chromium
  ];

  # https://devenv.sh/languages/
  languages.elixir.enable = true;
  languages.elixir.package = toolchain.elixir;
  languages.rust.enable = true;
  # nixpkgs' rustc ships only the host standard library. On Darwin, take the
  # same release from rust-overlay with the iOS targets mila-build needs.
  languages.rust.channel = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin "stable";
  languages.rust.version = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin "1.97.1";
  languages.rust.targets = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin [
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
  ];

  # @cc [owner:ghuntley,label:build] development-shell-prompt
  # Interactive devenv shells MUST initialize the Starship prompt.
  starship.enable = true;

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts.hello.exec = ''
    echo hello from $GREET
  '';
  # @cc [owner:ghuntley,label:build] marvin-development-commands
  # Development commands MUST install only lockfile-pinned tools, with install
  # scripts disabled, and invoke the same build/check source as release packaging.
  scripts.marvin-build.exec = ''
    cd "$DEVENV_ROOT/marvin"
    npm ci --ignore-scripts
    npm run build
    npm run package
  '';
  scripts.marvin-check.exec = ''
    cd "$DEVENV_ROOT/marvin"
    npm ci --ignore-scripts
    ${if isLinux
      then ''export CHROME="${lib.getExe pkgs.chromium}"''
      else ''export CHROME="''${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"''}
    npm run check
    npm run smoke:chrome
  '';
  scripts.marvin-watch.exec = ''
    cd "$DEVENV_ROOT/marvin"
    npm ci --ignore-scripts
    ${lib.getExe pkgs.watchexec} --watch common --watch scripts --watch types --watch package.json --watch package-lock.json --watch tsconfig.json --watch README.md --watch CONTRACTS -- npm run build
  '';

  # https://devenv.sh/basics/
  enterShell = ''
    # Release derivations deliberately build Cedar from vendored inputs offline;
    # the interactive development shell may fetch the pinned crate when its
    # cache is cold so local compilation is reproducible instead of failing on
    # an unrelated missing Cargo cache entry.
    export CARGO_NET_OFFLINE=false
    hello         # Run scripts directly
    git --version # Use packages
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # The Rust core is checked independently while native clients remain the current
  # presentation client. Nix runs the same locked workspace check offline.
  scripts.mila-rust-check.exec = ''
    cd "$DEVENV_ROOT/mila/rust"
    cargo fmt --all -- --check
    cargo test --workspace --locked
    cargo clippy --workspace --all-targets --locked -- -D warnings
  '';
  scripts.mila-rust-build.exec = ''
    cd "$DEVENV_ROOT/mila/rust"
    cargo build --workspace --locked
  '';
  # Native Apple app targets (ADR-0235); see mila/native/apple/README.md.
  scripts.mila-build.exec = ''
    exec "$DEVENV_ROOT/mila/native/mila-build" "$@"
  '';
  scripts.mila-run.exec = ''
    exec "$DEVENV_ROOT/mila/native/apple/run.sh" "$@"
  '';

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';

  # Linked worktrees share the common .git/hooks, so every shell entry would
  # rewrite the one pre-commit hook to load its own worktree's config. Give
  # each linked worktree its own hooks directory before the installer runs;
  # the main checkout keeps .git/hooks.
  tasks."overalls:worktree-hooks" = {
    exec = ''
      git=${pkgs.git}/bin/git
      if dir=$($git rev-parse --path-format=absolute --git-dir 2>/dev/null) &&
         common=$($git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
         [ "$dir" != "$common" ]; then
        $git config extensions.worktreeConfig true
        mkdir -p "$dir/hooks"
        [ "$($git config --worktree --get core.hooksPath || true)" = "$dir/hooks" ] ||
          $git config --worktree core.hooksPath "$dir/hooks"
      fi
    '';
    before = [ "devenv:git-hooks:install" ];
  };

  # https://devenv.sh/git-hooks/
  # The Python gates run through prek with the pinned ruff and ty; the same
  # checks run in CI as the python-static Nix check. The structured-event
  # logging gate runs per application through the same pinned Elixir as the
  # releases, matching each project's logging.check precommit alias.
  git-hooks = {
    enable = true;
    hooks = {
      # Merge commits skip ordinary pre-commit hooks, so this guard also runs
      # at pre-merge-commit; the conflict-markers Nix check covers CI.
      conflict-markers = {
        enable = true;
        name = "conflict-markers";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_conflict_markers.exs";
        language = "system";
        always_run = true;
        pass_filenames = false;
        stages = [ "pre-commit" "pre-merge-commit" ];
      };
      # Third-party fixed-output hashes come only from dependency-hashes.json
      # or lock files; the pins Nix check covers CI.
      pins = {
        enable = true;
        name = "pins";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_pins.exs";
        language = "system";
        files = "(\\.nix|dependency-hashes\\.json)$";
        pass_filenames = false;
      };
      # ADR-0265: adopted crates keep the canonical lint block, clippy.toml
      # and a reason on every lint exception; the rust-lints Nix check covers CI.
      rust-lints = {
        enable = true;
        name = "rust-lints";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_rust_lints.exs --strict";
        language = "system";
        files = "(Cargo\\.toml|clippy\\.toml|\\.rs|scripts/rust/.*)$";
        pass_filenames = false;
      };
      python-ruff-format = {
        enable = true;
        name = "ruff-format";
        description = "Check Python formatting with ruff";
        entry = "${pythonStatic.ruff}/bin/ruff format --check --force-exclude";
        language = "system";
        files = "\\.py$";
      };
      python-ruff = {
        enable = true;
        name = "ruff";
        description = "Lint Python with ruff";
        entry = "${pythonStatic.ruff}/bin/ruff check --force-exclude";
        language = "system";
        files = "\\.py$";
      };
      python-ty = {
        enable = true;
        name = "ty";
        description = "Type-check Python with ty";
        entry = "${pkgs.bash}/bin/bash antithesis/verification/static-check.sh ${pythonStatic.ty}/bin/ty ${pythonStatic.tyPython}/bin/python3 ${pythonStatic.harnessPython}/bin/python3 ${pythonStatic.antithesisWheels}";
        language = "system";
        files = "\\.py$";
        pass_filenames = false;
      };
      elixir-logging-marshall = {
        enable = true;
        name = "logging-check-marshall";
        description = "Enforce the Marshall structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs marshall";
        language = "system";
        files = "^(marshall/(lib|config)/.*\\.exs?$|marshall/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-lilly = {
        enable = true;
        name = "logging-check-lilly";
        description = "Enforce the Lilly structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs lilly";
        language = "system";
        files = "^(lilly/(lib|config)/.*\\.exs?$|lilly/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-audi = {
        enable = true;
        name = "logging-check-audi";
        description = "Enforce the Audi structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs audi";
        language = "system";
        files = "^(audi/(lib|config)/.*\\.exs?$|audi/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-galileo = {
        enable = true;
        name = "logging-check-galileo";
        description = "Enforce the Galileo structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs galileo";
        language = "system";
        files = "^(galileo/(lib|config)/.*\\.exs?$|galileo/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-peach = {
        enable = true;
        name = "logging-check-peach";
        description = "Enforce the Peach structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs peach";
        language = "system";
        files = "^(peach/(lib|config)/.*\\.exs?$|peach/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-susan = {
        enable = true;
        name = "logging-check-susan";
        description = "Enforce the Susan structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs susan";
        language = "system";
        files = "^(susan/(lib|config)/.*\\.exs?$|susan/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-enrico = {
        enable = true;
        name = "logging-check-enrico";
        description = "Enforce the Enrico structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs enrico";
        language = "system";
        files = "^(enrico/(lib|config)/.*\\.exs?$|enrico/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-brady = {
        enable = true;
        name = "logging-check-brady";
        description = "Enforce the Brady structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs brady";
        language = "system";
        files = "^(brady/(lib|config)/.*\\.exs?$|brady/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-ziggy = {
        enable = true;
        name = "logging-check-ziggy";
        description = "Enforce the Ziggy structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs ziggy";
        language = "system";
        files = "^(ziggy/(lib|config)/.*\\.exs?$|ziggy/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
      elixir-logging-porsche = {
        enable = true;
        name = "logging-check-porsche";
        description = "Enforce the Porsche structured-event catalog";
        entry = "${toolchain.elixir}/bin/elixir scripts/check_logging.exs porsche";
        language = "system";
        files = "^(porsche/(lib|config)/.*\\.exs?$|porsche/mix\\.exs$|scripts/check_logging\\.exs$)";
        pass_filenames = false;
      };
    };
  };

  # See full reference at https://devenv.sh/reference/options/
}
