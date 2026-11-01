# Inception development guests

`inception` runs PostgreSQL, Marshall and Lilly inside a Firecracker VM. Its
inner Lilly creates ordinary Firecracker guests. Any user permitted to create
VMs can select it once the deployment has configured the image and an eligible
host. There is no separate developer allowlist.

The default and minimum shape is 16 vCPUs, 32 GiB RAM and a 64 GiB ext4 root.
Each VM also has a fixed, sparse 256 GiB raw data disk. The inner ZFS pool reserves
240 GiB for guest datasets. Outer admission reserves 320 GiB at the default root
size; thin provisioning does not waive logical capacity or physical headroom.
The profile uses `10.40.0.0/16` and the existing guest isolation rules.

## Deployment configuration

Build `tools/buck2 build //:package-guest-inception`. Register its `manifest.json` through the
protected `Marshall.Compute.Images.register/2` operator action, and install
the resulting immutable image on the intended Lilly hosts. Use the canonical
image ID returned by registration for both Nix options:

```nix
services.marshall.inceptionImageId = "sha256:REPLACE_WITH_REGISTERED_IMAGE_ID";
services.lilly.inceptionImageId = "sha256:REPLACE_WITH_REGISTERED_IMAGE_ID";
services.lilly.images = [ "/nix/store/REPLACE_WITH_INCEPTION_IMAGE" ];
services.lilly.inceptionSMTPFile = "/run/secrets/inception-smtp.json";
```

These values are illustrative; keep other installed guest images in `images`.
Non-Nix Marshall deployments use `MARSHALL_INCEPTION_IMAGE_ID`. Upgrade Marshall,
Lilly and their shared protocol together before enabling selection. Older
consumers reject the fourth profile.

Provision the SMTP file through the deployment's existing secret mechanism:
root-owned, mode 0600, a regular single-link file in a private directory outside
the Nix store. Its closed JSON schema is:

```json
{
  "version": 1,
  "host": "smtp.example.net",
  "port": 587,
  "username": "REPLACE",
  "password": "REPLACE",
  "from": "developer@example.net",
  "tls": "starttls"
}
```

`tls` also accepts `implicit` for implicit TLS. An optional `ca_pem` supplies a private
relay's public CA certificate. Plaintext transport, unknown fields and internal
deployment credentials are rejected. Never place this JSON in a Nix expression,
image, process argument or source checkout. Guest administrators can read the
shared SMTP credentials; scope the relay account for this intended access.

At host startup, `lilly-inception-preflight.service` boots a trusted temporary
Firecracker guest which itself boots an ordinary Firecracker guest. It has no
host network access, receives no SMTP, and removes its temporary disks. Reserve
at least 8 GiB of temporary space under `/var/lib/lilly-inception-check`, plus
the host's normal operating headroom. Its private proof binds the host boot,
image, probe artifact and Firecracker executable. CPU flags alone do not enable
admission. A failed prerequisite leaves ordinary profiles available.

After changing any bound artifact, refresh the prerequisite during maintenance
with `systemctl restart lilly-inception-preflight.service`. Configuration changes
do not automatically restart this potentially expensive probe. Lilly advertises
Inception only with a matching current proof and valid SMTP configuration; normal
freshness, image, host readiness and capacity checks still apply.

## Working inside the guest

Choose **Inception** in the control plane's creation form. The image is bound to
the profile and its resource defaults populate automatically. The authenticated
outer terminal provides administrative access to the guest.

On first boot the guest clones `https://github.com/ghuntley/overalls` into the
editable, initialized Git checkout at `/workspace/overalls`. Enter
`devenv shell` there for the pinned development environment. Bootstrapped services
run the image's packaged releases: editing source does not automatically replace
them. Use the repository's ordinary build and development commands to test changes.

