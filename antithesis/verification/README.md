# Build identity and campaign ledger

These tools freeze local inputs and reserve remote attempt slots. They never build
images, submit Antithesis runs, or interpret a remote report themselves. Keep
manifests and ledgers under ignored `antithesis/runtime/` or another private
execution directory; they contain file paths, hashes, run IDs and public fixture
identifiers, but no credential values.

The default `control-core` selection includes only the `control`,
`control_rotation`, `control_dispatch`, `control_legacy_request`,
`control_delivery`, `host_sessions` and `host_rotation` command templates. The
latter six each contain one terminal singleton command; a timeline runs at most
one of them. The
separate `repository-origin` profile selects four repository commands with the
origin and Enrico overlays; `access-smtp` selects three access commands with
the SMTP overlay; `recorder-host` selects the three recorder commands with the
TCG recorder VM overlay; `admission-stub` selects the two admission commands
on the harness stub storage substrate (not ZFS; see the admission workload
notes); `backup-restic` selects the five backup commands with the
private Restic fixture volume; `satellite-standin` selects four satellite
commands with the origin, satellite and labelled guest stand-in overlays;
`guest-lifecycle` selects the one guest lifecycle command with the guest-vmm
and guest-lifecycle overlays, and its Lilly uses a separate STUB storage
release (a fixed synthetic pool, no ZFS) with no native KVM, ZFS or
Firecracker claim. Each requires an independent fixture readiness probe
before the sole bootstrap owner signals setup completion. In
`satellite-standin` only the unbound-source command can reach its
assertions; the three commands that need a current running VM record
unexercised because the controlled pool has no capacity. Stage the chosen
command selection immediately before building its workload image.

