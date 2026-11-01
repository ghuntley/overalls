# Windows guests under Firecracker

This documents the Windows Server 2025 guest recorded in
[ADR-0169](../architecture/decisions/0169-firmware-booted-windows-guests.md) (the
bootable image) and
[ADR-0170](../architecture/decisions/0170-lilly-firmware-guest-launch.md) (the
Lilly launch path). The image boots under the patched Firecracker to the
Windows Special Administration Console (SAC) on the serial port, and Lilly can
place it as a guest without agents: running, reachable on its `/32`, never
`guest_ready`. The `windows-v1` image adds the guest agents of
[ADR-0171](../architecture/decisions/0171-windows-guest-agents.md) (readiness, trust,
SSH, terminal, workspace and agent executor over virtio-vsock). The shared fleet
catalog now selects `windowsGuestPublished`: a sealed 64 GiB Desktop Experience image with
the pinned tools and a 96 GiB template budget. The agentless spike below retains
its separate scope. Current admission and execution limits are summarized in
the [OS matrix](os-matrix.md).

## What is built

| Output | Buck2 target or `lib.assemble {}` attribute | Contents |
|--------|-----------------|----------|
| Patched VMM | `packages.vmm` (checked by `//:check-firecracker-vmm`) | nixpkgs static Firecracker 1.16.1 plus the shared reviewed firmware, PCI, device, transport and reset patches selected in `nix/domains/artifacts/infrastructure/firecracker.nix` |
| Firmware | `packages.windowsFirmware` (`//:check-windows-firmware`) | edk2 CloudHv UEFI as a PVH ELF, PCI aperture ending at Firecracker's MMCONFIG (`$fd/FV/CLOUDHV.fd`) |
| Image | `//:package-guest-windows` | `firmware`, sparse `disk.raw` (64 GiB GPT), eight-key `manifest.json` version 5, `evidence/` |
| Launcher | `packages.windowsBoot` | `overalls-windows-boot IMAGE_DIR WORK_DIR [MEM_MIB] [VCPUS]` |

The installation ISO is the Windows Server 2025 **Evaluation** media pinned in
`nix/domains/artifacts/guest/windows/iso.json` (URL, build and SHA-256). It is fetched
by `fetchurl` like any other build input; the licence runs 180 days of guest
uptime. Production use needs licensed media swapped into `iso.json`.

## Building

```sh
tools/buck2 build //:check-windows-firmware
tools/buck2 build //:package-guest-windows   # ~6 GiB download, then 20-40 min of installation on KVM
```

The image build runs QEMU with KVM inside the Nix sandbox
(`requiredSystemFeatures = ["kvm"]`), offline (`restrict=on` user networking),
with OVMF, the virtio-win `2k25` drivers and `autounattend.xml`. Setup ends
with `SetupComplete.cmd`, which installs the remaining drivers, enables EMS on
COM1 at 115200 baud, disables sleep, Windows Update restarts, DHCP and IPv6,
writes `OVERALLS-SETUP-COMPLETE` to the serial port and powers off. The build
fails if the marker never appears.

Every rebuild produces a different disk image: Windows installation is not
byte-stable. Hash-pinned inputs keep rebuilds rare.

### Fleet publication

`windowsGuestAgents` remains the offline source builder for development and
verification. Fleet staging and catalog registration instead use
[`windowsGuestPublished`](../../nix/domains/artifacts/guest/windows/published.nix),
which fixes the existing `windows-v1` installation's recursive NAR identity.
The sealed directory contains exactly three regular files: `disk.raw`,
`firmware` and `manifest.json`, with no store references. Both hosts consume the
same bytes through the existing signed Overalls cache. A cache miss prints
publication guidance and fails; it cannot run another installation or select a
host-local image.

