{ pkgs, artifacts }:
# @cc [owner:ghuntley,label:build] mix-build-state-from-mix-release
# Buck2 Mix actions MUST run with the shell state of nixpkgs' mixRelease for
# the pinned OTP variant: the same setup hooks, compiler wrappers, hardening
# flags, PATH and Rebar/Hex paths that `beam.mixRelease` gives its builder.
# The state is captured from a mixRelease derivation itself, so the Buck2
# release cannot drift from the Nix one while both exist (ADR-0269).
let
  inherit (pkgs) lib;
  # Variables that describe one Nix build rather than the toolchain. The Buck2
  # action sets the output, temporary and per-output compiler flags itself.
  denied = lib.concatStringsSep "|" [
    "BASH.*" "BASHOPTS" "SHELLOPTS" "EUID" "PPID" "UID" "GROUPS" "FUNCNAME" "DIRSTACK"
    "PIPESTATUS" "RANDOM" "SRANDOM" "SECONDS" "LINENO" "HISTCMD" "EPOCH.*" "OPTERR"
    "OPTIND" "IFS" "PS4" "PWD" "OLDPWD" "HOME" "TMP" "TMPDIR" "TEMP" "TEMPDIR"
    "NIX_BUILD_TOP" "NIX_ATTRS_JSON_FILE" "NIX_ATTRS_SH_FILE" "NIX_LOG_FD"
    "NIX_BUILD_CORES" "SHLVL" "TERM" "HOSTNAME" "HOSTTYPE" "MACHTYPE" "OSTYPE" "_"
    "out" "outputs" "prefix" "name" "pname" "version" "src" "builder" "buildPhase"
    "installPhase" "configurePhase" "phases" "curPhase" "startTime" "endTime"
    "dontUnpack" "dontFixup" "script" "pkg" "env" "NIX_CFLAGS_COMPILE" "NIX_LDFLAGS"
    "NIX_MAIN_PROGRAM" "mixFodDeps"
  ];
  state = beam: beam.mixRelease {
    pname = "overalls-mix-build-state";
    version = "1";
    src = pkgs.emptyDirectory;
    dontUnpack = true;
    # Non-null so the fixed-output deps hook is installed; actions name their own.
    mixFodDeps = pkgs.emptyDirectory;
    # Marshall's Rustler NIF needs these; other applications ignore them.
    nativeBuildInputs = [ artifacts.cargoWorkspace.rustTools pkgs.pkg-config ];
    configurePhase = ":";
    installPhase = ":";
    dontFixup = true;
    buildPhase = ''
      mkdir -p "$out"
      denied='^(${denied})$'
      while IFS= read -r line; do
        flags=''${line#declare -}; flags=''${flags%% *}
        rest=''${line#declare -* }; var=''${rest%%=*}
        [[ $flags == *r* || $var =~ $denied ]] && continue
        printf '%s\n' "''${line/#declare -/declare -g -}"
      done < <(declare -p) > "$out/state.sh"
      # Exported per-output compiler flags, minus the output-specific parts
      # that the action recomputes for its own output (-frandom-seed, -rpath).
      printf 'declare -g mixStateCflags=%q\n' "''${NIX_CFLAGS_COMPILE/ -frandom-seed=* -isystem/ -isystem}" >> "$out/state.sh"
      declare -f >> "$out/state.sh"
      bash -n "$out/state.sh"
    '';
  };
in
{
  plain = state artifacts.beam;
  encrypted = state artifacts.encrypted.beam;
}
