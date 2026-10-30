---
modules: [Marshall.Access, Marshall.Access.AdminActions, Marshall.Access.Authorization, Marshall.Access.Change, Marshall.Access.Grant, Marshall.Access.Pin, Marshall.Access.Pins, Marshall.Access.Sharing, Marshall.Accounts, Marshall.Accounts.AccountLifecycle, Marshall.Accounts.AdminBootstrap, Marshall.Accounts.AdminEvent, Marshall.Accounts.AdminEvents, Marshall.Accounts.AdminUsers, Marshall.Accounts.Administrators, Marshall.Accounts.AuthEmail, Marshall.Accounts.AuthEmails, Marshall.Accounts.BootstrapAdministrator, Marshall.Accounts.DeleteUserMachines, Marshall.Accounts.DeliverAuthEmail, Marshall.Accounts.EligibleEmail, Marshall.Accounts.EmailAddress, Marshall.Accounts.GuestAccount, Marshall.Accounts.GuestAccounts, Marshall.Accounts.GuestUsername, Marshall.Accounts.Login, Marshall.Accounts.MagicLinkSignIn, Marshall.Accounts.Passkey, Marshall.Accounts.PasskeyChallenge, Marshall.Accounts.Profile, Marshall.Accounts.PruneSecurity, Marshall.Accounts.RegistrationFence, Marshall.Accounts.RememberedLogin, Marshall.Accounts.Security, Marshall.Accounts.TimeZones, Marshall.Accounts.Token, Marshall.Accounts.User, Marshall.Accounts.User.Senders.SendMagicLinkEmail, Marshall.Accounts.UserDeletion, Marshall.Accounts.ValidTimeZone, Marshall.Accounts.Verification, Marshall.Administration, Marshall.Administration.AuditEvent, Marshall.Administration.ExpireJobHistory, Marshall.Administration.JobEvent, Marshall.Administration.JobSnapshot, Marshall.Administration.Jobs, Marshall.Administration.Operations, Marshall.Authorization, Marshall.Authorization.AshAuthorizer, Marshall.Authorization.Cedar, Marshall.Authorization.DecisionSnapshot, Marshall.Authorization.Entity, Marshall.Authorization.Filter, Marshall.Authorization.Native, Marshall.Authorization.Principal, Marshall.Authorization.Record, Marshall.Authorization.Resource.Info, Marshall.Authorization.Resource.Persist, Marshall.Authorization.Resource.Rule, Marshall.Authorization.Resource.Verifier, Marshall.Authorization.SystemActor, Marshall.Authorization.VersionMapping, Marshall.Teams, Marshall.Teams.Coordinator, Marshall.Teams.Team, Marshall.Teams.TeamMember, Marshall.Teams.Transfer, Marshall.Teams.TransferSwap]
---

# Identity Authorization obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.identity_authorization.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.identity_authorization.I2 — Compute authority is a typed internal principal
- **scope:** `Marshall.Authorization.SystemActor.compute/0` and Cedar evaluation
- **must:** The compute actor MUST carry only its explicit purpose and authorization MUST fail closed when policy state or a recognized user principal is absent.
- **kind:** security
- **status:** active

### marshall.identity_authorization.I3 — Account boundary validators fail closed
- **scope:** `Marshall.Accounts.EmailAddress.valid?/1` and `Marshall.Accounts.GuestUsername.from_uid/1`
- **must:** Mailbox validation MUST reject nonbinary, control, whitespace, display-name, and overlong input; guest usernames MUST derive only from allocated durable UIDs and reject all other terms.
- **kind:** security
- **status:** active

### marshall.identity_authorization.I4 — Security proof freshness is time bounded
- **scope:** `Marshall.Accounts.Security.elevation_fresh?/3` and `email_fresh?/2`
- **must:** Future proofs, expired proofs, proofs older than their configured windows, and malformed terms MUST be rejected; only currently valid bounded proofs may authorize sensitive actions.
- **kind:** security
- **status:** active

### marshall.identity_authorization.I5 — Pin state machine admits only its closed transitions
- **scope:** `Marshall.Access.Pin` state machine and `Marshall.Access.Pins.limit/0`
- **must:** A pin MUST start `pinned`, MUST move only `pinned → unpinned` (`unpin`) and `unpinned → pinned` (`repin`), MUST expose no other state, and the per-user pin limit MUST be a fixed positive bound (20).
- **kind:** functional
- **status:** active

### marshall.identity_authorization.I6 — Pin projections fail closed for non-user actors
- **scope:** `Marshall.Access.Pins.pinned_vm_ids/1` and `pinned?/2`
- **must:** A compute system actor, nil or any term that is not a `Marshall.Accounts.User` MUST yield an empty pinned set and a false pin flag without reading another principal's pins.
- **kind:** security
- **status:** active

### marshall.identity_authorization.I7 — Time zone validation fails closed
- **scope:** `Marshall.Accounts.TimeZones.valid?/1`, `shift/2` and the `Marshall.Accounts.User` `store_time_zone` validation
- **must:** Only a binary of 1–64 bytes that the compiled Tz database resolves MAY be accepted; nil, non-binaries, blank, oversized, lowercase-mangled or unknown identifiers MUST be refused, and shifting with an unresolvable zone MUST fall back to UTC instead of raising.
- **kind:** security
- **status:** active

### marshall.identity_authorization.I8 — Time zone picker and difference are consistent
- **scope:** `Marshall.Accounts.TimeZones.options/1` and `difference/3`
- **must:** Every picker label MUST carry the zone's total offset in force at the given instant as `(GMT±HH:MM) City`, entries MUST be ordered by offset then city with no duplicate IANA id, and `difference/3` MUST be antisymmetric with text direction following its sign.
- **kind:** functional
- **status:** active