The reviewed publication is
`/nix/store/n1jf5kk658v71kixs1j0652mlqvb2in2-overalls-windows-server-2025-8ca0a11f`,
recursive NAR hash `sha256-MTpVti0Mc+c3FzqjUJLfBAfEIW+plgP+HheZnVdPlUo=`.
Its 68,719,476,736-byte root SHA-256 is
`2eee37f946e7688719b09b9e8b285431ef2332513f768c0b02a9e82c9e90fd05`;
the 4,194,304-byte firmware SHA-256 is
`261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2`.
The sealed 68,723,672,224-byte NAR has no references. Its public cache signature
passed actual Ed25519 verification of the exact NAR fingerprint. Independent
Dungarees substitution began with the path absent, then passed
`nix store verify --sigs-needed 1`, including full NAR content verification,
and independently checked the exact regular file set, manifest/canonical image
identity and complete disk/firmware hashes. The source selector pins those
reviewed bytes. Deployment and fresh guest execution remain separate evidence.

For an intentional image update, build once with the source builder, retain its
installation evidence, seal dereferenced disk/firmware and the unchanged
manifest, then review their sizes, digests, file custody and recursive NAR hash.
Update the publication name/hash and manifest pins together. Add the sealed
directory with `nix store add-path --name NAME DIRECTORY` and publish that exact
path through the existing Overalls Cachix publisher. Verify the fixed-output
package resolves to those bytes through ordinary signature-checked substitution
on the other host before activating a changed catalog. An input-addressed source
derivation path alone cannot establish a shared Windows identity.

## Installation evidence

The image directory carries `evidence/`, written by `install.py` during the
build so a failed or suspicious installation can be debugged without rerunning
it:

| File | Source | Use |
|------|--------|-----|
| `timeline.jsonl` | driver | One JSON object per line: UTC time, elapsed seconds, event. Events: `start` (full QEMU command), `qemu_event` (QMP `RESET`, `SHUTDOWN`, `POWERDOWN`, …; each RESET is a Windows Setup stage boundary), `serial_marker` (guest checkpoints), `screenshot`, `disk_usage`, `finish`. |
| `serial.log` | guest COM1 | Raw serial output. Checkpoints: `OVERALLS-WINPE-START`, `OVERALLS-SPECIALIZE-START`, `OVERALLS-SPECIALIZE-PAYLOAD-OK`, `OVERALLS-SETUPCOMPLETE-START`, `OVERALLS-DRIVERS-INSTALLED`, `OVERALLS-GUEST-CONFIGURED`, `OVERALLS-EMS-ENABLED`, `OVERALLS-LOGS-PUBLISHED`, `OVERALLS-SETUP-COMPLETE`. A missing checkpoint places the failure between two known steps. |
| `screenshots/` | QMP `screendump` | PNG frames taken every 30 s and after each lifecycle event or marker, kept only when the framebuffer changed. Names carry the frame index, elapsed seconds and the reason. |
| `summary.json` | driver | Result code and reason, duration, lifecycle events, markers seen, screenshots kept, disk usage. |
| `partitions.json` | `sfdisk --json` | Partition table of the installed disk. |
| `guest-logs/` | guest via ESP | `SetupComplete.cmd` publishes `C:\Windows\Panther\setupact.log`, `setuperr.log`, the specialize-pass logs under `UnattendGC`, `setupapi.dev.log` (driver binding), `setup-complete.log` and an `evidence/` inventory (`devices.txt`, `drivers.txt`, `driverquery.txt`, `systeminfo.txt`, `storage.txt`, `network.txt`, BCD before and after EMS) on the EFI system partition; the build reads them with `mcopy` from the raw disk. `guest-logs-missing` records why they could not be read. |

`overalls-windows-boot` writes Firecracker's own log (`firecracker.log`, level
from `OVERALLS_WINDOWS_LOG_LEVEL`, default `Info`) and metrics into the work
directory, so unhandled guest I/O and device errors from the real boot are kept
beside the disk copy.

### Failed installations keep their evidence

The disk derivation never fails on an installation error; it records the
driver's exit code in `evidence/result` and the image derivation refuses a
non-zero result. The evidence of a failed run therefore stays in the store:

```sh
tools/buck2 build //:package-guest-windows   # fails: "Windows installation failed with result 5; evidence kept in /nix/store/...-disk/evidence"
nix build --impure --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).packages.windowsGuest.disk' --print-out-paths
```

Result codes: `2` timeout, `3` guest powered off without the completion marker,
`4` QEMU exited with an error, `5` Setup stalled and forensics ran.

