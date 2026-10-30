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
  # @cc [owner:ghuntley,label:build] devenv-buck2-is-the-wrapper
  # `buck2` in the shell MUST be tools/buck2, which runs the flake-pinned buck2
  # from .buck-cells; the shell MUST NOT install a second buck2 (ADR-0269).
  scripts.buck2.exec = ''
    exec "$DEVENV_ROOT/tools/buck2" "$@"
  '';
  scripts.affected.exec = ''
    exec "$DEVENV_ROOT/tools/affected" "$@"
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

  # The repository precommit (ADR-0269 M8): tools/precommit runs
  # buck/bxl/precommit.bxl, which builds only the checks the changed files
  # affect. `precommit --fix` is the only mode that rewrites files.
  scripts.precommit.exec = ''
    exec "$DEVENV_ROOT/tools/precommit" "$@"
  '';

  # https://devenv.sh/git-hooks/
  # One hook runs tools/precommit over the staged files. It covers what the
  # separate hooks did (conflict markers, pins, rust-lints, ruff format, ruff,
  # ty, the ten per-application logging checks) plus the ADR, contract,
  # package-input-lock and toolchain checks, each only when its inputs change.
  # Merge commits skip ordinary pre-commit hooks, so it also runs at
  # pre-merge-commit. The OVERALLS_PRECOMMIT_* paths are the pinned tools for
  # the direct fallback when Buck2 cannot start.
  git-hooks = {
    enable = true;
    hooks = {
      precommit = {
        enable = true;
        name = "precommit";
        description = "Buck2 precommit checks for the staged files (tools/precommit)";
        entry = "${pkgs.coreutils}/bin/env OVERALLS_PRECOMMIT_ELIXIR=${toolchain.elixir}/bin/elixir OVERALLS_PRECOMMIT_RUFF=${pythonStatic.ruff}/bin/ruff 'OVERALLS_PRECOMMIT_TY=${pythonStatic.ty}/bin/ty ${pythonStatic.tyPython}/bin/python3 ${pythonStatic.harnessPython}/bin/python3 ${pythonStatic.antithesisWheels}' tools/precommit --";
        language = "system";
        always_run = true;
        pass_filenames = true;
        require_serial = true;
        # Every staged path, symlinks included, as the conflict-marker hook saw.
        types = [ ];
        stages = [ "pre-commit" "pre-merge-commit" ];
      };
    };
  };

  # See full reference at https://devenv.sh/reference/options/
}
