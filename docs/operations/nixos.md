# NixOS deployment

The root flake exports source-built Marshall and Lilly releases and independent
NixOS service modules. Application builds use the same locked input as `devenv`;
host configurations use the separately locked NixOS 26.05 input. The initial
supported target is `x86_64-linux`.

See the [Nix layout](../../nix/README.md) and [test catalog](../../nix/verification/tests/README.md)
for source ownership, suite locations and regression commands.

This implements part of [ADR-0030](../architecture/decisions/0030-nixos-deployment-and-tls.md).
Host provisioning uses reviewed inventory and provider profiles; see the
[provisioning guide](host-provisioning.md) for verification scope.
The complete three-Marshall/two-Lilly fleet check passes. Adapting the existing
reference host remains in progress.
Lilly accepts only native sparse ZFS pools with required
GUID identity; pools carry no logical budget. The [storage contract](storage-capacity.md)
describes upgrade ordering, ownership and the remaining acceptance work.

## Build

```sh
nix build .#marshall .#lilly
nix build .#checks.x86_64-linux.marshall-release
nix build .#checks.x86_64-linux.lilly-release
nix build .#checks.x86_64-linux.module-configuration
```

Dependency fetching uses hashes in `nix/domains/artifacts/dependency-hashes.json`, checked
against the production Mix locks and Cedar's Cargo lock. Release compilation has
no network access; Cedar compiles from source and assets use pinned executables.
After changing a lockfile, update the corresponding fetch hash deliberately.
The dependency output includes a copy of the Mix lock: a cached fetch with an
outdated lock fails the release build. No production secrets are needed to build.

For flake inspection use `nix flake show --allow-import-from-derivation`; the
pinned devenv package input evaluates a patched Nixpkgs derivation. Build commands
permit that evaluation by default. Files must be tracked by Git for a Git flake
to include them; review the dirty-tree warning before recording provenance.

`scripts/package_release.sh marshall|lilly` builds the selected release, runs its
payload check and exports the complete Nix closure using the existing transfer
format in the [deployment guide](deployment.md).

## Service options

Import `overalls.nixosModules.default`, or only `nixosModules.services.marshall` or
`nixosModules.services.lilly`, from a locked Overalls flake input. Neither service enables
the other. A host may run one local Marshall instance when the declared fleet
contains at least three, or several instances with unique identities and ports.

```nix
{
  imports = [ overalls.nixosModules.default ];
  services.marshall = {
    enable = true;
    publicHost = "control.example.com";
    replicaCount = 3;
    databaseConnectionBudget = 43;
    environmentFile = "/run/overalls-secrets/marshall.env";
    instances.node01 = {
      port = 4443;
      certificateFile = "/run/overalls-secrets/backend.crt";
      keyFile = "/run/overalls-secrets/backend.key";
    };
  };
}
```

Supply the runtime environment described in the deployment guide, including the
external PostgreSQL URL, shared signing/Cloak keys and SMTP credentials. Private
file options are strings naming runtime paths, never Nix path literals or secret
contents. `secretUnits` declares prerequisite preparation services. Missing
credentials fail startup. TLS keys and database trust are delivered through
systemd credentials to unprivileged Marshall instances.

The launch wrapper enforces instance identity, verified database TLS, fleet
budget and HTTPS-only listeners even if a shared environment file conflicts.
The default bind address is loopback. Use `instances.NAME.bindAddress` and
`openFirewall` deliberately for a remote proxy. `cpuCores` and `memoryMiB` apply
collectively to all local Marshall instances. Migrations remain an explicit
operator step; module activation never runs them.

Lilly requires `hostId`, `controlPlane`, `credentialFile`, `egressInterface` and
its enrolled `pools`/verified `images`. Each image entry is an object
`{ path = <image directory>; standby = <bool>; }`: `standby` says whether the
standby refill may pre-create disks for that image, and the module's
`standbyDisks.perImage × standby-eligible images ≤ 64` assertion counts only
eligible entries. Images whose artifacts exceed `imageTemplates.budgetBytes`
are never planned for standbys (a size check, no hashing). Unknown IOPS stays
unknown; `max_iops` requires `max_iops_source`.

Images whose build is not byte-stable (the Windows installation is one) must be
built once and distributed before they are staged: `nix build .#windows-guest`,
then `nix copy --to ssh://<host> <store path>` for every host, verify with
`nix path-info` that each host holds the same store path (and `du` versus
`du --apparent-size` that `disk.raw` stayed sparse), and only then push the
`fleet/guest-images.nix` entry with `standby = false`. Hosts then substitute
the image instead of each building a different one with a different identity. Add public management and infrastructure networks to
`protectedCidrs`. Private/special addresses and guest lateral traffic are already
denied by Lilly's runtime networking policy. Guest CPU and memory limits belong
to `lilly.slice`; the root daemon stays in `system.slice` with host mount
visibility. Restarting the daemon preserves durable state and independent guests.

Lilly enables nftables and IPv4 forwarding. Host firewall reloads must preserve
Lilly-owned tables, so `networking.nftables.flushRuleset = true` is rejected.
When host forward filtering is enabled, the module permits only Lilly's managed
uplink through the selected egress, in addition to the runtime isolation rules.
The module excludes that uplink from DHCP, NetworkManager and networkd management.

### Restricted source export service

Every enabled Lilly host includes the restricted ADR-0037 source endpoint.
It defaults to port 2223 with the firewall opened; disabling transfer or sharing
the administrative SSH port fails evaluation. A custom port can be configured:

```nix
services.lillyTransfer = {
  port = 2224;
};
```

It uses the existing `/etc/ssh/ssh_host_ed25519_key`; its public identity must
match the endpoint enrolled in Marshall. The service does not generate or rotate
host keys. Lilly supplies a private `/etc/lilly-transfer.json` from its bound
pools and the transfer journal root, `/var/lib/lilly/transfers` by default. The
standalone service instead requires an explicit private `configurationFile`.
Neither configuration contains Marshall credentials.