### Automatic forensics on a stalled Setup

If seven minutes pass with no reboot, no serial checkpoint and under 1 MiB
written to the disk, the driver assumes Windows Setup is stuck on an error
screen in Windows PE. It opens the Windows PE prompt with Shift+F10 through the
QEMU monitor, creates a 512 MiB FAT32 scratch partition labelled `OVERALLSLOG`
on the still-unused disk with `diskpart`, copies `X:\$WINDOWS.~BT\Sources\Panther`
(the new Setup's `setupact.log`, `setuperr.log`, `diagerr.xml`, `diagwrn.xml`)
and `X:\Windows\Panther` there, and powers off with `wpeutil shutdown`. Every
typed command is recorded in the timeline with a screenshot. The build then
reads the logs into `evidence/guest-logs/partition-<start>/` with mtools. The
Windows PE environment has no COM1 device, so serial checkpoints from the
`windowsPE` pass are not expected; the first checkpoint that can reach the
serial log is `OVERALLS-SPECIALIZE-START`.

### Driver-load variants

`mkWindowsGuest { winpeDriverLoad = "drvload"; }` (exported as
`windowsGuestDrvload`) loads `viostor` with `drvload` from a `RunSynchronous`
command instead of the answer file's `DriverPaths`. It exists to isolate Setup
initialization failures that involve driver paths; `paths` is the default.

## Booting

```sh
image=$(cat "$(tools/buck2 build --show-full-simple-output //:package-guest-windows)")
boot=$(nix build --impure --print-out-paths --no-link --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).packages.windowsBoot')
sudo "$boot/bin/overalls-windows-boot" "$image" work
```

The launcher copies `disk.raw` into `work/` (sparse, reflink where possible),
creates a tap device `fcwin0` with `172.16.0.1/30`, writes `firecracker.json`
(firmware as `kernel_image_path`, no initrd, no boot arguments, `cpu-config`
with `hyperv: true`, MMDS V2 on `eth0`) and runs
`firecracker --enable-pci`. The terminal is the Windows serial console:

1. Firmware banner, then the Windows boot manager over EMS.
2. `SAC>` prompt. `cmd` opens a command channel, `ch -si 1` switches to it.
3. Log in as `Administrator` with the bootstrap password from
   `nix/domains/artifacts/guest/windows/default.nix` (`adminPassword`).
4. `i` lists network interfaces; `i <index> 172.16.0.2 255.255.255.252 172.16.0.1`
   assigns an address on the launcher's tap.

The launcher runs without the jailer and without Lilly's network guard. It is
an operator tool for the spike only.

Recorded boot (2026-10-13, eight-patch VMM, 2 vCPU, 4 GiB): the firmware
enumerated the two virtio-pci devices, started the Windows Boot Manager from
the EFI system partition, and Windows printed its SAC banner within about a
minute. The console then answered:

```text
EVENT: The CMD command is now available.
SAC>id
           Computer Name: OVERALLS
           Computer GUID: 00000000-0000-0000-0000-000000000000
  Processor Architecture: AMD64
          Version Number: 10.0
            Build Number: 26100
                 Product: Windows Server
    Applied Service Pack: None
  Time since last reboot: 0:01:09
SAC>i
SAC is retrieving IP Addresses...
Net: 7, Ip=169.254.213.181  Subnet=255.255.0.0  Gateway=0.0.0.0
```

`firecracker.log` beside the disk copy shows the BAR relocations the firmware
performed and the guest's hypervisor probes (extended Hyper-V hypercall
`0x8001`, VMware port `0x5658`), all answered as absent.

## Launching through Lilly

A version-5 image is admitted by the shared protocol like any other image:
`OverallsProtocol.ImageManifest.validate/1` returns `boot_kind: :firmware`,
`root_format: :raw_gpt` and `guest_agents: :none`, and the identity is
`sha256:` over the `lilly-image-v5` array. Operators stage the image directory
in `services.lilly.images` and register it with
`Marshall.Compute.Images.register(manifest, name)` (the manifest carries no
name) after every host runs a release that understands the shape. This describes
the agentless spike. The shared `fleet/guest-images.nix` now stages and registers
the sealed `windowsGuestPublished` image through the ordinary fleet path.