Staging also writes the hosted Python assertion catalog. The workload image
copies `selected-test/catalog/` to `/opt/overalls-antithesis/catalog/`, and
that tree holds exactly the manifest's runtime dependencies (the traced
imports of the selected commands and bootstrap, including executed package
initializers) as one `workload` module. The Nix rootfs links
`/opt/antithesis/catalog` to that `workload` tree, so the Antithesis Python
instrumentor (`antithesis-python-instrumentor 0.1.4`) resolves one cataloged
root and writes one catalog subdirectory; the SDK (`antithesis` 0.4.0)
registers exactly one subdirectory per process, choosing the single one when
only one exists. Every workload process therefore declares every assertion
reachable from the selected commands, including ones a run never evaluates,
and no assertion from an unselected package; a zero-hit property in a hosted
report is a selected-scope gap, not an artifact of an unselected template.
Test commands carry no SDK assertions of their own, and staging refuses one
that does. The link matters: when the image held the packages under a real
`/opt/antithesis/catalog/workload/` directory, the instrumentor cataloged each
package as a separate root ("Paths found for Antithesis instrumentation"
listed five package paths), the SDK's importability vote registered only
`core`'s catalog, and unhit assertions in the other selected packages were
absent from the report rather than shown as zero-hit
(run `8e582f650dd7092cda983705eb7b0e05-65-0`). `identity.py freeze` refuses a
staged workload rootfs whose `/opt/antithesis/catalog` is not that one link.
On the next run, "Paths found for Antithesis instrumentation" should list the
single resolved path `/opt/overalls-antithesis/catalog/workload`, "Software
was instrumented" should name module `workload`, and every selected assertion
that no command reaches should appear with zero examples (for example the
`admission-stub` profile's `Always` properties when its commands are blocked).

After the selected Nix contexts are built and staged, stage the commands, build
Compose images, then materialize the selected graph as a standalone Snouty
config directory. The materializer rejects local bind mounts and removes build
directives; Snouty uses the retained local image tags to push images at launch.
Activate the pinned Compose/Podman environment before these commands:

```sh
python3.13 antithesis/verification/selection.py stage \
  --output antithesis/build/selected-test
python3.13 antithesis/verification/selection.py materialize --engine podman
python3.13 antithesis/verification/assertions.py --output antithesis/runtime/source-roster.json
python3.13 antithesis/verification/identity.py \
  --compose antithesis/config/docker-compose.yaml --engine podman \
  --output antithesis/runtime/control-core-identity.json
python3.13 antithesis/verification/campaign.py init \
  --identity antithesis/runtime/control-core-identity.json \
  --ledger antithesis/runtime/campaign-ledger.json
python3.13 antithesis/verification/campaign.py reserve \
  --identity antithesis/runtime/control-core-identity.json \
  --ledger antithesis/runtime/campaign-ledger.json --purpose baseline
```

For an optional profile, pass its JSON file to `selection.py stage` with
`--selection`, use the same file for `selection.py materialize`, then pass
`--selection repository-origin`, `--selection access-smtp`,
`--selection recorder-host`, `--selection admission-stub`,
`--selection backup-restic`, `--selection satellite-standin` or
`--selection guest-lifecycle` to `identity.py`. Render and build the exact ordered
Compose files listed in that profile. All campaign operations use the one
canonical ledger path. Point `snouty validate` or the launch skill at the
materialized `antithesis/runtime/configs/<profile>` directory only after its
identity is frozen; the source overlays are not a standalone Snouty config.

The reserve response contains an attempt ID. Reserve **before** each remote
launch, including bootstrap, retry and resweep attempts. After the launch tool
returns a run ID, record it with `submitted --attempt-id ID --run-id RUN_ID`.
When triage finishes, record `completed --attempt-id ID --result green|red|unknown`.
Every reserve, submission and completion also carries the exact campaign
duration in minutes. Baseline attempts use 60 minutes; bootstrap, mutant, retry
and resweep attempts use 15 minutes. Reservation defaults to the policy value,
while submission and completion require `--duration-minutes` (or
`--requested-duration-minutes` / `--observed-duration-minutes`) and refuse
missing, conflicting or mismatched values. Completion persists the observed
duration in the ledger.

For a baseline attempt, the transitions therefore look like:

```sh
python3.13 antithesis/verification/campaign.py submitted \
  --identity antithesis/runtime/control-core-identity.json \
  --ledger antithesis/runtime/campaign-ledger.json --attempt-id ID \
  --run-id RUN_ID --duration-minutes 60
python3.13 antithesis/verification/campaign.py completed \
  --identity antithesis/runtime/control-core-identity.json \
  --ledger antithesis/runtime/campaign-ledger.json --attempt-id ID \
  --result green --duration-minutes 60 --receipt PATH
```

Use `15` for bootstrap, mutant, retry and resweep attempts.
Every green completion also needs `--receipt PATH` containing a validated local triage
receipt, for example:

```json
{
  "format": 1,
  "run_id": "actual-run-id",
  "identity_sha256": "exact-identity-hash",
  "result": "green",
  "setup_complete": true,
  "execution_scope": "control-core: actual services, commands, assertions and observed prerequisites"
}
```

The operator must derive this receipt from the completed run; the ledger checks
its binding but cannot itself attest Antithesis results. A green receipt
licenses a reviewed mutant lineage from that baseline. Source, Nix closure,
Compose or image drift makes campaign operations fail until a new identity is
frozen and initialized; ordinary reinitialization invalidates the old baseline
while retaining all attempt expenditure. A reserved attempt stays spent after a failed
launch or crash. Use `abandoned --attempt-id ID` only for a reservation known
never to have reached remote submission. Once a run ID is submitted, retain its
concurrency slot until triage records completion, including an `unknown` result
if the run ended without a usable verdict. Completion is bound to the identity recorded on the
attempt, so it remains possible after source drift; a green result updates the
config baseline only while that config is still initialized at the attempt's identity. The global admission gate allows up to 32 active attempts so every hosted profile and its replicas can run concurrently; the per-profile baseline, mutant and identity rules remain unchanged.

For a mutant, reserve with `--purpose mutant --property-message 'literal SDK
message'`. Only one mutant may remain between selection and submission; at most
32 attempts may be active. The ceiling is five times the union of researched
primary safety messages and authored SDK safety messages, deduplicated by literal
message. `Sometimes` and `Reachable` stay in the roster but do not expand that
ceiling. A catalog entry with no authored callsite remains an implementation gap;
an authored callsite by itself is not a passed property. Each selected Compose
config has its own immutable identity and green baseline inside the shared
ledger. The 5N ceiling, spent attempts, active-attempt count and mutant
selection lock apply globally across configurations. Rebuilds retain spent
attempts and invalidate only the rebuilt config's baseline. An old format-1
per-config ledger is refused so prior expenditure cannot silently disappear;
it must be reviewed and migrated before another remote attempt.

A mutant has a new exact image/source identity. After building its artifact,
restage commands, rematerialize the hosted config, and freeze a new identity.
Initialize it with `--mutation-receipt PATH --patch PATH`; the receipt contains
`format: 1`, `baseline_identity_sha256`, `mutant_identity_sha256`,
`harness_scope_sha256`, `property_message`, and `patch_sha256`. The CLI hashes
the supplied patch bytes. The baseline lineage is preserved only if its green
identity and the frozen harness, configuration, test commands, assertion
roster, and oracle image scope match. The patch target must have an authored
safety assertion in the selected profile; catalog-only candidates still count
toward N but cannot be reserved as mutants. A receipt binds operator-reviewed
patch bytes and identities; it does not prove the patch's semantic effect.

The source inventory intentionally includes compiled `marshall/priv/docs` and
the executable `antithesis/test` tree. The frozen assertion roster is scoped to
selected commands, their traced runtime imports, and compiled selected services;
the standalone assertion scan remains a full source discovery report. The freeze
checks that the staged catalog tree equals those runtime imports byte for byte
and that the workload image copied it unchanged. It excludes research scratchbooks, root
architecture reviews, execution ledgers and local build outputs. It records
file bytes and modes plus symlink targets. Staged Nix closure trees, context
identities and actual Nix root derivation/requisite queries are captured, along
with rendered Compose, selected image IDs and the static assertion roster. Each
staged context must match the currently evaluated, built Nix output in full,
apart from the checked output-path stamp added during staging. Every selected
image must carry that exact output path, identity and closure list. This binds
the normal Docker COPY build to the verified Nix output; it does not independently
hash every in-image Nix file.
The verifier parses each selected Dockerfile stage and compares every direct
COPY input with image paths, modes, symlink targets and file bytes, including
the full workload tree. Missing contexts, changed source, unsupported COPY
syntax, stale images or failed queries prevent a freeze.

Validate the local code with:

```sh
devenv shell -- prek run --all-files
tools/buck2 build //:py-static
python3.13 -m unittest discover -s antithesis/verification/tests -v
node scripts/check_contracts.mjs format
```

The precommit and Nix `python-static` gates cover all Antithesis Python source:
workload modules, test commands, fixtures, emulation, integration and these
verification tools. They resolve Antithesis 0.4.0, psycopg 3.2.10 and websockets
17.2 through the same fixed-output wheel closure used by the workload image.
The type gate inventories harness Python files and fails when a new source tree
has no ty scope or a declared scope has no files.
Standalone machine-test driver fragments retain the repository's composed-driver
type-check boundary.
