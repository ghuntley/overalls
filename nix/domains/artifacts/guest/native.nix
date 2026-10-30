{ pkgs, firmware ? (import ./windows/firmware.nix { inherit pkgs; }).fd, nativeAgents ? null, lyra ? null }:
let
  inherit (pkgs) lib;
  nativeKernels = import ./native-kernels { inherit pkgs; };
  # Source/patch receipts do not establish a bootable kernel or installed service
  # closure. Keep admission closed until target-native assembly and machine
  # evidence are reviewed together under ADR-0190.
  nativeImageAssemblyReady = false;
  # Native guests are deliberately assembled from immutable upstream release
  # artifacts.  The source derivations are separate so a source refresh cannot
  # silently change the manifest or the file set.
  mkFreeBSDSource = pkgs.fetchurl {
    pname = "freebsd-14.3-amd64-basic-cloudinit-ufs";
    version = "14.3-RELEASE";
    # FreeBSD removed 14.3 from the rolling VM-IMAGES index. Keep the release
    # URL and digest explicit; updating this pin requires a reviewed source
    # refresh, rather than following Latest.
    url = "https://web.archive.org/web/20250625173735id_/https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz";
    hash = (import ../pins.nix).freebsdCloudImage;
  };
  mkOmniOSSource = pkgs.fetchurl {
    pname = "omnios-r151050-cloud-raw";
    version = "r151050";
    url = "https://downloads.omnios.org/media/r151050/omnios-r151050.cloud.raw.zst";
    hash = (import ../pins.nix).omniosCloudImage;
  };
  # illumos.org is the upstream operating-system project. It publishes the
  # common source and directs users to downstream distributions for installable
  # images; the pinned OmniOS artifact below is therefore the concrete illumos
  # image source used by this builder.
  illumosUpstreamUrl = "https://illumos.org/";
  nativeServices = import ./native-agents.nix {
    inherit pkgs lyra;
    terminald = import ../infrastructure/terminald.nix { inherit pkgs; };
  };
  nativePayload = if nativeAgents != null then nativeAgents
    else if lyra == null then null
    else pkgs.runCommand "overalls-native-agent-payload" {} ''
      mkdir -p "$out/freebsd" "$out/illumos"
      cp -a ${nativeServices.freebsd}/. "$out/freebsd/"
      cp -a ${nativeServices.illumos}/. "$out/illumos/"
    '';
  nativeAgentNames = nativeServices.manifest.agents;
  nativeGit = import ./native-git.nix { inherit pkgs; };
  # @cc [owner:ghuntley,label:build;protocol] freebsd-native-image-pinned
  # The FreeBSD builder MUST use the reviewed 14.3 source pin, preserve its
  # complete GPT/EFI/UFS disk for the CloudHv firmware boot path, and bind
  # every emitted artifact's exact byte length and SHA-256 in the v6 manifest.

  # @cc [owner:ghuntley,label:build;protocol] native-candidate-git-identity
  # Explicit version-1 attribution MUST require source-v2 and the native payload.
  # Its declaration changes candidate identity; it MUST NOT relabel published
  # immutable disks or establish admission without exact native qualification.
  mkFreeBSD = { imageName ? "lilly-freebsd-14_3-x86_64", minimumMemoryBytes ? 1073741824
    , minimumDiskBytes ? 68719476736, workspaceSourceVersion ? 2, gitIdentityVersion ? null
    , kernel ? nativeKernels.freebsd
    , kernelProvenance ? (if kernel ? provenance then kernel.provenance else null)
    , stagingOnly ? false }:
    assert workspaceSourceVersion == null || nativeAgents != null || lyra != null;
    assert gitIdentityVersion == null || (builtins.isInt gitIdentityVersion && gitIdentityVersion == 1 && workspaceSourceVersion == 2 && nativePayload != null);
    let
      kernelDescriptor = if kernelProvenance == null
        then "${kernel}/share/overalls/native-kernel/provenance.json"
        else pkgs.writeText "freebsd-kernel-provenance.json" (builtins.toJSON kernelProvenance);
      kernelReady = if kernelProvenance == null then kernel ? buildId else kernelProvenance.bytes > 1;
    in
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.mtools pkgs.util-linux pkgs.xz pkgs.gnutar pkgs.xorriso ]; preferLocalBuild = true;
      passthru = {
        os = "freebsd";
        release = "14.3-RELEASE";
        inherit firmware kernel kernelProvenance stagingOnly;
        kernelSourceRevision = kernel.sourceRevision;
        kernelSourceHash = kernel.sourceHash;
        kernelPatchHash = kernel.patchHash;
        kernelConfigurationHash = kernel.configurationHash;
        kernelCompiler = if kernelProvenance == null then kernel.compiler else kernelProvenance.compiler;
        inherit kernelReady;
        imageAssemblyReady = nativeImageAssemblyReady;
        nativeAdmission = false;
        source = mkFreeBSDSource;
        sourceUrl = "https://web.archive.org/web/20250625173735id_/https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz";
        sourceHash = (import ../pins.nix).freebsdCloudImage;
      }; } ''
      set -euo pipefail
      # A source receipt cannot replace the stock kernel in this disk. Fail
      # before unpacking it until both kernel and native assembly are attested.
      test ${if kernelReady then "true" else "false"} = true
      test ${if nativeImageAssemblyReady || stagingOnly then "true" else "false"} = true
      mkdir -p "$out"
      # Keep the source disk sparse while retaining GPT backup metadata and the
      # EFI system partition. A direct FreeBSD ELF kernel cannot be consumed by
      # Firecracker's Linux kernel loader.
      xz -dc ${mkFreeBSDSource} | dd of="$out/disk.raw" bs=1M conv=sparse status=none
      ${lib.optionalString (nativePayload != null) ''
        mkdir -p "$out/evidence/native-agents/freebsd" "$out/evidence/native-services/freebsd"
        for agent in ${lib.escapeShellArgs nativeAgentNames}; do
          test -x ${nativePayload}/freebsd/bin/"$agent"
        done
        cp -a ${nativePayload}/freebsd/bin/. "$out/evidence/native-agents/freebsd/"
        cp ${nativePayload}/freebsd/usr/local/libexec/native-agents-supervisor \
          ${nativePayload}/freebsd/usr/local/etc/rc.d/overalls-native-agents \
          ${nativePayload}/freebsd/etc/rc.conf.d/overalls_native_agents \
          "$out/evidence/native-services/freebsd/"
        # Linux cannot mutate UFS, and the pinned ESP cannot hold all native
        # binaries. Use a separate, read-only installation ISO for the target
        # assembler; the final installed disk must boot without this media.
        esp_start=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "efiesp") | .start')
        mmd -i "$out/disk.raw@@$((esp_start * 512))" ::overalls
        payload="$TMPDIR/freebsd-payload"
        mkdir -p "$payload"
        tar --format=ustar --owner=0 --group=0 --numeric-owner \
          -C ${nativePayload}/freebsd -cf "$payload/freebsd-root.tar" etc usr
        tar --format=ustar --owner=0 --group=0 --numeric-owner \
          -C ${nativeGit.freebsd} -cf "$payload/git-root.tar" .
        test -f ${nativeGit.freebsd}/usr/local/bin/sudo
        test ! -L ${nativeGit.freebsd}/usr/local/bin/sudo
        sha256sum ${nativeGit.freebsd}/usr/local/bin/sudo | cut -d ' ' -f1 > "$payload/sudo-sha256"
        cp ${./native-kernels/freebsd/vsock.h} "$payload/vsock.h"
        test -n '${lib.optionalString (kernel ? buildId) kernel.buildId}'
        test -f ${kernel}/kernel
        test "$(stat -Lc %s ${kernel}/kernel)" -eq "$(jq -er .bytes ${kernelDescriptor})"
        test "$(sha256sum ${kernel}/kernel | cut -d ' ' -f1)" = "$(jq -er .sha256 ${kernelDescriptor})"
        cp ${kernel}/kernel "$payload/kernel"
        printf '%s\n' '${lib.optionalString (kernel ? buildId) kernel.buildId}' > "$payload/kernel-build-id"
        cp ${kernelDescriptor} "$payload/kernel-provenance.json"
        xorriso -as mkisofs -quiet -R -J -V OVERALLS_NATIVE -o "$out/payload.iso" "$payload"
        config_start=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "config-drive") | .start')
        config_size=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "config-drive") | .size')
        config_drive="$TMPDIR/freebsd-config-drive.img"
        dd if="$out/disk.raw" of="$config_drive" bs=512 skip="$config_start" count="$config_size" status=none
        mformat -i "$config_drive" -v cidata ::
        cat > "$TMPDIR/freebsd-meta-data" <<'EOF'
