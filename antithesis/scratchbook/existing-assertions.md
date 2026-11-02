---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
---


# Existing Antithesis assertions

As-of source scan: **2026-10-17 UTC**. The repository scanner found **164 executable assertion callsites** (including the Marshall hint-relay `Reachable` anchor, which adds no catalog primary), with **30 of 104 planned primary literal messages authored**. Source presence is not hosted declaration, evaluation, baseline or physical acceptance. This moving shared worktree is distinct from the pinned provenance commit. The duplicate-message list below must be resolved before immutable selection.

The source scanner is `python3.13 antithesis/verification/assertions.py`, covering executable Antithesis Python and selected application Elixir files. It excludes unit-test fixture strings and research prose. The [template roster](evaluation/template-roster.json) records each primary match and its proof boundary.

| File:line | Kind | Literal message | Catalog primary |
| --- | --- | --- | --- |
| `antithesis/workload/access/browser.py:298` | `always` | Magic-link preview and pending MFA cannot grant browser work authority | `magic-link-preview-post-mfa-boundary` |
| `antithesis/workload/access/browser.py:317` | `reachable` | Magic-link CSRF POST created one stored login before MFA | support / startup |
| `antithesis/workload/access/browser.py:326` | `always` | Replayed magic-link POST creates no second stored browser login | support / startup |
| `antithesis/workload/access/browser.py:350` | `always` | Magic-link pending MFA login serves ordinary reads on another replica without elevation | support / startup |
| `antithesis/workload/access/browser.py:360` | `always` | Magic-link pending MFA login cannot change a passkey on another replica before step-up | support / startup |
| `antithesis/workload/access/browser.py:368` | `reachable` | Same-login WebAuthn verification completed after pending-MFA probes | support / startup |
| `antithesis/workload/access/browser.py:421` | `reachable` | Remembered cookie exchanged through second Marshall before sign-out | support / startup |
| `antithesis/workload/access/browser.py:442` | `always` | Revoked remembered cookie cannot mint or use browser authority across Marshall replicas | `remembered-cookie-revocation-cross-replica` |
| `antithesis/workload/access/browser.py:449` | `reachable` | Copied remembered cookie was refused on second Marshall after sign-out | support / startup |
| `antithesis/workload/access/browser.py:563` | `reachable` | Authorized Control room set-role committed target and audit before demotion | support / startup |
| `antithesis/workload/access/browser.py:576` | `always` | Stale Control room tab cannot commit an admin mutation after authority withdrawal | `stale-admin-tab-current-mutation-authority` |
| `antithesis/workload/access/browser.py:582` | `reachable` | Stale admin LiveView event was processed after committed demotion | support / startup |
| `antithesis/workload/admission/physical_scenario.py:69` | `always` | marshall placement fits fresh measured physical headroom and all outstanding holds | `marshall-admission-measured-physical-capacity` |
| `antithesis/workload/admission/physical_scenario.py:74` | `reachable` | Marshall admitted against independently sampled live ZFS capacity | support / startup |
| `antithesis/workload/admission/scenarios.py:212` | `always` | Marshall acknowledged admission has one joined allocation and dispatch job | `marshall-admission-atomic-allocation` |
| `antithesis/workload/admission/scenarios.py:214` | `reachable` | Marshall admission reached joined dispatch enqueue | support / startup |
| `antithesis/workload/admission/scenarios.py:244` | `always` | Marshall replayed admission key never allocates a second VM | `marshall-admission-key-survives-archive` |
| `antithesis/workload/admission/scenarios.py:316` | `reachable` | Marshall admission reused durable idempotency history | support / startup |
| `antithesis/workload/admission/scenarios.py:338` | `reachable` | Marshall admission rejected changed same-key request | support / startup |
| `antithesis/workload/admission/scenarios.py:362` | `reachable` | Marshall admission replay found archived idempotency history | support / startup |
| `antithesis/workload/backup/scenarios.py:55` | `always` | Backup retention keeps exactly the newest complete manifest points | support / startup |
| `antithesis/workload/backup/scenarios.py:73` | `always` | Retained backup manifest references restorable component snapshots | `backup-retained-manifest-closure` |
| `antithesis/workload/backup/scenarios.py:80` | `always` | Retained backup point passes the production manifest validator | support / startup |
| `antithesis/workload/backup/scenarios.py:91` | `reachable` | Backup retained points share a real Restic component snapshot | support / startup |
| `antithesis/workload/backup/scenarios.py:113` | `always` | Uploaded backup manifest remains tag-visible after its reply is lost | support / startup |
| `antithesis/workload/backup/scenarios.py:119` | `reachable` | Backup manifest upload completed before its coordinator reply was lost | support / startup |
| `antithesis/workload/backup/scenarios.py:123` | `always` | Uploaded backup manifest remains valid after its reply is lost | support / startup |
| `antithesis/workload/backup/scenarios.py:134` | `always` | Retained uploaded backup point restores its component after local reply loss | support / startup |
| `antithesis/workload/backup/scenarios.py:172` | `always` | Interrupted backup restore leaves its partial target unpublished | `backup-interrupted-restore-target-unpublished` |
| `antithesis/workload/backup/scenarios.py:177` | `reachable` | Backup restore interruption retained a verified component prefix | support / startup |
| `antithesis/workload/backup/scenarios.py:180` | `always` | Backup restore refuses a nonempty partial target without changing its bytes | support / startup |
| `antithesis/workload/backup/scenarios.py:194` | `sometimes` | Fresh backup restore eventually completes after an interrupted attempt | support / startup |
| `antithesis/workload/backup/scenarios.py:199` | `always` | Fresh backup restore publishes only after every component verifies | support / startup |
| `antithesis/workload/backup/scenarios.py:200` | `reachable` | Backup restore completed into a fresh isolated target after interruption | support / startup |
| `antithesis/workload/backup/scenarios.py:225` | `always` | Successful coordinator backup advertises exactly one new host manifest | support / startup |
| `antithesis/workload/backup/scenarios.py:235` | `always` | Newly published backup point passes its retention manifest validator | `backup-published-manifest-retention-compatible` |
| `antithesis/workload/backup/scenarios.py:241` | `reachable` | Backup coordinator published a point under a backward wall-clock step | support / startup |
| `antithesis/workload/backup/scenarios.py:242` | `reachable` | Backup coordinator published a tag-visible host manifest | support / startup |
| `antithesis/workload/backup/scenarios.py:281` | `always` | Mixed-time backup restore remains in its private isolated target | support / startup |
| `antithesis/workload/backup/scenarios.py:294` | `reachable` | Backup fixture published independently timed components | support / startup |
| `antithesis/workload/control/bounds.py:44` | `always` | control client pending requests fit negotiated window and busy calls send no frame | `control-inflight-limit-and-retirement` |
| `antithesis/workload/control/bounds.py:50` | `reachable` | Control negotiated window saturates then admits fresh work | support / startup |
| `antithesis/workload/control/delivery.py:126` | `always` | Control transport never redelivers an uncertain application call | `control-no-hidden-redelivery` |
| `antithesis/workload/control/delivery.py:241` | `reachable` | Control delivery sentinel has a distinct committed session receipt | support / startup |
| `antithesis/workload/control/delivery.py:243` | `reachable` | Control lost reply may conceal a committed domain effect | support / startup |
| `antithesis/workload/control/dispatch.py:195` | `always` | Control rejects cross-service and invalid documents before domain effects | `control-service-dispatch-closed` |
| `antithesis/workload/control/dispatch.py:201` | `reachable` | Control bound Lilly socket refused a valid foreign-service document | support / startup |
| `antithesis/workload/control/dispatch.py:203` | `reachable` | Control bound Lilly request reached a closed service or document refusal | support / startup |
| `antithesis/workload/control/dispatch.py:231` | `reachable` | Control bound Lilly v4 session has a durable positive witness | support / startup |
| `antithesis/workload/control/dispatch.py:272` | `always_or_unreachable` | Control wrong outer version is refused before socket upgrade | support / startup |
| `antithesis/workload/control/dispatch.py:277` | `reachable` | Control wrong-version upgrade reaches permanent HTTP 426 | support / startup |
| `antithesis/workload/control/dispatch.py:313` | `reachable` | Execution v4 accepted matching machine-bound session | support / startup |
| `antithesis/workload/control/dispatch.py:351` | `always_or_unreachable` | Execution v4 refuses legacy authority without changing durable command | `execution-v4-refuses-legacy-document` |
| `antithesis/workload/control/dispatch.py:356` | `reachable` | Execution legacy inner session reaches authenticated decoder refusal | support / startup |
| `antithesis/workload/control/host_sessions.py:270` | `reachable` | Successor host session made progress after old nonce replay | support / startup |
| `antithesis/workload/control/host_sessions.py:272` | `always` | Superseded Lilly host session cannot change exchange state or dispatch work | `host-session-successor-fences-old-exchanges` |
| `antithesis/workload/control/host_sessions.py:348` | `always` | Committed host credential rotation fences old Control request authority | `host-credential-rotation-fences-old-socket` |
| `antithesis/workload/control/host_sessions.py:356` | `reachable` | Archived host credential refused on old socket and fresh upgrade | support / startup |
| `antithesis/workload/control/host_sessions.py:379` | `reachable` | New host credential opened a successor session after rotation | support / startup |
| `antithesis/workload/control/pending.py:42` | `always` | Control responses settle only their live pending request | `control-pending-response-retirement` |
| `antithesis/workload/control/pending.py:48` | `reachable` | Control late retired response is ignored while fresh work completes | support / startup |
| `antithesis/workload/control/scenarios.py:149` | `always` | Control domain effects require the authenticated service hello | `control-bind-before-domain-effects` |
| `antithesis/workload/control/scenarios.py:159` | `reachable` | Control first-request refusal is observed before any domain dispatch | support / startup |
| `antithesis/workload/control/scenarios.py:241` | `reachable` | Bound control current credential completes a new session after rotation | support / startup |
| `antithesis/workload/control/scenarios.py:251` | `always` | Bound control sockets revalidate current credentials before each domain effect | `control-bound-credential-revalidated` |
| `antithesis/workload/control/scenarios.py:262` | `reachable` | Bound control credential rotation is refused on the next request | support / startup |
| `antithesis/workload/control/version_refusal.py:54` | `always` | Control transport version refusal stops its owner without losing its class | `control-version-refusal-remains-terminal` |
| `antithesis/workload/control/version_refusal.py:60` | `reachable` | Control 4001 refusal retired a held call and stayed stopped past backoff | support / startup |
| `antithesis/workload/core/bootstrap.py:104` | `reachable` | Overalls bootstrap observed Control connection and independent oracle | support / startup |
| `antithesis/workload/core/smoke.py:34` | `always_or_unreachable` | Control smoke wrong outer version receives terminal 426 | support / startup |
| `antithesis/workload/core/smoke.py:41` | `always_or_unreachable` | Control smoke invalid credential refused before upgrade | support / startup |
| `antithesis/workload/core/smoke.py:46` | `reachable` | Control smoke observed authentication refusal on fleet listener | support / startup |
| `antithesis/workload/core/smoke.py:57` | `reachable` | Control smoke observed fresh connected host report | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:42` | `always` | Completed guest lifecycle outcome matches current VM state and execution identity | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:192` | `always` | Guest ready outcome has current tuple and independent live QEMU guest readiness | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:198` | `reachable` | Accepted provision reached a real QEMU guest boot and port 1024 readiness | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:215` | `always` | Accepted stop has no QEMU process and retains the measured guest overlay | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:221` | `reachable` | Accepted stop has independently absent QEMU and retained qcow2 hash | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:249` | `always` | Fresh start reaches a new physical boot on the retained guest placement | support / startup |
| `antithesis/workload/guest_lifecycle/scenarios.py:251` | `reachable` | Stopped retained guest restarted with a new kernel boot UUID | support / startup |
| `antithesis/workload/recorder/scenarios.py:124` | `always` | Request recorder exact capacity holds 4096 real worker admissions | support / startup |
| `antithesis/workload/recorder/scenarios.py:129` | `reachable` | Request recorder reached 4096 live authenticated producer workers | support / startup |
| `antithesis/workload/recorder/scenarios.py:145` | `always` | request recorder saturation cannot fabricate admitted tickets or a clean quality interval | `request-recorder-capacity-does-not-admit-phantom-work` |
| `antithesis/workload/recorder/scenarios.py:150` | `reachable` | Request recorder refused 4097th measurement after fixture effect | support / startup |
| `antithesis/workload/recorder/scenarios.py:160` | `always_or_unreachable` | Request recorder freed capacity admits one new measured worker | support / startup |
| `antithesis/workload/recorder/scenarios.py:191` | `always` | Request recorder acknowledged admission has durable checkpoint custody | support / startup |
| `antithesis/workload/recorder/scenarios.py:201` | `always_or_unreachable` | Request recorder lost Admit reply changes durable admission at most once | support / startup |
| `antithesis/workload/recorder/scenarios.py:206` | `reachable` | Request recorder committed admission before caller discarded reply | support / startup |
| `antithesis/workload/recorder/scenarios.py:219` | `always` | Request recorder recovery conserves admissions without inventing producer death | `request-recorder-restart-conserves-custody` |
| `antithesis/workload/recorder/scenarios.py:238` | `always_or_unreachable` | Request recorder restart retains live unexpired admissions | support / startup |
| `antithesis/workload/recorder/scenarios.py:243` | `reachable` | Request recorder reopened pending work while its original producer remained alive | support / startup |
| `antithesis/workload/recorder/scenarios.py:269` | `always` | Trace archive recovery preserves accepted immutable custody through acknowledgment loss | `trace-archive-ack-loss-preserves-replay` |
| `antithesis/workload/recorder/scenarios.py:293` | `always_or_unreachable` | Trace archive replay restores pending index without rewriting accepted bytes | support / startup |
| `antithesis/workload/recorder/scenarios.py:298` | `reachable` | Trace spool replayed immutable archive through production replay mode | support / startup |
| `antithesis/workload/recorder/scenarios.py:320` | `reachable` | Trace spool faced real ENOSPC on dedicated archive backing | support / startup |
| `antithesis/workload/recorder/scenarios.py:326` | `reachable` | Trace spool refused an archive write during real ENOSPC | support / startup |
| `antithesis/workload/recorder/scenarios.py:337` | `always_or_unreachable` | Trace spool poisoned storage refuses fresh ACKs until reopen | support / startup |
| `antithesis/workload/recorder/scenarios.py:343` | `reachable` | Trace spool reused allocated archive pages during backing pressure | support / startup |
| `antithesis/workload/recorder/scenarios.py:350` | `always_or_unreachable` | Trace spool retains accepted bodies after physical space restoration | support / startup |
| `antithesis/workload/recorder/scenarios.py:373` | `always_or_unreachable` | Trace spool reopen replaces the poisoned process identity | support / startup |
| `antithesis/workload/recorder/scenarios.py:378` | `always_or_unreachable` | Trace spool reopen retains previously accepted archive bytes | support / startup |
| `antithesis/workload/recorder/scenarios.py:390` | `always_or_unreachable` | Trace spool reopen admits one fresh reviewed batch without losing prior custody | support / startup |
| `antithesis/workload/recorder/scenarios.py:395` | `reachable` | Trace spool accepted fresh batch after poisoned process reopen | support / startup |
| `antithesis/workload/recorder/scenarios.py:425` | `always` | Trace spool successful intake has immutable SQLite custody | support / startup |
| `antithesis/workload/recorder/scenarios.py:430` | `reachable` | Trace spool accepted a reviewed producer batch into SQLite custody | support / startup |
| `antithesis/workload/recorder/scenarios.py:450` | `reachable` | Trace spool committed a batch despite discarded intake ACK | support / startup |
| `antithesis/workload/recorder/scenarios.py:454` | `always_or_unreachable` | Trace spool duplicate after lost intake ACK keeps one immutable batch | support / startup |
| `antithesis/workload/recorder/scenarios.py:482` | `always` | Trace spool pressure retains previously witnessed archive bytes | support / startup |
| `antithesis/workload/recorder/scenarios.py:487` | `always_or_unreachable` | Trace spool acknowledged pressure intake has one durable new batch | support / startup |
| `antithesis/workload/recorder/scenarios.py:492` | `reachable` | Trace spool observed exhausted filesystem backing | support / startup |
| `antithesis/workload/recorder/scenarios.py:494` | `always` | trace spool saturation preserves accepted archive bytes and refuses on exhausted backing | `trace-spool-physical-quota-with-retained-custody` |
| `antithesis/workload/recorder/scenarios.py:500` | `reachable` | Trace spool reached real archive or pending quota refusal | support / startup |
| `antithesis/workload/recorder/scenarios.py:503` | `reachable` | Trace spool storage unavailable and refused further intake | support / startup |
| `antithesis/workload/recorder/scenarios.py:510` | `always_or_unreachable` | Trace spool uncertain storage refuses later admission without evicting custody | support / startup |
| `antithesis/workload/repository/scenarios.py:143` | `always` | Enrico published Git head remains addressable through failed refresh | `enrico-published-head-remains-addressable` |
| `antithesis/workload/repository/scenarios.py:151` | `always` | Enrico explicit published SHA returns the original sentinel blob | support / startup |
| `antithesis/workload/repository/scenarios.py:156` | `reachable` | Enrico retained prior published head across force push | support / startup |
| `antithesis/workload/repository/scenarios.py:161` | `reachable` | Marshall settled failed Enrico refresh without replacing head | support / startup |
| `antithesis/workload/repository/scenarios.py:226` | `always` | Enrico retained attempt replay returns its completed receipt | support / startup |
| `antithesis/workload/repository/scenarios.py:231` | `always` | Enrico retained attempt replay starts no second fetch | `enrico-attempt-replay-bounded-receipts` |
| `antithesis/workload/repository/scenarios.py:235` | `reachable` | Enrico returned retained attempt receipt without new fetch | support / startup |
| `antithesis/workload/repository/scenarios.py:291` | `always` | Enrico oldest completed receipt evicts after 1,025 native Git attempts | support / startup |
| `antithesis/workload/repository/scenarios.py:296` | `reachable` | Enrico evicted oldest completed attempt receipt at cap | support / startup |
| `antithesis/workload/repository/scenarios.py:308` | `always` | Enrico newest receipt remains replayable at the bounded cap | support / startup |
| `antithesis/workload/repository/scenarios.py:313` | `always` | Enrico retained attempt replay starts no second fetch at receipt cap | support / startup |
| `antithesis/workload/repository/scenarios.py:382` | `reachable` | Enrico restart retired prior native Git slot owners | support / startup |
| `antithesis/workload/repository/scenarios.py:439` | `always` | Enrico native Git ownership bounds physical concurrent refreshes | `enrico-native-git-admission-after-manager-restart` |
| `antithesis/workload/repository/scenarios.py:467` | `always` | Enrico ninth refresh receives admission refusal while eight native slots remain held | support / startup |
| `antithesis/workload/repository/scenarios.py:472` | `reachable` | Enrico observed ninth-admission refusal with eight physical slots held | support / startup |
| `antithesis/workload/satellite/editor.py:280` | `reachable` | Editor login code committed while its only callback reply was lost | support / startup |
| `antithesis/workload/satellite/editor.py:287` | `always` | Editor login code creates at most one credential after reply loss | `editor-login-code-single-use-after-reply-loss` |
| `antithesis/workload/satellite/editor.py:291` | `sometimes` | Editor login code exchange issued one session through Audi | support / startup |
| `antithesis/workload/satellite/private_ingress.py:72` | `reachable` | Guest stand-in reached private Audi over verified TLS | support / startup |
| `antithesis/workload/satellite/private_ingress.py:74` | `always` | Private Audi forwards nothing for a guest source Lilly never bound | support / startup |
| `antithesis/workload/satellite/private_ingress.py:79` | `reachable` | Private Audi refused an unbound guest-side source | support / startup |
| `antithesis/workload/satellite/scenarios.py:72` | `reachable` | Ziggy admitted real guest inference with provider acceptance | support / startup |
| `antithesis/workload/satellite/scenarios.py:73` | `always` | Ziggy settled guest inference conserves one Marshall Daily update | support / startup |
| `antithesis/workload/satellite/scenarios.py:142` | `reachable` | Galileo named request reached the independent origin | support / startup |
| `antithesis/workload/satellite/scenarios.py:143` | `always` | Galileo named request selected A and platform headers | support / startup |
| `antithesis/workload/satellite/scenarios.py:191` | `reachable` | Galileo named origin stream was open at committed detachment | support / startup |
| `antithesis/workload/satellite/scenarios.py:207` | `always` | Galileo detached held origin stream closes before fixture deadline | support / startup |
| `antithesis/workload/satellite/scenarios.py:231` | `reachable` | Galileo detached attachment refused a fresh named request | support / startup |
| `antithesis/workload/satellite/scenarios.py:232` | `always` | Galileo detached attachment blocks fresh upstream effect | support / startup |
| `antithesis/workload/satellite/scenarios.py:270` | `always` | Galileo reattached name resumes one authorized A effect | support / startup |
| `antithesis/workload/terminal/scenarios.py:78` | `reachable` | Terminal browser reply loss followed observed guest PTY birth | support / startup |
| `antithesis/workload/terminal/scenarios.py:96` | `always` | Terminal create replay retains one guest PTY and one opened receipt | `terminal-create-reply-loss-one-pty` |
| `antithesis/workload/terminal/scenarios.py:106` | `reachable` | Terminal duplicate create returned original session receipt | support / startup |
| `antithesis/workload/terminal/scenarios.py:188` | `always` | terminal calibration marker consumed once | support / startup |
| `antithesis/workload/terminal/scenarios.py:226` | `reachable` | terminal identical DATA frames received a Lilly input ACK | support / startup |
| `antithesis/workload/terminal/scenarios.py:249` | `always` | terminal same-channel DATA replay has one guest input effect | support / startup |
| `antithesis/workload/terminal/scenarios.py:296` | `always` | terminal physical scrollback backing stays within reserved aggregate budget | `terminal-physical-scrollback-budget` |
| `antithesis/workload/terminal/scenarios.py:319` | `reachable` | terminal create failed with aggregate ring budget full and survivors live | support / startup |
| `antithesis/workload/terminal/scenarios.py:398` | `sometimes` | terminal neighbor completes create attach and byte delivery while another viewer is credit stalled | `terminal-stalled-viewer-neighbor-progress` |
| `antithesis/workload/terminal/scenarios.py:460` | `reachable` | terminal guest PTY master input write stayed blocked before kill | support / startup |
| `antithesis/workload/terminal/scenarios.py:497` | `sometimes` | terminal kill retires blocked PTY child and releases capacity | support / startup |
| `audi/lib/audi/application.ex:17` | `reachable` | Overalls Audi application started | support / startup |
| `brady/lib/brady/application.ex:17` | `reachable` | Overalls Brady application started | support / startup |
| `enrico/lib/enrico/application.ex:17` | `reachable` | Overalls Enrico application started | support / startup |
| `galileo/lib/galileo/application.ex:17` | `reachable` | Overalls Galileo application started | support / startup |
| `lilly/lib/lilly/application.ex:19` | `reachable` | Overalls Lilly application started | support / startup |
| `marshall/lib/marshall/application.ex:20` | `reachable` | Overalls Marshall application started | support / startup |
| `marshall/lib/marshall/control/hints/relay.ex:37` | `reachable` | Marshall notifier recovered after losing a host command hint | support / hint-loss anchor (no primary) |
| `porsche/lib/porsche/application.ex:17` | `reachable` | Overalls Porsche application started | support / startup |
| `ziggy/lib/ziggy/application.ex:17` | `reachable` | Overalls Ziggy application started | support / startup |

