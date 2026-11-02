# Team transfer consent preserves a single owner

## Property

Concurrent offer, accept, decline, cancel, membership removal, and account retirement operations never leave an active team with zero owners or more than one owner. An ownership transfer is accepted only by its designated target; terminal transfer states cannot be transitioned again. Acceptance demotes the previous owner to admin and promotes exactly the target in one committed transaction.

## Assertion

Use `Always` for the committed database invariant (one active owner per active team and immutable terminal transfer state). Use `Reachable` for a successful accepted transfer and `Sometimes` for progress through a designated offer/accept pair after concurrent stale operations are healed. The assertion should include team ID, transfer ID, actor IDs, state transition and transaction commit sequence in the independent witness; do not treat a returned HTTP success as proof.

## Evidence trail

- `marshall/lib/marshall/teams/transfer.ex` defines the pending → accepted/declined/cancelled state machine and `Marshall.Teams.TransferSwap`.
- `marshall/lib/marshall/teams/coordinator.ex:offer/3` locks the team, checks owner/target membership and enforces one pending offer; `accept/2`, `decline/2`, and `cancel/2` authorize the designated actor under the same team lock.
- `marshall/lib/marshall/teams/coordinator.ex:retire_user!/2` locks affected teams in sorted order, refuses retirement of an active owner, archives memberships, and cancels pending transfers.
- `marshall/test/marshall_web/teams_live_test.exs` covers repeated offers and UI flow, but does not establish adversarial concurrent transfer races or recovery after reply loss.

## Antithesis scenario

Create a team with owner A and members B/C. Randomly issue one pending offer, then race accept/decline/cancel, duplicate accepts, owner membership removal, and account retirement while killing or delaying the worker between the state transition and receipt/event scheduling. After healing, read the team, membership history, transfer row, receipts, and audit events from PostgreSQL. Check that exactly one owner exists, every terminal transfer is immutable, and accepted ownership swaps are atomic.

## Open questions

- [needs human input] Is account retirement allowed to cancel an offer where the retiring user is the target, or should it fail closed like owner retirement?
- [partial: source tests] Existing tests cover repeated offer rejection but no concurrent transfer/retirement fault schedule or hosted Antithesis oracle.

## Investigation log

- 2026-11-02: Inspected the Transfer Ash state machine, coordinator lock/order paths, retirement handling, and existing team LiveView tests. Confirmed the single-owner and terminal-state contract is implemented in source but absent from the current 104-property catalog and Antithesis workload. No hosted or native run was used to claim the property passes.