The service on a configured Lilly host also supplies its transfer state
directory to the control runtime. The runtime polls authenticated destination
key-preparation requests, keeps private keys locally, and returns public keys to
Marshall after binding the enrolled source pin. Declare `lilly.transferEndpoint`
in the fleet host JSON with `address`, `port` and the pinned Ed25519 `host_key`.
Enrollment sends that endpoint to Marshall and the host profile uses its port
for the listener. Existing database registrations still need endpoint enrollment;
activating Nix alone does not change Marshall's durable host record.

Only current permit-derived keys can use the dedicated listener. The
`lilly-transfer` account is denied on ordinary SSH. Socket workers run in
`lillyexport.slice`, bounded collectively to two CPU cores and 1 GiB, separately
from the guest reservation slice. Stopping the listener interrupts its transfers;
source quiescence must still be confirmed before cleanup or reservation release.

This endpoint is an implementation component, not a completed relocation feature.
Authenticated permit distribution and Marshall coordination remain unfinished.
See the [relocation review](../architecture/reviews/2026-09-16-workload-relocation.md)
for executed machine evidence and outstanding acceptance.

## Opt-in host TCP profile

Import `overalls.nixosModules.platform.sysctl` (also included by `nixosModules.default`)
and enable the profile explicitly:

```nix
{
  imports = [ overalls.nixosModules.platform.sysctl ];
  overalls.sysctl.enable = true;
}
```

The profile loads `tcp_bbr` and `sch_fq`, selects BBR congestion control and
sets the default queue discipline to `fq`. No service role enables it implicitly;
bootstrap, installer and Firecracker guest images do not opt in. This controls
the importing machine's TCP stack and default packet scheduling. It does not
select congestion control inside separately booted Firecracker guests, although
host queues also carry forwarded traffic. Guest isolation and forwarding rules
remain owned by Lilly.

Ordinary NixOS assignments override either default without `mkForce`:

```nix
boot.kernel.sysctl = {
  "net.ipv4.tcp_congestion_control" = "cubic";
  "net.core.default_qdisc" = "fq_codel";
};
```

Resource limits remain inherited. The pinned NixOS defaults already provide
524288 inotify instances/watches and `kernel.pid_max = 4194304`; Linux 6.18
provides 4 MiB receive/send buffer maxima. The profile therefore omits the
redundant or lower limits in the referenced Loom configuration, including its
100000 system-wide file cap and unsupported BSD `kern.maxproc` setting.
Marshall/Lilly retain their per-service `LimitNOFILE = 65536`.

Inspect an enabled host with:

```sh
sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc
tc qdisc show dev YOUR_UPLINK
ss -tin
```

Use a kernel with BBR and fq support; the machine check exercises the pinned
NixOS kernel. Sysctl changes select defaults for new sockets and queue creation;
existing sockets/listeners and interface queues can retain their earlier policy
after a live switch. Disabling the option removes the profile's configuration,
but does not reset live sysctls or unload modules. To restore policy, explicitly
configure the desired congestion-control and queue defaults and rebuild, or
disable the profile and reboot. Reboot also recreates listeners and interfaces;
schedule it through the normal host-maintenance workflow. The module neither
reboots hosts nor replaces active interface queues automatically.

This is functional configuration, not a measured throughput improvement. See
[ADR-0039](../architecture/decisions/0039-opt-in-host-tcp-profile.md) and its
[verification review](../architecture/reviews/2026-09-17-host-tcp-profile.md).

## Non-Nix executables

