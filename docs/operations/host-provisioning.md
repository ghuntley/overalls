# Bare-metal host provisioning

`tools/buck2 run //:host -- --help` exposes `discover`, `plan`, `install`, `enroll` and
`verify`. There are no default production machines. Every declaration lives in
`fleet/hosts/NAME/host.json` (lowercase names, at most 28 characters, excluding
the reserved `-base` suffix); NixOS configurations and secret recipients derive
from that inventory. An optional `configuration.nix` in that directory supplies
application roles for the enrolled configuration only. The `NAME-base`
configuration is accessible by SSH without roles or polling. The enrolled `NAME`
output appears once its authenticated key, Git pin and Git document reference are
declared. Unkeyed base hosts are excluded from secret recipients.

The target must provide root or passwordless sudo, Python 3, OpenSSH, lsblk and
iproute2. Use x86_64 bare metal with working `/dev/kvm`; readiness actually creates
and closes a KVM VM. Authenticate the rescue/Ubuntu SSH Ed25519 key out of band
and put it in a dedicated known-hosts file. Supply your existing administrator
private key outside the checkout. The tool never accepts a new SSH key on trust.
The operator's Git SSH configuration must also authenticate the repository server.


Administrative transport uses `--ssh-port` (default 22). After moving a host's
administrative OpenSSH listener to 2222, pass `--ssh-port 2222` to discovery,
planning, enrollment and verification. Nix closure copies use the same pinned
transport. For enrollment preparation, `--marshall-ssh-port` selects the Marshall
operator connection independently. Management SSH on port 22 cannot run host tools.

Installation plans bind both `--ssh-port` and `--installer-ssh-port` (default 22).
Use those same values for `install`; changing either invalidates the approved
plan. The pinned installer receives separate pre/post-kexec ports, and all later
installer validation and installation connections use the installer port. Pin the
keys for each host/port in the supplied known-hosts file; nonstandard OpenSSH
entries use `[hostname]:port`.

## Discovery and review

```sh
tools/buck2 run //:host -- discover --platform hetzner --name example \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key --output /private/example.candidate.json
```

