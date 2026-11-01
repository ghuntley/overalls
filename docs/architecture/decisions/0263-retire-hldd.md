# ADR-0263: Retire the HLDD handbook and its review gates

- ID: ADR-0263
- Date: 2026-10-29
- Status: accepted
- Implementation: implemented
- Components: Marshall Web, documentation, Nix, repository governance
- Supersedes: ADR-0250
- Superseded by: none

## Context

ADR-0121, ADR-0122 and ADR-0250 established an authenticated `/hldd` handbook in
Marshall, a corpus of reviewed chapters and YAML scenarios under
`marshall/priv/hldd`, per-source review receipts under `docs/hldd/reviews`, and a
blocking gate (`scripts/check_hldd.exs`, Ash/topology views and option reference)
wired into Marshall's `mix precommit`, the prek `hldd-review` hook and the Nix
`hldd` check. Every change had to refresh or justify thousands of receipts. The
repository owner asked to delete the HLDD concept and its precommit checks
entirely while keeping architecture decision records.

## Decision

Remove the HLDD handbook, its content, receipts, maintenance skill, checker
scripts and every gate that enforced them:

- Marshall no longer serves `/hldd` or `/hldd/:section`; `MarshallWeb.HLDDLive`,
  `Marshall.Handbook`, the `Handbook` browser hook, its styles, the vendored
  Mermaid renderer it alone used, and the shared-menu HLDD entry are deleted.
  Source code now follows Field notes directly in the Reference tree.
- `mix precommit` drops `hldd.check`; `devenv.nix` drops the `hldd-review` prek
  hook; `flake.nix` drops the `hldd` check; the `hldd-browser` machine test is
  removed from the catalog.
- Localization tooling no longer carries an HLDD-prose exclusion, and the
  handbook-only messages leave the Marshall catalogs.

ADRs, architecture reviews, `CONTRACTS`, Covenant obligations, native and machine
tests remain the architecture and verification record. Historical reviews and
ledgers that mention HLDD are left unchanged as dated records.

Authorization: the repository owner's explicit request on 2026-10-29.

## Alternatives

- Keep the handbook but make the gate advisory. Rejected: the owner asked for
  the concept to be removed, and an unenforced receipt corpus drifts silently.
- Delete the HLDD ADRs as well. Rejected: accepted rationale is preserved and
  superseded rather than erased, and the owner asked to keep ADRs.

## Consequences

Changes no longer need HLDD receipts, chapters or scenario updates, removing a
large source of merge conflicts between concurrent agents. Signed-in users lose
the in-product design and operations manual; the architecture overview and ADRs
in the repository are the remaining reference. Marshall's CSP comment no longer
cites Mermaid; xterm still requires inline styles.

## Invariants and verification

- No route, LiveView, navigation entry or asset references `/hldd`.
- No precommit, prek, Nix or CI gate invokes an HLDD checker.
- Marshall `mix precommit`, all-file prek hooks and `elixir scripts/check_adrs.exs`
  pass without the removed files.

## Implementation evidence

- [Marshall router](../../../marshall/lib/marshall_web/router.ex) has no `/hldd`
  routes; [layouts](../../../marshall/lib/marshall_web/components/layouts.ex)
  carries the updated `signed-in-source-code-navigation` contract.
- [Marshall mix aliases](../../../marshall/mix.exs) no longer include `hldd.check`.
- [devenv hooks](../../../devenv.nix) and [flake checks](../../../flake.nix) no
  longer define `hldd`; no [machine test](../../../nix/verification/tests/machines)
  is named `hldd-browser`.
- [Localization catalog migration](../../../scripts/localization_catalog_migration.ex)
  requires every original identity to map, with no HLDD exclusion.

## Open questions

None.

## Related decisions

Supersedes [ADR-0250](0250-independent-hldd-review-records.md), which superseded
[ADR-0122](0122-hldd-section-pages.md) and
[ADR-0121](0121-authenticated-hldd.md). Amends the menu placement in
[ADR-0196](0196-single-account-settings-page.md) and the HLDD language note in
[ADR-0201](0201-localized-human-surfaces.md).
