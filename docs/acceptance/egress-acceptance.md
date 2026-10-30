# Live HTTPS egress acceptance

[The opt-in runner](../../scripts/egress_acceptance.py) creates three disposable
machines through Porsche: NixOS and Ubuntu OSS guests and a NixOS Customer guest.
It exercises real Audi SSH, guest trust, Brady HTTPS and public caching on
Overalls. Each fixture uses one vCPU and at least 16 GiB logical disk. The NixOS
OSS fixture uses 2 GiB RAM; Ubuntu OSS and NixOS Customer use 512 MiB.
This is a billable production workflow, not an ordinary offline test.

## Private setup

Create a unique mode-0700 directory outside Git. Its `run.json` contains:

```json
{
  "run": "egress-20261002-150000",
  "host": "ghuntley.dev",
  "admin_alias": "overalls-rebuild",
  "identity": "/home/ghuntley/.ssh/id_rsa",
  "protected_address": "203.0.113.10"
}
```

`protected_address` is the host's primary public IPv4 address, which guests must
not reach. It is a fleet secret (for example `PANTERLOONS_PRIMARY_IPV4` in
`secrets/fleet-addresses.enc.json`); copy it from the decrypted document and keep
it only in the private directory.

Use an existing registered account key with mode 0600. The runner references it;
it does not copy, register or revoke keys. `admin_alias` must select an independently
pinned administrator SSH connection with read-only sudo access to updater state,
Brady counters/journal and nftables. The control plane's administrative OpenSSH uses
port 2222; Porsche uses port 22.

Place a pinned `known_hosts` entry for Porsche in the private directory. Obtain
its public key from `/var/lib/porsche/keys/ssh_host_ed25519_key.pub` through the
already verified administrative connection; do not trust an unauthenticated
`ssh-keyscan` result. Guest connections obtain scoped public CA policy through
verified HTTPS and bind Audi's certificate principal to the current route key,
following Lyra's existing protocol. A changed CA during a run is refused.

## Phases

Run from the repository root using Python 3.13 or newer:

```sh
python3 scripts/egress_acceptance.py /private/RUN create
python3 scripts/egress_acceptance.py /private/RUN snapshot --stage baseline
python3 scripts/egress_acceptance.py /private/RUN probe --stage baseline
python3 scripts/egress_acceptance.py /private/RUN restart --stage lifecycle
python3 scripts/egress_acceptance.py /private/RUN probe --stage after-restart
python3 scripts/egress_acceptance.py /private/RUN snapshot --stage after-restart
python3 scripts/egress_acceptance.py /private/RUN cleanup --stage cleanup
```

Creation is sequential and pins image digests from the live catalog. Existing
create intents retain their original command and request ID. A failed request
stops the phase and remains failed evidence; do not substitute a fresh VM or
request ID to conceal it. Diagnose separately before explicitly recovering the
same fixture. A repeated restart stage reconciles its original stop/start receipts;
use a new stage only for an intentional new cycle. Cleanup resumes already
admitted deletions without submitting another mutation.

Every mutation checks a matching create receipt, exact UUID, current ownership,
name, image, profile and SSH host. Delete only the three recorded fixtures.
Uncertain responses require reconciliation against the original request.
Timeouts terminate the local SSH attempt and its proxy process; they do not
cancel an already admitted VM lifecycle request.

## Assertions and boundaries

The public reference is the version-pinned MIT `is-number@7.0.0/index.js` served
by jsDelivr. The runner compares the guest SHA-256 with an independent verified
HTTPS fetch. Both distributions must pass normal CA verification without custom
CA flags, display the Brady signer chain, follow a GitHub redirect, shallow-clone
`octocat/Hello-World`, and return identical repeated public bytes. Scoped Brady
events must show successful resolved HTTPS and a cache hit of the artifact's
length for the current generation and owning account. Provider policy changes
that make this object ineligible must be diagnosed; never relax public-only
cache admission to make the test pass.

Protected-address probes cover the fleet overlay, metadata address and Overalls
public control-plane address. The Customer probe pins a currently reachable
public IPv4 address, so a DNS failure cannot satisfy the TCP refusal assertion.
Only connection refusal or timeout satisfies this negative probe; a TLS handshake
or receive error fails acceptance rather than being mistaken for network policy.
SSH transport errors, missing tools, malformed envelopes and unfinished probes
fail acceptance. Public responses and fixed probe diagnostics stay in the private
evidence directory; ordinary Brady logs contain no URLs, headers or payloads.

