# The scope every machine test and test check is instantiated in (ADR-0270).
# A machine test's expression lives in its suite's BUCK `test` attribute;
# nix_assemble writes it next to this file and lib.assemble evaluates it with
# these names in scope. The checks that are not machine tests live in
# nix/assemble/outputs.nix and take the same scope.
{ buildPkgs, testPkgs, nixpkgs, packages, modules, fixtures, kexec, imageSource, diskoModule, diskoSource, nixCompactSource }:
let
  # Keep the application build input separate from the stable NixOS test input.
  service = { pkgs = testPkgs; module = modules.default; inherit packages; };
  # The service inputs with only the named system modules (ADR-0270): the
  # machine test then declares only their files (buck/machine_tests.py).
  serviceOf = names: service // { module = modules.select names; };
  storage = { pkgs = testPkgs; inherit packages; };

  # @cc [owner:ghuntley,label:verification] hegel-framework-packages
  # The Hegel PBT framework (engine, Python binding, test composer) MUST be
  # built against the stable NixOS test package set; tests opt in per-check
  # via `hegel.runTest`.
  hegelLibhegel = import ../hegel/libhegel.nix { pkgs = testPkgs; };
  hegelPython = import ../hegel/hegel-python.nix {
    pkgs = testPkgs;
    libhegel = hegelLibhegel;
  };
  hegel = import ../hegel/run-test.nix { pkgs = testPkgs; inherit hegelPython; };
  featureFleet = options: import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; inherit hegel;
  } // options);
  # The fleet variants fleet-guest-trust-configuration inspects.
  featureFleets = {
    fleet = featureFleet {};
    porsche-fleet = featureFleet { porsche = true; };
    cloning-fleet = featureFleet { porsche = true; cloning = true; };
    brady-fleet = featureFleet { brady = true; };
    customer-isolation-fleet = featureFleet { customerIsolation = true; };
    relocation-fleet = featureFleet { relocation = true; };
    memory-suspension-fleet = featureFleet { relocation = true; suspension = true; audi = true; };
    ubuntu-fleet = featureFleet { ubuntu = true; porsche = true; relocation = true; };
    # Combined sharing surfaces: one member's concurrent Audi SSH, shared
    # terminal viewer and private web under a single direct revocation.
    sharing-surfaces = featureFleet { audi = true; sharingSurfaces = true; };
  };
in
{
  inherit buildPkgs testPkgs nixpkgs packages modules fixtures kexec imageSource diskoModule diskoSource nixCompactSource;
  inherit service serviceOf storage hegel hegelLibhegel hegelPython featureFleet featureFleets;
}