What Lilly does differently for a firmware image:

- The dataset holds `firmware`, `rootfs.ext4` (the root drive slot, filled from
  the image's `disk.raw`) and a version-2 `boot-bundle.json`
  (`boot: firmware`, `pci: true`, `guest_agents: none`, `firmware_bytes`).
- The jail bind-mounts the firmware read-only and writes `metadata.json`
  (`{"lilly": {version, placement, execution_epoch, boot_challenge, ipv4,
  prefix_length: 32, gateway, mac}}`), which Firecracker loads into MMDS with
  `--metadata` before the guest runs; `firecracker.json` boots `/firmware` with
  `cpu-config.hyperv` and MMDS V2 on `eth0`, no initrd, no boot arguments and
  a vsock device only when the bundle's agent set speaks the Lilly guest
  protocols (`windows-v1`; the agentless image has none); the unit adds
  `--enable-pci`.
- Trust is recorded as `skipped` for the boot (`guest-trust.json`), provisioning
  ends in the `unattested` phase (`provisioning.json`), and the VM is reported
  running without `guest_ready`. Terminals, workspace sources and the Inception
  profile are refused.

Inside the guest, the scheduled task `Overalls\Bootstrap`
(`C:\overalls\bootstrap\overalls-bootstrap.ps1`, SYSTEM, at every boot) reaches
MMDS over a temporary link-local address if needed, fetches `/lilly` with a V2
session token, validates every field including the adapter MAC, sets exactly
the delivered `/32` with an on-link route to the gateway and a default route
through it, keeps DHCP and IPv6 off, grows `C:` into host-added space and logs
to `C:\overalls\logs\bootstrap-*.log` (never the token or the challenge). The
applied identity is kept in `C:\overalls\network\state.json` and, together
with the log, published on the EFI system partition under `\overalls\logs`, so an
operator can read it from the raw disk with mtools without logging in; an
Application event log entry (`Overalls`) records the result. Lilly's host policy
drops unmarked traffic between the host and a Customer guest, so the guest is
not reachable from the host until Windows agents and the SSH ingress path exist.

In Marshall the VM shows Settings and Access only: Terminal, Agents, the editor
and the SSH connection panel are hidden and refused server-side because the
image's per-capability facts (`guest_capabilities`, derived from
`OverallsProtocol.GuestAgents` for the agent set `none`) are all false,
Inception admission is refused, and only the physical service level is
measured. A `windows-v1` image (ADR-0171) turns on Terminal, Agents, SSH and
the creation-to-ready measurement with a 600 s readiness budget and keeps the
editor and Inception refused.

## Windows agents over vsock (ADR-0171, in progress)

The agents are Rust binaries cross-built from the Lyra crate:

```sh
tools/buck2 build //lyra:windows --show-output   # bin/*.exe + manifest.json
```

The image ships the virtio-win `viosock` driver (virtio-vsock, PCI `1AF4:1053`)
and, while the real agents are being built, the transport probe
`C:\overalls\agents\overalls-winprobe.exe` as the SYSTEM task `Overalls\WinProbe`.
The probe discovers the provider's address family at runtime (the `\\.\Viosock`
control device or the Winsock catalog), listens on vsock port 1099 and answers
each host connection with one JSON line; its log is `C:\overalls\logs\winprobe.log`,
published on the EFI system partition like the bootstrap log. With the operator
launcher the vsock Unix socket is `work/v.sock`:

```sh
printf 'CONNECT 1099\n' | socat - UNIX-CONNECT:work/v.sock
# OK 1099
# {"probe":"overalls-winprobe","version":"0.1.0","address_family":N,"source":"ioctl","peer_cid":2,...}
```

