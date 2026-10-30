{ pkgs }:
let
  # @cc [owner:ghuntley,label:security;deployment] staging-acme-roots-test-only
  # Audi's staging issuer MUST validate issued leaf chains against only the
  # pinned, official Let's Encrypt staging roots. These deliberately untrusted
  # roots MUST NOT be added to the host or ordinary application trust stores.
  roots = [
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem";
      hash = (import ../nix/domains/artifacts/pins.nix).letsencryptStagingRootX1;
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem";
      hash = (import ../nix/domains/artifacts/pins.nix).letsencryptStagingRootX2;
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/gen-y/root-ye.pem";
      hash = (import ../nix/domains/artifacts/pins.nix).letsencryptStagingRootYE;
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/gen-y/root-yr.pem";
      hash = (import ../nix/domains/artifacts/pins.nix).letsencryptStagingRootYR;
    })
  ];
in
pkgs.runCommand "letsencrypt-staging-roots.pem" { } ''
  for root in ${builtins.concatStringsSep " " roots}; do
    cat "$root" >> "$out"
    printf '\n' >> "$out"
  done
''