Use `--platform ec2` for EC2 bare metal, or `--platform hcloud` for a Hetzner Cloud
virtual server (see [Hetzner Cloud hosts](#hetzner-cloud-hosts)). Discovery writes a new candidate and
refuses to overwrite an existing file. It proposes DHCP for EC2 and interface
addresses for Hetzner; the original routes are preserved as discovery evidence.
Review Hetzner gateways, on-link routes, DNS, IPv6 and MAC matches explicitly.
`network` contains NixOS `systemd.network.networks` definitions, for example
`matchConfig.MACAddress`, `address`, `routes` and `networkConfig.DNS`.

Before copying the candidate to `fleet/hosts/NAME/host.json`:

- Set `reviewed` to true after validating hardware, firmware and networking.
- Select `storage.system` by disk IDs: two physical disks on Hetzner; the existing
  root EBS volume on EC2. Select every local-NVMe ID in `storage.guests` on EC2;
  leave that list empty on Hetzner. EBS volumes are excluded even when NVMe.
- Keep the complete discovery inventory, including unused EBS volumes. Disk
  model, serial, size, transport, controller classification and stable by-id path
  must agree at installation; kernel numbering may change.
- Assign a persistent, nonzero eight-digit hexadecimal `identity.hostId`.
  Leave `identity.sshKeys` empty until the installed identity is retrieved.
- Set exactly the positive `budgets.guestCpuCores`, `guestMemoryMiB` and
  `arcMaxMiB`; any other budget key, including the retired `logicalBytes`, is
  refused. Set a reviewed `storage.quotaBytes` on Hetzner; EC2 has no guest quota.
  Enrollment storage headroom (`lilly.overheads.storageBytes`) must stay below
  the guest quota on Hetzner, or below the summed raw size of the local guest
  disks on EC2.
- Review `storage.ashift`, the SSH Git repository, and authenticated Git-server
  known-host lines in `git.knownHosts`. No private key belongs in the declaration.

Commit and publish the reviewed declaration and lockfile on `trunk`. Planning
requires a full commit reachable from the published `trunk` branch; uncommitted
working-tree changes are never installed. This publication is operator work;
the tool does not create provider resources or push commits.

## Plan and install

```sh
tools/buck2 run //:host -- plan --host example --revision FULL_COMMIT \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key --output /private/example.plan.json
```

The plan includes the complete declaration, authenticated target key, firmware,
revision, exact system/guarded-disko/kexec paths and erasure list. Review the JSON
and the displayed paths. Credentials are not included. Plan publication builds
before any destructive operation. The host tool patches the pinned
nixos-anywhere SSH default to strict checking and uses a locked kexec image.

```sh
tools/buck2 run //:host -- install --plan /private/example.plan.json --erase PLAN_SHA256 \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key
```

Installation verifies the published build, enters kexec, compares the complete
inventory again, and runs the guard and formatter under a lock. Mounted devices,
swap, device holders and imported pools are refused. It installs BIOS or UEFI
according to the reviewed firmware; Hetzner gets a bootloader on each disk.
BIOS installations keep boot files on separate ext4 partitions on each system
disk so GRUB need not interpret modern ZFS features; UEFI uses separate ESPs.
The installed host key is generated privately inside `/mnt/etc/ssh`, and its
public key and storage GUID baseline are retrieved before reboot. The private
key never travels to the operator. The installed base boots independently of
enrollment publication.

The base system has no fleet-address document, so its perimeter grants no
reviewed public source. Installation therefore records the source IPv4 of the
authenticated installer connection in the root-only file
`/var/lib/overalls-host/base-source`, and every host admits that one source to
its administrative SSH ports only ([ADR-0234](../architecture/decisions/0234-installer-source-administrative-grant.md)).
Run discovery, planning, installation and enrollment from the same machine.
The grant survives enrollment, including a move to another deployment; delete
the file to withdraw it. Hosts installed earlier have no file and stay
reachable only through their reviewed sources or Tailscale.

`PLAN.state.json` records the current phase. `PLAN.installed.json` records the
new public key and storage receipt; preserve this file. An interrupted install
never silently resumes formatting. A new invocation requires the erasure digest
again. If the target is already in the installer, authenticate that environment
with its retained rescue identity. Mounted leftovers must be inspected and
explicitly unmounted/exported before a destructive retry. A completed install
refuses another destructive invocation of the same plan.

## Enroll and verify

Build a new known-hosts file using the installed public key from the authenticated
installer receipt. Record that same key in `identity.sshKeys`. Add the document
reference `{"name":"example-git","path":"secrets/example-git.enc.json"}` to
`credentials`. All recovery-enabled users in `nix/policy/identity/users.nix` are recipients.
Stage the public declaration so Nix's Git source includes it. Supply the **shared**
Git deploy key as a mode-0600 file outside the checkout:

```sh
tools/buck2 run //:host -- enroll --host example --deploy-key /private/shared-git-key \
  --root . --target ghuntley@HOST --known-hosts /private/installed-known-hosts \
  --identity /private/operator-key
```

This prepares the existing SecretSpec/SOPS Git bundle; it does not install or
start polling. Publish the updated declaration, ciphertext, and any explicitly
configured roles. Then activate that exact commit:

```sh
tools/buck2 run //:host -- enroll --host example --revision ENROLLED_FULL_COMMIT \
  --install-receipt /private/example.plan.json.installed.json \
  --target ghuntley@HOST --known-hosts /private/installed-known-hosts \
  --identity /private/operator-key
tools/buck2 run //:host -- verify --target ghuntley@HOST \
  --known-hosts /private/installed-known-hosts --identity /private/operator-key
```

Enrollment authenticates both the installed key and storage receipt. It gates
polling, builds/copies the exact candidate, reuses updater secret staging,
compatibility checks, migrations and health verification, checks pinned Git
repository access and storage/KVM, then persists the enrollment receipt and
starts the timer. It never formats or replaces identity. Retry the same command
after a failure; the timer remains gated until the checks complete. There is no
automatic database rollback or reboot. Private phase logs are under
`/var/lib/overalls-auto-update`; installation/enrollment receipts are under
`/var/lib/overalls-host` on system storage. Lilly journals also remain on system
storage; only its managed guest pool is ephemeral on EC2.

Updates follow this repository over SSH on `main`, with the existing ten-second
interval and jitter. Platform, firmware, disk inventory, boot/pool topology and
persistent identity changes are rejected by ordinary updates. Use deliberate
maintenance instead of trying to roll such a change through the timer.

## Hetzner Cloud hosts

`hcloud` ([ADR-0231](../architecture/decisions/0231-hetzner-cloud-hosts-and-susan-placement.md))
is for KVM-less service hosts. A fresh Hetzner Cloud image forces a root password
change on first login; change it, add the operator public key to root's
`authorized_keys`, and pin the server's Ed25519 key before discovery. Review:

- `storage.system` names the single disk; `storage.guests` stays empty and
  `storage.quotaBytes` stays null.
- `budgets` is exactly `{"arcMaxMiB": N}`; there is no `lilly` section.
- The proposed network uses `DHCP = "ipv4"`, a default via `fe80::1` for IPv6,
  and `LinkLocalAddressing = "ipv6"` so that the IPv6 gateway stays reachable.
  It carries no address literals; the profile refuses them
  ([ADR-0233](../architecture/decisions/0233-fleet-addresses-from-sops.md)).
- Public addresses of every fleet host live in the shared
  `secrets/fleet-addresses.enc.json` (see the [secrets guide](../../secrets/README.md)).
  Add the host's names to `nix/policy/network/fleet-addresses.nix`, list the
  `fleet-addresses` document in `credentials`, and re-encrypt it once the host
  key is enrolled. Point public listeners at `overalls.fleetAddresses.files`
  and its `unit`. To rotate an address, change the document; no code changes.

The guard and the storage receipt skip KVM and bind `zroot/root`. Plan, install,
enroll and verify are otherwise identical, including the trunk auto-updater.
[Salopettes](../../fleet/hosts/salopettes/configuration.nix) is the reference role.

## EC2 storage loss and deliberate recovery

A missing local drive or different pool/dataset GUID fails readiness and blocks
Lilly and polling; the EBS root and SSH remain available after the bounded ZFS
device-discovery wait (normally up to sixty seconds when a pool is missing). Boot and activation
never create pools, and enrollment never accepts a new GUID in place of the
installed baseline. Do not delete a baseline merely to make a check pass.

Disable/drain the host through Marshall's [maintenance workflow](host-maintenance.md).
Fence its old sessions and reconcile every lost placement, retained reservation
and journal with the control plane. Preserve system identity, journals, receipts
and diagnostic evidence. Determine whether the original devices can be reattached
without changing ownership. If they cannot, guest data is lost; this tooling does
not restore it. Review and publish a replacement host declaration and perform an
explicit destructive installation with a new plan. Reconcile/retire the former
host before enrolling the new identity. The current tool intentionally has no
in-place guest-pool reset command that could bypass reconciliation.

## Verification scope

Profile evaluation and plan safety checks are exported as `storage-configuration`
and `host-planning`. Production-profile firmware/image checks and updater/secret
checks remain separate. See [ADR-0043](../architecture/decisions/0043-declarative-host-provisioning.md)
and its [review](../architecture/reviews/2026-09-17-host-provisioning.md) for the exact
executed matrix. Physical Hetzner and EC2 acceptance is still required; synthetic
controller fixtures and local QEMU boots do not prove provider conversion.


## Prepare Lilly enrollment

Declare the Lilly role before installing the base host, so it includes the
application identity helper. Add this public section to `host.json` (choose
actual overheads and the installed uplink):

```json
"lilly": {
  "controlPlane": "https://marshall.example.com",
  "egressInterface": "eth0",
  "credentialTtlSeconds": 157680000,
  "overheads": {"cores": 1, "memoryBytes": 1073741824, "storageBytes": 1073741824}
}
```

The lifetime defaults to five 365-day years; supported values are 1..157680000
seconds. `transferEndpoint` optionally accepts the existing complete pinned SSH
transfer endpoint. A fleet host names its address by secret instead
(`"addressSecret": "NAME_PRIMARY_IPV4"` beside `port` and `host_key`);
preparation decrypts `secrets/fleet-addresses.enc.json` with the recovery key and
sends the validated address to Marshall, so no address enters the declaration. Configure image manifests and any extra networking through the
existing host role module. Do not hand-set generated Lilly host or pool IDs.
Host names for this workflow may have at most 26 characters so `NAME-lilly`
fits the secret inventory name limit.

After installation, authenticate the installed host using its receipt's SSH key.
Deploy the new Marshall release/module and its migration first, then run:

```sh
tools/buck2 run //:host -- prepare-enrollment --host NAME --root . \
  --target admin@installed-host --marshall-target admin@marshall-host \
  --identity /private/admin-key --known-hosts /private/known-hosts \
  --install-receipt /private/host-plan.installed.json \
  --recovery-key /private/recovery-key
```

Both targets require pinned Ed25519 host keys and administrative SSH access.
The recovery key must belong to a current secret-recovery user. Marshall's
`overalls-marshall-enrollment` helper runs the operator as a dedicated unprivileged
account with the configured protected environment file and verified database TLS.

The command registers a disabled host, prepares `NAME-git` and `NAME-lilly`
SOPS ciphertext for the host and every recovery user, and writes only public
registration data to `lilly.binding`. It does not commit, push, activate or enable
scheduling. Review and publish the changes, use the existing `enroll --revision`
activation command with the same installation receipt, verify readiness, and
explicitly enable the returned host UUID through Marshall's operator CLI.

Use the same arguments with `rotate-credential` for explicit replacement.
**Rotation revokes the previous credential immediately.** Deploy the prepared
ciphertext promptly to restore control exchanges. Guest reservations remain held.
Existing expiry dates never change merely because the default lifetime increased.

Interrupted operations retain their UUID and sealed artifacts under
`$XDG_STATE_HOME/overalls/enrollment` (default `~/.local/state/overalls/enrollment`).
Rerun the identical command to recover a lost response, failed encryption or
partial file publication. Preserve this directory until recovery completes;
conflicting input or manually changed output requires reconciliation, not deleting
the journal and rotating again. A successful preparation retry preserves its
credential; a new rotation after a completed rotation intentionally issues another.
The journal contains public metadata and ciphertext, never a plaintext key.
