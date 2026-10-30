# Fleet users and secret recovery

Edit [`nix/policy/identity/users.nix`](../../nix/policy/identity/users.nix) to manage infrastructure users. Marshall's
email identities and guest accounts are separate. The initial registry preserves
ghuntley's reviewed Ed25519 public key; there are no remote key lookups.

```nix
{
  alice = {
    sshKeys = [ "ssh-ed25519 ..." ]; # Replace with the complete public key.
    login = true;
    group = "users";
    extraGroups = [ "reports" ];
    admin = false;
    secretRecovery = true;
  };
}
```

All permission flags default to false; lists default to empty and `group` to
`users`. Login and recovery require at least one ordinary Ed25519 public key.
Hardware-backed SSH keys and SSH certificates are not convertible recovery keys.
Multiple keys support overlap during rotation. `admin` requires `login` and grants
passwordless sudo through a per-user rule. Groups have their ordinary Unix
meaning, including any privileges granted by other services. Administrators can
access their hosts' identities and local secrets through root; `secretRecovery`
adds off-host access to every inventoried document.

Import `nixosModules.security.access` (included in `nixosModules.default`) and set
`overalls.access.enable = true` on every participating host. The module reads the
shared registry by default; `overalls.access.users` accepts the same typed
attribute set for explicit compositions and tests. Keep fleet compositions on
the shared registry so SSH and the public recipient package agree.

Hosts require a keyed administrator. Named users authenticate with centrally
declared keys; root SSH, password login, home-directory authorized keys and
alternative SSH key commands/certificate authorities are disabled. The allowlist
also rejects non-registry service-account logins on this management SSH server;
review existing SSH automation before enabling it. Unix account
and group databases are declarative. Disabling `login` or removing an entry
revokes new SSH sessions on the next activation. Home data remains, and existing
sessions/processes require separate termination. A recovery-only entry creates
no Unix account. Secret preparation alone creates host keys without enabling SSH.

Fleet access also enables Mosh on the host and opens UDP ports 60000–61000 in
the NixOS firewall. Any provider firewall must permit that range too. Install a
Mosh client locally and connect with `mosh USER@HOST`; where Porsche owns port 22
(including Panterloons), use `mosh --ssh="ssh -p 2222" ghuntley@HOST` to bootstrap
through administrative OpenSSH. New sessions use the same declared SSH keys.
Existing Mosh sessions require separate termination after key/account revocation.
This configuration does not enable Mosh inside guest VMs.

Login-enabled fleet users also have systemd lingering enabled: their user managers
start at boot and remain available after logout for user services. Recovery-only
entries still create no account. Removing a login account removes its managed
linger entry on activation; existing processes retain the revocation limits above.

Bootstrap and installer use the same registry. Connect as `ghuntley` and use
`sudo -n`; use the [host tool](host-provisioning.md) for installation.
For an existing machine, review the removal of manually created accounts before
activation, retain a verified administrative session, then independently verify
named login and sudo before closing it. This repository change does not deploy
or activate any existing host.

## Public inventory

[`nix/policy/secrets/secret-documents.nix`](../../nix/policy/secrets/secret-documents.nix) registers the `git-bootstrap` recovery
document alongside the host-derived inventory. Populate authenticated public
host keys and actual ciphertext paths through reviewed host declarations; a
bootstrap recovery document does not identify a production host.

The host-specific fields live in `fleet/hosts/marshall1/host.json`, alongside
its reviewed hardware, networking and budgets (see [host provisioning](host-provisioning.md)):

```json
{
  "identity": {"hostId": "REVIEWED_ID", "sshKeys": ["ssh-ed25519 ..."]},
  "credentials": [{"name": "marshall", "path": "secrets/marshall.enc.json"}]
}
```

This snippet shows recipient fields only, not a complete machine declaration.

Documents use unique paths under `secrets/`, ending in `.enc.json`, `.enc.yaml`
or `.enc.yml`. Ordinary documents require at least one declared host and one
recovery user. A bootstrap recovery document instead sets `hosts = [];` and
`recoveryOnly = true;`; it must have no hosts and still requires a recovery user.
Both kinds participate in the same `check`, `decrypt` and `rekey` commands. Recipients are the selected host keys plus **all** users with
`secretRecovery = true`, independently of login and groups. Hosts can list old
and new keys during a staged rotation. Authenticate host keys out of band before
adding them; an unauthenticated key scan is not sufficient.