NixOS has no global FHS library path. Generic Linux dynamically linked binaries
such as operator tools installed under `$HOME` fail at the stub interpreter with
[the nix.dev FAQ](https://nix.dev/permalink/stub-ld). Fleet host profiles enable
the documented `programs.nix-ld` compatibility layer:

```nix
programs.nix-ld.enable = true;
```

Add missing libraries to `programs.nix-ld.libraries`, not `environment.systemPackages`.
A new login session is required after first enablement so `NIX_LD` and
`NIX_LD_LIBRARY_PATH` propagate. Guest images and service-only module imports do
not receive this setting from the host profile. Lilly's jailed guest ELF checks
remain independent.

## Tailscale mesh access

Fleet host profiles run the Tailscale client daemon on every base and enrolled
host, so operators keep a management path independent of the provider network:

```nix
services.tailscale.enable = true;
```

The daemon starts unauthenticated and joins the tailnet only when an operator
runs `sudo tailscale up` over SSH; the profile holds no Tailscale credentials
and does not auto-enroll hosts. The module marks `tailscale0` unmanaged for
networkd, leaving the reviewed host network configuration untouched. The NixOS
firewall trusts all traffic arriving on `tailscale0`.

Exit-node routing is separately opt-in and defaults off. Panterloons, Dungarees
and Salopettes enable it explicitly:

```nix
overalls.tailscale.exitNode = true;
```

The option selects Tailscale's server routing features, enabling IPv4 and IPv6
kernel forwarding, and applies `tailscale set --advertise-exit-node` after the
daemon starts. Tailnet policy still controls whether clients may use the route.

`nix/policy/network/allowed-hosts.nix` separately defines named public IPv4 sources that may
connect to every TCP and UDP port on fleet hosts, explicitly including HTTP 80
and HTTPS 443. The fleet hosts' reviewed addresses and Geoffrey Huntley's
operator source (ADR-0247) are the entries; each names a value held only in the
fleet-addresses SOPS document, never a literal (ADR-0075, ADR-0233). Every entry has a required comment, and malformed or
duplicate addresses fail evaluation. All global TCP/UDP port and port-range
openings from service modules are suppressed on fleet hosts: new external
connections are accepted only from those addresses or through `tailscale0`.
Loopback and replies to established outbound traffic remain available. This
source grant does not apply to other protocols. Guest images and service-only
module imports do not receive these host-profile settings.

## TLS proxy

`nixosModules.default` also includes `services.marshallProxy`; a proxy-only host
can import `nixosModules.network.proxy`. It does not enable Marshall or Lilly. Configure
`publicHost`, `certificateFile`, `backendCAFile` and named `backends` with
`address`, `port` and `serverName`. A local proxy can reach loopback Marshall
listeners; remote proxies require explicitly reachable backend addresses.

The frontend PEM contains its private key and full chain. Publish it atomically
outside the store with a private parent and read access for the `haproxy` group
(for example directory 0750, file 0640, owned by root). This file is reread on
HAProxy's validated reload; it is not held in a startup-only credential snapshot.
Alternatively, enable the ACME integration below to manage this file.

Both traffic and `/health/ready` probes verify backend trust and the configured
hostname. The proxy accepts the public Host header, preserves WebSocket upgrade
behavior, and replaces client-supplied forwarding headers. Structured request
logs include status, size and timing; they exclude URLs, headers and payloads.
The VM suite tests backend loss/recovery and wrong-hostname rejection against
the real Marshall release. The local ACME suite passed WebSocket transport
survival. The complete fleet check passed real terminal sessions, sharing,
revocation and recovery across Marshall machine loss.

## ACME: HTTP-01 or Route 53

Import the default module or `nixosModules.network.acme`. With the proxy configured as
above, omit `certificateFile`. HTTP-01 is the default and needs no AWS credentials:

```nix
services.marshallProxy.acme = {
  enable = true;
  email = "operator@example.com";
};
# Set only after accepting the selected CA's terms.
security.acme.acceptTerms = true;
```

Public DNS must resolve to the frontend, and public TCP port 80 must reach it.
An independent, unprivileged HAProxy service answers HTTP before the first
certificate exists. It routes challenge GETs to a bounded local lookup service
and permanently redirects ordinary requests to the configured HTTPS hostname
and port with status 308, retaining path and query. Other hostnames receive 421;
challenge methods other than GET receive 405. HTTPS still requires a validated
certificate; no bootstrap self-signed certificate is served.

### Three frontends sharing a hostname

For rotating DNS, every frontend must be able to answer every active challenge.
Configure the private address of each issuer and list the other two on every
machine. For example, on the first machine:

```nix
services.marshallProxy.acme = {
  enable = true;
  email = "operator@example.com";
  http01 = {
    bindAddress = "10.0.0.11";
    port = 9080;
    peers = [
      { address = "10.0.0.12"; port = 9080; }
      { address = "10.0.0.13"; port = 9080; }
    ];
  };
};
```

On the other machines, change `bindAddress` and list the remaining two addresses.
For more machines, list every other issuer on each frontend; there is no
two- or three-machine limit on the peer list.
Use stable RFC1918 or IPv6 ULA addresses of the same family on a trusted private
network. Peer access delegates validation authority for this hostname. The
lookup service queries the local and configured peer Lego responders directly,
once each, concurrently; it does not recursively contact public listeners.
The first matching key authorization wins and outstanding requests are cancelled.
Certificates, account keys and certificate private keys remain on their issuer.
No shared database, filesystem or leader is needed.

The lookup deadline is three seconds, individual endpoints get two seconds,
responses are limited to 1 KiB and only sixteen lookups may run concurrently.
Excess work receives 503. Missing tokens receive 404 when all responders return
404; unavailable or invalid responders yield 503 if no valid response is found.
Responses are not cached. Redirects, environment proxies, arbitrary destinations
and raw request/provider logging are disabled. The socket service cannot read
proxy certificates or AWS credentials.

`http01.bindAddress` defaults to `127.0.0.1`, `port` to `9080`, and `peers` to `[]`
for standalone operation. Peer mode requires a private local bind address and
rejects duplicate/self peers. Port 9080 is an internal responder port; the public
ACME validation port remains 80. With `services.marshallProxy.openFirewall = true`,
the module opens public port 80 and permits responder access only from configured
peer IPs to the selected local address. With it disabled, supply equivalent
firewall rules yourself. Do not independently expose the responder port globally.
Roll out peer membership before adding a frontend to public DNS. Remove unreachable
frontends from DNS; forwarding cannot make an offline public address reachable.
Three-machine functionality is the acceptance target, not a large-fleet load claim.

### Route 53 DNS-01

Select DNS validation explicitly when inbound HTTP validation is unsuitable:

```nix
{ config, ... }:
{
  services.overallsSecrets = {
    enable = true;
    bundles.route53 = {
      encryptedFile = "${./secrets/route53.enc.json}";
      outputs.credentials = { format = "raw"; secrets = [ "AWS_CREDENTIALS" ]; };
    };
  };
  services.marshallProxy.acme = {
    enable = true;
    challengeType = "dns-01";
    email = "operator@example.com";
    route53 = {
      hostedZoneId = "ZEXAMPLE";
      credentialsFile = "${config.services.overallsSecrets.bundles.route53.directory}/credentials";
    };
    secretUnits = [ config.services.overallsSecrets.bundles.route53.unit ];
  };
  security.acme.acceptTerms = true;
}
```

The encrypted `overalls-route53.production.AWS_CREDENTIALS` value is an AWS shared
credentials INI string containing only `[default]`, `aws_access_key_id`,
`aws_secret_access_key` and, if needed, `aws_session_token`. Systemd delivers it
privately to the issuer. The client excludes ambient credentials, other profiles,
external credential processes and instance metadata. Raw provider diagnostics
are suppressed. No private material belongs in Nix expressions or arguments.

DNS-01 adds neither a port-80 listener nor HTTP redirects. Its
`system.build.marshallRoute53Policy` artifact restricts changes to the selected
zone and exact `_acme-challenge.PUBLIC_HOST` TXT record; apply it separately in AWS.
`route53.region` defaults to `us-east-1`; the policy uses the standard AWS partition.
`route53.endpoint` and `route53.dnsResolver` support isolated fixtures. The module
neither provisions AWS infrastructure nor coordinates concurrent TXT updates
between independent DNS issuers. No automatic HTTP/DNS fallback occurs.

For both methods, `server` defaults to the Let's Encrypt production directory,
`caFile` to the pinned public CA bundle, and `secretUnits` supplies any explicit
trust/credential prerequisites. The old flat DNS options have been removed;
there are no compatibility aliases or provider inference from credential fields.

NixOS manages issuance and renewal. `marshall-certificate.service` verifies the
issued chain, hostname, current lifetime, matching private key and HAProxy
configuration before atomically publishing
`/var/lib/overalls-certificates/marshall/full.pem`. The directory is root-owned
0750 and the file 0640, readable by the proxy group. Files and the directory
publication are fsynced before requesting a graceful reload. The default minimum
remaining lifetime for a new publication is one hour.

A failed issue, validation or reload leaves the active proxy serving its previous
certificate. Publication is retried at boot and every 15 minutes, including the
reload when certificate bytes have not changed but the proxy still serves the
previous certificate. If the expected certificate is already served, the check
avoids an unnecessary reload and the old workers it would create. Proxy startup and reload
independently verify the persistent certificate. Startup can use a still-valid
previous certificate when new issuer output is unavailable or invalid; an
invalid or missing cache fails startup. Preserve both `/var/lib/acme` and
`/var/lib/overalls-certificates` as private host state. Reusable images must contain
neither generated identities nor private certificate state.

The ACME checks use real Lego and Pebble for both HTTP and DNS validation.
The HTTP suite targets three frontends plus a separate validator; the Route 53
suite uses signed provider requests and runtime-generated credentials. Cloud IAM enforcement, public DNS,
real CA issuance and physical power-loss recovery remain separate acceptance.

## SSH-derived secrets

Import `nixosModules.security.secrets` or the default module and enable
`services.overallsSecrets`. This generates a persistent Ed25519 host key when
absent, without enabling human SSH access. Enable `overalls.access.enable` for
named fleet accounts from `nix/policy/identity/users.nix`; see the [fleet user and recovery
guide](fleet-users.md) for groups, sudo and repository-wide re-encryption.
No GitHub lookup occurs. Reusable images contain no private host identity.

`bundles.NAME` selects a SOPS document and publishes files under
`/run/overalls-secrets/NAME`. Each document uses the SecretSpec project
`overalls-NAME`, profile `production`, and the required uppercase secret names.
For example, a Marshall document contains
`{"overalls-marshall":{"production":{"DATABASE_URL":"...",...}}}` before
encryption. Encrypt to the authenticated host's converted age recipient and the
registry-selected recovery recipients. Keep plaintext and private keys outside the repository.

```nix
{ config, ... }:
{
  services.overallsSecrets = {
    enable = true;
    bundles.marshall = {
      encryptedFile = "${./secrets/marshall.enc.json}"; # Encrypted content only.
      outputs.environment = {
        format = "environment";
        secrets = [
          "DATABASE_URL" "MARSHALL_CLOAK_KEYS" "SECRET_KEY_BASE"
          "TOKEN_SIGNING_SECRET" "MARSHALL_SMTP_HOST" "MARSHALL_SMTP_USERNAME"
          "MARSHALL_SMTP_PASSWORD" "MARSHALL_SMTP_CA_CERTFILE" "MARSHALL_MAIL_FROM"
        ];
      };
    };
  };
  services.marshall = {
    environmentFile = "${config.services.overallsSecrets.bundles.marshall.directory}/environment";
    secretUnits = [ config.services.overallsSecrets.bundles.marshall.unit ];
  };
}
```

Combine this with the Marshall options above and valid TLS/CA files. Use a
separate host-specific bundle for Lilly's enrollment credential, with one `raw`
output containing its credential JSON as a string. Set `credentialFile` and
`secretUnits` to that bundle's output and preparation unit. Enrollment remains
the protected operator workflow in the deployment guide.

Build the registry-derived public recovery recipients with:

```sh
nix build .#user-recipients --out-link result-recipient
cat result-recipient/ghuntley.age
nix shell .#legacyPackages.x86_64-linux.secretTools.ssh-to-age \
  -c ssh-to-age -i ./authenticated-host-ed25519.pub
```

Use the converted `age1` recipients consistently. Operator recovery uses the
matching private-key conversion in the operator's own private environment;
never copy the operator private key to a host. SecretSpec 0.19.1, SOPS 3.13.3,
ssh-to-age 1.3.0 and age 1.3.1 come from the locked build input.

Root preparation runs without network access, resolves only selected required
values and atomically replaces the complete output directory. An invalid update
retains the previous bundle and prevents a dependent service from starting.
The temporary age identity is removed after use; stop/failure cleanup also
removes abandoned staging directories. Resolver deadlines and output limits
apply without exposing raw errors or decrypted values to the journal.

Default output permissions are 0700 directories and 0600 files owned by root.
An explicitly declared `group` receives 0750/0640 access, suitable for a consumer
that must reread files. `environment` outputs use systemd's EnvironmentFile
format; never source them in a shell. `raw` outputs contain exactly one selected
value. Concurrent consumers must order startup/reload after preparation so they
read one fully published generation.

`secretUnits` uses systemd `Requires`/`After`: restarting a prerequisite can
restart its running consumers. To control the rollout, publish the encrypted
document, explicitly stop the selected consumers, restart
`overalls-secrets-NAME.service`, check success, then start those consumers and
check readiness. Updating a file alone does not change an already running
process's environment. A shared bundle can affect every local consumer that
requires it. Host-recipient rotation and separately keyed replacement recovery
pass the machine suite. Coordinated fleet signing/Cloak/database credential
rotation passes the separate four-machine check described below.

### Host identity rotation and replacement

Keep a verified administrative session and recovery access throughout this
workflow. For planned rotation, generate the new private SSH key on its host;
authenticate and transfer only its public key to the operator. For replacement,
boot the new host with its own generated identity and authenticate that public
key. Do not clone the old host's private key.

1. In the operator's private environment, recover the existing document using
   the operator identity. Re-encrypt that payload for the old host, new host and
   operator recipients. Verify each intended identity can decrypt before
   retiring any recipient. Private keys and plaintext stay outside the Nix store,
   repository, process arguments and logs.
2. Deliver the staged encrypted document. For rotation on the existing host,
   install the new SSH key pair with the required ownership/permissions and
   restart SSH while retaining recovery access. Independently verify its new
   fingerprint before updating trusted client host-key records.
3. Stop the affected application consumers, prepare their bundles through
   `overalls-secrets-NAME.service`, then start them and check readiness. A
   replacement first verifies bundle preparation; application startup also needs
   its database, TLS and enrollment configuration. Lilly host ownership and VM
   recovery follow their own enrollment/lifecycle procedures.
4. Freshly encrypt the recovered payload for the final recipients, removing the
   retired host. Verify an old-identity-only attempt cannot decrypt the new
   document and both the new host and operator still can. Deliver it and repeat
   controlled preparation/readiness checks before retiring old key material.

The [rotation review](../architecture/reviews/2026-09-16-secret-host-rotation.md)
records this custody test. A retired host may already know application secrets;
removing its age recipient does not revoke those credentials. Coordinate their
separate rotation across the affected services. For a lost or compromised old
host, use operator recovery and authenticated replacement recipients without
adding the old recipient to new documents.

### Coordinated application credential rotation

The [four-machine rotation suite](../architecture/reviews/2026-09-16-fleet-credential-rotation.md)
passed the following workflow in 249.75 seconds; its review records the evidence
and acceptance boundaries.

For Cloak, preserve each existing key's tag and bytes. First distribute an ordered
`[old, new]` keyring in the encrypted documents and restart each affected Marshall
consumer, checking readiness and access to existing encrypted credentials. Only
after every replica can decrypt with the new key should a second rolling update
promote `[new, old]`. New writes then use the new key while all nodes can read both
generations. Retain old decryption keys while records or retained backups need
them; this workflow does not rewrite all encrypted data or retire backup keys.

The current signing configuration accepts one token secret and one cookie secret.
For their rotation, schedule a coordinated control-plane interruption and expect
users to sign in again. Stop every affected consumer, including operator processes
and background workers using these credentials. Prepare matching new signing and
cookie values in each host's encrypted bundle. If also rotating the shared
database role password, change that role while its consumers are stopped and
prepare the matching database URL everywhere. Resolve each bundle successfully,
then start all consumers and check verified-TLS readiness and authentication.
Verify fresh database connections reject the retired password, old logins fail,
and new logins and retained encrypted credentials work across all replicas.
Avoid serving replicas with mixed single signing keys. This is a coordinated
cutover, with no claim of uninterrupted control-plane availability.

The scheduled updater refuses such a candidate as `coordinated_secret_change`
before migration or activation, because it must never admit changed signing
authority unattended. The refusal retries with a deterministic backoff capped
at fifteen minutes (failure count caps at sixteen) and never expires. After you
complete the manual cutover — the active system and its deployment manifest
exactly match the refused candidate and each bundle is re-prepared — the next
updater run **after the persisted retry time** finds the already-active
candidate and only re-verifies live health: it does not re-stage, re-resolve,
migrate or switch. Until that retry time arrives, `overalls-auto-update status`
may keep showing the refused phase; this stale window of at most fifteen
minutes is the current expected behavior, not a second failure. The
[updater custody review](../architecture/reviews/2026-09-26-custody-updater.md)
records the exact refusal label, backoff cadence and verify-only recovery.

If custody instead removes a host from a document its configuration still
selects, the next candidate wedges at staging: resolution can no longer decrypt
with the host identity, the attempt log records failure `operation_failed` in
phase `stage`, and the same capped backoff applies. Restore custody for the
host or remove the bundle from its configuration; the corrected revision
recovers without touching the last published bundle.

## Machine checks

The detailed fleet collector has isolated measurement/buffering and configuration
checks:

```sh
nix build .#checks.x86_64-linux.fleet-monitor
nix build .#checks.x86_64-linux.fleet-monitor-configuration
```

These do not establish native fleet monitoring acceptance. Its opt-in
`services.overallsFleetMonitor` module requires a dedicated runtime credential and
the versioned Marshall ingestion endpoint; that server path remains in progress.
Keep it disabled until ingestion is deployed. Sampling is five seconds, with ZFS
accounting every 30 seconds and bounded 30-minute retry storage.

```sh
nix build -L .#checks.x86_64-linux.service-roles
nix build -L .#checks.x86_64-linux.secret-custody
nix build -L .#checks.x86_64-linux.credential-rotation
nix build -L .#checks.x86_64-linux.acme-lookup
nix build -L .#checks.x86_64-linux.acme-http01
nix build -L .#checks.x86_64-linux.acme-route53
```

This uses `pkgs.testers.runNixOSTest`, actual releases and four QEMU nodes for
neither service, Marshall only, Lilly only and both. It generates synthetic keys
at runtime and uses local TLS PostgreSQL. The builder must have usable KVM and
advertise `nixos-test`, `kvm` and `nested-kvm`. Lilly's startup ownership check
requires usable inner KVM even before any guest is provisioned. Give the Nix
build users access to `/dev/kvm`; advertising a feature does not grant access.
The suite forces hardware acceleration and passes the host CPU through, so an
incapable builder fails instead of falling back to software emulation.
Keep Python lint/type checks enabled. A defined
or built driver does not establish a passing machine run.

The role suite checks service startup, explicit migration, TLS, privileges,
configuration authority and role independence. Its combined machine runs three
Marshall instances, Lilly and HAProxy with reduced fixture resource budgets. It
verifies effective CPU/memory limits, independent service restarts and proxy
readiness as backends stop and recover. Guest execution and separate-machine
coordination have their own suites below. The secret suite uses two additional simulated
hosts, actual SecretSpec/SOPS and a synthetic independent recovery key. It tests
private delivery, wrong-host and missing-value rejection; its boundary tests
exercise generated values through actual systemd parsing. Group isolation,
interrupted publication, controlled application credential rotation and switching
NixOS generations while retaining the SSH identity also pass. The expanded suite
also passes staged host-recipient rotation, old-key rejection and recovery onto a
separately keyed replacement. The separate four-machine rotation suite passes
staged/promoted encryption keys, coordinated signing/cookie/database cutover and
old-credential rejection across three real Marshall nodes.
Image/reboot identity checks pass in the separate installation/image suites below.
The HTTP-01 suite adds three frontends and a separate local Pebble/DNS validator,
including cross-frontend issuance, simultaneous renewal, private-port restrictions
and standalone operation. See the [HTTP-01 review](../architecture/reviews/2026-09-17-http01-validation.md)
for execution results and limits. The DNS ACME suite adds a local DNS/Route 53/Pebble machine with actual Marshall and
HAProxy. It passed issuance, renewal, failed-provider handling, certificate validation,
cached-certificate startup and reload recovery. Its WebSocket check
uses Marshall transport heartbeats; it does not establish an authenticated guest
terminal session through this proxy.

The complete suite definitions and separate physical
acceptance obligations are listed in
[ADR-0033](../architecture/decisions/0033-nixos-machine-verification.md), including
the additional `nested-kvm` capability for real Firecracker guests.

### Fleet coordination check

```sh
nix build .#checks.x86_64-linux.fleet --no-link --print-build-logs
```

This nested-KVM suite boots nine machines: three Marshall nodes, two Lilly nodes,
PostgreSQL, HAProxy, a local egress/DNS fixture and a browser client. Its declared
memory totals 23.5 GiB; allow additional builder and nested-virtualization
overhead. The test has a one-hour overall bound. It uses private runtime-generated
credentials and independent overlays of prepared virtual ZFS mirrors.

The current driver defines authenticated capacity reports, synchronized admission
races, six real guests, node/database outages, daemon survival, stop/start/delete,
and stale-capacity fencing. See the
[fleet review](../architecture/reviews/2026-09-16-nixos-fleet.md) for completed
derivations and prior failures. The complete current-source fleet passed in
1108.23 seconds, including deterministic abandoned database transaction/session
reclamation and deletion while unrelated guests continue running.

### Native ZFS observation check

```sh
nix build .#checks.x86_64-linux.native-zfs --no-link --print-build-logs
```

This check requires usable KVM and exercises the source-built Lilly reader on
real OpenZFS datasets backed by two virtual mirror members. It verifies sparse
allocation, compression, quota pressure, identity changes, unexpected properties
and descendants, degraded backing and large property-tree responses. It includes
401 child datasets; parser properties cover the 4096-child bound. These numbers
are test coverage, not a measured production density or throughput limit.

The observation fixture uses ZFS utilities to create and destroy datasets. See the
[native observation review](../architecture/reviews/2026-09-16-native-zfs-observations.md)
for executed reader results. The lifecycle and guest suites below separately
verify disk mutations and simulated host-loss recovery.

### Owned ZFS disk lifecycle

```sh
nix build .#checks.x86_64-linux.zfs-lifecycle --no-link --print-build-logs
```

This separate check invokes Lilly's actual disk/ownership APIs using the verified
NixOS guest image on a ZFS mirror. It covers sparse publication, retained data,
creation/copy/destruction interruption, ownership and GUID conflicts, missing
initialized disks, mount aliases and durable tombstones. It starts no VMMs;
nested guest execution and host-loss flush durability remain separate checks.

The module requires a previously imported, mounted parent with the required
LZ4/no-reservation properties. Set a persistent eight-hex-digit
`networking.hostId` for NixOS ZFS support; it is distinct from Lilly’s enrolled
host UUID. Supply the actual enrollment GUIDs:

```nix
services.lilly.pools = [{
  id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"; # Actual enrolled pool UUID.
  path = "/pool";
  filesystem_id = "zfs:123:456"; # Illustrative GUIDs; replace both.
  storage = {
    backend = "zfs";
    zpool_guid = "123";
    dataset_guid = "456";
    dataset = "tank/lilly";
  };
}];
```

Use one schedulable parent per zpool on a host. The module supplies the host's
ZFS userspace package and mount ordering; it does not create/import pools,
partition devices or mutate properties at activation. Keep ownership state and
tombstones on the parent intact. Adapting the existing reference host remains in
progress; the separate installation module is described below. See the
[lifecycle review](../architecture/reviews/2026-09-16-owned-zfs-lifecycle.md).

### Firecracker on ZFS

The dedicated relocation acceptance fixture runs three Marshall instances and two
Lilly nodes with real ZFS pools and pinned transfer SSH identities:

```sh
nix build .#checks.x86_64-linux.relocation-fleet --no-link --print-build-logs
```

It exercises public automatic admission, a running baseline, writes after that
snapshot, final transfer, destination readiness, source reclamation and returning
to the former host under a new placement. Recovery scenarios include mid-stream
cancellation, endpoint restarts, source reboot after stop, readiness timeout,
Delete with pending cleanup, real updater activation and physical storage
pressure. It has a three-hour global limit; credentials and fault controls remain
private to the disposable fixture. One complete move has passed; acceptance of
the expanded matrix remains pending. Exact revisions and results belong in the
[relocation review](../architecture/reviews/2026-09-16-workload-relocation.md).

```sh
nix build .#checks.x86_64-linux.zfs-guest --no-link --print-build-logs
```

This check requires a verified `nested-kvm` builder. It imports Lilly's module
for host prerequisites and uses isolated source-built API workers to launch a
real confined guest. The control daemon is disabled because this check has no
Marshall fixture. It checks console writes across worker exit and VM stop/start,
capacity while stopped/running, deletion and recovery after the framework's
simulated host crash. QEMU virtual disks use Writeback; the outer host stays
alive. This does not establish physical power-loss durability or the required
three-Marshall/two-Lilly fleet scenarios. Executed results are recorded in the
[lifecycle review](../architecture/reviews/2026-09-16-owned-zfs-lifecycle.md).

### Native ZFS I/O observations

```sh
nix build .#checks.x86_64-linux.zfs-io --no-link --print-build-logs
```

This KVM machine check runs the actual source-built Lilly collector on two ZFS
pools. A fixture writes and reads outside Lilly's dataset to verify logical
whole-pool I/O scope while capacity remains limited by the enrolled dataset.
Malformed output, utility timeout and actual pool export/import must withhold
rates and recover on the next clean sample. It does not calibrate physical IOPS
or benchmark VM density. See the [scope/precision guide](storage-capacity.md)
and [I/O review](../architecture/reviews/2026-09-16-native-zfs-io.md).

## Bare-metal host provisioning

Use the [host provisioning workflow](host-provisioning.md) for reviewed Hetzner
and EC2 machines. `fleet/hosts/NAME/host.json` derives base/enrolled configurations
and secret recipients. `nix run .#host -- …` provides discovery, published plans,
explicit installation, enrollment and verification. Production budgets are
explicit; image sizes remain in fixtures. The generic bootstrap, installer-ISO
and mirrored-module exports have been removed under ADR-0043.

## Automatic host updates

Import `inputs.overalls.nixosModules.default` (or the standalone `auto-update`
module alongside the role modules), then configure each host explicitly:

```nix
services.overallsAutoUpdate = {
  enable = true;
  repository = "git@github.com:YOUR_ORG/YOUR_INFRA.git";
  branch = "main";
  flakeAttr = "YOUR_HOST";
  sshKeyFile = "/run/overalls-secrets/git/key";
  secretUnits = [ "overalls-secrets-git.service" ];
};
```

The repository must expose that host under `nixosConfigurations` and commit its
lockfiles. Install the repository's SSH host key in `knownHostsFile` (default
`/etc/ssh/ssh_known_hosts`). Deliver the Git key using the existing SecretSpec
bundle facilities before enabling polling. Do not put private keys, tokens or
plaintext application secrets in Nix expressions or Git URLs.
Deliver externally managed encrypted files before publishing the commit that
should consume them. An unchanged healthy revision is a no-op; an out-of-band
secret change needs a new deployment commit to trigger publication.

