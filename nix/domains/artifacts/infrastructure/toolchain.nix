{ pkgs, encryptedCrashDumps ? false }:

let
  # @cc [owner:ghuntley,label:build] otp-pin-and-analysis-metadata
  # erlang MUST build OTP 29.0.6 from the hash-verified upstream source and retain
  # debug information; changing the pin requires matching project runtime gates.
  erlang = (pkgs.beam_minimal.interpreters.erlang_29.override {
    enableDebugInfo = true;
  }).overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ pkgs.lib.optional encryptedCrashDumps "--enable-encrypted-crash-dumps";
    # Server host certificates are opt-in; ordinary OTP SSH defaults stay unchanged.
    patches = (old.patches or []) ++ [ ../../../platform/patches/otp-ssh-host-certificates.patch ];
    version = "29.0.6";
    src = pkgs.fetchFromGitHub {
      owner = "erlang";
      repo = "otp";
      tag = "OTP-29.0.6";
      hash = (import ../pins.nix).otpSource;
    };
  } // pkgs.lib.optionalAttrs encryptedCrashDumps {
    ERL_CRASH_DUMP_PUBLIC_KEY = "${../build-crash-dump-public.pem}";
  });

  # @cc [owner:ghuntley,label:build] elixir-uses-pinned-otp
  # beam MUST use the overridden erlang package so the Elixir compiler and its
  # runtime agree on the exact OTP build used by releases and Dialyzer.
  beam = pkgs.beamMinimal29Packages.overrideScope (_final: _previous: {
    inherit erlang;
  });
  # @cc [owner:ghuntley,label:build] elixir-pin-and-analysis-metadata
  # elixir MUST build 1.20.4 from the hash-verified upstream source with debug
  # information retained; changing it requires matching project runtime gates.
  elixir = (beam.elixir_1_20.override {
    debugInfo = true;
  }).overrideAttrs (_: {
    version = "1.20.4";
    src = pkgs.fetchFromGitHub {
      owner = "elixir-lang";
      repo = "elixir";
      tag = "v1.20.4";
      hash = (import ../pins.nix).elixirSource;
    };
  } // pkgs.lib.optionalAttrs encryptedCrashDumps {
    ERL_CRASH_DUMP_PUBLIC_KEY = "${../build-crash-dump-public.pem}";
  });
in
{
  inherit erlang elixir;
}
