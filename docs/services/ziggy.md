# Ziggy private inference

Customer workspaces are excluded by [ADR-0064](../architecture/decisions/0064-customer-workspace-isolation.md):
private DNS, HTTPS and inference admission/renewal are denied.

Canonical endpoint: `https://llm.internal`. Architecture:
[ADR-0063](../architecture/decisions/0063-private-services-and-ziggy.md).

Enabling Lilly automatically enables an independent Ziggy release. Explicitly
disabling Ziggy on a Lilly node fails NixOS evaluation. Audi answers `.internal`
inside Lilly's network namespace and terminates TLS at `169.254.254.1:443`.
Lilly derives execution identity from the guest's pre-NAT address. Audi forwards
that binding through a private Unix socket; Ziggy obtains current Marshall
admission before persisting local admission and calling a provider. Guest-supplied
credentials and identity headers confer no authority. There is no public listener.

## Native guest clients and routes

Rebuilt NixOS and Ubuntu images install pinned Codex and Claude Code with their
native system settings under
[ADR-0167](../architecture/decisions/0167-native-guest-coding-clis.md). Codex selects
`https://llm.internal/openai/v1` through `/etc/codex/config.toml` and uses HTTP
Responses without OpenAI login or WebSockets. Claude selects
`https://llm.internal/anthropic` through
`/etc/claude-code/managed-settings.json`; its required authentication value is a
nonsecret sentinel. Both retain native sessions/model selection and verify the
guest CA bundle. Image rebuilding does not update retained guest disks.

Ziggy supports native OpenAI Responses/chat and Anthropic Messages/token counting.
POST `/v1/messages` and `/v1/messages/count_tokens`, plus their matching
`/anthropic`-prefixed paths, accept either no query or the literal `beta=true`.
The validated beta query reaches the provider URL; accounting retains the
query-free operations `messages` and `count_tokens`. Native request bytes and
permitted `anthropic-version`/`anthropic-beta` headers remain unchanged.
Additional, duplicate or encoded query parameters, other values, mismatched
provider prefixes and queries on other routes are refused before provider effects.
There is no API translation.

Codex must use stateless text Responses: stored/background requests,
`previous_response_id`, audio and non-text modalities remain refused. Native
client model catalogs may include models Ziggy does not provide; no catalog
synchronization is promised. Model choice cannot enable a disabled provider.
Production hosts enable only OpenAI, so Claude currently receives
`provider_unavailable` even though its beta URL is supported. This change does
not introduce Anthropic credentials or enablement.

## Deployment inputs

Ziggy inherits Lilly's `hostId`, verified `controlPlane`, and control-plane CA.
`services.ziggy.enabledProviders` defaults to `[ "openai" "anthropic" ]`.
An explicit nonempty selection limits discovery and inference to those providers;
readiness still requires discovery for every enabled provider and valid Marshall
authority. Disabled providers return `provider_unavailable` before admission or
provider effects. Existing runtime configurations without `enabled_providers`
retain both providers. Overalls currently selects only OpenAI; the
retained Anthropic placeholder does not enable Anthropic inference.
Configure `services.ziggy.secretsFile` with its SOPS document; missing secrets
must not silently disable the required service. That
JSON document supplies `ZIGGY_CREDENTIAL`, `OPENAI_API_KEY`, and
`ANTHROPIC_API_KEY` under `overalls-ziggy.production`. Existing SecretSpec bundles publish private runtime files;
systemd `LoadCredential` supplies snapshots exclusively to Ziggy. Startup copies
them into a private 0700 runtime directory with 0400 files. Socket sharing uses a
separate group from credential custody. Marshall and
Audi never receive provider keys. Dedicated Ziggy credentials are issued by
the existing Marshall operator CLI: `ziggy-rotate HOST TTL_SECONDS OUTPUT_FILE`,
`ziggy-verify OUTPUT_FILE`, and `ziggy-revoke HOST`.
Enrollment must write the returned credential directly to private operator
custody and encrypt it, never to arguments or logs.

Enable `services.audiPrivate` alongside Ziggy. Supply `secretsFile` containing
`AUDI_PRIVATE_CERTIFICATE_CHAIN` and `AUDI_PRIVATE_CERTIFICATE_KEY` under
`overalls-audi-private.production`, plus `rootsFile` for the public CA bundle.
The private frontend does not require public Audi ingress. No deployed service
holds the root or intermediate signing key.

`audi/priv/private_pki/bootstrap.py` creates the independent root and intermediate
keys plus one fleet wildcard leaf in an empty private operator directory. It writes
`recovery.json` for recovery-only root/intermediate custody and `audi-private.json`
for the runtime SecretSpec/SOPS bundle. Encrypt recovery material with a
recovery-only declaration (`hosts = []; recoveryOnly = true`) and encrypt the
runtime bundle for every private-services host through `overalls-secrets encrypt
--input`. Commit only encrypted documents and the public root. Never put plaintext
keys in Nix expressions or guest image inputs. OpenAI uses the separately encrypted
operator key; Anthropic remains disabled with its retained placeholder.