Each host polls independently every ten seconds, with up to two seconds of
jitter. A revision is built once into an exact deployment bundle; candidate
secrets are decrypted into private staging using the persistent SSH identity.
Marshall migrations run before consumers stop, using the candidate release,
Ecto's PostgreSQL advisory lock and two database connections. Configure `databaseConnectionBudget` for at least
`replicaCount * (poolSize + 3) + 10` when enabling updates. Migrations must be
compatible with all serving releases; successful schema changes are not rolled
back if switching later fails.

The updater rejects automatic changes to `DATABASE_URL`, `SECRET_KEY_BASE` and
`TOKEN_SIGNING_SECRET`. Cloak keys may be added, but existing keys and the first
(active encryption) key must remain unchanged. Use the coordinated maintenance
procedure for promotion, removal or shared authority changes. Lilly accepts an
already-issued replacement credential; issuance and enrollment remain separate.
Its host identity, storage and network bindings must remain unchanged.

Activation stops consumers before publishing the validated bundles, then starts
them even for secret-only updates. It verifies every local Marshall instance
with TLS and Lilly through its private readiness socket. For private CAs or
per-instance names, set `marshallHealth.INSTANCE = { serverName = "...";
caFile = "/path/to/ca.crt"; };`. Success requires two observations five seconds
apart; `healthTimeout` defaults to 120 seconds. Lilly requires authenticated
control, a recently delivered report, fresh actor reconciliation and console
readiness. Running guest processes continue across the daemon restart.

