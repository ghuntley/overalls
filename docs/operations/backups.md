# Host recovery backups

Backups recover a node after disk or machine loss. Each hostname gets a separate
Restic repository and independently generated password under the same S3 bucket.
The default schedule is every thirty minutes, delayed by a stable per-machine
random offset of up to five minutes. Keep twelve complete host recovery points
(roughly six hours when runs succeed), without archival tiers.

The implementation and isolated recovery tests follow [ADR-0070](../architecture/decisions/0070-host-recovery-backups.md).
Production backups are not enabled until an operator supplies the S3 destination
and provisions the host's encrypted backup document. Panterloons and Dungarees
already explicitly select `randomizedDelaySec = 300`.

The native backup-recovery test creates an active Marshall wildcard certificate
and ACME account with AshCloak-encrypted fields, captures the PostgreSQL dump
and a fixture keyring in Restic, and restores both into an isolated database.
A fresh Marshall release rejects an unrelated keyring, then decrypts the
restored values with the matching keyring and checks their saved digests. The
fixture keyring is disposable; production keyring custody remains
the encrypted Marshall secret document described below.

For an Inception child, Marshall's PostgreSQL database and its Cloak keyring
reside on the guest drives captured by Lilly's native ZFS snapshot path. The
snapshot is crash consistent; a child database/keyring restore and wildcard
decryption test has not yet passed. ADR-0106 remains partial on this recovery
evidence.

## Server configuration

Import the repository's default NixOS module and configure the destination:

```nix
services.overallsBackups = {
  enable = true;
  s3 = {
    endpoint = "https://objects.example.com";
    bucket = "node-recovery";
    region = "your-region";
    prefix = "hosts";
  };
  randomizedDelaySec = 300;
  retention.keepLast = 12;
};
```

For hostname `panterloons`, that selects
`s3:https://objects.example.com/node-recovery/hosts/panterloons`. Dungarees uses the
same destination with `/dungarees`. Changing a hostname requires an explicit
repository migration/recovery decision; it does not discover the old repository.

Useful optional settings:

```nix
services.overallsBackups = {
  extraPaths = [ "/var/lib/my-service" ];
  excludePaths = [ "/var/lib/my-service/disposable-cache" ];
  uploadLimitKiB = 20480;
  minimumFreeBytes = 2 * 1024 * 1024 * 1024;
  commandTimeoutSeconds = 7200;
};
```

`defaults.enable = false` disables role discovery, including default Lilly and
PostgreSQL captures. `postgres.enable = true` can explicitly select Marshall's
configured database capture again. Paths inside Lilly's pool are handled by its
native capture boundary; do not add the pool parent or guest disks to
`extraPaths`. The module rejects attempts to snapshot those managed datasets
through the generic host-files path.

## Secret custody

For each enrolled fleet host, add a credential document to its `host.json`:

```json
{"name": "overalls-backup", "path": "secrets/overalls-backup.enc.json"}
```

Prepare a mode-0600 private JSON input with these keys:

- `RESTIC_PASSWORD`: independently generated random password, such as 32 random
  bytes encoded using a password generator; never derive it from the hostname.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the provider's S3 credentials.

Use the existing operator secret workflow:

```sh
nix run .#secrets -- encrypt overalls-backup --input /private/overalls-backup.json
nix run .#secrets -- check
```