Snapshot files distinguish candidate, activated and healthy updater revisions.
A pushed commit is not evidence of deployment. Capture healthy activation and
repeat `probe` under a fresh stage after any repair reaches the host.

Do not stop shared production services, exhaust storage or inject stale kernel
flows with this runner. Use the isolated `brady-network`, `brady-native-storage`
and `brady-fleet` NixOS checks for those scenarios. Live results cover one physical
host and the explicitly created guests; they do not establish relocation,
throughput, arbitrary parser inputs or all cache-policy combinations.

The [2026-10-02 review](../architecture/reviews/2026-10-02-https-egress-production.md)
records the initial production campaign and the additional native HTTPS cache
recovery scenario.

## Pinned nixpkgs acceptance

After healthy activation, run `archive --stage after-large-cache` against the
private campaign directory. The phase pins the repository flake.lock revision
and NAR hash, independently hashes the compressed legacy archive with bounded
reads, and compares two actual downloads on each OSS distribution. Nix uses the
separate `/tar.gz/` representation, independently measured before its request
window; the legacy curl representation cannot establish Nix wire size. NixOS also
uses a 2 GiB NixOS fixture to accommodate archive unpacking and
runs two real GitHub flake fetches with independent local stores and download
caches. Current owner/generation-bound HTTPS cache hits are required; successful
curl or a locally reused Nix store is insufficient. The phase retains failed
attempts and never injects production proxy/storage faults. Use the existing
cleanup phase and independently check reservations, datasets and units afterward.

The native `brady-large-storage` check covers empty through 4 GiB + 1 byte fixed/chunked
objects, second-peer reuse, exact digest/length, restart with origin stopped,
ranges, concurrent/slow readers, private/trailer/truncation refusals and real
quota/headroom. It is a disposable veth/ZFS fixture, not Firecracker attribution.

Run `large --stage after-large-cache` for a separately pinned public LLVM archive
above 200 MiB. It requires independent streaming SHA/length and two current
attributed HTTPS completions with cache reuse on each OSS distribution. Exact
200/256 MiB synthetic bodies remain in the native check.

Long Nix and large-download checks run as private bounded guest jobs with
deterministic paths, exact script fingerprints and atomic exit receipts.
Interrupted transport attempts remain in the campaign record; authorized receipt
reads retry without rerunning an already claimed job. Failed or missing receipts
never count as success. Root-owned Nix stores are removed between independent
passes. Large client files use private home-directory paths so a small `/tmp`
tmpfs does not constrain the payload. Progress markers, SSH keepalives and
background receipts do not establish a fix for separate SSH/attribution failures.

## Multi-GiB acceptance

Run `large4gib --stage live-4gib` for Google's published SigLIP 2 g-opt/16
checkpoint (CC-BY 4.0). Its anonymous query-free HTTPS response explicitly
declares public freshness, so ordinary cache admission applies without an
exception. The phase requires 4–16 GiB independent streamed references before
and after two exact downloads on each OSS distribution; changed bytes or missing
current owner/generation cache hits fail. Guest jobs are bounded to 3,000 seconds
and each transfer to 1,200 seconds. The guest home filesystem must have the full
object size plus 512 MiB available. Existing durable jobs include timeout in their
identity; changing a bound cannot adopt a prior job. Do not count a smaller archive
or successful forwarding as multi-GiB reuse. Use normal fixture cleanup afterward.

The expanded native matrix includes 512 MiB, 1/2/4 GiB and one-byte boundary
witnesses, with sparse 512 GiB mirrors and unchanged 2 GiB VM RAM. Execution
status and limits belong to the extension review, not the fixture's existence.

Completed guest jobs retain script fingerprints and bounded exit receipts. Replaying
the same stage resumes cleanup, with at most five attempts on unconfirmed channels,
without relaunching a completed job. Multi-GiB stages retain their original
per-guest request window and reference identity; later cleanup cannot substitute
a new window or accept unrelated historical hits. Legacy receipts without a
fingerprint fail closed. Certificate failures still stop immediately.