Only ciphertext and public declarations belong in Git. Register new Nix files
with Git before evaluating a Git-backed flake. Build public conversion artifacts:

```sh
nix build .#user-recipients
cat result/recipients.json
cat result/ghuntley.age
```

Per-user `.pub` and `.age` files can contain multiple
lines. Only recovery-enabled users appear in the aggregate recovery list.

## Local commands

Run from the repository root, or supply `--root /path/to/checkout`. `nix run`
builds the public policy from the flake being invoked; use that same checkout as
the document root. Rebuild/rerun from updated source after changing the registry.

```sh
nix run .#secrets -- check
nix run .#secrets -- encrypt marshall --input /private/marshall.json
nix run .#secrets -- decrypt marshall --ssh-key /private/id_ed25519 --output /private/recovered.json
nix run .#secrets -- rekey --ssh-key /private/id_ed25519
```

Create the ciphertext's parent directory first. Plaintext input and recovered
output must be outside the checkout and Nix store; inputs must be private,
single-link regular files owned by the operator. Encryption and decryption refuse
to overwrite an existing destination. The input format matches the document's
extension; preserve the existing SecretSpec `overalls-BUNDLE` / `production`
mapping described in the [NixOS guide](nixos.md#ssh-derived-secrets).

`check` validates public policy and recipient metadata; it cannot verify the
encrypted payload without a private identity. `rekey` requires a private key of
a recovery user who remains in the destination recipient set and can decrypt
each changed source. Add and verify a successor first when replacing that user.

Replacing a recovery user therefore takes two generations, with a commit after
each registry change:

1. Add the successor alongside the incumbent. Reconcile with the incumbent's
   key, then verify the joined generation:
   ```sh
   nix run .#secrets -- rekey --ssh-key /private/incumbent_id_ed25519
   nix run .#secrets -- check
   nix run .#secrets -- decrypt marshall --ssh-key /private/successor_id_ed25519 --output /private/verify.json
   ```
2. Remove the incumbent. Reconcile with the successor's key and verify again;
   the retired identity still decrypts preserved historical ciphertext but
   nothing current uses it.

Never replace in one edit. A direct full turnover refuses in both directions
and leaves every document unchanged: the departed identity fails the retention
check (`Reconciliation requires a retained recovery identity.`) and the new
identity cannot decrypt the sealed documents (`Cryptographic operation failed;
check the identity and document.`). `check` reports the drift; restoring the
previous manifest converges immediately. Both refusals and the ceremony are
exercised with synthetic identities in the exported `secret-reconciliation`
check.

Plan removals against retained ciphertext. Restic recovery points captured
before the turnover keep the historical recipient envelope for their full
twelve-point retention window, and Git history keeps it indefinitely: a later
restore from such a point still needs the retired identity to decrypt its
embedded credential documents. Neither `check` nor Restic retention warns about
stranded historical generations today, so keep the retiring identity's key
available until every pre-turnover point has aged out; see the
[backup guide](backups.md#recipient-turnover-and-retained-points).
Encrypted SSH keys prompt on an interactive terminal; unattended use never
falls back to another identity or SSH agent. Private conversions use temporary
0700 storage and 0600 files, with cleanup on success, error or termination.

Reconciliation stages ciphertext copies, updates recipients and rotates the data
key. It decrypts staged results to verify the payload and verifies the intended
recipient list before publishing anything. Preparation failure leaves every
original unchanged. Publication uses atomic replacement per file and fsync;
an interrupted multi-file publication reports completed document names and can
be rerun. It skips unchanged recipient sets and locks the document root against
concurrent tool invocations. Coordinate other editors separately.

Deliver changed ciphertext and activate access changes through your normal
deployment workflow. The tool does not contact hosts, restart consumers, rotate
application credentials, commit files or deploy changes. Existing
`services.overallsSecrets.bundles` paths and controlled restart procedures remain
unchanged. Revoking a recipient cannot erase older ciphertext or previously
learned credentials; rotate affected credentials separately. Cryptographic
decryption also enables re-encryption; publishing changes is governed by
repository/deployment permissions, not a second cryptographic permission flag.