Repeat for Dungarees with a different Restic password. The inventory workflow
includes the authenticated host recipients and retained recovery recipients.
Verify recovery decryption with an operator key before relying on the backup.
An actual restore drill must decrypt the restored ciphertext generation: the
exported `backup-custody` check covers restored bytes through the secret CLI
into repository access with the recovered password. Keep recovery identities
outside the node; its loss must not also lose the
repository password. See [secret custody](../../secrets/README.md). To rotate the
password value, follow [repository password rotation](#repository-password-rotation).

The fleet profile materializes `/run/overalls-secrets/backup/password` and
`/run/overalls-secrets/backup/s3.env`. A non-fleet NixOS host can supply equivalent
private files through `passwordFile`, `environmentFile` and `secretUnits`.
Never put plaintext credentials in Nix values or source an EnvironmentFile as
shell code. S3 credentials may be scoped to a host prefix when the provider
supports that. Independent repository passwords provide separate encryption
domains even if the provider credentials are shared.

## Repository password rotation

Rotating the `RESTIC_PASSWORD` value is a two-party ceremony: the repository key
must learn the new password through Restic **before** the rotated document is
deployed. Changing SOPS recipients never rotates repository keys
([ADR-0070](../architecture/decisions/0070-host-recovery-backups.md)), and the
managed wrapper deliberately exposes no `restic key` operation; run the raw
commands below on the host as root with its current credentials in place.
Mutating Restic commands must never run while a managed operation is active, so
stop the scheduled units first:

```sh
systemctl stop overalls-backup.timer overalls-backup-prune.timer \
  overalls-backup-check.timer overalls-backup-read-check.timer
```

1. Generate the new password into a private mode-0600 file outside the checkout
   and Nix store, exactly like the current one.
2. Add it as an additional repository key while the old value is still
   published:

   ```sh
   export RESTIC_REPOSITORY=s3:ENDPOINT/BUCKET/PREFIX/HOSTNAME
   export RESTIC_PASSWORD_FILE=/run/overalls-secrets/backup/password
   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
   restic key add --new-password-file /private/new-password
   ```

   Export the provider credential values directly from the host's private
   backup document; never source the runtime environment file as a shell
   program. From this point both passwords open the repository.
3. Replace the value in the host's backup document and deploy:

   ```sh
   nix run .#secrets -- encrypt HOST-backup --input /private/HOST-backup.json --replace
   ```

   Deployment republishes `/run/overalls-secrets/backup/password` through the
   preparation unit. Because the old key remains valid until step 4, scheduled
   and operator runs keep succeeding throughout the rotation.
4. Verify, then retire the old key. With the new password now published, plain
   `restic key list` marks the in-use key as current; remove the other entries:

   ```sh
   restic key list
   restic key remove OLD_KEY_ID
   systemctl start overalls-backup.timer overalls-backup-prune.timer \
     overalls-backup-check.timer overalls-backup-read-check.timer
   overalls-backup check
   ```

   Restic refuses to remove the key currently used to access the repository;
   remove the non-current one. Afterwards the old password no longer opens the
   repository.

### Wedge after rotation without the ceremony

If the rotated document is deployed without step 2, the published password no
longer matches any repository key. Every repository-mediated operation then
fails at repository access: scheduled backups report status `state: failed`
with failure label `repository` and exit nonzero with a generic diagnostic that
never names credentials. Listing, inspection, integrity checks and pruning fail
identically; the snapshot inventory and last-success timestamp are untouched
and cleanup (which needs no repository) keeps running. Recovery uses the
previous document generation, which remains decryptable by retained recovery
identities through Git history:

```sh
git show PREVIOUS_REVISION:secrets/HOST-backup.enc.json > /private/previous.enc.json
# place the historical ciphertext at the document's declared path inside a
# private checkout copy, then decrypt it with a retained recovery identity
nix run .#secrets -- decrypt HOST-backup \
  --ssh-key /private/recovery_id_ed25519 --output /private/previous-backup.json \
  --root /private/checkout
# copy the recovered RESTIC_PASSWORD value into a private mode-0600 file
export RESTIC_PASSWORD_FILE=/private/previous-password
restic key passwd --new-password-file /run/overalls-secrets/backup/password
```

`key passwd` rewrites the repository key to the published new password and
retires the recovered one, so the next scheduled run succeeds. Both the wedge
and this recovery are exercised by the exported `backup-custody` check against
the real runtime and tools.

## Recipient turnover and retained points

Recipient changes move only the SOPS envelope recipients; repository passwords
and every stored backup stay byte-identical. Retained recovery points and Git
history, however, keep their historical ciphertext: a point captured before a
turnover still embeds the document generation sealed to the historical
recipient set. Removing a recovery identity while points captured under its
generation remain inside the twelve-point retention window strands those
embedded credential documents — a later restore from such a point needs the
retired identity to decrypt them. Keep the retiring identity available until
every pre-turnover point has aged out; `overalls-backup list` and `inspect`
points carry timestamps for that comparison. The inventory `check` validates
only the working-tree generation and Restic retention does not warn about
stranded generations; that warning is tracked separately, so plan turnovers
against the retention window explicitly. Follow the two-generation recipient
ceremony in the [fleet recovery guide](fleet-users.md#local-commands).

## Default recovery contents

Only enabled roles contribute their state. Configured paths replace the defaults
below when the service exposes a directory option.

| Role | Recovery contents |
| --- | --- |
| Host | `/etc/machine-id`, configured SSH host keys and public keys, generated host/installation declarations and service CA, enrollment receipts in `/var/lib/overalls-host` when auto-update is enabled, evaluated recovery configuration and encrypted SOPS documents |
| Lilly | `/var/lib/lilly/control`, `/var/lib/lilly/vms`, `/var/lib/lilly/network`, configured transfer journals, pool ownership/import/tombstone metadata under `.lilly-zfs`, all ready owned VM drives, and configured image manifests/kernels/initrds/templates |
| Marshall | Custom-format logical dump of the database in its runtime `DATABASE_URL`, archive metadata and checksum; the encrypted Marshall secret document preserves the application keyring |
| Porsche | `/var/lib/porsche/keys` |
| Audi | `/var/lib/audi/keys` (SSH host key). Public wildcard certificate and ACME account/key material live as Cloak ciphertext in Marshall PostgreSQL and are included in the PostgreSQL dump. |
| Private Audi | Fleet wildcard certificate ciphertext through the host's SecretSpec bundle; no runtime certificate state directory |
| ACME | `/var/lib/acme` and `/var/lib/overalls-certificates` when Marshall proxy ACME is enabled |
| Ziggy | `/var/lib/ziggy/spool`, a bounded usage/receipt metadata spool, not request bodies or an instruction replay queue |
| Underclass | `/var/lib/underclass`, including the host-local SQLite account pool and plaintext OAuth tokens inside the encrypted Restic repository; production capture and restore remain disabled/unverified |

Lock files, temporary `.pending-*` files and socket paths are excluded. This is
selected persistent recovery state, not a copy of every ZFS dataset, the Nix
store, build cache, logs or memory. ZFS-backed selected host files use native
read-only snapshots. Non-ZFS host files use ordinary Restic file capture and can
change while read. Guest disks always use Lilly's native ZFS snapshot path.

A stopped guest is never started for backup. A running guest receives a bounded
`sync` request tied to its current boot. There is no freeze or pause: development
continues, although syncing/uploading can compete for I/O. A missing or
unresponsive helper records an unconfirmed flush and still backs up the disk.
Snapshots preserve filesystem crash consistency, not unsaved editor buffers or
application-level cross-system transactions.

PostgreSQL capture uses the exact runtime Marshall connection identity, verified
TLS and its configured CA. It does not assume localhost or require a replication
role. The database owner must have dump access to the selected database. The
client must support the server major version; the default is PostgreSQL 18.

## Operations and status

Run as root on the configured host:

```sh
systemctl start overalls-backup.service
overalls-backup list
overalls-backup inspect --snapshot FULL_SNAPSHOT_ID
overalls-backup check
overalls-backup read-check
overalls-backup cleanup
```

`list` reports host-manifest candidates. `inspect` validates the selected manifest
structure. Neither command proves that every referenced component is available;
restoration verifies each component as it is read.

`overalls-backup` launches a transient systemd service with runtime EnvironmentFiles
and a private mount namespace. All operations contend on the same host lock.
Never invoke Restic mutations independently while a managed operation is active.
While the lock is held, operator reads (`list`, `inspect`, `restore`, `init`)
refuse with the busy message and scheduled units skip without touching status
or the repository.

Every repository-touching operation validates credential custody before any
repository access: the password file must be a private single-link regular file
and the S3 environment must be present. Refusals close generically as the
`credentials` failure; capture already behaved this way, and the same gate now
covers operator reads, retention and integrity checks.

If the runtime is killed mid-upload or times out, the next cleanup unit run
(boot and every five minutes) records the run as `failed(interrupted)` after
retrying snapshot cleanup; already-uploaded-but-unreferenced components survive
only their one-day grace. A run stopped between manifest upload and journal
completion leaves its published point listable, inspectable, restorable and
retention-counted while the run itself is recorded as failed — publish a point
only as all-components-complete remains unchanged. An uncatchably killed
Restic upload also abandons the writer's repository lock: reads and further
backups keep working, while exclusive retention (`forget`/`prune`) and
integrity checks refuse —
closed as the `retention` failure with every snapshot preserved. After
confirming no other live backup writes to that repository, remove the stale
lock with the documented remediation
`restic -r REPOSITORY unlock`; subsequent scheduled retention then proceeds
normally. A mid-restore credential change fails the remaining components as a
generic repository failure with verified partial output retained and no
`manifest.json`; restore custody and retry into a fresh empty target.

The fleet/host admin dashboard receives backup observations through the existing
independent fleet monitor. It displays last success, duration, guest counts,
unconfirmed flushes and pending cleanup with closed failure categories. A stale
collector or old success cannot appear healthy. Status does not authorize restore
or VM operations. Local state is under `/var/lib/overalls-backups`, mode 0700.

The durable coordinator records cleanup before native snapshot creation. Cleanup
runs on boot and every five minutes and does not need S3 or database credentials.
A failed cleanup prevents publication of a complete point and remains retryable.
Never manually erase ownership journals to make an error disappear. A replaced
GUID or foreign nonce requires inspection; a similar snapshot name is not proof
of ownership.

Daily retention pruning removes component snapshots only after verifying all
retained manifest references. Failed runs do not replace good points. Old failed
components get a one-day grace period. Daily metadata checks and rotating weekly
quarter-repository data checks cover repository integrity. A provider's object
versioning, lifecycle or object-lock configuration may keep deleted bytes longer;
configure those policies to match the desired short physical retention.

## Isolated recovery and node replacement

1. Fence the failed node and its old control-plane/database authority. Confirm
   whether it is physically dead or merely disconnected; disconnection alone
   cannot authorize duplicate VM execution. Retain current surviving-node evidence.
2. Obtain the host's backup password and S3 credentials using a recovery identity.
   The recovered document generation must be one the available identity can
   open: the current working tree, or Git history when a recipient turnover
   happened since the point was captured (see
   [recipient turnover](#recipient-turnover-and-retained-points)). Recreate the
   configured backup module on an isolated recovery machine using the
   old hostname/repository location. Keep serving Marshall, job workers, Lilly
   reconciliation and customer traffic disabled.
3. Select a complete host manifest and restore into an empty private destination:

   ```sh
   overalls-backup restore --snapshot FULL_SNAPSHOT_ID --target /var/lib/recovery
   ```

   The command restores and verifies each referenced component into a numbered
   subdirectory and writes `manifest.json`. Guest `guest.json` records the
   placement, drive paths/specification, source GUIDs and flush result. Host
   `configuration/paths.json` maps captured paths back to their intended paths;
   temporary snapshot mount prefixes must not be copied as production paths.
   If a component restore fails, already restored numbered directories remain
   inspectable and no final `manifest.json` is written. Preserve this partial
   output, resolve the failure and explicitly retry into a fresh empty private
   destination. Retrying into the nonempty partial directory is refused.
4. Inspect the recovered host state before applying it. Rebuild the declared NixOS
   revision and preserve the required identities and service keys. Do not blindly
   overwrite current locks or resurrect transfer/cleanup work. Ziggy metadata
   requires reconciliation with live durable accounting; never replay requests.
5. Restore the PostgreSQL custom archive into a **new isolated database**, using a
   compatible `pg_restore`. Start with `--no-owner --no-acl`, then reconstruct the
   intended Marshall role and grants from configuration. Validate the recorded
   SHA-256 and actual tables/application data. Preserve the matching ordered
   `MARSHALL_CLOAK_KEYS` keyring from the encrypted Marshall secret document and
   verify application decryption, including an active Audi wildcard certificate,
   its private key and the saved ACME account key. A readable SQL archive alone
   is insufficient. Keep the restored issuer queue paused until the certificate
   generation, DNS proof state and surviving gateways have been reconciled.
6. Recreate native ZFS datasets and restore each guest's complete drive set with
   sparse-file preservation. Restoring files creates new native GUIDs: the old
   GUID-bound ownership and installation receipts are historical evidence, not
   automatically valid claims on the replacement storage. Re-enroll/reconcile the
   replacement host and pool bindings under explicit operator control. Test guest
   boot and data recovery in isolation before assigning production identity.
7. Before restoring control-plane authority, reconcile post-backup revocations,
   credentials, host/session epochs, VM generations, reservations, terminal/login
   grants and pending commands against surviving physical state. Fence previous
   authority and rotate/revoke credentials as required. Unknown allocations stay
   unavailable until settled. Only then enable serving and reconciliation.

This is a guided recovery workflow, not automatic failover or automated rebinding
of historical authority. Existing HA physical-restore drills and synchronous WAL
requirements still apply to deployments claiming those guarantees; these logical
host backups do not establish PITR or lossless promotion. See the
[database recovery guide](database-recovery.md).
