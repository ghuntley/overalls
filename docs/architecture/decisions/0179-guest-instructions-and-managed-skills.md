# ADR-0179: Guest project instructions and managed skills

- ID: ADR-0179
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: Marshall Agents, Threads, shared protocol, Lyra, guest images
- Supersedes: none
- Superseded by: none

## Context

Marshall-owned agents need the instructions and reusable task guidance present
inside their work machine. Reading the control-plane filesystem would select
the wrong project, identity and trust boundary. A shared thread also needs one
stable configuration owner rather than changing its personal instructions when
a collaborator submits a prompt. Managed skill installation must survive
thread reopen without following a changed upstream branch or overwriting local
work.

The user's October 16, 2026 approved plan and implementation request authorize
guest instruction discovery, skill use and a manager-controlled public
repository installer. ADR-0178 defines the context snapshot consuming these
sources. Existing profile permissions and guest execution fences remain in
force; instruction files cannot grant capability or authority.

## Decision

### Instruction collection

Persist an explicit working directory, defaulting to a verified source checkout
and otherwise the guest workspace. Children inherit the selected directory.
`/context` reports that directory, loaded sources, warnings and current context
usage, and offers Reload. A model control tool can change working directory at
a safe boundary and refresh applicable instructions before further inference.

Typed bounded guest inventory and paginated file reads use the existing
authenticated executor path. Marshall does not inspect its own filesystem for
thread context. Linux and Windows resolve the creator's home through the durable
guest account identity, including Windows profile lookup. Collaborators do not
replace the thread's configuration owner.

Load machine guidance, creator guidance and then project guidance from the
repository root to the selected directory. Honor worktree roots,
`AGENTS.override.md`, `AGENTS.md`, configured fallback filenames and empty-file
semantics. The project instruction budget is 32 KiB; truncation is visible.
Nested guidance below the selected directory remains applicable when the agent
works there and must be inspected before those edits.

Collect new instructions before each new turn, explicit reload and
working-directory change. A context snapshot retains source identity, digest
and applied text. Retry changed-source collection twice before returning
`context_changed`; this does not claim an atomic filesystem snapshot. Compaction
rebuilds these instructions rather than depending on a generated summary.

### Skill discovery and invocation

Discover repository `.agents/skills`, creator skill directories, machine
defaults and managed installations. Bound traversal, detect cycles, use
canonical identities and report failures explicitly. Parse `SKILL.md`
frontmatter and supported optional metadata, including implicit invocation
policy. Duplicate names remain distinct; an ambiguous `$name` requires an exact
selection rather than silently choosing a source.

`/skills` opens the catalog and management interface. `$` completion chooses a
specific identity without sending the prompt. Initial context contains bounded
catalog metadata. Explicit selected skills load before inference; implicit use
follows model selection from descriptions. Skill bodies load completely through
paginated reads, with supporting resources resolved relative to the skill
directory. Required instructions that exceed the context bounds fail visibly
instead of being silently shortened. Skills do not grant tools; unsupported
connector dependencies are reported without automatic installation.

### Managed installation

Thread-scoped Ash installation, revision and immutable operation-receipt
resources retain the authorized configuration. Current managers can install,
update, enable, disable and remove managed skills. Operators can invoke enabled
skills and viewers remain read-only. The public installer accepts GitHub,
GitLab, Codeberg and Bitbucket repository URLs, an optional revision and a skill
subdirectory. Every resolved version records a full commit and content digest.
Private repository credentials and plugin marketplaces are outside this scope.

Fetching and materialization execute inside the guest through typed fenced
operations. Credential-free Git uses bounded fetching and validated contained
paths, with no hooks, filters, submodules or installation-time script execution.
Immutable revision directories live outside repository-discovered skill paths.
Failed updates retain the active revision. Local edits are detected and
preserved, never overwritten as an incidental update or removal.

An ambiguous installation result is reconciled by operation-status reads using
the original identity, not blind re-execution. Reopen restores the recorded
commit and digest rather than resolving a current branch head. Configuration
changes affect subsequent context snapshots; admitted work retains its
referenced revision. Removing a managed installation leaves project and
personal skill files intact.

## Alternatives

Reading the Marshall host would confuse control-plane and guest identities.
Following a branch on every turn would make admitted work non-reproducible.
Installing into project discovery paths would create duplicate catalog entries
and mix managed removal with user files. Running repository setup hooks during
installation would give an otherwise read-and-copy operation unrelated command
effects. Switching personal configuration with each collaborator would change
the shared thread's behavior based on its latest submitter.

