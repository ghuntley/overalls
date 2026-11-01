# Code contracts

Overalls uses the [code-contracts format](https://code-contracts.cc/) for concrete
requirements and assumptions beside code. ADRs preserve system decisions and
rationale; contracts state the obligations a change must preserve at the relevant
source or directory boundary. The owner is `ghuntley`, verified through the
authenticated GitHub account. Notifications are not configured.

## Work with contracts

Read root and ancestor `CONTRACTS` files, declaration-adjacent notes and the
contracts of called code before changing a behavior. Use the installed
[skill](../../.agents/skills/code-contracts/SKILL.md) for semantic verification.
Introduce or revise obligations with the implementation and tests. Each contract
should prevent an identifiable regression, not merely describe a function's
purpose. A mismatch must be fixed or reported explicitly; never weaken a contract
to hide a defect.

Install the development-only CLI from its exact package version and lockfile:

```sh
devenv shell
npm ci --prefix tools/code-contracts --ignore-scripts
node scripts/check_contracts.mjs format
node scripts/check_contracts.mjs list lilly/lib/lilly/vm/driver.ex
node scripts/check_contracts.mjs list nix/domains/artifacts/guest/default.nix
node scripts/check_contracts.mjs list marshall/assets/js/terminal_state.mjs
node scripts/check_contracts.mjs coverage
node --test scripts/test/check_contracts_test.mjs
```

Run these commands from the repository root. Each project's `mix contracts.check`
and precommit's `//:contracts` and `//:contracts-tests` checks also run the
repository check and checker regression tests.
Checks never install packages or rewrite source. A missing or mismatched
installation fails with a setup instruction. Node 24.16+ and npm 11.11+ are
required by the pinned `@spolu/cc-check` 0.2.0; the development shell supplies Node.
No Node tooling is required by a running production Elixir release.

## Syntax and language support

Each `CONTRACTS` file contains plain directives and prose. Its requirements apply
to that directory and descendants. IDs must be unique along that ancestor chain;
sibling directory scopes may reuse an ID. Put a rule at the narrowest directory
where it actually holds. Test fixtures and third-party maintenance rules require
their own precise scope.

Elixir, Nix, shell, systemd and deployment examples use adjacent hash comments:

```elixir
# @cc [owner:ghuntley,label:recovery] durable-before-receipt
# accept/2 MUST persist accepted intent before acknowledging it to Marshall.
@spec accept(store(), command()) :: :ok | {:error, atom()}
```

One contiguous comment group contains exactly one directive. Separate it from
ordinary comments and from another contract with a blank line. C uses one
`/** ... */` documentation block per directive. Native note IDs are unique within
their source file, a deliberately stronger local convention than upstream's
declaration-scoped IDs. These are source notes adjacent to the declaration;
they do not change Elixir module attributes or generated runtime documentation.

The upstream CLI does **not** support Elixir, Nix, shell, C, or JavaScript files in
version 0.2.0. The repository adapter extracts the documented native comment forms
and validates temporary `CONTRACTS` projections with the official parser. It
preserves original line numbers, verifies one directive per comment, and reports
diagnostics against original files. Native extraction is lexical; it does not
parse the language or infer declaration attachment. Keep these directives in
actual comments, not strings or documentation examples. Native `list` inventories
all notes in a file plus its ancestor contracts; attachment and callee obligations
must be reviewed manually. It does not accept a native `file:line` argument.

JavaScript uses normal JSDoc, one directive per block. The adapter gives unchanged
source a temporary `.ts`/`.tsx` suffix so upstream can parse documentation and
declarations. Listing copies the original ancestor contracts and maps names back
to the real files. This is syntax discovery, not TypeScript type checking.
Python uses a function/class docstring with one directive; upstream handles its
extraction directly. Supported TypeScript, Python, Rust and Go files use upstream
validation without source transformation.

The official CLI remains available for its native formats, for example:

```sh
tools/code-contracts/node_modules/.bin/cc-check format CONTRACTS
```

## Coverage and verification limits

Inventory includes Git-tracked and nonignored untracked files; this matters while
the initial monorepo is uncommitted. Symlinks are not traversed. Every maintained
source file must have local notes or a `CONTRACTS` scope below the repository root.
This is an omission check, not a demand for boilerplate on every function.

| Area | Contract focus |
| --- | --- |
| Marshall domains | Transactional admission, durable generations/outcomes, current authorization, terminal authority, email privacy, telemetry and release configuration |
| Lilly | Host ownership, unknown capacity, durable receipt/intent, independent VM lifetime, physical cleanup, privileged utilities and console fences |
| Shared protocol | Pure bounded validation, explicit versions, finite enums and trusted encoder preconditions |
| Nix and deployment | Pinned runtime and guest artifacts, closure exports, TLS/readiness and systemd namespace/cgroup boundaries |
| Web and assets | Current login, user-scoped reads, bounded terminal buffers, no automatic input replay and untrusted output |
| Scripts and tests | Fixture ownership, destructive-operation boundaries, independent-node assertions and honest acceptance claims |
| Generated/vendor content | Provenance, regeneration, schema snapshots and exclusions from edits to third-party implementation |
| Agent skills | Development/test tooling excluded from application releases and runtime authority; skill execution alone is not repository acceptance |

Vendored implementations, generated resource snapshots and generated static assets
are not parsed as maintained source. Their adjacent maintenance contracts still
participate in grammar and ancestry checking. Do not put `CONTRACTS` inside
`priv/static`: Phoenix would publish/digest it as an asset. Binary files, lockfiles,
translations, templates and configuration without a supported comment format
inherit the relevant directory requirements; they are not rewritten for annotation.

The format command validates syntax, cardinality, ID uniqueness and scoped source
coverage only. It cannot prove prose is true, reason about callers, or establish
production safety. Existing application tests, property tests, Dialyzer and
explicit semantic reviews provide separate evidence. Physical multi-host,
production-provider and fleet-scale obligations remain as recorded in the ADRs.
