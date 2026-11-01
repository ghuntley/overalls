{ pkgs, firmware, githubTools ? import ../github { inherit pkgs; } }:
{ imageName ? "lilly-windows-server-2025-x86_64"
, iso ? builtins.fromJSON (builtins.readFile ./iso.json)
, windowsIso ? pkgs.fetchurl { inherit (iso) url sha256 name; }
  # Desktop Experience: winget (App Installer) and AppX provisioning exist
  # only there; Server Core has no DISM AppX provider (ADR-0173).
, wimImageName ? "Windows Server 2025 SERVERSTANDARD"
  # Bootstrap credential for the built-in Administrator account of a spike
  # image. It is not a secret: the image has no agents, no roster and is only
  # reachable through the serial console or an operator-attached network.
, adminPassword ? "Overalls-Spike-2026!"
  # 64 GiB: Desktop Experience, the winget packages and Visual Studio with
  # the C++ and .NET desktop workloads use about 29 GiB (ADR-0173).
, diskBytes ? 68719476736
, minimumMemoryBytes ? (if editorBundle == null then 2147483648 else 4294967296)
, installMemoryMiB ? 4096
, installCores ? 4
, installTimeoutSeconds ? 10800
  # How Windows PE gets the virtio storage driver: "paths" uses the answer
  # file's DriverPaths (processed by Setup itself); "drvload" loads it with a
  # RunSynchronous command before Setup touches the disk.
, winpeDriverLoad ? "paths"
  # Guest agents shipped on the configuration media (a derivation whose
  # bin/*.exe are copied to C:\overalls\agents), or null for an agentless image.
, agents ? null
  # Editor candidates use their separate versioned contract; supplying the pair
  # chooses it by default, and explicitly mixing it with windows-v1 refuses.
, guestAgents ? (if editorBundle == null then "none" else "windows-editor-v1")
  # ConPTY terminal daemon (bin/overalls-terminald.exe), copied beside the agents.
, terminald ? null
  # Native editor runtime inputs are staged for Windows bring-up diagnostics,
  # but remain inert until a Windows broker and editor-capable image contract
  # are reviewed. Presence MUST NOT change the manifest capability row.
, editorRuntime ? null
  # Reviewed native source-built bundle and broker for isolated bring-up only.
  # This installs independent supervised SYSTEM broker and custodian tasks
  # under the separate v7 candidate contract. Its metadata stays unqualified
  # and the fleet remains unchanged.
, editorBundle ? null
, editorBroker ? null
}:
assert builtins.elem winpeDriverLoad [ "paths" "drvload" ];
assert builtins.elem guestAgents [ "none" "windows-v1" "windows-editor-v1" ];
assert guestAgents == "none" || (agents != null && terminald != null);
assert terminald == null || agents != null;
assert editorRuntime == null || (agents != null && terminald != null && guestAgents == "windows-v1");
assert (editorBundle == null) == (editorBroker == null);
assert (guestAgents == "windows-editor-v1") == (editorBundle != null);
assert editorBundle == null || (agents != null && terminald != null);
assert editorBundle == null || (editorBundle.targetPlatform == "win32-x64" && editorBundle.nativeBundle && !editorBundle.editorCapability);
assert editorBundle == null || (editorBundle.editorProtocol == 1 &&
  builtins.match "[0-9a-f]{40}" editorBundle.sourceCommit != null &&
  builtins.match "[0-9a-f]{64}" editorBundle.releaseId != null);