## Consequences

Guest operations need explicit version/capability validation on both Linux and
Windows. Deploy compatible consumers and executors before enabling the new
operations; incompatible guests return an upgrade-required state. Existing
Linux update and rebuilt Windows image paths are used without another service
or listener. Managed revisions require retained-state accounting and cleanup
that preserves admitted snapshots. Public repository fetching still follows
the VM's existing network and profile restrictions.

## Invariants and verification

- Guest identity, current placement, executor lease and fence bind every read
  and install operation; stale or foreign results cannot become current context.
- Instruction precedence, worktree roots, empty files, Windows profiles,
  symlink cycles, changing files and truncation have explicit bounded outcomes.
- Skill content cannot override trusted mode, profile tool policy or ACLs.
  Duplicate names never silently resolve to a different identity.
- Manager-only configuration changes recheck current authority and return
  immutable replay results. Failed updates preserve the active revision.
- Traversal, URL injection, hooks, filters, submodules and installation scripts
  cannot escape the bounded fetch-and-materialize operation.
- Reopen restores exact pinned content; locally changed files and references
  held by admitted snapshots survive managed update/removal.
- Properties and native Linux/Windows guest tests distinguish parser/path
  evidence from actual transport, filesystem and recovery acceptance.

## Implementation evidence

The [agent domain](../../../marshall/lib/marshall/agents.ex) registers
[SkillInstallation](../../../marshall/lib/marshall/agents/skill_installation.ex),
[SkillRevision](../../../marshall/lib/marshall/agents/skill_revision.ex) and
[SkillOperation](../../../marshall/lib/marshall/agents/skill_operation.ex).
The [skill coordinator](../../../marshall/lib/marshall/agents/skills.ex)
checks thread management authority, immutable request identity and the current
machine generation before accepting publication. Its
[catalog](../../../marshall/lib/marshall/agents/skills/catalog.ex) preserves
canonical identities, validates bounded metadata and refuses ambiguous names.

The [guest context reader](../../../lyra/src/agent/context.rs) implements bounded
inventory, precedence, worktree discovery and digest-bound chunks. The
[account resolver](../../../lyra/src/agent/context/account_home.rs) reads the
Linux account database or Windows SID profile registration.
[Managed skill operations](../../../lyra/src/agent/managed_skills/mod.rs) implement
bounded public Git fetching, ordinary-blob extraction, durable guest receipts,
content digests and local-edit refusal. These sources add no standalone service.
The installation lock explicitly unlocks on every completed invocation,
including error returns, before its descriptor closes. This preserves progress
when another process inherited the same open file description. The colocated
`completed_lock_is_released_even_while_an_inherited_descriptor_remains` regression
keeps a duplicate alive, verifies concurrent refusal, then verifies that a
completed owner releases the lock without releasing a subsequent owner's lock.
All twelve focused managed-skill tests passed on October 17, 2026. This is local
lock-lifetime evidence; native installation and recovery acceptance remain
separate.
The [skill maintenance loop](../../../marshall/lib/marshall/agents/skill_maintenance.ex)
round-robins bounded replacement-machine scans, skips generations with an
existing restoration receipt, and records rejected restorations as catalogued
outcomes so one failed thread cannot starve later work.

[Catalog cases](../../../marshall/test/marshall/agents/skills_catalog_test.exs),
[skill authority/recovery and restoration scheduling cases](../../../marshall/test/marshall/agents/skills_test.exs)
and colocated Rust file/operation tests are present. The distributed recovery
suite also verifies that a managed-skill operation can be dispatched and
completed by replacement peers after process loss; this remains database-state
evidence, not guest installation or physical reopen evidence. Final
integration, guest transport, Windows native runtime, physical reopen and live
deployment acceptance remain tracked in the [context review](../reviews/2026-10-16-agent-context-and-planning.md).

## Open questions

None for the authorized public-repository scope. Native Windows profile,
installation, restoration and stale-authority acceptance remain delivery
requirements.

## Related decisions

- [ADR-0100: Pulled agent work](0100-pulled-agent-work-over-ziggy-control.md)
- [ADR-0158: Durable guest identities](0158-durable-guest-identities.md)
- [ADR-0159: Remove legacy compatibility](0159-remove-legacy-compatibility.md)
- [ADR-0171: Windows guest agents](0171-windows-guest-agents.md)
- [ADR-0175: Thread sharing](0175-thread-sharing-and-bound-machine-authority.md)
- [ADR-0178: Context and planning](0178-durable-agent-context-and-planning.md)
