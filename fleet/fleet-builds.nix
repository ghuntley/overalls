{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  builders = import ./remote-builders.nix { inherit lib; };
  # The build roles (ADR-0248) of the one deployment that delegates builds come
  # from the fleet host roster; a deployment without delegation declares null.
  builds = lib.findFirst (value: value != null)
    (throw "No fleet deployment delegates builds")
    (map (deployment: deployment.builds) (builtins.attrValues
      (import ../nix/policy/fleet/hosts.nix { inherit lib; }).deployments));
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
  grpcCaCertificate = certificate "grpc-ca";
  machines = lib.genAttrs participants (name: {
    inherit (builders.${name}) address logicalCpus systems supportedFeatures;
    grpcCertificate = certificate "grpc-${name}";
    encryptedFile = let
      document = lib.findFirst (item: item.name == "${name}-fleet-builds")
        (throw "Missing fleet build credential") inventory.${name}.credentials;
      path = ../. + ("/" + document.path);
    in assert lib.assertMsg (builtins.pathExists path) "Missing fleet build ciphertext"; "${path}";
  });
}
