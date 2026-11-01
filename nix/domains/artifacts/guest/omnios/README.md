# OmniOS native candidate installation

`tools/buck2 build //:package-omnios-image-candidate-kit` builds immutable installation inputs,
not an admitted guest image. The kit contains the compiled kernel objects,
native link/install helpers, complete daemon and bootstrap service roots, pinned
Git runtime, and exact hashes of the stock GPT disk and every payload file.
Regular kit files use the final Nix publication modes `0444` or `0555`, so the
manifest remains valid after publication. Installation restores the reviewed
regular sudoers policy to root:root mode `0440` and records that target mode
separately from its immutable source permissions.

## Nix KVM assembly

`tools/buck2 build //:package-omnios-image-candidate` performs the procedure below inside a
`kvm`-feature Nix build. It decompresses the pinned stock disk twice, checks the
scratch copy against the kit's whole-disk digest, and boots the administration
copy offline in QEMU twice through the serial console in single-user mode
([`serial_session.py`](serial_session.py)). The first boot runs
`zpool reguid rpool`. The second boot attaches the scratch copy, a read-only
FAT transfer disk carrying `kit.tar` and [`guest-assemble.sh`](guest-assemble.sh),
and a writable FAT evidence disk. Both copies share vdev GUIDs, so QEMU runs
with `-boot strict=on` to expose only the administration disk to the loader,
and the stage selects the scratch slice by reading each ZFS label directly.
The guest's Solaris `ld` links the nine modules and `native_image.py assemble`
installs them. A read-only import then copies the exact receipts and
installed-module digests to the evidence disk.

[`check_assembly.py`](check_assembly.py) binds those receipts to the Nix build
ID, the pinned pool GUID, the stock `unix` digest and the final raw disk. Each
module whose objects equal the promoted `45983bb7` kit's objects must reproduce
the promoted module digest, recorded in
[`promoted-assembly-reference.json`](promoted-assembly-reference.json). The
output contains `disk.raw`, `firmware`, a test-only `manifest.json` with
`transport_build_id`, and `evidence/`. The raw disk is not bit-reproducible:
ZFS snapshot/clone GUIDs, transaction groups, timestamps, the SMF repository and
the rebuilt boot archive differ between native runs. The output keeps
`native_admission=false` and is not a production v6 manifest; the formal
`native-omnios-transport` and `native-omnios-reset` checks consume it.

## Manual native assembly

Use a disposable OmniOS r151050 administration VM with a separate scratch copy
of the pinned raw image attached as another disk. Its administration pool must
have a different GUID from that source image; two copies of the same source
cannot be imported together. A separately installed administration VM works, or
change only the disposable administration copy's GUID before attaching the target.
The helper refuses every already imported pool, including the running root.

Mount the read-only kit in the administration guest. With its build ID and the
target's decimal pool GUID from `zpool import`, run as root:

```sh
python3 -B -E -s /mnt/kit/bin/native_image.py assemble \
  /mnt/kit /dev/dsk/c2t0d0s0 TARGET_POOL_GUID BUILD_ID
```

The device is an explicit example: select the attached scratch disk's actual
ZFS partition. The helper verifies its complete raw `p0` disk against the pinned
image before importing it through a private device directory. It clones the
original BE, installs the exact module and service roots, removes the four fixed
stock network files, rebuilds the boot archive, selects the clone, and exports
the pool. It preserves the original BE. A failed installation requires a fresh
scratch disk; the helper does not roll back or silently reuse partial clones.
If native pool export refuses, it retains the mounted workspace for recovery
and fails; it never removes files beneath a pool that remains imported.
The kit and every ancestor must be root-owned and not writable by group or
others. Preserve the archive's exact file modes when unpacking; normalized
writable modes or a kit beneath `/var/tmp` are refused before pool access.

The removed files are `/etc/hostname.vioif0`, `/etc/dhcp.vioif0`,
`/etc/dhcp6.vioif0` and `/etc/hostname6.vioif0`. Assembly checks every destination
before removal and refuses links or nonregular files; it preserves unrelated
interface configuration. Even a plumb-only hostname file competes with the later
growth-gated MMDS bootstrap and can make stock `network/physical` fail with an
unusable zero address. The assembly receipt binds this exact removal list and
boot verification requires all four files to remain absent. Kit validation
refuses their reintroduction before accessing the target pool, including a
repacked kit with internally consistent hashes.

The installed SMF site profile disables all four stock cloud-init instances
and stock SSH. Assembly applies it only to the cloned root's offline SMF
repository and checks every enabled property is false. A fresh stock image has
a seed repository, so assembly first imports its two fixed vendor manifests.
Both the repository command and `SVCCFG_REPOSITORY` select the same clone;
the environment selector prevents waiting for a live restarter during import.
Overalls MMDS bootstrap
owns the static network and resolver; its roster-bound supervisor starts SSH.
Cloud-init must not overwrite the resolver or block the native service boot.

