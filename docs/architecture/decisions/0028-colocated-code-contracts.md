# ADR-0028: Colocated code contracts and structural gates

- ID: ADR-0028
- Date: 2026-09-16
- Status: accepted
- Implementation: implemented
- Components: repository governance, all source projects, Nix, verification tooling
- Supersedes: none
- Superseded by: none

## Context

The user requested code-contracts adoption for all existing repository work,
especially Elixir and Nix, and installed the repository skill. Existing ADRs
capture architecture but do not colocate critical assumptions with implementations.
The initial worktree includes untracked source, so committed-file-only scanning
would miss the implementation. Upstream cc-check 0.2.0 supports TypeScript,
Python, Rust and Go, but not Elixir, Nix, C, shell or JavaScript extensions.

## Decision

Adopt the standard @cc grammar, one concrete obligation per documentation block,
with authenticated GitHub owner ghuntley and no notification recipients. Put
directory-wide obligations in CONTRACTS and declaration-specific obligations
adjacent to their code. Preserve the existing architecture and product decisions;
this adoption is authorized by the user's repository-wide request.

Use adjacent hash-comment notes for Elixir/Nix/shell/systemd and documentation
blocks for C. Native note IDs are unique per source file. A small repository
adapter validates normalized temporary CONTRACTS projections with the exact
upstream parser. It lists source notes and ancestor scopes without claiming native
declaration resolution. JavaScript JSDoc is parsed from byte-identical temporary
TypeScript-suffixed copies. Preserve original source paths in diagnostics.

Pin upstream tooling as a development-only npm dependency and lockfile. Every
project's precommit runs the repository syntax/coverage check and its regression
tests, in addition to existing gates. Checking includes tracked and nonignored
untracked source, never follows symlinks, never installs tooling and never rewrites
source. A missing/mismatched tool or failed check fails the gate.

Coverage requires each maintained source file to have a local obligation or a
directory scope below the root. Generated/vendor implementations retain scoped
maintenance requirements but are not bulk-annotated or parsed. Keep governance
files outside public static assets. Semantic review remains mandatory: structural
checks do not prove compliance, physical isolation or deployment acceptance.

## Alternatives

Directory-only rules are portable but obscure important local invariants.
Pretending upstream understands Elixir/Nix would silently omit most code.
Implementing a second grammar or full language server adds unnecessary divergence.
Projections reuse the official parser while explicitly limiting scope claims.

## Consequences

Developers install the locked Node tooling before precommit. Native discovery
requires manual interpretation of declaration attachment and callers. Source notes
must be real comments, not string literals or examples. Existing ADRs retain
rationale and implementation status; comment additions do not complete their
outstanding acceptance obligations. No production wire, schema or runtime
dependency is introduced.

## Invariants and verification

- Malformed syntax, empty prose, multiple native directives, duplicate local IDs
  and duplicate ancestor IDs fail with original source locations.
- JavaScript parsing must reject invalid contracts, not silently skip extensions.
- Listing includes ancestor contracts and actual local annotations.
- Checking leaves source unchanged and cleans temporary projections on failures.
- All three precommit suites and the architecture structural checker must pass.
- Review statements against implementation and consumers; report contradictions.

## Implementation evidence

[Root contracts](../../../CONTRACTS) and
[the contributor workflow](../../../AGENTS.md) establish repository obligations.
[The adapter](../../../scripts/check_contracts.mjs),
[negative/discovery tests](../../../scripts/test/check_contracts_test.mjs),
[Mix bridge](../../../scripts/check_contracts.exs) and
[locked tool manifest](../../../tools/code-contracts/package.json) supply the
structural mechanism. Marshall, Lilly and protocol Mix projects invoke the gate.
The same pattern now enforces the reviewed structured-event surface:
[the logging gate](../../../scripts/check_logging.exs) is pinned into all six
application precommits beside the contract gate, and its fail-closed reminder
text names the catalog fix. See the
[fleet logging review](../reviews/2026-09-19-structured-logging-fleet.md).
The gate now also parses runtime/config `.exs` files and recognizes inference
completion and workload materialization as mutation boundaries. Rust terminal
logging is closed by a typed event enum and Clippy print-macro denies. See the
[audit hardening review](../reviews/2026-09-22-structured-logging-audit-hardening.md).

[The adoption guide](../../development/code-contracts.md) documents native limitations,
commands and maintained/generated scope. Local requirements exist across
[admission](../../../marshall/lib/marshall/compute/admission.ex),
[VM execution](../../../lilly/lib/lilly/vm/driver.ex),
[wire validation](../../../protocol/lib/overalls_protocol/execution.ex),
[guest builds](../../../nix/domains/artifacts/guest/default.nix) and
browser input state, with scoped
contracts throughout the rest of the repository. All three precommit gates,
19 checker regression tests, native/JavaScript discovery, Nix parsing and shared
formatting pass. The [adoption review](../reviews/2026-09-16-code-contracts.md)
records semantic scope, independent checker findings and fixes, validation
results and the existing inline-theme-script guidance discrepancy.

The [skill subtree contract](../../../.agents/skills/CONTRACTS) now covers installed
development/test assets without changing their implementation or excluding them
from the validator. It states the existing separation from production runtime
authority and release source filesets (now the Buck2 `release_srcs`; contract
`release-source-allowlist` in [buck/CONTRACTS](../../../buck/CONTRACTS)).
This repairs the coverage omission introduced when additional skills were
installed; it does not certify the behavior of those external tools.

## Open questions

Native AST-aware discovery can replace the documented lexical adapter when
upstream supports these languages. CI hosting and external review-bot notification
remain unselected; this change does not install remote review automation.

## Related decisions

[ADR-0001](0001-architecture-governance.md),
[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0009](0009-assurance-and-testing.md).
