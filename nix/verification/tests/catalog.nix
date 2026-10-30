{ buildPkgs, testPkgs, nixpkgs, packages, modules, fixtures, kexec, imageSource, diskoModule, diskoSource }:
let
  # Keep the application build input separate from the stable NixOS test input.
  service = { pkgs = testPkgs; module = modules.default; inherit packages; };
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
  # Keep the engine/binding smoke suite as an explicit check.  Machine tests
  # depend on these packages transitively, but that does not make shrinking,
  # replay mismatch handling, or concurrent state-machine cleanup observable
  # when no migrated machine is selected by a CI matrix.
  hegel-framework-packages = buildPkgs.linkFarm "overalls-hegel-framework-packages" [
    { name = "libhegel"; path = hegelLibhegel; }
    { name = "python"; path = hegelPython; }
  ];
  featureFleet = options: import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; inherit hegel;
  } // options);
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
# @cc [owner:ghuntley,label:verification] explicit-check-catalog
# Every current required check MUST be explicitly exported. Superseded checks
# MUST be replaced in the documented catalog without compatibility aliases.
# Release checks MUST use buildPkgs; machine checks MUST use testPkgs.
buildPkgs.lib.genAttrs [ "marshall-release" "lilly-release" "audi-release" "porsche-release" "ziggy-release" "brady-release" "galileo-release" "enrico-release" "peach-release" "susan-release" ] (name:
  let application = buildPkgs.lib.removeSuffix "-release" name;
  in import ./release {
    pkgs = buildPkgs;
    inherit application;
    package = packages.${application};
    inherit (packages) toolchain;
  }) // {
  hegel-framework-packages = hegel-framework-packages;
  team-ssh = import ./machines/team-ssh service;
  vscode-web-package = import ./machines/vscode-web { pkgs = testPkgs; inherit packages; };
  windows-editor-acceptance-harness = import ./machines/windows-editor { pkgs = testPkgs; inherit packages; };
  vscode-web-broker = packages.vscodeWebBroker;
  vscode-web-extensions = import ../../domains/artifacts/vscode-web/check-extensions.nix {
    pkgs = buildPkgs;
    vscodeWeb = packages.vscodeWeb;
  };
  vscode-web-nixos-fleet = featureFleet { editor = true; audi = true; };
  vscode-web-ubuntu-fleet = featureFleet { editor = true; audi = true; ubuntu = true; };
  vscode-web-arch-fleet = featureFleet { editor = true; audi = true; editorFamily = "arch"; };
  vscode-web-almalinux-fleet = featureFleet { editor = true; audi = true; editorFamily = "almalinux"; };
  coding-clis-nixos-fleet = featureFleet { codingClis = true; };
  coding-clis-ubuntu-fleet = featureFleet { codingClis = true; ubuntu = true; };
  database-recovery = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; };
  database-recovery-active = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; activeHolder = true; };
  database-recovery-silent = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; faultMode = "silent"; };
  database-recovery-asymmetric = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; faultMode = "asymmetric"; };
  database-recovery-active-silent = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; activeHolder = true; faultMode = "silent"; };
  database-recovery-active-asymmetric = import ./machines/database-recovery { pkgs = testPkgs; inherit packages; activeHolder = true; faultMode = "asymmetric"; };
  teams-browser = import ./machines/teams service;
  scim = import ./machines/scim service;
  installer-trust = import ./machines/installer-trust service;
  admin-account-browser = import ./machines/admin-account service;
  localization-account-porsche = import ./machines/localization service;
  control-room-browser = import ./machines/control-room service;
  credential-self-service-browser = import ./machines/credential-self-service service;
  job-history-browser = import ./machines/job-history service;
  mfa-login-browser = import ./machines/mfa-login service;
  ziggy-service = import ./machines/ziggy-service service;
  agent-cli = import ./machines/agent-cli { pkgs = testPkgs; inherit packages hegel; };
  ziggy-underclass = import ./machines/ziggy-underclass service;
  fleet-network = import ./machines/fleet-network { pkgs = testPkgs; };
  galileo-service = import ./machines/galileo-service service;
  github-integration = import ./machines/github-integration service;
  github-integration-fleet = featureFleet { githubIntegration = true; audi = true; galileo = true; };
  github-integration-ubuntu-fleet = featureFleet { githubIntegration = true; githubFamily = "ubuntu"; audi = true; galileo = true; };
  github-integration-arch-fleet = featureFleet { githubIntegration = true; githubFamily = "arch"; audi = true; galileo = true; };
  github-integration-almalinux-fleet = featureFleet { githubIntegration = true; githubFamily = "almalinux"; audi = true; galileo = true; };
  github-integration-windows-fleet = featureFleet { githubIntegration = true; githubFamily = "windows"; audi = true; galileo = true; };
  enrico-service = import ./machines/enrico-service { pkgs = testPkgs; module = modules.services.enrico; inherit packages; };
  git-mirrors-browser = import ./machines/git-mirrors service;
  underclass-package = packages.underclass;
  underclass-configuration = import ./evaluation/underclass.nix {
    pkgs = testPkgs; inherit nixpkgs; module = modules.default;
  };
  underclass-service = import ./machines/underclass-service (service // { inherit hegel; });
  underclass-egress = import ./machines/underclass-egress service;
  underclass-slo = import ./machines/underclass-slo service;
  porsche-service = import ./machines/porsche-service service;
  push-notifications = import ./machines/push-notifications service;
  mila-journey = import ./machines/mila-journey service;
  push-relay = import ./machines/push-relay service;
  porsche-secrets = import ./machines/porsche-secrets service;
  # Susan push relay (ADR-0224): service limits/replay/audit, SOPS custody and
  # the OCI image. Susan is deployed independently of every Marshall.
  susan-service = import ./machines/susan-service service;
  susan-secrets = import ./machines/susan-secrets service;
  # SOPS-delivered fleet addresses and runtime firewall rules (ADR-0233).
  fleet-addresses = import ./machines/fleet-addresses service;
  susan-image = import ./machines/susan-image { pkgs = testPkgs; inherit packages; };
  porsche-crash-dumps = import ./machines/porsche-crash-dumps service;
  administrative-ssh = import ./machines/administrative-ssh service;
  porsche-configuration = import ./evaluation/porsche.nix { pkgs = testPkgs; module = modules.default; };
  logging-transports = import ./evaluation/logging.nix { pkgs = testPkgs; inherit packages; };
  encrypted-crash-dumps = buildPkgs.runCommand "overalls-encrypted-crash-dumps" { nativeBuildInputs = [ buildPkgs.python3 buildPkgs.openssl ]; } ''
    python3 ${./evaluation/encrypted-crash-dumps.py} ${packages.encrypted.toolchain.erlang}/bin/erl
    touch $out
  '';
  logging = import ./machines/logging { pkgs = testPkgs; };
  log-store = import ./machines/log-store { pkgs = testPkgs; };
  public-grafana = import ./machines/public-grafana { pkgs = testPkgs; module = modules.default; };
  public-grafana-configuration = import ./evaluation/public-grafana.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
  proxy-runtime-address = import ./machines/proxy-runtime-address { pkgs = testPkgs; module = modules.default; };
  runtime-socket-configuration =import ./evaluation/runtime-socket.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
  trace-spool-native = import ./machines/trace-spool { pkgs = testPkgs; };
  otel-fleet = import ./machines/otel-fleet { pkgs = testPkgs; };
  otel-burn-delivery = import ./machines/otel-burn-delivery { pkgs = testPkgs; inherit hegel; };
  otel-marshall = import ./machines/otel-marshall service;
  otel-request-recorder = import ./machines/otel-request-recorder { pkgs = testPkgs; inherit (packages) toolchain; inherit hegel; };
  otel-request-recorder-commit-reply-loss = import ./machines/otel-request-recorder {
    pkgs = testPkgs; inherit (packages) toolchain; inherit hegel; commitReplyLoss = true;
  };
  otel-slo-rules = import ./evaluation/otel-slo-rules.nix { pkgs = buildPkgs; };
  telemetry-diagnostics = import ./evaluation/telemetry-diagnostics.nix { pkgs = buildPkgs; };
  application-metrics = import ./machines/application-metrics service;
  relocation-diagnostics = buildPkgs.runCommand "overalls-relocation-diagnostics-tests" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    python3 -W error ${./evaluation/relocation-diagnostics.py} ${./machines/fleet/relocation-diagnostics.py}
    touch "$out"
  '';
  fleet-monitor = buildPkgs.runCommand "overalls-fleet-monitor-tests" { nativeBuildInputs = [ (buildPkgs.python3.withPackages (p: [ p.hypothesis ])) ]; } ''
    python3 ${./evaluation/fleet-monitor.py} ${../../domains/system/fleet-exporter/metrics.py} ${../../domains/system/fleet-exporter}/runtime.py
    python3 ${./evaluation/fleet-exporter.py} ${../../domains/system/fleet-exporter}
    python3 ${./evaluation/terminal-metrics.py} ${../../domains/system/fleet-exporter/terminal_metrics.py}
    touch $out
  '';
  brady-storage = buildPkgs.runCommand "brady-storage-tests" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
    python3 ${./evaluation/brady-storage.py} ${../../domains/system/brady/storage.py}
    touch $out
  '';
  brady-configuration = import ./evaluation/brady.nix { pkgs = testPkgs; module = modules.default; };
  brady-large-storage = import ./machines/brady-network { pkgs = testPkgs; inherit packages; storage = true; large = true; };
  brady-native-storage = import ./machines/brady-network { pkgs = testPkgs; inherit packages; storage = true; };
  brady-network = import ./machines/brady-network { pkgs = testPkgs; inherit packages; };
  brady-flow = import ./machines/brady-flow { pkgs = testPkgs; inherit packages; };
  vm-watch = import ./machines/vm-watch { pkgs = testPkgs; inherit packages; };
  fleet-exporter-native = import ./machines/fleet-exporter service;
  fleet-monitor-configuration = import ./evaluation/fleet-monitor.nix { pkgs = testPkgs; module = modules.default; };
  remote-builders = import ./machines/remote-builders service;
  remote-builders-configuration = import ./evaluation/remote-builders.nix { pkgs = testPkgs; inherit nixpkgs; module = modules.default; };
  fleet-roster = import ./evaluation/fleet-roster.nix { pkgs = buildPkgs; };
  fleet-builds = import ./machines/fleet-builds (service // { fleetModule = modules.fleetBuilds; });
  access = import ./machines/access { pkgs = testPkgs; module = modules.security.access; };
  access-configuration = import ./evaluation/access.nix {
    pkgs = testPkgs; inherit nixpkgs;
    accessModule = modules.security.access; secretsModule = modules.security.secrets;
  };
  fleet-firewall-configuration = import ./evaluation/fleet-firewall.nix {
    pkgs = testPkgs; inherit nixpkgs; module = modules.network.fleet-firewall;
  };
  secret-reconciliation = import ./evaluation/secrets.nix { pkgs = buildPkgs; };
  auto-update-compatibility = import ./evaluation/auto-update-compatibility.nix { pkgs = buildPkgs; };
  auto-update-custody = import ./evaluation/auto-update-custody.nix { pkgs = buildPkgs; };
  ubuntu-build-boundaries = import ./evaluation/ubuntu-build-boundaries.nix { pkgs = buildPkgs; inherit packages; };
  ubuntu-guest-unit = import ./evaluation/ubuntu-guest.nix { pkgs = buildPkgs; inherit packages; };
  foreign-linux-guest-unit = import ./evaluation/foreign-linux-guests.nix { pkgs = buildPkgs; inherit packages; };
  foreign-linux-guest-filesystem = import ./evaluation/foreign-linux-filesystem.nix { pkgs = buildPkgs; inherit packages; };
  foreign-linux-pam-helper = import ./evaluation/foreign-linux-pam-helper.nix { pkgs = buildPkgs; inherit packages; };
  editor-target-boundaries = import ./evaluation/editor-target-boundaries.nix { pkgs = buildPkgs; inherit packages; };
  windows-editor-runtime = import ./evaluation/windows-editor-runtime.nix { pkgs = buildPkgs; inherit packages; };
  native-os-guest-unit = import ./evaluation/native-os-guests.nix { pkgs = buildPkgs; inherit packages; };
  native-image-promotion = packages.nativeImagePromotionChecks;
  # Windows guest spike (ADR-0169): VMM identity, firmware provenance and the
  # offline image assembly rules, without installing or booting Windows.
  firecracker-vmm = import ./evaluation/firecracker-vmm.nix { pkgs = buildPkgs; inherit packages; };
  firecracker-patch-tests = import ./evaluation/firecracker-patch-tests.nix { pkgs = buildPkgs; inherit packages; };
  native-vsock-core = import ../../domains/artifacts/guest/native-kernels/common { pkgs = buildPkgs; };
  native-fixture-unit = import ./evaluation/native-fixtures.nix { pkgs = buildPkgs; };
  native-reset-probes = import ./evaluation/native-reset-probes.nix { pkgs = buildPkgs; inherit packages; };
  native-freebsd-reset = import ./machines/native-reset { pkgs = testPkgs; inherit packages; };
  android-emulator-software = import ./machines/android-emulator { pkgs = testPkgs; inherit packages; };
  android-guest-unit = import ./evaluation/android-guest.nix { pkgs = buildPkgs; inherit packages; };
  android-firecracker = import ./machines/zfs-guest {
    pkgs = testPkgs;
    inherit packages;
    guest = packages.androidGuest;
    android = true;
  };
  native-freebsd-transport = import ./machines/native-transport { pkgs = testPkgs; inherit packages; };
  native-freebsd-wrong-cid = import ./machines/native-transport { pkgs = testPkgs; inherit packages; faultInjection = true; };
  native-freebsd-services = import ./machines/native-services { pkgs = testPkgs; inherit packages; };
  github-tools-freebsd-retained = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.freebsdGuest; github = true;
  };
  github-tools-illumos-retained = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest; osName = "illumos"; github = true;
  };
  native-freebsd-isolation = import ./machines/native-services { pkgs = testPkgs; inherit packages; isolation = true; };
  native-freebsd-growth = import ./machines/native-services { pkgs = testPkgs; inherit packages; growth = true; };
  native-freebsd-recovery = import ./machines/native-services { pkgs = testPkgs; inherit packages; recovery = true; };
  native-freebsd-crash-recovery = import ./machines/native-services { pkgs = testPkgs; inherit packages; crash = true; };
  # OmniOS/illumos uses the separately promoted image. The explicit admission
  # opt-in keeps these test receipts scoped to verification; each runner still
  # emits native_admission=false. Formal OmniOS transport/reset instead use the
  # non-admitted Nix KVM-assembled candidate, whose test-only manifest binds the
  # transport token, assembly receipt and raw disk the runners require.
  native-omnios-transport = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosImageCandidate;
    osName = "illumos"; transport = true;
    transportProbe = "${packages.lyra.native.probes}/bin/x86_64-unknown-illumos-overalls-native-transport-probe";
    transportBuildId = packages.omniosImageCandidate.buildId;
  };
  native-omnios-reset = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosImageCandidate;
    osName = "illumos"; transportReset = true;
    transportProbe = "${import ./evaluation/native-reset-probes.nix { pkgs = buildPkgs; inherit packages; }}/bin/illumos-reset-probe";
    transportBuildId = packages.omniosImageCandidate.buildId;
  };
  native-omnios-services = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest;
    osName = "illumos"; allowNativeAdmission = true;
  };
  native-omnios-isolation = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest;
    osName = "illumos"; isolation = true; allowNativeAdmission = true;
  };
  native-omnios-growth = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest;
    osName = "illumos"; growth = true; allowNativeAdmission = true;
  };
  native-omnios-recovery = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest;
    osName = "illumos"; recovery = true; allowNativeAdmission = true;
  };
  native-omnios-crash-recovery = import ./machines/native-services {
    pkgs = testPkgs; inherit packages; image = packages.omniosGuest;
    osName = "illumos"; crash = true; allowNativeAdmission = true;
  };
  # Native durability (ADR-0190, ADR-0243): interrupted root growth, host power loss
  # replayed from a dm-log-writes journal, and two-host ZFS relocation.
  native-freebsd-interrupted-growth = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "interrupted-growth";
  };
  native-freebsd-power-loss = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "power-loss";
  };
  native-freebsd-relocation = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "relocation";
  };
  native-omnios-interrupted-growth = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "interrupted-growth";
    image = packages.omniosGuest; osName = "illumos"; allowNativeAdmission = true;
  };
  native-omnios-power-loss = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "power-loss";
    image = packages.omniosGuest; osName = "illumos"; allowNativeAdmission = true;
  };
  native-omnios-relocation = import ./machines/native-durability {
    pkgs = testPkgs; inherit packages; scenario = "relocation";
    image = packages.omniosGuest; osName = "illumos"; allowNativeAdmission = true;
  };
  windows-firmware = packages.windowsFirmware;
  windows-guest-unit = import ./evaluation/windows-guest.nix { pkgs = buildPkgs; inherit packages; };
  # Long-running: builds the evaluation-ISO Windows image (unattended install
  # under KVM) and boots it under the patched Firecracker to the SAC prompt.
  windows-guest = import ./machines/windows-guest { pkgs = testPkgs; inherit packages; };
  # Long-running: places the Windows image through the real Lilly driver on
  # nested KVM (ADR-0170): firmware bundle, skipped trust, unattested
  # provisioning, MMDS-configured /32 reachable from the host, SAC on the boot log.
  windows-lilly-guest = import ./machines/windows-lilly-guest { pkgs = testPkgs; inherit packages; };
  # Long-running: the windows-v1 image through the real Lilly driver: trust
  # installed by the guest, provisioning ready with a guest boot identity.
  windows-lilly-guest-agents = import ./machines/windows-lilly-guest {
    pkgs = testPkgs;
    inherit packages;
    guest = packages.windowsGuestAgents;
    agents = true;
  };
  guest-readiness = import ./evaluation/guest-readiness.nix { pkgs = buildPkgs; };
  image-copy = import ./machines/image-copy { pkgs = testPkgs; inherit packages; };
  image-template = import ./machines/image-template { pkgs = testPkgs; inherit packages; };
  guest-ssh = import ./evaluation/guest-ssh.nix { pkgs = buildPkgs; };
  guest-flush = import ./evaluation/guest-flush.nix { pkgs = buildPkgs; };
  guest-toolset = import ./evaluation/guest-toolset.nix { pkgs = buildPkgs; };
  python-static = import ./evaluation/python-static.nix { pkgs = buildPkgs; };
  backup-types = import ./evaluation/backup-types.nix { pkgs = buildPkgs; };
  backup-operators = import ./evaluation/backup-operators.nix { pkgs = buildPkgs; };
  backup-custody = import ./evaluation/backup-custody.nix { pkgs = buildPkgs; };
  backup-configuration = import ./evaluation/backup-configuration.nix { pkgs = testPkgs; module = modules.default; };
  backup-recovery = import ./machines/backups service;
  guest-backups = import ./machines/zfs-guest { pkgs = testPkgs; inherit packages; backups = true; };
  zfs-guest-clone = import ./machines/zfs-guest (storage // { cloneMatrix = true; });
  private-services-guest = import ./evaluation/private-services.nix { pkgs = buildPkgs; };
  audi-private-pki = import ./evaluation/private-pki.nix { pkgs = buildPkgs; };
  inception-runtime = import ./evaluation/inception-runtime.nix { pkgs = buildPkgs; inherit (packages) toolchain; };
  inception-ssh-host-ca = import ./machines/inception-ssh-host-ca { pkgs = testPkgs; };
  inception-image-builder = import ./evaluation/inception-image-builder.nix { pkgs = buildPkgs; inherit packages; };
  inception-probe = import ./evaluation/inception-probe.nix { pkgs = testPkgs; };
  inception-systemd = import ./evaluation/inception-systemd.nix { pkgs = testPkgs; };
  inception-proof-broker = buildPkgs.runCommand "inception-proof-broker-check" { nativeBuildInputs = [ buildPkgs.python3 ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    python3 -W error ${./evaluation/inception-proof-broker.py} ${../../domains/artifacts/guest/inception} ${packages.audi}/bin/audi
    touch $out
  '';
  module-configuration = import ./evaluation/module-configuration.nix {
    pkgs = testPkgs;
    inherit nixpkgs;
    module = modules.default;
    sysctlModule = modules.platform.sysctl;
  };
  storage-configuration = import ./evaluation/storage-configuration.nix {
    pkgs = testPkgs;
    inherit fixtures;
  };
  smtp-relay = import ./machines/smtp-relay service;
  enrollment-operator = import ./machines/enrollment-operator service;
  service-roles = import ./machines/service-roles service;
  ziggy-configuration = import ./evaluation/ziggy.nix { pkgs = testPkgs; module = modules.default; inherit packages; };
  audi-configuration = import ./evaluation/audi.nix { pkgs = testPkgs; module = modules.default; };
  audi-service = import ./machines/audi-service service;
  audi-dns = import ./machines/audi-dns service;
  ssh-host-certificates = import ./machines/ssh-host-certificates storage;
  audi-openssh = import ./machines/audi-openssh storage;
  sysctl = import ./machines/sysctl { pkgs = testPkgs; module = modules.platform.sysctl; };
  nix-ld = import ./machines/nix-ld { pkgs = testPkgs; };
  auto-update = import ./machines/auto-update service;
  nix-gc-configuration = import ./evaluation/nix-gc.nix {
    pkgs = testPkgs; inherit nixpkgs; module = modules.default; inherit fixtures;
  };
  nix-cache-configuration = import ./evaluation/nix-cache.nix {
    pkgs = testPkgs; inherit nixpkgs fixtures; module = modules.default;
  };
  tailscale-configuration = import ./evaluation/tailscale.nix {
    pkgs = testPkgs; inherit nixpkgs; module = modules.default; inherit fixtures;
  };
  audi-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; audi = true; });
  ssh-bootstrap-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; sshBootstrap = true;
  });
  ssh-bootstrap-ubuntu-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; sshBootstrap = true; ubuntu = true;
  });
  ssh-roster-matrix-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; sshRosterMatrix = true;
  });
  ssh-roster-matrix-ubuntu-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; sshRosterMatrix = true; ubuntu = true;
  });
  user-ssh-journey-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; relocation = true; userSshJourney = true;
  });
  user-ssh-journey-ubuntu-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; relocation = true; userSshJourney = true; ubuntu = true;
  });
  audi-ubuntu-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; audi = true; ubuntu = true; });
  audi-ubuntu-relocation-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; audi = true; ubuntu = true; relocation = true; });
  audi-relocation-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; });
  galileo-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; relocation = true; galileo = true;
  });
  agent-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true;
  });
  otel-guest-native = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; otelGuest = true;
  });
  otel-galileo-native = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; relocation = true; otelGalileo = true;
  });
  otel-audi-ssh-native = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; otelAudiSsh = true;
  });
  otel-porsche-native = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; otelPorsche = true;
  });
  agent-cli-journey = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; agentCli = true;
  });
  executor-loss = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; agentCli = true; executorLoss = true;
  });
  guest-cli-recovery = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; guestCliRecovery = true;
  });
  guest-cli-recovery-ubuntu = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; guestCliRecovery = true; ubuntu = true;
  });
  # Server tools end to end through a real guest (plan: artifacts, thread tool).
  artifact-agent-publish = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; artifactAgentPublish = true;
  });
  thread-tool = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; threadTool = true;
  });
  agent-ubuntu-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; galileo = true; agent = true; ubuntu = true;
  });
  ubuntu-fleet = featureFleets.ubuntu-fleet;
  porsche-fleet = featureFleets.porsche-fleet;
  porsche-threads = featureFleet { porsche = true; porscheThreads = true; };
  porsche-lifecycle-fleet = featureFleet { porsche = true; porscheLifecycleOnly = true; };
  porsche-lifecycle-ubuntu-fleet = featureFleet {
    porsche = true; porscheLifecycleOnly = true; ubuntu = true; relocation = true;
  };
  fleet-guest-trust-configuration = import ./evaluation/fleet-guest-trust.nix {
    pkgs = buildPkgs; variants = featureFleets;
  };
  fleet-guest-trust = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; ubuntu = true; guestTrust = true;
  });
  private-web = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; galileo = true; teamResources = true; privateWeb = true;
  });
  integration-renewals = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; galileo = true; teamResources = true; integrationRenewals = true;
  });
  team-resources = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; galileo = true; teamResources = true;
  });
  maintenance-evacuation = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; maintenanceEvacuation = true;
  });
  host-replacement = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; hostReplacement = true;
  });
  clone-cancellation = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; cloneCancellation = true;
  });
  clone-destination-loss = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; cloning = true; cloneDestinationLoss = true;
  });
  clone-marshall-restart = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; cloning = true; cloneMarshallRestart = true;
  });
  resize-browser = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; resize = true;
  });
  account-lifecycle = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; accountLifecycle = true;
  });
  account-lifecycle-ubuntu = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; audi = true; porsche = true; accountLifecycle = true; ubuntu = true;
  });
  default-oss-creation = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; audi = true; defaultOss = true;
  });
  repository-launch = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; audi = true; repositoryLaunch = true;
  });
  repository-launch-ubuntu-fleet = import ./machines/fleet (service // {
    hostFixture = fixtures.hetzner-uefi; porsche = true; audi = true; repositoryLaunch = true; ubuntu = true;
  });
  cloning-fleet = featureFleets.cloning-fleet;
  brady-fleet = featureFleets.brady-fleet;
  lilly-runtime-readiness = featureFleet { runtimeReadiness = true; };
  lilly-observability-recovery = featureFleet { runtimeReadiness = true; observabilityRecovery = true; };
  fleet = featureFleets.fleet;
  terminal-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; terminal = true; audi = true; });
  terminal-ubuntu-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; terminal = true; audi = true; ubuntu = true; });
  # SSH attach (ADR-0223): Porsche `terminal attach` into the browser's
  # personal session, read-only refusal, revocation and journal privacy.
  porsche-terminal-fleet = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; terminal = true; audi = true; porsche = true; porscheTerminal = true; });
  # Mila terminal journey (ADR-0264): the Mila Rust core's C ABI drives the
  # same real guest PTY through Porsche at the public host (nested KVM).
  mila-journey-terminal = import ./machines/fleet (service // { hostFixture = fixtures.hetzner-uefi; terminal = true; audi = true; porsche = true; porscheTerminal = true; milaTerminal = true; });
  customer-isolation-fleet = featureFleets.customer-isolation-fleet;
  relocation-fleet = featureFleets.relocation-fleet;
  memory-suspension-fleet = featureFleets.memory-suspension-fleet;
  secret-custody = import ./machines/secret-custody (service // { inherit hegel; });
  sharing-surfaces = featureFleets.sharing-surfaces;
  # Artifact content origin lockdown (plan §6): proxy + Marshall + Chromium.
  artifact-origin = import ./machines/artifact-origin (service // { inherit hegel; });
  credential-rotation = import ./machines/credential-rotation service;
  acme-lookup = import ./evaluation/acme-lookup.nix { pkgs = testPkgs; };
  acme-http01 = import ./machines/acme-http01 service;
  acme-route53 = import ./machines/acme-route53 service;
  native-zfs = import ./machines/native-zfs storage;
  native-backup-cleanup = import ./machines/backup-cleanup storage;
  packaged-backup-cleanup = import ./machines/backup-cleanup/packaged.nix service;
  private-services-network = import ./machines/private-services storage;
  peach-service = import ./evaluation/peach-service.nix { pkgs = testPkgs; packages = packages; };
  audi-ingress-network = import ./machines/audi-ingress storage;
  zfs-lifecycle = import ./machines/zfs-lifecycle storage;
  zfs-retained-bundle = import ./machines/zfs-lifecycle (storage // { retainedBundleOnly = true; });
  ubuntu-guest = import ./machines/zfs-guest (storage // {
    ubuntu = true;
    guest = import ./fixtures/ubuntu { inherit packages; };
  });
  zfs-guest = import ./machines/zfs-guest storage;
  # Boot profile of the production-shaped NixOS image: private services and
  # boot trust enabled with the fixture root, as fleet images are.
  guest-boot-profile = import ./machines/zfs-guest (storage // {
    bootProfile = true;
    guest = import ../../domains/artifacts/guest {
      pkgs = buildPkgs;
      inherit (packages) terminald lyraLinux;
      privateServiceRoots = [ ./fixtures/ubuntu/ca.crt ];
    };
  });
  ubuntu-guest-boot-profile = import ./machines/zfs-guest (storage // {
    ubuntu = true;
    bootProfile = true;
    guest = import ./fixtures/ubuntu { inherit packages; };
  });
  lilly-native-actor-recovery = import ./machines/zfs-guest (storage // { actorRecovery = true; inherit hegel; });
  zfs-namespace-cleanup = import ./machines/zfs-guest (storage // { namespaceCleanup = true; });
  inception = import ./machines/inception storage;
  inception-checkout = import ./machines/inception (storage // { checkoutOnly = true; });
  zfs-transfer = import ./machines/zfs-transfer (storage // { inherit hegel; });
  ssh-transfer = import ./machines/ssh-transfer storage;
  source-export = import ./machines/source-export storage;
  export-endpoint = import ./machines/export-endpoint storage;
  zfs-io = import ./machines/zfs-io storage;
  mirrored-installation = import ./machines/mirrored-installation {
    pkgs = testPkgs;
    inherit nixpkgs;
    hostFixture = fixtures.hetzner-uefi;
    inherit imageSource;
    secretsModule = modules.security.secrets;
  };
  host-hetzner-bios = import ./machines/mirrored-installation {
    pkgs = testPkgs; inherit nixpkgs; hostFixture = fixtures.hetzner-bios;
    inherit imageSource;
    secretsModule = modules.security.secrets; platform = "hetzner"; firmwareMode = "bios";
  };
  host-ec2-bios = import ./machines/mirrored-installation {
    pkgs = testPkgs; inherit nixpkgs; hostFixture = fixtures.ec2-bios;
    inherit imageSource;
    secretsModule = modules.security.secrets; platform = "ec2"; firmwareMode = "bios";
  };
  host-ec2-uefi = import ./machines/mirrored-installation {
    pkgs = testPkgs; inherit nixpkgs; hostFixture = fixtures.ec2-uefi;
    inherit imageSource;
    secretsModule = modules.security.secrets; platform = "ec2"; firmwareMode = "uefi";
  };
  host-images = import ./machines/host-images { pkgs = testPkgs; images = fixtures.hetzner-uefi.config.system.build.overallsTestImages; };
  host-enrollment = import ./machines/host-enrollment {
    pkgs = testPkgs; inherit nixpkgs packages diskoModule diskoSource imageSource; module = modules.default;
  };
  host-conversion = testPkgs.linkFarm "overalls-host-conversion" (map (sourceOS: {
    name = sourceOS;
    path = import ./machines/host-conversion {
      pkgs = testPkgs; inherit nixpkgs kexec imageSource diskoModule sourceOS; module = modules.default;
    };
  }) [ "recovery" "ubuntu" ]);
  enrollment-configuration = import ./evaluation/enrollment-configuration.nix { pkgs = testPkgs; inherit nixpkgs diskoModule; module = modules.default; };
  enrollment-preparation = import ./evaluation/enrollment-preparation.nix { pkgs = buildPkgs; };
  host-planning = import ./evaluation/host-planning.nix { pkgs = buildPkgs; };
}