The ADR-0078 production root, issuer and fleet wildcard leaf were generated on
2026-09-21; Overalls and Dungarees Ziggy and Audi credentials are enrolled.

Supply the public root paths as `privateServiceRoots` to `nix/domains/artifacts`, or
`rootCertificates` to the guest's `overalls.privateServices` module. The guest
retains public trust and routes only `.internal` to the local resolver. Roots
are reproducible image inputs. Existing writable guest disks are not rewritten.
A CA change needs overlapping public roots and explicit guest image rollout.
Root, intermediate and fleet wildcard leaf lifetimes are 20, 10 and 10 calendar
years. Rotation is an offline operator action followed by bundle re-encryption and
redeployment; no runtime issuer or renewal service exists.

## Accounting and monitoring

Owners use `/usage`; administrators use `/admin/usage`. Detail records contain
metadata and numeric usage only. Missing usage is unknown, never zero. Cost
estimates are token-only and include LLMDB version/digest provenance. Configure
`services.marshall.inference.detailDays` (90) and `aggregateDays` (365) for
retention. Duplicate completion delivery does not count usage twice.
If Marshall returns `completion_conflict`, Ziggy retains the disputed receipt
and emits `ziggy.accounting_retry` with that reason. Operators can distinguish
it from transient authority unavailability; it does not automatically discard
or rewrite the receipt.

The existing fleet collector discovers `ziggy.service`, retaining its CPU,
memory, pressure and I/O measurements. Its bounded Unix-socket probes add
readiness, active requests, pending accounting receipts, spool capacity and
availability, and OpenAI/Anthropic model counts. Each Lilly maintenance page
links to the corresponding physical host's Ziggy dashboard, including historical
charts. Failed or stale observations remain unknown and cannot authorize guest
execution. Provider keys, prompts, responses and VM request identities do not
enter monitoring samples. Logging recognizes the `ziggy` and `audi` sources;
operators select destinations through the existing logging configuration.

## Verification ledger

The [native coding CLI review](../architecture/reviews/2026-10-13-native-guest-coding-clis.md)
records the current beta-routing gate: 71 Ziggy checks, zero-error forced
Dialyzer and a passing 86.48-second packaged service fixture with beta Messages
streaming, token counting, exact query forwarding and query-free accounting.
Its control authority is synthetic; both actual guest-client journeys and
production provider acceptance remain separate.

The original private-services implementation capture recorded:

- Full `mix precommit` gates: Protocol 126, Audi 140, Lilly 297, Ziggy 21 and
  Marshall 684 passing tests/properties (two Marshall tests excluded). Marshall's
  existing one Dialyzer suppression remained in force.
- Dedicated Marshall accounting/idempotency/access and proxy monitoring/chart tests.
- Nine Python PKI tests with real cryptographic signatures and trust overlap.
- Twelve fleet-collector tests, including closed proxy metrics and timeout behavior.
- Nine updater unit tests, including exact host-bound Ziggy readiness and bounded probes.
- Nix guest trust, PKI and Ziggy/service/secret configuration checks.
- Packaged Ziggy release isolation, fleet-monitor configuration, logging transport
  checks, ADR validation and contract validation/regression checks.
- NixOS `ziggy-service`: real Ziggy release, SecretSpec/SOPS and systemd credentials,
  TLS provider fixtures, native OpenAI/Anthropic streaming, durable usage delivery,
  socket/key access boundaries, full-spool admission refusal, revocation during
  a live stream and restart without replay. The control authority
  is an isolated fixture, not real Marshall execution admission.
- NixOS `private-services-network`: real packaged Audi DNS/TLS, Lilly nftables,
  private key custody, forged-header denial and frontend restart in a VM using
  network namespaces. This is not a Firecracker/provider acceptance claim.

Remaining acceptance and integration work:

- Replace the explicitly marked OpenAI/Anthropic placeholders before deployment
  acceptance. The updater intentionally requires provider catalog readiness; with
  placeholders it cannot mark this configuration healthy. Private-service readiness
  also gates new guest starts. Provisioning alone does not enable usable inference.
- Full native two-host Firecracker request/relocation/lifecycle acceptance.
- 1,000 active real guest streams per host for fifteen minutes.
- Rotation/recovery, full spool and deployment-update failure scenarios across
  the complete service chain.

That original capture activated Overalls with explicitly requested placeholder
provider keys: Audi private DNS/TLS was ready while Ziggy provider readiness was
false. It predates later provider-selection deployment and does not describe
current OpenAI readiness. Current fleet declarations select only OpenAI and
retain Anthropic disabled. The new client and beta-fixture checks do not establish
production provider availability or capacity acceptance.