## Scan identity

- Exact SHA-256 for every listed callsite source is in [the as-of roster snapshot](evaluation/template-roster.json), under `authored_snapshot.source_sha256`; it shares this scan timestamp.
- Duplicated authored literal messages: `[]`.
- Selected `control-core` manifest has 13 commands and 40 runtime dependencies; its manifest hash is `0d48b340435a19f45b73c2e7d0bf043fca178606179bf682104afb21a96772c0`. It is current for scanned selected sources; source selection must be staged again before identity freeze.
- This scan does not freeze `N`, choose a hosted template, or claim any selected assertion evaluated.

## Addendum: backup-restic and satellite-standin profiles (2026-10-17)

A later scan added six callsites (159 total; 27 of 104 primary messages authored).
Line numbers are omitted because the files are new and moving; the template roster
records the editor primary's current line and hash. None has a hosted run.

| File | Kind | Literal message | Catalog primary |
| --- | --- | --- | --- |
| `antithesis/workload/satellite/editor.py` | `reachable` | Editor login code committed while its only callback reply was lost | support |
| `antithesis/workload/satellite/editor.py` | `always` | Editor login code creates at most one credential after reply loss | `editor-login-code-single-use-after-reply-loss` |
| `antithesis/workload/satellite/editor.py` | `sometimes` | Editor login code exchange issued one session through Audi | support (positive control) |
| `antithesis/workload/satellite/private_ingress.py` | `reachable` | Guest stand-in reached private Audi over verified TLS | support / stand-in channel |
| `antithesis/workload/satellite/private_ingress.py` | `always` | Private Audi forwards nothing for a guest source Lilly never bound | support / stand-in refusal |
| `antithesis/workload/satellite/private_ingress.py` | `reachable` | Private Audi refused an unbound guest-side source | support / stand-in refusal |

The private-ingress checks use the labelled guest stand-in, which is not a guest:
they test private Audi's transport-only attribution for a source Lilly never bound,
with the independent origin fixture as effect witness. They make no guest, tap,
pre-NAT routing or isolation claim. The editor callsites are selected in
`satellite-standin` but cannot be reached there: Marshall's editor login needs a
current running VM and editor release that the hosted controlled pool cannot supply.
The `backup-restic` profile selects the existing backup callsites unchanged.

## Open Questions

- Which authored primary assertions will be included and meaningfully evaluated in the next immutable selected image? Resolve the current source/manifest hash drift before answering.