Assembly and boot verification run the target's actual `svccfg validate` on all
three exact installed Overalls manifests before emitting a receipt. Their
`stability` value is the schema-supported `Unstable`. Native validation passed
for all three corrected manifests, while a deliberate former `Uncommitted`
mutant was refused. This is native schema evidence; service import, method
execution and readiness require normal-boot machine evidence.

The clone preserves the stock loader and configuration. Assembly appends
`set pseudo_isa=1` to `/etc/system`, enabling the pinned kernel's UART nexus on
Firecracker's virtual hardware. Its `/boot/loader.conf.local` selects `ttya` for
both `console` and `os_console` and sets `ttya-mode="115200,8,n,1,-"`. The pinned
loader reads this local file after its defaults and `/boot/loader.conf`. The
administration boot can leave a transient `/boot/transient.conf` with a
standalone `-s` in `boot-args`; assembly removes only that token while preserving
the ZFS root, boot path and console arguments, and second boot rejects any
remaining single-user token. The exact final console files and modes enter the
payload receipt and are checked after boot. These settings add no debugger,
singleuser, verbose boot or root autologin defaults; terminal authority remains
boot-bound vsock.

The immutable vendor CA snapshot is `/etc/overalls/system-ca.pem`. Offline
assembly verifies both this snapshot and the initial `/etc/ssl/cacert.pem`
byte-for-byte. After boot, trustd may replace only the effective CA path with a
root-owned link to `/var/lib/overalls-trust/bundle-<digest>.pem`. Verification
requires a regular root:root mode `0644` target, the exact immutable vendor
prefix, and one to 32 bounded public PEM roots. All other installed payloads
retain their digest and mode checks. The filename and bundle structure do not
prove current-boot authority; only the daemon's boot-bound protocol receipt
provides that evidence.

After the administration VM powers off cleanly, boot the target under the
patched Firecracker with its native virtio-vsock device. On that second boot:

```sh
python3 -B -E -s \
  /opt/overalls/libexec/image-candidate/native_image.py verify BUILD_ID
```

Verification requires the assembled clone, exact unix and nine installed
module digests, every payload's digest and mode, the sudoers owner and mode,
the disabled state of stock cloud-init and SSH, and the running socket family's
exact compiled build token. It also requires both recorded console configuration
files and the reviewed final UART settings.
The unix digest remains separate from the module hashes. Cleanly power off
before recording the final raw disk's byte length and SHA-256. The kit binds
the stock Python 3.12.3 interpreter's actual digest from the pinned image;
repository static checks use Python 3.13.

Both receipts retain `native_admission=false`. These commands do not establish
complete native daemon, network isolation, recovery or catalog acceptance, and
do not emit a production v6 manifest. The matching native image has executed
the complete kit's pool import, clone, linkage, install, archive rebuild, bootfs
selection and clean export. A historical QEMU boot reached an earlier candidate
clone. A later diagnostic Firecracker boot passed complete image verification
and host vsock transport with a debugger-applied UART setting. The subsequent
ordinary boot exposed stock-network and SMF-schema defects, now corrected,
and unexplained ZFS EIO. Normal fresh-boot verification and complete services
remain acceptance work for the corrected final image.
The final token `985301b4` kit passed native assembly, three manifest validations,
764 payload checks and clean export. Its first service, ordinary-transport and
reset attempts failed before fixtures/probes with blank serial and Firecracker
`Shutdown(GenericError)`; the cause is under investigation. The native review
records exact disk/receipt hashes and separate assembly/runtime scopes.
The later completion-corrected kit `wvz8`, token `76b8c1ad`, passed a separate
pristine assembly with the same nine-module/764-entry/schema/network checks,
read-only receipt extraction and clean shutdown. Its sealed disk is `a49255bd`;
the earlier failed `9853` disk remains preserved. A paired direct-only QEMU
diagnostic reaches console login on `76b8` under the same no-vsock settings
where `9853` panics mounting root. Growth enters maintenance in that diagnostic;
Firecracker service/transport/reset acceptance remains separate. Corrected
runtime tests use independent clones and grant no admission from assembly alone.
The first corrected-image Firecracker service run stays alive and reaches login,
but growth enters maintenance and bootstrap withholds network/identity, missing
the 240-second fixture deadline. The retained serial contains the banner/login;
the wrapper's earlier blank-serial rendering was incomplete evidence. A separate
host-direct diagnostic identifies the sliced `zpool online -e` operand refusal;
the helper now derives the unsliced whole-disk operand while preserving exact
partition/pool authority. Corrected kit `d0rd` passed a fresh native assembly,
native schema checks, read-only receipt extraction, clean export and shutdown.
Its sealed disk is `bea32fe6`; exact service/growth/transport/reset replay is
still required. The native review records full disk/receipt identities.
Fresh-boot verification must also establish that the imported pool's candidate name,
selected BE, vfstab, loader and pool cache survive export and a fresh boot.
