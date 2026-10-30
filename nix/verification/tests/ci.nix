{ lib, checks }:
let
  # @cc [owner:ghuntley,label:verification] ci-check-selection
  # Every exported check MUST carry `meta.ci` so GitHub Actions derives its
  # matrices by evaluation rather than a hand-maintained list. A check is
  # excluded from CI only by name here, never by omission from the catalog.
  excluded = [
  ];

  # Checks that run NixOS machine tests without being one themselves.
  machineAggregates = [ "host-conversion" ];

  # @cc [owner:ghuntley,label:verification;capacity] ci-isolated-heavy-builds
  # Checks whose build closure alone approaches a CI runner's 116 GB store
  # volume (each measured at 60-80 GB) MUST build on a runner of their own;
  # sharing one with other checks exhausted it (publish-cache run
  # 41034532972, shard 0). Isolation only places a check; it never skips it.
  isolatedBuilds = [
    "foreign-linux-guest-filesystem"
    "fleet-guest-trust-configuration"
    "inception-image-builder"
    "ubuntu-build-boundaries"
    "ubuntu-guest-unit"
  ];

  # @cc [owner:ghuntley,label:verification] ci-lazy-required-features
  # Feature discovery MUST preserve enabled NixOS tester requirements, including
  # nested-kvm, without forcing a lazy driver's derivation or guest-image build.
  # The tester exposes requirements through config instead of its lazy wrapper.
  features = check:
    if check ? requiredSystemFeatures then check.requiredSystemFeatures
    else if check ? config && builtins.isAttrs check.config then
      lib.attrNames (lib.filterAttrs (_: enabled: enabled) (check.config.requiredFeatures or { }))
    else [ ];

  ciMeta = name: check: {
    enable = !(builtins.elem name excluded);
    machine = check ? driver || builtins.elem "kvm" (features check)
      || builtins.elem name machineAggregates;
    nestedKvm = builtins.elem "nested-kvm" (features check);
    isolated = builtins.elem name isolatedBuilds;
  };
in
assert lib.all (name: checks ? ${name}) isolatedBuilds;
lib.mapAttrs (name: check:
  check // { meta = (check.meta or { }) // { ci = ciMeta name check; }; }
) checks