instance-id: overalls-native
local-hostname: overalls-native
EOF
        mcopy -i "$config_drive" "$TMPDIR/freebsd-meta-data" ::meta-data
        cat > "$TMPDIR/freebsd-user-data" <<'EOF'
#!/bin/sh
set -eu
esp=/boot/efi
if ! mount -p | grep -q '[[:space:]]/boot/efi[[:space:]]'; then
  mount -t msdosfs /dev/gpt/efiesp "$esp"
fi
payload=/mnt/overalls-installer
mkdir -p "$payload"
mount -t cd9660 /dev/iso9660/OVERALLS_NATIVE "$payload"
tar -xpf "$payload/freebsd-root.tar" -C /
tar -xpf "$payload/git-root.tar" -C /
install -d -o root -g wheel -m 0755 /usr/local/libexec /usr/local/etc/rc.d /etc/rc.conf.d /etc/overalls
install -o root -g wheel -m 0644 "$payload/vsock.h" /usr/include/sys/vsock.h
install -o root -g wheel -m 0644 "$payload/kernel-build-id" /etc/overalls/kernel-build-id
install -o root -g wheel -m 0644 "$payload/kernel-provenance.json" /etc/overalls/kernel-provenance.json
install -o root -g wheel -m 0555 "$payload/kernel" /boot/kernel/kernel
# The pinned Firecracker microVM supplies MSI-X and no chipset capability list.
# Enable MSI for this platform; generic FreeBSD blacklist policy is unchanged.
printf '\nhw.pci.honor_msi_blacklist="0"\n' >> /boot/loader.conf.local
sync
# Services start through rc.d after the target assembler reboots into the new
# kernel. Running them against the stock first-boot kernel cannot prove support.
EOF
        cp "$TMPDIR/freebsd-user-data" "$out/evidence/freebsd-user-data"
        mcopy -i "$config_drive" "$TMPDIR/freebsd-user-data" ::user-data
        dd if="$config_drive" of="$out/disk.raw" bs=512 seek="$config_start" conv=notrunc status=none
      ''}
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "efiesp")' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "rootfs")' >/dev/null
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson git_identity ${if gitIdentityVersion == null then "null" else toString gitIdentityVersion} \
        --argjson source ${lib.optionalString (workspaceSourceVersion == null) "null"}${lib.optionalString (workspaceSourceVersion != null) (toString workspaceSourceVersion)} \
        --slurpfile kernel ${kernelDescriptor} \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"freebsd",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},kernel:$kernel[0],root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"freebsd-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source} + (if $git_identity == 1 then {git_identity_version:1} else {} end)' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] omnios-native-image-pinned
  # The OmniOS builder MUST use the immutable r151050 cloud raw pin and emit
  # the v6 illumos firmware/raw-GPT shape; it MUST NOT reuse a Linux ext4
  # builder or infer its agent capability from installed files.
  mkOmniOS = { imageName ? "lilly-omnios-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null, gitIdentityVersion ? null
    , kernel ? nativeKernels.illumos, kernelProvenance ? kernel.provenance }:
    assert workspaceSourceVersion == null || nativeAgents != null || lyra != null;
    assert gitIdentityVersion == null || (builtins.isInt gitIdentityVersion && gitIdentityVersion == 1 && workspaceSourceVersion == 2 && nativePayload != null);
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux pkgs.zstd ]; preferLocalBuild = true;
      passthru = {
        os = "illumos";
        distribution = "OmniOS";
        release = "r151050";
        nativeAgentsAvailable = nativeAgents != null;
        inherit firmware kernel kernelProvenance;
        kernelSourceRevision = kernel.sourceRevision;
        kernelSourceHash = kernel.sourceHash;
        kernelPatchHash = kernel.patchHash;
        kernelConfigurationHash = kernel.configurationHash;
        kernelCompiler = kernelProvenance.compiler;
        kernelReady = kernelProvenance.bytes > 1;
        imageAssemblyReady = nativeImageAssemblyReady;
        nativeAdmission = false;
        illumosSdk = nativeKernels.illumosSdk;
        upstreamUrl = illumosUpstreamUrl;
        source = mkOmniOSSource;
        sourceUrl = "https://downloads.omnios.org/media/r151050/omnios-r151050.cloud.raw.zst";
        sourceHash = (import ../pins.nix).omniosCloudImage;
      }; } ''
      set -euo pipefail
      # A source receipt cannot replace the stock kernel in this disk. Fail
      # before unpacking it until both kernel and native assembly are attested.
      test ${if kernelProvenance.bytes > 1 then "true" else "false"} = true
      test ${if nativeImageAssemblyReady then "true" else "false"} = true
      mkdir -p "$out"
      zstd -dc ${mkOmniOSSource} > "$out/disk.raw"
      ${lib.optionalString (nativePayload != null) ''
        mkdir -p "$out/evidence/native-agents/illumos" "$out/evidence/native-services/illumos"
        for agent in ${lib.escapeShellArgs nativeAgentNames}; do
          test -x ${nativePayload}/illumos/bin/"$agent"
        done
        cp -a ${nativePayload}/illumos/bin/. "$out/evidence/native-agents/illumos/"
        cp ${nativePayload}/illumos/opt/overalls/libexec/native-agents-supervisor \
          ${nativePayload}/illumos/opt/overalls/libexec/native-agents-start \
          ${nativePayload}/illumos/lib/svc/manifest/site/overalls-native-agents.xml \
          "$out/evidence/native-services/illumos/"
        # These are installation inputs only. The Linux builder cannot replace
        # the ZFS root's kernel/modules or import SMF services. Target-native
        # assembly and a subsequent verified boot remain mandatory.
      ''}
      # Keep the complete OmniOS GPT layout.  The loader and ZFS partitions
      # are required by CloudHv firmware; accepting an arbitrary raw disk here
      # would produce a manifest that cannot boot the pinned userspace.
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.label == "gpt"' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "loader")' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "zfs")' >/dev/null
      # The CloudHv PVH firmware is supplied by the pinned package input. It is
      # content-addressed in the manifest alongside the OmniOS disk.
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson git_identity ${if gitIdentityVersion == null then "null" else toString gitIdentityVersion} \
        --argjson source ${lib.optionalString (workspaceSourceVersion == null) "null"}${lib.optionalString (workspaceSourceVersion != null) (toString workspaceSourceVersion)} \
        --argjson kernel '${builtins.toJSON kernelProvenance}' \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"illumos",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},kernel:$kernel,root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"illumos-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source} + (if $git_identity == 1 then {git_identity_version:1} else {} end)' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] illumos-downstream-image
  # The generic illumos constructor MUST use the pinned OmniOS downstream
  # artifact while preserving the illumos protocol family and manifest shape.
  # illumos.org is an upstream source project, not an image distribution, so a
  # direct URL cannot be used as a guest root without selecting a downstream.
  mkIllumos = { imageName ? "lilly-illumos-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null, gitIdentityVersion ? null
    , kernel ? nativeKernels.illumos, kernelProvenance ? kernel.provenance }:
    mkOmniOS { inherit imageName minimumMemoryBytes minimumDiskBytes workspaceSourceVersion gitIdentityVersion kernel kernelProvenance; };
in
{ inherit mkFreeBSD mkOmniOS mkIllumos mkFreeBSDSource mkOmniOSSource illumosUpstreamUrl nativeKernels; }
