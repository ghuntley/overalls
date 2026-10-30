{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  builders = import ./remote-builders.nix { inherit lib; };
  # The one deployment's build roles (ADR-0248) come from the fleet host roster.
  inherit ((import ../nix/policy/fleet/hosts.nix { inherit lib; }).deployments.panterloons) builds;
  inherit (builds) participants;
  # Interpolation copies each certificate alone, not the repository source.
  certificate = name: "${./fleet-builds + "/${name}.crt"}";
in
# @cc [owner:ghuntley,label:security] fleet-build-participant-authority
# Participant addresses, CPU counts, systems and features MUST derive from the
# authoritative builder registry; encrypted document paths MUST derive from
# host inventory. Only public certificates are committed in fleet/fleet-builds.
{
  inherit (builds) scheduler;
  tribuchetCaCertificate = certificate "tribuchet-ca";
  grpcCaCertificate = certificate "grpc-ca";
  machines = lib.genAttrs participants (name: {
    inherit (builders.${name}) address logicalCpus systems supportedFeatures;
    tribuchetCertificate = certificate "tribuchet-${name}";
    tribuchetHubCertificate = if name == builds.hub then certificate "tribuchet-hub" else null;
    grpcCertificate = certificate "grpc-${name}";
    encryptedFile = let
      document = lib.findFirst (item: item.name == "${name}-fleet-builds")
        (throw "Missing fleet build credential") inventory.${name}.credentials;
      path = ../. + ("/" + document.path);
    in assert lib.assertMsg (builtins.pathExists path) "Missing fleet build ciphertext"; "${path}";
  });
}
