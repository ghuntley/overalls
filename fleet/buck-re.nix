{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  roster = import ../nix/policy/fleet/hosts.nix { inherit lib; };
  ports = import ../nix/policy/fleet/ports.nix { };
  # The one deployment's cache roles (ADR-0272) come from the fleet host roster.
  inherit ((roster.deploymentOf "panterloons").buildCache) server readers workers;
  address = roster.hosts.${server}.tailnetAddress;
  # Interpolation copies each certificate alone, not the repository source.
  certificate = name: "${./buck-re + "/${name}.crt"}";
  encryptedFile = name: credential: let
    document = lib.findFirst (item: item.name == "${name}-${credential}")
      (throw "Missing buck-re credential") inventory.${name}.credentials;
    path = ../. + ("/" + document.path);
  in assert lib.assertMsg (builtins.pathExists path) "Missing buck-re ciphertext"; "${path}";
in
# @cc [owner:ghuntley,label:security] buck-remote-cache-authority
# The cache server and scheduler, its readers and workers, its tailnet address
# and its ports MUST derive
# from the fleet roster (nix/policy/fleet) and encrypted document paths from
# host inventory. Only public certificates are committed in fleet/buck-re
# (ADR-0272).
{
  forHost = name: lib.optionalAttrs (lib.elem name readers || lib.elem name workers || name == server) {
    encryptedFile = encryptedFile name "buck-re";
    client = lib.optionalAttrs (lib.elem name readers) {
      enable = true;
      inherit address;
      readPort = ports.buckCacheRead;
      caCertificate = certificate "ca";
    };
    server = lib.optionalAttrs (name == server) {
      enable = true;
      listenAddress = address;
      readPort = ports.buckCacheRead;
      uploadPort = ports.buckCacheUpload;
      certificate = certificate "server-${server}";
      readerCaCertificate = certificate "ca";
      uploaderCaCertificate = certificate "uploader-ca";
      execution = {
        enable = true;
        executePort = ports.buckExecute;
        workerPort = ports.buckWorker;
        executorCaCertificate = certificate "executor-ca";
        workerCaCertificate = certificate "worker-ca";
      };
    };
    worker = lib.optionalAttrs (lib.elem name workers) {
      enable = true;
      encryptedFile = encryptedFile name "buck-re-worker";
      schedulerAddress = address;
      port = ports.buckWorker;
      caCertificate = certificate "ca";
      # Half the host's threads: workers share it with Lilly guests.
      maxInflightTasks = roster.hosts.${name}.builder.logicalCpus / 2;
    };
  };
}