Useful service names are `postgresql`, `marshall-inception`, `inception-marshall-listener`, `lilly`, `inception-source`,
`inception-storage`, `inception-enrollment` and `inception-enable`. The source unit
retries the public checkout independently of stack readiness. Marshall listens on
guest-local browser TLS port 4443 and fleet TLS port 5443; PostgreSQL listens on loopback. Local TLS public
certificates are under `/run/inception-public`. Administrative bootstrap material
is private under `/var/lib/inception`; do not copy it to another deployment.
The root identity, database, workspace edits, enrollment and ZFS binding survive
stop/start. Missing or substituted initialized storage fails without formatting.

Inception supports one development layer. The inner deployment does not offer
the Inception profile. The current implementation adds parent-published control
and app names, Audi/Porsche ingress and independent inner authentication under
[ADR-0085](../architecture/decisions/0085-inception-public-ingress.md). Full native
public-access acceptance remains incomplete; see its
[implementation review](../architecture/reviews/2026-09-18-inception-public-ingress.md).
The profile's transfer and clone wiring carries both drives in one dataset
stream, but native relocation, evacuation and clone acceptance remain gated by
the outstanding ADR-0072 fleet evidence. Root growth is accounted separately;
the data disk remains 256 GiB.

## Inner inference configuration

Inner Ziggy enrolls with inner Marshall using its own durable token. Restart
does not rotate it or extend expiry. Provider secrets are separate from that
token and are never inherited from the parent. The encrypted provider document
belongs at `/var/lib/inception/ziggy-providers.enc.json`, with the SecretSpec
project `overalls-inception-ziggy`, profile `production`, and fields
`OPENAI_API_KEY` and `ANTHROPIC_API_KEY`. Both fields are required by the delivery
bundle; Ziggy loads only the selected providers. No default provider keys are
supplied.

Use the authenticated console to obtain this instance's recipient with
`ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`. Encrypt the document for that
recipient using SOPS. This SSH identity exists for secret custody; it does not
enable an administrative SSH listener. Keep the encrypted document root-owned
and do not copy another instance's private keys or authority files.

By default both providers are selected. A root-owned, mode-0600 file at
`/var/lib/inception/ziggy-providers.json` may select one, for example
`{"version":1,"enabled_providers":["openai"]}`. It cannot override endpoints or
credential paths. After installing the encrypted document or changing selection,
restart `inception-ziggy-runtime`, `overalls-secrets-inception-ziggy`, and `ziggy`.
Then start `audi-private-certificate` and `audi-private`. Missing or invalid
credentials fail startup without a parent fallback. Lilly requires both private
services to be ready before starting nested guests.

Private Audi uses the inner issuer, its own host certificate, and Lilly's exact
owned namespace. Service wiring and configuration checks pass; native startup
and private-inference acceptance remain incomplete. The registered nested guest
image is a public seed; Lilly delivers the instance's private-service root
through the authenticated trust receiver for each child boot, so inner guests
trust only their own environment. Enrollment alone does not establish a
working `llm.internal` service.

## Credentials and maintenance

Each guest generates its own database password, application signing/encryption
keys, TLS identity and Lilly enrollment credential. Only the SMTP bundle is
shared. Runtime delivery uses the owned VM's private vsock and current boot
challenge. The initial running outcome waits for the complete stack to become
ready, rather than just the kernel booting.

Atomically replace the private host SMTP file to rotate the bundle. Reconciliation
refreshes running Inception guests and restarts their Marshall service when the
bundle changes; stop/start also receives the current bundle. Failed refreshes are
retried without stopping the guest. Identity and database credentials are retained.

The current deployment binds one Inception image ID. Keep the configured image
and proof available for existing guests; changing them can make those guests
ineligible for restart, credential delivery or relocation destinations.
Multi-version rolling image upgrades are not provided by this change.

See [ADR-0054](../architecture/decisions/0054-inception-development-profile.md) and
the [implementation review](../architecture/reviews/2026-09-18-inception-profile.md)
for executed checks and remaining acceptance limits. Native nested execution and
live SMTP delivery are separate evidence; synthetic mail fixtures do not prove
inbox delivery.