```sh
sudo systemctl start overalls-auto-update.service
sudo overalls-auto-update status
sudo journalctl -u overalls-auto-update.service
sudo systemctl stop overalls-auto-update.timer
```

Status persists in `/var/lib/overalls-auto-update/status.json`, including the
candidate, failed phase, active system and last healthy revision. Private command
output is retained in that directory's `attempt.log`; journal events contain
sanitized phase/reason codes. A failed revision backs off from thirty seconds to
fifteen minutes. A corrective commit bypasses the delay. An activated candidate
that failed health verification is checked again without another restart.

This is independent host automation: simultaneous restarts are possible. It does
not provide fleet sequencing, schema rollback, automatic reboot or
generation-sized retention; the separate garbage collection below reclaims old
generations. Kernel and incompatible protocol/schema changes need planned
maintenance. Disable the timer before manual recovery. Existing installations
must first gain the public deployment descriptor from these modules through a
reviewed manual deployment so unattended secret comparisons have a baseline.

## Automatic Nix store garbage collection

`services.overallsNixGc` reclaims old Nix store generations before host storage
runs out. The shared host profile enables it on every fleet host; override the
reviewed values through each host's configuration:

```nix
services.overallsNixGc = {
  interval = "1h";
  diskThresholdGiB = 200;
  maxFreedGiB = 400;
  preserveGenerations = "14d";
};
```