assert editorBroker == null || (editorBroker.targetPlatform == "win32-x64" && !editorBroker.editorCapability);
let
  inherit (pkgs) lib;
  editorDescriptor = if editorBundle == null then null else {
    protocol = editorBundle.editorProtocol;
    commit = editorBundle.sourceCommit;
    release = editorBundle.releaseId;
  };
  editorConfigurationFields = {
    descriptor = editorDescriptor;
    node = "C:\\overalls\\editor\\node.exe";
    server = "C:\\overalls\\editor\\out\\server-main.js";
    system_root = "C:\\Windows";
    account_authorizer = "C:\\overalls\\agents\\overalls-ssh-sync-windows.exe";
    state_directory = "C:\\overalls\\editor-state";
    worker_path = lib.concatStringsSep ";" [
      "C:\\overalls\\editor\\project-language-adapters"
      "C:\\overalls\\editor"
      "C:\\Program Files\\Git\\cmd"
      "C:\\Windows\\System32"
      "C:\\Windows"
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0"
    ];
  };
  editorConfiguration = if editorBundle == null then null else pkgs.writeText "overalls-windows-editor-broker.json" (builtins.toJSON (editorConfigurationFields // {
    ca_bundle = "C:\\overalls\\editor-broker\\ca-bundle.pem";
  }));
  editorCustodianConfiguration = if editorBundle == null then null else pkgs.writeText "overalls-windows-editor-custodian.json" (builtins.toJSON (editorConfigurationFields // {
    ca_bundle = "C:\\overalls\\editor-broker\\custodian-ca-bundle.pem";
  }));
  # viosock is the virtio-vsock driver and Winsock provider the guest agents
  # use to reach Lilly (ADR-0171); it binds PCI\VEN_1AF4&DEV_1053 at first boot.
  driverDirectories = [ "viostor" "NetKVM" "vioserial" "viorng" "Balloon" "viosock" ];
  # The drivers live inside boot.wim, so their Windows PE path is fixed
  # (X:\overalls\drivers). %configsetroot% did not resolve when Setup was started
  # with /unattend from the launcher, which left the virtio disk invisible.
  driverPathsXml = ''
    <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>X:\overalls\drivers\viostor</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>X:\overalls\drivers\NetKVM</Path>
            </PathAndCredentials>
          </DriverPaths>'';
  drvloadXml = ''
    <RunSynchronousCommand wcm:action="add">
              <Order>3</Order>
              <Description>overalls load virtio storage driver</Description>
              <Path>cmd /c (drvload X:\overalls\drivers\viostor\viostor.inf &amp; echo OVERALLS-WINPE-DRVLOAD &gt; X:\overalls-winpe-drvload.txt) &amp; exit /b 0</Path>
            </RunSynchronousCommand>'';
  # Driver tree copied into boot.wim and onto the boot ISO.
  driverTree = pkgs.runCommand "windows-virtio-drivers-2k25" { } ''
    mkdir -p "$out"
    for driver in ${toString driverDirectories}; do
      cp -r ${pkgs.virtio-win}/$driver/2k25/amd64 "$out/$driver"
    done
    chmod -R u+w "$out"
  '';

  # @cc [owner:ghuntley,label:build] windows-answer-file-substitution
  # The answer file MUST install exactly the configured WIM image by name, set
  # the Administrator password from the builder argument, and contain no other
  # unsubstituted @placeholder@ once rendered.
  answerFile = pkgs.runCommand "windows-autounattend.xml" { } ''
    substitute ${./autounattend.xml} "$out" \
      --subst-var-by WIM_IMAGE_NAME ${lib.escapeShellArg wimImageName} \
      --subst-var-by ADMIN_PASSWORD ${lib.escapeShellArg adminPassword} \
      --subst-var-by WINPE_DRIVER_PATHS ${lib.escapeShellArg (if winpeDriverLoad == "paths" then driverPathsXml else "")} \
      --subst-var-by WINPE_DRVLOAD ${lib.escapeShellArg (if winpeDriverLoad == "drvload" then drvloadXml else "")}
    if grep -q "@[A-Z_]*@" "$out"; then
      echo "unsubstituted placeholder in autounattend.xml" >&2
      exit 1
    fi
  '';

  # Boot files from Microsoft's ISO: UEFI boot manager, BCD, the Windows PE
  # ramdisk descriptor and boot.wim. The media's ISO 9660 side holds only a
  # README; the real tree is UDF, which 7-Zip reads.
  bootFiles = pkgs.runCommand "windows-boot-files" {
    nativeBuildInputs = [ pkgs.p7zip ];
  } ''
    mkdir -p "$out"
    7z x -y -o"$out" ${windowsIso} boot efi bootmgr bootmgr.efi sources/boot.wim > 7z.log
    chmod -R u+w "$out"
    test -s "$out/efi/microsoft/boot/efisys_noprompt.bin"
    test -s "$out/boot/boot.sdi"
    test -s "$out/sources/boot.wim"
  '';

  # @cc [owner:ghuntley,label:build] windows-legacy-setup-entry
  # The Windows PE image (boot.wim index 2) MUST start the legacy Windows Setup
  # through winpeshl.ini and overalls-setup.cmd with `/legacy`, `/installfrom`
  # pointing at Microsoft's media and `/unattend` pointing at the rendered
  # answer file. The new Server 2025 Setup entry point MUST NOT be used: it
  # fails Windows PE initialization under QEMU (0x80070001 - 0x40030).
  bootWim = pkgs.runCommand "windows-boot-wim" {
    nativeBuildInputs = [ pkgs.wimlib pkgs.hivex ];
  } ''
    cp ${bootFiles}/sources/boot.wim boot.wim
    chmod u+w boot.wim
    wimlib-imagex info boot.wim 2 > image-info.txt
    grep "Windows Setup" image-info.txt > /dev/null
    # SAN policy OnlineAll in the Windows PE SYSTEM hive (see winpe-san-policy.reg).
    wimlib-imagex extract boot.wim 2 /Windows/System32/config/SYSTEM --dest-dir=hive --no-acls
    chmod u+w hive/SYSTEM
    hivexregedit --merge hive/SYSTEM --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' ${./winpe-san-policy.reg}
    hivexregedit --export hive/SYSTEM 'ControlSet001\Services\partmgr\Parameters' > san-policy.txt
    grep -i "SanPolicy" san-policy.txt > /dev/null
    wimlib-imagex update boot.wim 2 \
      --command="add hive/SYSTEM /Windows/System32/config/SYSTEM"
    wimlib-imagex update boot.wim 2 \
      --command="add ${./winpeshl.ini} /Windows/System32/winpeshl.ini"
    wimlib-imagex update boot.wim 2 \
      --command="add ${./overalls-setup.cmd} /overalls-setup.cmd"
    # virtio drivers at a fixed Windows PE path for DriverPaths and drvload.
    wimlib-imagex update boot.wim 2 \
      --command="add ${driverTree} /overalls/drivers"
    wimlib-imagex dir boot.wim 2 --path=/overalls/drivers/viostor > viostor.txt
    grep -i "viostor.inf" viostor.txt > /dev/null
    wimlib-imagex dir boot.wim 2 --path=/Windows/System32 > system32.txt
    grep -i "winpeshl.ini" system32.txt > /dev/null
    install -D -m 0444 boot.wim "$out/sources/boot.wim"
  '';

  # @cc [owner:ghuntley,label:build] windows-boot-media-offline
  # The boot ISO MUST be UEFI-bootable through Microsoft's no-prompt EFI boot
  # image and carry the modified boot.wim, the rendered answer file at its
  # root, the post-setup script, the boot-time bootstrap script and the
  # Windows Server 2025 virtio drivers from the pinned virtio-win package, and
  # the winget payload staged from winget.json and vs-layout.json, only;
  # nothing is downloaded during assembly and Microsoft's ISO is used
  # unmodified as the installation source.

  # @cc [owner:ghuntley,label:build;security] windows-winget-pinned-offline
  # winget and every winget package MUST come from winget.json: the App
  # Installer release assets and, per package, the winget-pkgs manifests and
  # the one x64 installer, each fetched by Nix against its SHA-256. The
  # installation guest gets the manifests on the boot media and the installers
  # only from `wingetServer`, the build host's guestfwd file server that
  # serves exactly the staged installers; it never reaches another network.
  wingetPins = builtins.fromJSON (builtins.readFile ./winget.json);
  wingetServer = "http://10.0.2.100";
  wingetFiles =
    let
      pinned = [ wingetPins.winget.bundle wingetPins.winget.license wingetPins.winget.dependencies ]
        ++ lib.concatMap (p: builtins.attrValues p.manifests ++ [ p.installer ]) wingetPins.packages;
    in
    builtins.listToAttrs (map (f: lib.nameValuePair f.url (pkgs.fetchurl { inherit (f) url sha256; })) pinned);
  # Visual Studio Community offline layout (vs-layout.json, recorded by
  # update-vs-layout.ps1): every layout file by URL and SHA-256, the small
  # generated files by content, and the signer intermediate the offline chain
  # needs. One fetch per distinct digest.
  vsLayoutPins = builtins.fromJSON (builtins.readFile ./vs-layout.json);
  vsFiles =
    let
      pinned = vsLayoutPins.files ++ vsLayoutPins.intermediates;
      byDigest = builtins.listToAttrs (map (f: lib.nameValuePair f.sha256 f.url) pinned);
    in
    lib.mapAttrs (sha: url: pkgs.fetchurl { inherit url; sha256 = sha; name = "vs-layout-${builtins.substring 0 16 sha}"; }) byDigest;
  wingetPayload = pkgs.runCommand "windows-winget-payload" {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyyaml ])) ];
  } ''
    python3 -I ${./stage-winget.py} ${./winget.json} ${pkgs.writeText "winget-files.json" (builtins.toJSON wingetFiles)} ${wingetServer} "$out" \
      ${./vs-layout.json} ${pkgs.writeText "vs-layout-files.json" (builtins.toJSON vsFiles)}
    test -s "$out/media/packages.txt"
    test -s "$out/media/vslayout/files.tsv"
  '';
  configMedia = pkgs.runCommand "windows-boot-media.iso" {
    nativeBuildInputs = [ pkgs.python3 pkgs.xorriso ];
  } ''
    mkdir -p tree/overalls/setup tree/overalls/bootstrap tree/overalls/drivers tree/sources
    cp -r ${bootFiles}/boot tree/boot
    cp -r ${bootFiles}/efi tree/efi
    cp ${bootFiles}/bootmgr tree/bootmgr
    cp ${bootFiles}/bootmgr.efi tree/bootmgr.efi
    cp ${bootWim}/sources/boot.wim tree/sources/boot.wim
    cp ${answerFile} tree/autounattend.xml
    cp ${./SetupComplete.cmd} tree/overalls/setup/SetupComplete.cmd
    cp ${./specialize.cmd} tree/overalls/setup/specialize.cmd
    cp ${./overalls-winget.ps1} tree/overalls/setup/overalls-winget.ps1
    cp ${./FirstLogon.cmd} tree/overalls/setup/FirstLogon.cmd
    cp ${./overalls-github-tools.ps1} tree/overalls/setup/overalls-github-tools.ps1
    mkdir -p tree/overalls/github-tools
    cp ${githubTools.gh.windows-amd64}/bin/gh.exe tree/overalls/github-tools/gh.exe
    cp ${githubTools.lfs.windows-amd64}/bin/git-lfs.exe tree/overalls/github-tools/git-lfs.exe
    cp ${githubTools.configuration} tree/overalls/github-tools/github.gitconfig
    mkdir -p tree/overalls/winget
    cp -r ${wingetPayload}/media/. tree/overalls/winget/
    cp ${./overalls-bootstrap.ps1} tree/overalls/bootstrap/overalls-bootstrap.ps1
    cp -r ${driverTree}/. tree/overalls/drivers/
    ${lib.optionalString (agents != null) ''
      mkdir -p tree/overalls/agents tree/overalls/trust tree/overalls/ssh
      cp ${agents}/bin/*.exe tree/overalls/agents/
      ${lib.optionalString (terminald != null) "cp ${terminald}/bin/overalls-terminald.exe tree/overalls/agents/"}
      # Public roots every Windows TLS client and Git start from; Lilly's
      # delivered roots are appended per boot by overalls-trustd-windows.
      cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt tree/overalls/trust/base-ca-bundle.pem
      # Public-key-only sshd configuration fed by the roster agent's key files.
      cp ${./sshd_config} tree/overalls/ssh/sshd_config
    ''}
    ${lib.optionalString (editorRuntime != null) ''
      mkdir -p tree/overalls/editor-runtime
      cp ${editorRuntime}/bin/node.exe tree/overalls/editor-runtime/node.exe
      cp ${editorRuntime}/bin/rg.exe tree/overalls/editor-runtime/rg.exe
      cp ${editorRuntime}/overalls-editor-windows-runtime.json tree/overalls/editor-runtime/runtime.json
      cp -r ${editorRuntime}/licenses tree/overalls/editor-runtime/licenses
    ''}
    ${lib.optionalString (editorBundle != null) ''
      mkdir -p tree/overalls/editor-broker
      # Joliet has a 240-character path limit. Keep the native payload in one
      # short regular-file archive and let the SYSTEM installer verify and
      # extract it after boot, preserving long editor paths exactly.
      python3 -I ${./stage-editor.py} ${editorBundle} tree/overalls/editor-broker
      cp ${editorBroker}/bin/overalls-vscode-web-broker.exe tree/overalls/editor-broker/
      cp ${editorBroker}/manifest.json tree/overalls/editor-broker/manifest.json
      cp ${editorConfiguration} tree/overalls/editor-broker/broker.json
      cp ${editorCustodianConfiguration} tree/overalls/editor-broker/custodian.json
      cp ${./editor-custody.ps1} tree/overalls/editor-broker/custody.ps1
      cp ${./install-editor.ps1} tree/overalls/editor-broker/install.ps1
      cp ${./start-editor.ps1} tree/overalls/editor-broker/start.ps1
      cp ${./start-custodian.ps1} tree/overalls/editor-broker/start-custodian.ps1
    ''}
    chmod -R u+w tree
    xorriso -as mkisofs -iso-level 3 -J -R -V OVERALLS_SETUP \
      -eltorito-alt-boot -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
      -o "$out" tree
  '';

  # @cc [owner:ghuntley,label:build;isolation] windows-install-kvm-sandbox
  # The installation MUST run inside the Nix sandbox on KVM with user-mode
  # networking restricted (`restrict=on`), boot the raw disk through
  # modern-only virtio-pci devices, and succeed only when the guest reports
  # OVERALLS-SETUP-COMPLETE over COM1 and powers off by itself.

  # @cc [owner:ghuntley,label:verification] windows-install-evidence
  # Every installation run MUST leave `evidence/` with the driver timeline
  # (`timeline.jsonl`), the raw serial log, change-triggered screenshots, the
  # driver summary and, when the guest published them, the Windows Setup and
  # driver-binding logs read back from the EFI system partition with mtools.
  # Missing guest logs are recorded in `evidence/guest-logs-missing`, never
  # silently dropped, and never fail an otherwise complete installation.
  disk = pkgs.runCommand "${imageName}-disk" {
    # The installed disk and its evidence MUST NOT reference build inputs
    # (ISO, QEMU, firmware, vendored crates): hosts would keep them alive.
    allowedReferences = [ ];
    requiredSystemFeatures = [ "kvm" ];
    preferLocalBuild = true;
    nativeBuildInputs = [ pkgs.qemu_kvm pkgs.util-linux pkgs.python3 pkgs.mtools pkgs.jq ];
    MTOOLS_SKIP_CHECK = "1";
  } ''
    mkdir -p "$out/evidence" work
    truncate -s ${toString diskBytes} work/disk.raw
    cp ${pkgs.OVMF.variables} work/vars.fd
    chmod u+w work/vars.fd
    # The driver's exit code is recorded, not propagated: a failed installation
    # must still leave its evidence in the store (a failed derivation output is
    # discarded). The image derivation below refuses a non-zero result.
    set +e
    python3 -I ${./install.py} \
      --qemu ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
      --ovmf-code ${pkgs.OVMF.firmware} \
      --ovmf-vars work/vars.fd \
      --boot-iso ${configMedia} \
      --source-iso ${windowsIso} \
      --disk work/disk.raw \
      --evidence-dir "$out/evidence" \
      --monitor work/monitor.sock \
      --qmp work/qmp.sock \
      --memory-mib ${toString installMemoryMiB} \
      --cores ${toString installCores} \
      --timeout-seconds ${toString installTimeoutSeconds} \
      --keypress-seconds 0 \
      --serve "${wingetServer}" \
      --serve-command "${pkgs.python3}/bin/python3 -I ${./serve-pinned.py} ${wingetPayload}/serve $PWD/work/serve-pinned.log"
    result=$?
    set -e
    echo "$result" > "$out/evidence/result"
    # The file server's request log (request lines and statuses only).
    cp work/serve-pinned.log "$out/evidence/serve-pinned.log" 2>/dev/null || echo "no requests" > "$out/evidence/serve-pinned.log"
    # Guest logs live on FAT32 partitions: the EFI system partition after a
    # complete installation, or the OVERALLSLOG scratch partition the forensics
    # step creates when Setup stalls. Read every FAT partition with mtools.
    sfdisk --json work/disk.raw > "$out/evidence/partitions.json" 2>/dev/null || echo '{}' > "$out/evidence/partitions.json"
    found=0
    for start in $(jq -r '.partitiontable.partitions[]?.start // empty' "$out/evidence/partitions.json"); do
      target="$out/evidence/guest-logs/partition-$start"
      mkdir -p "$target"
      if mcopy -n -s -i "work/disk.raw@@$((start * 512))" ::/overalls/logs/ "$target/" 2>/dev/null; then
        found=1
      else
        rmdir "$target" 2>/dev/null || true
      fi
    done
    if [ "$found" = 0 ]; then
      echo "no FAT partition with /overalls/logs in the installed disk" > "$out/evidence/guest-logs-missing"
    fi
    fallocate --dig-holes work/disk.raw
    install -m 0444 work/disk.raw "$out/disk.raw"
  '';

  firmwareImage = "${firmware.fd}/FV/CLOUDHV.fd";
in
# @cc [owner:ghuntley,label:build] windows-image-artifacts
# The image directory MUST contain `firmware` (the PVH UEFI firmware),
# `disk.raw` (the installed GPT disk) and a `manifest.json` with only
# protocol-owned keys: `boot.kind` `firmware` with `pci` true,
# `root.format` `raw-gpt`, the configured `guest_agents` (`none`,
# `windows-v1` or `windows-editor-v1`), the minima and a workspace source version that is 2 for
# an agent-bearing image and null otherwise, and git_identity_version 1 only
# with agents, with digests and byte counts matching the two artifacts exactly.
# Ordinary images MUST remain v5 without an editor descriptor. Editor
# candidates MUST use v7, os windows and the exact immutable editor descriptor.
# No display name: Marshall names images at
# registration. The installation evidence directory is kept beside them.
pkgs.runCommand imageName {
  nativeBuildInputs = [ pkgs.jq ];
  preferLocalBuild = true;
  # The runtime closure is the disk and the firmware only (ADR-0171 image
  # pre-distribution copies it to every host).
  allowedReferences = [ disk firmware.fd ];
  passthru = {
    inherit disk firmware configMedia bootWim bootFiles driverTree answerFile windowsIso wimImageName diskBytes agents guestAgents editorRuntime editorBundle editorBroker editorConfiguration editorCustodianConfiguration editorDescriptor wingetPayload;
    editorCapability = false;
  };
} ''
  result=$(cat ${disk}/evidence/result)
  if [ "$result" != 0 ]; then
    echo "Windows installation failed with result $result; evidence kept in ${disk}/evidence" >&2
    jq . ${disk}/evidence/summary.json >&2 || true
    exit 1
  fi
  # A complete installation without its tools, or with any trace of the
  # build's one-shot autologon, is not an image.
  for marker in OVERALLS-SPECIALIZE-FEATURES-ENABLED OVERALLS-WINGET-INSTALLED OVERALLS-WINGET-COMPLETE OVERALLS-AUTOLOGON-CLEARED ${lib.optionalString (editorBundle != null) "OVERALLS-EDITOR-CANDIDATE-INSTALLED"}; do
    if ! grep -aq "$marker" ${disk}/evidence/serial.log; then
      echo "Windows installation lacks $marker; evidence kept in ${disk}/evidence" >&2
      exit 1
    fi
  done
  mkdir -p "$out"
  ln -s ${firmwareImage} "$out/firmware"
  ln -s ${disk}/disk.raw "$out/disk.raw"
  cp -r ${disk}/evidence "$out/evidence"
  chmod -R u+w "$out/evidence"
  firmware_bytes=$(stat -L -c %s "$out/firmware")
  firmware_sha256=$(sha256sum "$out/firmware" | cut -d ' ' -f 1)
  disk_bytes=$(stat -L -c %s "$out/disk.raw")
  disk_sha256=$(sha256sum "$out/disk.raw" | cut -d ' ' -f 1)
  jq -n \
    --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
    --argjson disk_bytes "$disk_bytes" --arg disk_sha256 "$disk_sha256" \
    --argjson minimum_memory_bytes ${toString minimumMemoryBytes} \
    --argjson minimum_disk_bytes ${toString diskBytes} \
    --arg guest_agents ${lib.escapeShellArg guestAgents} \
    --argjson workspace_source_version ${if guestAgents != "none" then "2" else "null"} \
    --argjson editor_descriptor ${lib.escapeShellArg (builtins.toJSON editorDescriptor)} \
    '{
      version: 5,
      architecture: "x86_64",
      boot: { kind: "firmware", pci: true, firmware: { bytes: $firmware_bytes, sha256: $firmware_sha256 } },
      root: { format: "raw-gpt", bytes: $disk_bytes, sha256: $disk_sha256 },
      guest_agents: $guest_agents,
      minimum_memory_bytes: $minimum_memory_bytes,
      minimum_disk_bytes: $minimum_disk_bytes,
      workspace_source_version: $workspace_source_version
    } + (if $guest_agents != "none" then {git_identity_version:1} else {} end)
      + (if $editor_descriptor == null then {} else {version:7,os:"windows",editor:$editor_descriptor} end)' > "$out/manifest.json"
''