`windowsGuestAgents` (`mkWindowsGuest { agents = lyraWindows; terminald =
terminaldWindows; guestAgents = "windows-v1"; }`) builds the image whose manifest
declares the agent set and workspace source version 2; a `windows-v1` image
requires the terminal daemon. The default `windowsGuest` keeps
`guest_agents = none` with the probe aboard. Every agent is a SYSTEM task under
`\Overalls\` without `schtasks`' default 72-hour execution limit; logs are in
`C:\overalls\logs`.
Standby eligibility, the 96 GiB template budget and the pre-distribution
procedure are described in [docs/operations/nixos.md](../operations/nixos.md).

SSH (gate 3): Win32-OpenSSH has no `AuthorizedKeysCommand`, so
`overalls-ssh-sync-windows.exe` (task `Overalls\SshSync`) pulls the roster and
creates the `u<uid>` accounts (Administrators, random unrecorded password),
requiring each SID-bound registered profile before activation. A new boot
stops `sshd`, clears prior managed authorized-key files and waits for the
verified current-boot host certificate before starting a keyless listener.
It publishes `ssh-ready` before ordinary key retrieval so readiness can
complete provision/start without weakening key authority. Every readiness
poll requires the current bootstrap and certificate receipts plus live sshd.
The agent then pulls `GET /ssh/v1/authorized-keys` every two seconds under
the existing running-execution/completed-start binding and writes
`C:\overalls\ssh\authorized_keys\<user>`. Same-boot retries preserve
current keys. It uses the
shipped `sshd_config` (`AuthorizedKeysFile C:/overalls/ssh/authorized_keys/%u`,
public-key only, no `administrators_authorized_keys`).
`overalls-host-certificate-windows.exe` (task `Overalls\HostCertificate`)
generates a fresh host key at every boot and installs the certificate Audi
issues into `%ProgramData%\ssh`. The roster agent also tails
`%ProgramData%\ssh\logs\sshd.log` (sshd logs to file, `SyslogFacility LOCAL0`)
and reports each accepted public-key login to Audi's `/ssh/v1/login`; after
successful key delivery to a nonempty roster it retires the bootstrap `Administrator` (random
unrecorded password, disabled), so the SAC prompt no longer offers a login on
such guests. Logs: `ssh-sync.log` and `host-certificate.log` beside the other
agent logs.

The repaired profile/bootstrap image `8ca0a11f` passed actual installation in
1,834.2 seconds. Its immutable NTFS copies of the three repaired executables
match the reviewed payloads; the sealed recursive NAR has no references.
Signed cache publication and Ed25519 verification of the exact NAR fingerprint
also passed, followed by independent full-content Dungarees substitution and
whole-artifact hashes. After healthy deployment at `132bc28b5`, a fresh exact
`8ca0a11f` fixture passed create/readiness, strict personal-account CLI SSH with
the exact Server 2025 edition/build 26100 oracle, stop with an independent
stopped-state checkpoint, restart, repeated strict SSH and deleted cleanup.
The runner admits only the exact stock three-line OpenSSH post-quantum warning
for Windows, with unchanged algorithms and trust; its original warning-only
failed stage remains preserved. This records CLI identity and lifecycle scope,
not terminal, executor, workspace, growth or native isolation acceptance. The
old disposable fixture's manual profile repair remains separate evidence.
The [matrix review](../architecture/reviews/2026-10-18-guest-os-matrix.md)
records exact image, NAR and private receipt identities.

Terminal (gate 4): `overalls-terminald.exe` (task `Overalls\Terminald`,
`tools/buck2 build //:check-terminald-windows`) is the Linux
terminald source built for Windows. It listens on vsock port 1075, derives its
HELLO key from the MMDS boot challenge and runs each session as PowerShell in
ConPTY inside a kill-on-close job: `root` is LocalSystem and any other name must
be an enabled roster account (S4U logon). Its log is `terminald.log`.

Workspace (gate 5): `overalls-workspaced-windows.exe` (task `Overalls\Workspaced`)
answers Lilly's delivery on vsock port 1031 and clones into `C:\workspace` with
Git for Windows, installed machine-wide by winget from
`nix/domains/artifacts/guest/windows/winget.json`
(`C:\Program Files\Git\cmd\git.exe`, OpenSSL backend, the trust daemon's
current bundle). Log: `workspaced.log`.