A run executes only when free space on the filesystem holding `/nix` falls
below `diskThresholdGiB`; it then runs `nix-collect-garbage
--delete-older-than preserveGenerations --max-freed` capped at `maxFreedGiB`,
using the host's configured `nix.package`. Generations younger than the
preservation window always survive. Panterloons and Dungarees use the values
above, reviewed against their 1.73 TiB mirror and 1593 GiB guest quota; the
default interval is hourly with jitter and missed-run catch-up.

Because the guest dataset quota is a ceiling rather than a reservation,
legitimate guest growth can push free space below the threshold; a run then
finds nothing older than the window and exits. Unreachable remote-builder
cache paths may be reclaimed within the cap and repopulate on demand.
Concurrent auto-update builds stay safe through Nix's temporary roots. Stop
the timer before manual recovery:

```sh
sudo systemctl stop overalls-nix-gc.timer
sudo journalctl -u overalls-nix-gc.service
```

## Host-local SMTP relay

`services.marshall.smtpRelay.enable` defaults to `false`. Enable it on each
Marshall host that should use the managed synchronous relay. Multiple Marshall
instances on a machine share one `overalls-smtprelay.service`. The relay binds
SMTP and metrics only to `127.0.0.1`, and opens no firewall ports. Host-local
processes are trusted to submit mail from the configured sender.

