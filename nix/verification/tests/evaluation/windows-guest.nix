{ pkgs, packages }:
let
  inherit (pkgs) lib;
  # Store-path context is irrelevant to these textual builder checks.
  plain = builtins.unsafeDiscardStringContext;
  image = packages.windowsGuest;
  iso = builtins.fromJSON (builtins.readFile ../../../domains/artifacts/guest/windows/iso.json);
  diskScript = plain image.passthru.disk.buildCommand;
  mediaScript = plain image.passthru.configMedia.buildCommand;
  manifestScript = plain image.buildCommand;
  installDriver = builtins.readFile ../../../domains/artifacts/guest/windows/install.py;
  installEditor = builtins.readFile ../../../domains/artifacts/guest/windows/install-editor.ps1;
  startEditor = builtins.readFile ../../../domains/artifacts/guest/windows/start-editor.ps1;
  startCustodian = builtins.readFile ../../../domains/artifacts/guest/windows/start-custodian.ps1;
  setupComplete = builtins.readFile ../../../domains/artifacts/guest/windows/SetupComplete.cmd;
  specialize = builtins.readFile ../../../domains/artifacts/guest/windows/specialize.cmd;
  firstLogon = builtins.readFile ../../../domains/artifacts/guest/windows/FirstLogon.cmd;
  wingetPins = builtins.fromJSON (builtins.readFile ../../../domains/artifacts/guest/windows/winget.json);
  vsLayoutPins = builtins.fromJSON (builtins.readFile ../../../domains/artifacts/guest/windows/vs-layout.json);
  bootstrap = builtins.readFile ../../../domains/artifacts/guest/windows/overalls-bootstrap.ps1;
  sshdConfig = builtins.readFile ../../../domains/artifacts/guest/windows/sshd_config;
  answerTemplate = builtins.readFile ../../../domains/artifacts/guest/windows/autounattend.xml;
  bootScript = plain packages.windowsBoot.text;
  firmware = packages.windowsFirmware;
  firmwarePatches = map (p: baseNameOf (toString p)) (packages.vmm.passthru.overallsPatches);
  accepts = args: (builtins.tryEval (packages.mkWindowsGuest args).drvPath).success;
  published = packages.windowsGuestPublished;
  fleetImages = import ../../../../fleet/guest-images.nix { overallsPackages = packages; };
  fleetWindows = lib.filter (entry: entry.name == "Windows Server 2025") fleetImages;
  # Local declaration fixtures exercise constructor refusal without compiling
  # or qualifying a Windows build. The native acceptance gate is separate.
  editorFixture = pkgs.runCommand "windows-editor-constructor-fixture" {
    passthru = {
      targetPlatform = "win32-x64";
      nativeBundle = true;
      editorCapability = false;
      editorProtocol = packages.windowsEditorSource.editorProtocol;
      sourceCommit = packages.windowsEditorSource.sourceCommit;
      releaseId = packages.windowsEditorSource.releaseId;
    };
  } "touch $out";
  editorArgs = {
    agents = packages.lyraWindows;
    terminald = packages.terminaldWindows;
    editorBundle = editorFixture;
    editorBroker = packages.windowsEditorBroker;
  };
  editorCandidate = packages.mkWindowsEditorCandidate {
    nativeBuild = editorFixture;
    # Constructor fixture only; this does not point at a published bundle or
    # establish native Windows evidence.
    narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
  candidateMedia = plain editorCandidate.passthru.configMedia.buildCommand;
  candidateManifest = plain editorCandidate.buildCommand;
  brokerConfiguration = builtins.fromJSON (plain editorCandidate.passthru.editorConfiguration.text);
  custodianConfiguration = builtins.fromJSON (plain editorCandidate.passthru.editorCustodianConfiguration.text);
in
# @cc [owner:ghuntley,label:verification;deployment] windows-fleet-sealed-selection
# The shared fleet list MUST select the reviewed recursive-hash Windows pin,
# whose fallback only refuses. The source windows-v1 builder MUST remain an
# independent development target; declaration checks do not prove guest boot.
assert published.name == "overalls-windows-server-2025-8ca0a11f";
assert published.drvAttrs.outputHash == "sha256-MTpVti0Mc+c3FzqjUJLfBAfEIW+plgP+HheZnVdPlUo=";
assert published.drvAttrs.outputHashMode == "recursive";
assert published.drvAttrs.allowedReferences == [ ];
assert builtins.getContext published.buildCommand == { };
assert lib.hasInfix "exit 1" published.buildCommand;
assert lib.hasInfix "signed Overalls cache" published.buildCommand;
assert published.passthru.manifest.version == 5;
assert published.passthru.manifest.guest_agents == "windows-v1";
assert published.passthru.manifest.workspace_source_version == 2;
assert published.passthru.manifest.boot.kind == "firmware";
assert published.passthru.manifest.boot.pci;
assert published.passthru.manifest.boot.firmware == {
  bytes = 4194304;
  sha256 = "261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2";
};
assert published.passthru.manifest.root == {
  format = "raw-gpt";
  bytes = 68719476736;
  sha256 = "2eee37f946e7688719b09b9e8b285431ef2332513f768c0b02a9e82c9e90fd05";
};
assert builtins.length fleetWindows == 1;
assert (builtins.head fleetWindows).package.drvPath == published.drvPath;
assert published.drvPath != packages.windowsGuestAgents.drvPath;
assert !(lib.any (entry: (entry.package.passthru.guestAgents or null) == "windows-editor-v1") fleetImages);
# @cc [owner:ghuntley,label:verification] windows-guest-offline-kvm-assembly
# The cheap evaluation gate MUST prove the builder keeps the installation in a
# KVM sandbox with restricted user networking, modern-only virtio-pci devices,
# the hash-pinned Microsoft evaluation ISO and the pinned virtio-win drivers.
# It is not a substitute for running the installation or booting the image.
assert image.passthru.disk.drvAttrs.requiredSystemFeatures == [ "kvm" ];
assert image.passthru.disk.drvAttrs.preferLocalBuild == true;
assert lib.hasInfix "\"user\", \"id=net0\", \"restrict=on\"" installDriver;
assert lib.hasInfix "virtio-blk-pci,drive=root,disable-legacy=on,bootindex=1" installDriver;
assert lib.hasInfix "virtio-net-pci,netdev=net0,disable-legacy=on" installDriver;
assert lib.hasInfix "OVERALLS-SETUP-COMPLETE" installDriver && lib.hasInfix "OVERALLS-SETUP-COMPLETE" firstLogon;
assert lib.hasInfix "fallocate --dig-holes work/disk.raw" diskScript;
# Installation evidence: QMP lifecycle timeline, screenshots, serial markers in
# every unattend pass, guest logs published on the ESP and read back with mtools.
assert lib.hasInfix "\"execute\": \"screendump\"" installDriver;
assert lib.hasInfix "qmp_capabilities" installDriver && lib.hasInfix "timeline.jsonl" installDriver;
assert lib.hasInfix "--evidence-dir \"$out/evidence\"" diskScript && lib.hasInfix "--qmp work/qmp.sock" diskScript;
# Legacy Setup entry: modified boot.wim on a no-prompt UEFI boot ISO, Microsoft's
# ISO unmodified as the installation source.
assert lib.hasInfix "/Windows/System32/winpeshl.ini" (plain image.passthru.bootWim.buildCommand);
assert lib.hasInfix "hivexregedit --merge hive/SYSTEM" (plain image.passthru.bootWim.buildCommand);
assert lib.hasInfix "\"SanPolicy\"=dword:00000001" (builtins.readFile ../../../domains/artifacts/guest/windows/winpe-san-policy.reg);
assert lib.hasInfix "echo online disk noerr" answerTemplate;
assert lib.hasInfix "efisys_noprompt.bin -no-emul-boot" mediaScript;
assert lib.hasInfix "--keypress-seconds 0" diskScript;
assert lib.hasInfix "/legacy /installfrom:%SRC% /unattend:%CFG%" (builtins.readFile ../../../domains/artifacts/guest/windows/overalls-setup.cmd);
assert lib.hasInfix "overalls-setup.cmd" (builtins.readFile ../../../domains/artifacts/guest/windows/winpeshl.ini);
assert lib.hasInfix "mcopy -n -s -i" diskScript && lib.hasInfix "guest-logs-missing" diskScript;
# Failed installations keep their evidence: the disk derivation records the
# result and the image derivation refuses a non-zero one.
assert lib.hasInfix "echo \"$result\" > \"$out/evidence/result\"" diskScript;
assert lib.hasInfix "Windows installation failed with result" manifestScript;
assert lib.hasInfix "FORENSICS_COMMANDS" installDriver && lib.hasInfix "wpeutil shutdown" installDriver;
assert lib.hasInfix "OVERALLS-WINPE-START" answerTemplate && lib.hasInfix "OVERALLS-SPECIALIZE-START" answerTemplate;
assert lib.hasInfix "@WINPE_DRIVER_PATHS@" answerTemplate && lib.hasInfix "@WINPE_DRVLOAD@" answerTemplate;
assert accepts { winpeDriverLoad = "drvload"; };
assert !accepts { winpeDriverLoad = "floppy"; };
assert lib.all (marker: lib.hasInfix marker setupComplete) [
  "OVERALLS-SETUPCOMPLETE-START" "OVERALLS-DRIVERS-INSTALLED" "OVERALLS-EMS-ENABLED" "OVERALLS-SETUPCOMPLETE-DONE"
];
assert lib.all (marker: lib.hasInfix marker firstLogon) [
  "OVERALLS-FIRSTLOGON-START" "OVERALLS-DHCP-DISABLED" "OVERALLS-LOGS-PUBLISHED" "OVERALLS-SETUP-COMPLETE"
];
assert lib.hasInfix "Panther\\setupact.log" firstLogon && lib.hasInfix "setupapi.dev.log" firstLogon;
assert lib.hasInfix "cp -r ${plain "${image.passthru.disk}"}/evidence" manifestScript;
assert lib.hasInfix (plain "${image.passthru.windowsIso}") diskScript;
assert image.passthru.windowsIso.url == iso.url;
assert lib.hasPrefix "https://software-static.download.prss.microsoft.com/" iso.url;
assert lib.hasInfix "/2k25/amd64" (plain image.passthru.driverTree.buildCommand);
# virtio-vsock (viosock) ships beside the storage, network, serial, RNG and
# balloon drivers; the transport probe rides on the media and is registered as
# a SYSTEM task only when present (ADR-0171 gate 1).
assert lib.hasInfix "viosock" (plain image.passthru.driverTree.buildCommand);
assert lib.hasInfix "tree/overalls/agents/" mediaScript;
assert lib.hasInfix "overalls-winprobe.exe" setupComplete;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\WinProbe\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Readinessd\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Trustd\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "tree/overalls/trust/base-ca-bundle.pem" mediaScript;
# Gate 3: sshd is public-key only through the roster agent's per-account key
# files (Win32-OpenSSH has no AuthorizedKeysCommand), started on demand after
# the first roster, with the per-boot host certificate and no
# administrators_authorized_keys.
assert lib.hasInfix "tree/overalls/ssh/sshd_config" mediaScript;
assert lib.hasInfix "AuthorizedKeysFile C:/overalls/ssh/authorized_keys/%u" sshdConfig;
assert lib.hasInfix "HostCertificate __PROGRAMDATA__/ssh/ssh_host_ed25519_key-cert.pub" sshdConfig;
assert lib.hasInfix "PasswordAuthentication no" sshdConfig && lib.hasInfix "AuthenticationMethods publickey" sshdConfig;
assert lib.hasInfix "SyslogFacility LOCAL0" sshdConfig;
assert !(lib.hasInfix "\nAuthorizedKeysCommand" sshdConfig) && !(lib.hasInfix "Match Group administrators" sshdConfig);
assert lib.hasInfix "del /F /Q %ProgramData%\\ssh\\administrators_authorized_keys" setupComplete;
assert lib.hasInfix "Set-Service -Name sshd -StartupType Manual" setupComplete;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\SshSync\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\HostCertificate\" /SC ONSTART /RU SYSTEM" setupComplete;
assert image.passthru.guestAgents == "none";
assert packages.windowsGuestAgents.passthru.guestAgents == "windows-v1";
assert lib.hasInfix "--arg guest_agents 'windows-v1'" (plain packages.windowsGuestAgents.buildCommand)
  || lib.hasInfix "--arg guest_agents windows-v1" (plain packages.windowsGuestAgents.buildCommand);
assert !(lib.hasInfix "tree/overalls/agents/" (plain (packages.mkWindowsGuest { }).passthru.configMedia.buildCommand));
assert accepts { agents = packages.lyraWindows; terminald = packages.terminaldWindows; guestAgents = "windows-v1"; };
assert accepts { agents = packages.lyraWindows; terminald = packages.terminaldWindows; editorRuntime = packages.windowsEditorRuntime; guestAgents = "windows-v1"; };
assert !accepts { guestAgents = "windows-v1"; };
# windows-v1 declares the terminal capability, so its image MUST carry the daemon.
assert !accepts { agents = packages.lyraWindows; guestAgents = "windows-v1"; };
assert !accepts { terminald = packages.terminaldWindows; };
assert !accepts { agents = packages.lyraWindows; terminald = packages.terminaldWindows; editorRuntime = packages.windowsEditorRuntime; guestAgents = "none"; };
assert lib.hasInfix "tree/overalls/editor-runtime/node.exe" (plain (packages.windowsGuestRuntime.passthru.configMedia.buildCommand));
assert lib.hasInfix "tree/overalls/editor-runtime/runtime.json" (plain (packages.windowsGuestRuntime.passthru.configMedia.buildCommand));
assert packages.windowsGuestRuntime.passthru.editorRuntime == packages.windowsEditorRuntime;
# @cc [owner:ghuntley,label:verification;security] windows-editor-candidate-closed-constructor
# The candidate constructor MUST require the paired unqualified Windows bundle
# and broker, select windows-editor-v1 with its exact v7 descriptor, and refuse
# incomplete, runtime-only or explicitly windows-v1 combinations. These are
# declaration checks only, not native bundle, image or browser acceptance.
assert accepts editorArgs;
assert editorCandidate.passthru.guestAgents == "windows-editor-v1";
assert !editorCandidate.passthru.editorCapability;
assert editorCandidate.passthru.editorDescriptor == { protocol = 1; commit = editorFixture.sourceCommit; release = editorFixture.releaseId; };
assert editorCandidate.passthru.editorBundle.drvAttrs.outputHash == "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
assert editorCandidate.passthru.editorBundle.drvAttrs.outputHashMode == "recursive";
assert lib.hasInfix "--argjson minimum_memory_bytes 4294967296" candidateManifest;
assert lib.hasInfix "OVERALLS-EDITOR-CANDIDATE-INSTALLED" candidateManifest;
assert lib.hasInfix ''{version:7,os:"windows",editor:$editor_descriptor}'' candidateManifest;
assert lib.hasInfix "tree/overalls/editor-broker/start.ps1" candidateMedia;
assert lib.hasInfix "tree/overalls/editor-broker/start-custodian.ps1" candidateMedia;
assert lib.hasInfix "tree/overalls/editor-broker/custodian.json" candidateMedia;
assert lib.hasInfix "stage-editor.py" candidateMedia;
assert lib.hasInfix "Install-EditorArchive" installEditor;
assert lib.hasInfix "editor.inventory.json" installEditor;
assert lib.hasInfix "editor.archive.json" installEditor;
assert lib.hasInfix "Get-FileHash -LiteralPath $Archive" installEditor;
assert lib.hasInfix "tar.exe" installEditor;
assert lib.hasInfix "editor_archive_nonregular" installEditor;
assert lib.hasInfix "editor_archive_file_mismatch" installEditor;
# @cc [owner:ghuntley,label:verification;security;recovery] windows-editor-independent-task-declarations
# Both fixed SYSTEM roles MUST have separate task actions and checked trust
# snapshots with the same immutable worker/release configuration. Declaration
# and parse checks MUST NOT establish native scheduler or Job Object recovery.
assert lib.hasInfix "'Bootstrap', 'EditorBroker', 'EditorCustodian'" setupComplete;
assert lib.hasInfix "Register-EditorTask -TaskName 'EditorBroker'" installEditor;
assert lib.hasInfix "Register-EditorTask -TaskName 'EditorCustodian'" installEditor;
assert lib.hasInfix "ValidateSet('EditorBroker', 'EditorCustodian')" installEditor;
assert lib.hasInfix "O:SYG:SYD:P(A;;FA;;;SY)(A;;FR;;;BA)" installEditor;
assert lib.hasInfix "-ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew" installEditor;
assert lib.hasInfix "-RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)" installEditor;
assert lib.hasInfix "New-ScheduledTaskTrigger -AtStartup" installEditor;
assert lib.hasInfix "'--custodian' 'C:\\overalls\\editor-broker\\custodian.json'" startCustodian;
assert !(lib.hasInfix "'--custodian'" startEditor);
assert lib.all (source: lib.hasInfix "if ($LASTEXITCODE -eq 0) { exit 0 }" source && lib.hasInfix "exit 1" source) [ startEditor startCustodian ];
assert brokerConfiguration.ca_bundle == "C:\\overalls\\editor-broker\\ca-bundle.pem";
assert custodianConfiguration.ca_bundle == "C:\\overalls\\editor-broker\\custodian-ca-bundle.pem";
assert builtins.removeAttrs brokerConfiguration [ "ca_bundle" ] == builtins.removeAttrs custodianConfiguration [ "ca_bundle" ];
assert lib.hasInfix "-Destination 'C:\\overalls\\editor-broker\\ca-bundle.pem'" startEditor;
assert lib.hasInfix "-Destination 'C:\\overalls\\editor-broker\\custodian-ca-bundle.pem'" startCustodian;
assert !(lib.hasInfix "tree/overalls/editor-broker/" mediaScript);
assert !(lib.hasInfix "tree/overalls/editor-broker/" (plain packages.windowsGuestRuntime.passthru.configMedia.buildCommand));
assert !accepts (editorArgs // { editorBroker = null; });
assert !accepts (editorArgs // { editorBundle = null; });
assert !accepts (editorArgs // { agents = null; });
assert !accepts (editorArgs // { terminald = null; });
assert !accepts (editorArgs // { guestAgents = "windows-v1"; });
assert !accepts (editorArgs // { guestAgents = "none"; });
assert !accepts (editorArgs // { editorRuntime = packages.windowsEditorRuntime; });
assert !accepts { agents = packages.lyraWindows; terminald = packages.terminaldWindows; guestAgents = "windows-editor-v1"; };
assert !accepts (editorArgs // { editorBundle = editorFixture // { targetPlatform = "linux-x64"; }; });
assert !accepts (editorArgs // { editorBundle = editorFixture // { nativeBundle = false; }; });
assert !accepts (editorArgs // { editorBundle = editorFixture // { editorCapability = true; }; });
assert !accepts (editorArgs // { editorBundle = editorFixture // { editorProtocol = 2; }; });
assert !accepts (editorArgs // { editorBundle = editorFixture // { sourceCommit = "invalid"; }; });
assert !accepts (editorArgs // { editorBundle = editorFixture // { releaseId = "invalid"; }; });
assert !accepts (editorArgs // { editorBroker = packages.windowsEditorBroker // { targetPlatform = "linux-x64"; }; });
assert !accepts (editorArgs // { editorBroker = packages.windowsEditorBroker // { editorCapability = true; }; });
assert lib.hasInfix "overalls-terminald.exe tree/overalls/agents/"
  (plain packages.windowsGuestAgents.passthru.configMedia.buildCommand);
assert !(lib.hasInfix "overalls-terminald.exe" mediaScript);
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Terminald\" /SC ONSTART /RU SYSTEM" setupComplete;
# Gate 5: the workspace receiver task and the pinned MinGit, on windows-v1 media only.
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Workspaced\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "\"overalls-workspaced-windows\"" (builtins.readFile ../../../domains/artifacts/infrastructure/lyra.nix);
# The image's runtime closure is its disk and firmware only; agents carry no store paths.
assert image.passthru.disk.drvAttrs.allowedReferences == [ ];
assert packages.lyraWindows.drvAttrs.allowedReferences == [ ];
assert packages.terminaldWindows.drvAttrs.allowedReferences == [ ];
assert lib.hasInfix "--remap-path-prefix" (plain packages.lyraWindows.buildPhase);
assert lib.hasInfix "STORE_HASH.sub" installDriver;
# Gate 5: the agent executor task, and private names through the local resolver only.
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Agentd\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "\"overalls-agentd-windows\"" (builtins.readFile ../../../domains/artifacts/infrastructure/lyra.nix);
assert lib.hasInfix "Add-DnsClientNrptRule -Namespace '.internal' -NameServers '169.254.254.1'" bootstrap;
# The private endpoint lives on the host side's loopback: reach it through the
# gateway, never on-link (nothing answers ARP for it on the tap).
assert lib.hasInfix "-DestinationPrefix '169.254.254.1/32' -NextHop $gateway" bootstrap;
assert !(lib.hasInfix "-DestinationPrefix '169.254.254.1/32' -NextHop 0.0.0.0" bootstrap);
# Bootstrap and verified host-certificate receipts are per boot; readiness also
# probes the live sshd service (C:\overalls\run survives reboots and relocation).
assert lib.all (probe: lib.hasInfix probe (builtins.readFile ../../../../lyra/src/bin/overalls-readinessd.rs)) [
  "if !ssh_bootstrap_ready("
  "boot_id::marker_is_current(Path::new(ssh_bootstrap::READY))"
  "boot_id::marker_is_current(Path::new(ssh_bootstrap::CERTIFICATE_READY))"
  "|| services::running(SSHD)"
];
assert lib.hasInfix "boot_id::write_marker(Path::new(ssh_bootstrap::READY))" (builtins.readFile ../../../../lyra/src/bin/overalls-ssh-sync-windows.rs);
assert lib.hasInfix "boot_id::write_marker(Path::new(ssh_bootstrap::CERTIFICATE_READY))" (builtins.readFile ../../../../lyra/src/bin/overalls-host-certificate-windows.rs);
# Public names resolve through the Linux guests' resolvers (workspace clones).
assert lib.hasInfix "-ServerAddresses @('1.1.1.1', '9.9.9.9')" bootstrap;
# ADR-0173: Desktop Experience, winget and its packages from winget.json only,
# served to the offline installation by the guestfwd file server; WSL features
# enabled in specialize (before Setup's restart), and an image without the
# winget or feature markers is refused.
assert image.passthru.wimImageName == "Windows Server 2025 SERVERSTANDARD";
assert lib.all (p: lib.hasPrefix "https://raw.githubusercontent.com/microsoft/winget-pkgs/${wingetPins.source.commit}/" p)
  (lib.concatMap (p: map (m: m.url) (builtins.attrValues p.manifests)) wingetPins.packages);
assert lib.all (id: lib.elem id (map (p: p.id) wingetPins.packages))
  [ "Git.Git" "GitHub.cli" "Anthropic.ClaudeCode" "OpenAI.Codex" "Microsoft.WSL" "RedHat.Podman" "Microsoft.VCRedist.2015+.x64" ];
assert lib.hasInfix "cp -r ${plain image.passthru.wingetPayload.outPath}/media/. tree/overalls/winget/" mediaScript;
assert lib.hasInfix "guestfwd" installDriver && lib.hasInfix "restrict=on" installDriver;
assert lib.hasInfix "--serve-command" (plain image.passthru.disk.buildCommand);
assert lib.hasInfix "overalls-winget.ps1 -Phase provision" setupComplete;
assert lib.hasInfix "overalls-winget.ps1 -Phase install" firstLogon;
assert lib.hasInfix "/FeatureName:VirtualMachinePlatform" specialize;
assert lib.hasInfix "/FeatureName:Microsoft-Windows-Subsystem-Linux" specialize;
assert lib.hasInfix "OVERALLS-WINGET-COMPLETE" (plain image.buildCommand);
assert lib.hasInfix "C:\\\\Program Files\\\\Git\\\\cmd\\\\git.exe" (builtins.readFile ../../../../lyra/src/bin/overalls-workspaced-windows.rs);
assert !(builtins.pathExists ../../../domains/artifacts/guest/windows/mingit.json);
# Visual Studio Community from the pinned offline layout (ADR-0173 decision 7):
# every layout file from Microsoft's download host by digest, the bootstrapper
# pinned in winget.json, the layout rebuilt and installed with --noWeb, and a
# 64 GiB disk for it.
assert lib.elem "Microsoft.VisualStudio.Community" (map (p: p.id) wingetPins.packages);
assert lib.all (f: lib.hasPrefix "https://download.visualstudio.microsoft.com/" f.url) vsLayoutPins.files;
assert lib.all (f: builtins.stringLength f.sha256 == 64) (vsLayoutPins.files ++ vsLayoutPins.intermediates);
assert vsLayoutPins.bootstrapper.sha256
  == (lib.findFirst (p: p.id == "Microsoft.VisualStudio.Community") null wingetPins.packages).installer.sha256;
assert lib.hasInfix "--installLayoutPath $VsLayout --noWeb" (builtins.readFile ../../../domains/artifacts/guest/windows/overalls-winget.ps1);
assert lib.hasInfix "Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Workload.ManagedDesktop"
  (builtins.readFile ../../../domains/artifacts/guest/windows/overalls-winget.ps1);
assert image.passthru.diskBytes == 68719476736;
# schtasks' default 72-hour execution limit MUST NOT apply to the agent daemons.
assert lib.hasInfix "New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew" setupComplete;
assert lib.hasInfix "Get-ScheduledTask -TaskPath '\\Overalls\\'" setupComplete;
assert !accepts { guestAgents = "linux"; };
assert lib.hasInfix (plain "${pkgs.virtio-win}") (plain image.passthru.driverTree.buildCommand);
assert lib.hasInfix "/overalls/drivers/" mediaScript;
# Headless serial management: EMS on COM1, no autologon in the finished image,
# no Windows Update restarts.
assert lib.hasInfix "bcdedit /emssettings emsport:1 emsbaudrate:115200" setupComplete;
assert lib.hasInfix "bcdedit /ems {current} on" setupComplete;
assert lib.hasInfix "bcdedit /bootems {bootmgr} on" setupComplete;
assert lib.hasInfix "sc config wuauserv start= disabled" setupComplete;
assert lib.hasInfix "DisabledComponents" setupComplete;
assert lib.hasInfix "-Dhcp Disabled" firstLogon;
assert !(lib.hasInfix "-Dhcp Disabled" setupComplete);
# The build's only autologon is one-shot (ADR-0173): LogonCount 1, its values
# removed and verified by FirstLogon.cmd, and the image refused otherwise.
assert lib.hasInfix "<LogonCount>1</LogonCount>" answerTemplate;
assert lib.hasInfix "cmd /c C:\\overalls\\setup\\FirstLogon.cmd" answerTemplate;
assert lib.hasInfix "OVERALLS-AUTOLOGON-CLEARED" firstLogon;
assert lib.hasInfix "/v DefaultPassword /f" firstLogon;
assert lib.hasInfix "OVERALLS-AUTOLOGON-CLEARED" (plain image.buildCommand);
assert lib.hasInfix "<Value>@WIM_IMAGE_NAME@</Value>" answerTemplate;
assert lib.hasInfix "X:\\overalls\\drivers\\viostor" (plain image.passthru.answerFile.buildCommand);
assert lib.hasInfix "Microsoft-Windows-PnpCustomizationsNonWinPE" answerTemplate;
assert lib.hasInfix "/overalls/drivers" (plain image.passthru.bootWim.buildCommand);
# Manifest v5 shape (ADR-0169): firmware boot, raw GPT root, no agents, and no
# display name (the protocol admits exactly eight keys).
assert lib.hasInfix "version: 5" manifestScript;
assert lib.hasInfix "kind: \"firmware\", pci: true" manifestScript;
assert lib.hasInfix "format: \"raw-gpt\"" manifestScript;
assert lib.hasInfix "--arg guest_agents 'none'" manifestScript || lib.hasInfix "--arg guest_agents none" manifestScript;
assert lib.hasInfix "--argjson workspace_source_version null" manifestScript;
assert lib.hasInfix "--argjson workspace_source_version 2" (plain packages.windowsGuestAgents.buildCommand);
assert !(lib.hasInfix "name:" manifestScript);
# Boot-time bootstrap (ADR-0170): a SYSTEM task reads Lilly's identity from MMDS
# V2 and applies exactly the delivered /32; no credential material is involved.
assert lib.hasInfix "overalls-bootstrap.ps1" mediaScript;
assert lib.hasInfix "schtasks /Create /TN \"Overalls\\Bootstrap\" /SC ONSTART /RU SYSTEM" setupComplete;
assert lib.hasInfix "OVERALLS-BOOTSTRAP-REGISTERED" setupComplete;
assert lib.hasInfix "169.254.169.254" bootstrap;
assert lib.hasInfix "X-metadata-token-ttl-seconds" bootstrap && lib.hasInfix "X-metadata-token" bootstrap;
assert lib.hasInfix "'Accept' = 'application/json'" bootstrap;
assert lib.hasInfix "-PrefixLength 32" bootstrap && lib.hasInfix "-Dhcp Disabled" bootstrap;
assert lib.hasInfix "-NextHop 0.0.0.0" bootstrap && lib.hasInfix "'0.0.0.0/0' -NextHop $gateway" bootstrap;
assert lib.hasInfix "Resize-Partition -DriveLetter C" bootstrap;
assert lib.hasInfix "OVERALLS-NETWORK-READY" bootstrap;
assert lib.hasInfix "Normalize-Mac $lilly.mac" bootstrap;
assert !(lib.hasInfix "Overalls-Spike" bootstrap) && !(lib.hasInfix "net user" bootstrap);
assert !(lib.hasInfix "Write-Log ('token" bootstrap);
# Launcher: firmware as kernel, PCI transport, Hyper-V template, no boot args.
assert lib.hasInfix "firecracker --enable-pci" bootScript;
assert lib.hasInfix "kernel_image_path: $firmware" bootScript;
assert lib.hasInfix "\"cpu-config\": { hyperv: true }" bootScript;
assert lib.hasInfix "vsock: { guest_cid: 3, uds_path: $vsock }" bootScript;
assert !(lib.hasInfix "boot_args" bootScript) && !(lib.hasInfix "initrd_path" bootScript);
# Firmware and VMM provenance.
assert firmware.pname == "cloudhv-firecracker-firmware";
assert packages.vmm.version == "1.16.1";
assert firmwarePatches == [
  "firecracker-snapshot-block-barrier.patch"
  "firecracker-snapshot-anonymous-restore.patch"
  "firecracker-pvh-rsdp-paddr.patch"
  "firecracker-acpi-pm-timer.patch"
  "firecracker-hyperv-cpuid.patch"
  "firecracker-pci-decode-enabled.patch"
  "firecracker-cmos-rtc.patch"
  "firecracker-cloudhv-poweroff.patch"
  "firecracker-omnios-serial-shutdown.patch"
  "firecracker-uart-thre-tests.patch"
  "firecracker-pci-bar-relocation.patch"
  "firecracker-virtio-init-queue.patch"
  "firecracker-pci-config-notify.patch"
  "firecracker-msix-reset-state.patch"
  "firecracker-virtio-reset.patch"
  "firecracker-net-reset-reuse.patch"
  "firecracker-virtio-blk-sg.patch"
  "firecracker-vsock-indirect-desc.patch"
  "firecracker-vsock-reset.patch"
  "firecracker-rng-reset.patch"
  "firecracker-uart-thre-enable.patch"
];
# Builder argument validation stays in Nix evaluation.
assert accepts { wimImageName = "Windows Server 2025 SERVERDATACENTERCORE"; };
assert accepts { diskBytes = 68719476736; };
pkgs.runCommand "windows-guest-unit" {
  nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.powershell ];
} ''
  cp ${../../../domains/artifacts/guest/windows/install.py} install.py
  cp ${../../../../pyproject.toml} pyproject.toml
  ruff check --no-cache --config pyproject.toml --select ANN,E,F,I,W install.py
  ruff format --check --config pyproject.toml install.py
  python3 -I -c 'import ast, sys; ast.parse(open("install.py").read())'
  cp ${../../../domains/artifacts/guest/windows/install-editor.ps1} install-editor.ps1
  cp ${../../../domains/artifacts/guest/windows/start-editor.ps1} start-editor.ps1
  cp ${../../../domains/artifacts/guest/windows/start-custodian.ps1} start-custodian.ps1
  cp ${../../../domains/artifacts/guest/windows/editor-custody.ps1} editor-custody.ps1
  pwsh -NoLogo -NoProfile -NonInteractive -Command \
    '$files = @("install-editor.ps1", "start-editor.ps1", "start-custodian.ps1", "editor-custody.ps1"); foreach ($file in $files) { $tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $file), [ref]$tokens, [ref]$errors); if ($errors.Count -ne 0) { throw "windows_editor_source_parse_failed" } }'
  python3 -I - <<'PY'
import subprocess, sys
# The driver must refuse to start without every required path.
result = subprocess.run([sys.executable, "-I", "install.py"], capture_output=True, text=True)
assert result.returncode == 2, result
assert "--qemu" in result.stderr
PY
  touch "$out"
''