Tools (ADR-0173): images are Windows Server 2025 Desktop Experience with winget
and the pinned packages `git`, `gh`, `claude`, `codex` (with `rg` and the
Visual C++ redistributable), `wsl` and `podman` on the machine PATH; WSL's
optional features are enabled during installation. Add or move a package with
`update-winget-pins.py` (see its header) and rebuild the image; the build
installs only what `winget.json` pins. Visual Studio Community 2026 (C++ and
.NET desktop workloads) comes from the pinned offline layout `vs-layout.json`;
to move it, run `update-vs-layout.ps1` (see its header) as an administrator on
a Windows Desktop Experience guest after importing the intermediates listed in
`vs-layout.json`, copy the result back and rebuild. Installation evidence:
`evidence/winget*.log` beside the image.

Agent executor (gate 5): `overalls-agentd-windows.exe` (task `Overalls\Agentd`)
runs the shared Lyra executor against `llm.internal`; the bootstrap adds an NRPT
rule sending only `.internal` names to 169.254.254.1. Commands run through
Windows PowerShell 5.1 with a 20 s deadline. There is no self-update; a new
executor ships with a rebuilt image. Log: `agentd.log`.

## Checks

- `//:check-firecracker-vmm`: version, `--enable-pci`, static pair.
- `//:check-windows-firmware`: builds the firmware and verifies the
  PVH note and the patched aperture.
- `//:check-windows-guest-unit`: builder rules without installing.
- `//nix/verification/tests/machines/windows-guest:windows-guest`: installs and boots to `SAC>` on nested
  KVM with the operator launcher, then dials the transport probe through the
  launcher's vsock socket and reads its published log. Long-running; not part
  of any fast aggregate. First recorded execution 2026-10-14: firmware banner
  after 253 s of guest time, `SAC>` 6 s later; probe executions are recorded in
  the [agents review](../architecture/reviews/2026-10-14-windows-guest-agents.md).
- `//:check-lyra`: Linux tests and clippy plus a type check of the
  library and the Windows bins for `x86_64-pc-windows-gnu`.
- `//:check-terminald-windows`: builds the Windows terminal daemon;
  `//:check-terminald` keeps the Linux suite on the shared engine.
- `//nix/verification/tests/machines/windows-lilly-guest:windows-lilly-guest-agents`: the `windows-v1` image
  (`windowsGuestAgents`) through the real Lilly driver: vsock in the jail,
  trust `installed` by the guest's trust daemon, provisioning `ready` with the
  guest's boot UUID within the 600 s budget, a root ConPTY session through
  Lilly's terminal client, a workspace delivery accepted for the boot, the
  daemons' published logs, a new boot UUID after restart. Long-running;
  executions are recorded in the
  [agents review](../architecture/reviews/2026-10-14-windows-guest-agents.md).
- `//nix/verification/tests/machines/windows-lilly-guest:windows-lilly-guest`: places the image through the real
  Lilly driver on nested KVM, asserts the firmware bundle, skipped trust and
  `unattested` provisioning, reads `SAC>` from the boot log and the guest's
  bootstrap log from the live disk's EFI system partition (no login), then
  reaches the guest's `/32` through a test-only accept in Lilly's host policy
  (which otherwise drops every unmarked packet between the host and a Customer
  guest; the tap guard stays intact and its counters are asserted), restarts
  from the portable bundle and deletes.
  Long-running. Executions are recorded in the
  [launch review](../architecture/reviews/2026-10-14-windows-lilly-launch.md).

## Known gaps

- The agentless `windowsGuest` spike has no readiness proof, trust installation,
  roster identity, terminals or workspace delivery. The catalog's
  `windowsGuestAgents` image implements those surfaces; editor and Inception
  remain disabled.
- SAC permits bootstrap Administrator login on the agentless spike. The roster
  agent disables that account after activating a personal account.
- The current 64 GiB image has named-fleet SSH/tool evidence and a 96 GiB
  template budget. Its latest nested test passed readiness and reachability,
  then hung in stop; a complete stop/restart/delete pass for those exact bytes
  remains open. See [ADR-0173's implementation evidence](../architecture/decisions/0173-windows-images-winget-desktop-experience.md#implementation-evidence).
- Installed WSL/Podman tools do not establish nested-hypervisor execution.
- Hyper-V synthetic timers are not advertised; only reference time, TSC page,
  hypercall and APIC MSRs. The CMOS clock is read-only and follows host UTC.