Use the existing secret subsystem with a separate SMTP bundle:

```nix
{ config, ... }:
{
  services.overallsSecrets = {
    enable = true;
    bundles.smtp = {
      encryptedFile = "${./secrets/smtp.enc.json}";
      outputs.username = { format = "raw"; secrets = [ "SMTP_USERNAME" ]; };
      outputs.password = { format = "raw"; secrets = [ "SMTP_PASSWORD" ]; };
    };
  };
  services.marshall.smtpRelay = {
    enable = true;
    from = "noreply@example.com";
    upstream = {
      provider = "ses";
      region = "us-east-1";
      usernameFile = "${config.services.overallsSecrets.bundles.smtp.directory}/username";
      passwordFile = "${config.services.overallsSecrets.bundles.smtp.directory}/password";
    };
    secretUnits = [ config.services.overallsSecrets.bundles.smtp.unit ];
  };
}
```

Before encryption, the document has the shape
`{"overalls-smtp":{"production":{"SMTP_USERNAME":"…","SMTP_PASSWORD":"…"}}}`.
Encrypt it to the authenticated hosts' converted age recipients and the operator
recovery recipient, as described above. Only encrypted documents belong in the
repository. Raw output values must be nonempty, at most 4096 bytes, and contain
no newline, carriage return or NUL; no trimming changes a supplied password.

Root preparation publishes the complete bundle atomically. Systemd
`LoadCredential` gives its username/password to the relay's dynamic user.
Marshall receives only the local address, port and sender. Remove remote SMTP
credentials and settings from the Marshall bundle's selected environment values
when enabling the relay; retain its database, signing and Cloak secrets. Existing
shared environment SMTP entries are removed/overridden by the launch wrapper,
but should not remain in that bundle unnecessarily. No new decryption identity,
resolver or plaintext Nix value is introduced.

| Option under `services.marshall.smtpRelay` | Default / requirement |
| --- | --- |
| `from` | Required verified sender address; used for an exact envelope-sender restriction |
| `port` | 2525, loopback submission |
| `metricsPort` | 9469, loopback Prometheus metrics |
| `maxConnections` | 100; bounded between 1 and 1000 |
| `maxMessageSize` | 1048576 bytes; bounded between 1 KiB and 10 MiB |
| `upstream.provider` | `generic`, `ses`, or `resend`; default `generic` |
| `upstream.host` | Required for generic; derived for presets; may be overridden |
| `upstream.region` | Required for SES; supplies `email-smtp.REGION.amazonaws.com` |
| `upstream.tls` | `starttls` by default; `implicit` for Resend; no plaintext mode |
| `upstream.port` | 587 for STARTTLS, 465 for implicit TLS; may be overridden |
| `upstream.auth` | `plain` or `login`; default `plain` |
| `upstream.usernameFile` | Private raw runtime credential; required except for Resend's fixed `resend` username |
| `upstream.passwordFile` | Required private raw runtime credential |
| `upstream.caFile` | System public CA bundle; may point to an explicit private CA bundle |
| `secretUnits` | Bundle preparation units required before relay startup |

SES uses region-specific **SMTP** credentials, not an ordinary AWS secret access
key. Override the hostname when using a nonstandard AWS partition/endpoint.
Resend uses `smtp.resend.com` and its API key as the password; select
`provider = "resend"`, omit `usernameFile` and the unused username output, and
supply `passwordFile` through the same bundle mechanism. Both providers still
require sender verification and their DNS setup. The modules provision neither
provider accounts nor DNS and do not imply inbox delivery.

The relay uses the source-pinned Grafana v2.2.3 package from Loom with maintained
patches for verified outbound TLS, authentication, bounded forwarding and safe
diagnostics. Its upstream dependency hash is regenerated under Overalls' pinned
Go toolchain and tested with package tests. No protocol/header logs or tracing
are enabled. The relay keeps no durable mail queue; Oban retries failed attempts
and preserves the encrypted payload. Monitor relay metrics and Marshall's safe
`mail_delivery_attempt` events separately from provider inbox acceptance.

For SMTP-only manual rotation, update the encrypted document, stop
`overalls-smtprelay.service`, restart `overalls-secrets-smtp.service`, check success,
and start the relay. Updating a file alone does not replace credentials in a
running process. A missing value preserves the previous complete bundle but
blocks dependent startup. Automatic updates reuse descriptor-bound private
staging and the existing broader stop/prepare/start workflow; the relay is also
a deployment health unit. Upstream connectivity is not part of web readiness.

Both serving and candidate migration launchers share the local transport
configuration, so migration does not require provider credentials. Disabling the
relay requires restoring valid direct SMTP configuration. No database migration
is introduced. Verify a controlled mailbox with the chosen real provider before
public deployment; the `smtp-relay` check uses only local TLS fixtures.

## Host logs and diagnostics

See [per-host observability](observability.md) for direct Fluent Bit exports,
CloudWatch management, restricted audit/Firecracker logs and encrypted crash dumps.


Relocation receive bandwidth is configured with
`services.lilly.transferBytesPerSecond` (default `67108864`, or 64 MiB/s).
Valid values are positive integers up to `1073741824` (1 GiB/s). Lilly applies the
limit to each receive stream, including resumed streams, with a 64 KiB burst
allowance. This is a transport limit; it is not durable-byte progress or a storage
reservation. Relocation acceptance remains partial as recorded in ADR-0037.

`nix build .#checks.x86_64-linux.audi-fleet` targets the Audi acceptance composition:
three Marshall nodes, two Lilly/Audi hosts, independent Audi DNS on two control
nodes, and a DNS-validating Pebble CA. It provisions a real nested Firecracker
HTTP/WebSocket guest and exercises browser access, policy revocation and gateway
restart. The new scenario is not yet verified; it requires KVM and the same host
resources as the existing fleet checks.
