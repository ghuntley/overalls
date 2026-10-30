# ADR-0187: Detached ingress bridges survive lilly-hostd and Lilly restarts

- ID: ADR-0187
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Lilly, lilly-hostd, lilly-ingress-bridge, NixOS lilly module, Marshall SSH session renewal
- Supersedes: none
- Superseded by: none

## Context

Guest SSH reaches a VM through Audi, Lilly's ingress socket
(`/run/lilly-ingress/audi.sock`) and, since
[ADR-0184](0184-lilly-owns-every-socket.md), hostd op 13 and
`lilly-ingress-bridge`. Before this decision, a guest SSH connection crossed
three processes:

1. Audi's connection was accepted by a BEAM worker
   (`Lilly.Ingress.Server`), which relayed bytes in Elixir (`pump/3`).
2. The worker's own Unix socket was bridged by `lilly-ingress-bridge` to the
   guest connection that hostd dialled inside the VM namespace.
3. That bridge was a command of the hostd session that started it: it ran in
   a `run-N` cgroup beneath `lilly-hostd.service`, with a parent-death signal.

So a `lilly-hostd` restart ended every live guest SSH session. The fleet
user-SSH journey asserted that loss ("a lilly-hostd restart ends live guest
SSH and new sessions reconnect"). Two facts made it worse than one hop:

- `lilly.service` has `BindsTo=lilly-hostd.service`, and systemd propagates a
  restart of the bound unit to it, because every lease lives in hostd (ADR-0176
  decision 4). A hostd restart therefore also restarts the BEAM.
- The BEAM relay was itself in the byte path, so even a bridge that survived
  hostd would have ended with the BEAM's socket (`bridge-ends-with-lilly`).

The user asked that live ingress bridges, and ideally the guest SSH sessions
inside them, survive a hostd restart, without weakening ADR-0184's custody
(the BEAM holds only descriptors it created) or the ingress fence: a bridge
must not outlive its execution's authority (`ingress-watchdog-independent-deadline`,
`ingress-current-observed-execution`).

## Decision

Accepted on 2026-10-17 under the user's instruction to "resolve all the
things", which authorized designing away the documented hostd-restart loss.
This amends ADR-0184 decision 3 for preface-free services; ADR-0184's other
decisions stand.

1. **Audi's connection goes straight to the guest.** For a binding that needs
   no preface and no ready frame (`:ssh`, `:web`, `:porsche_ssh`,
   `:audi_ssh`), the BEAM no longer relays. After guardian admission it sends
   the Audi connection it accepted (a socket it created) to hostd with a new
   typed request, `BridgeIngress` (op 14). hostd:
   - refuses the descriptor unless it is a connected, non-listening AF_UNIX
     stream socket whose `SO_PEERCRED` uid is Audi's (`--ingress-peer-user`,
     resolved from `/etc/passwd` at startup);
   - dials the guest exactly as op 13 (`hostd-netns-connect`);
   - starts `lilly-ingress-bridge --detached 5 3 4 <service uid>` with Audi's
     connection at 3, the guest at 4 and a fresh control socket at 5, keeping
     no copy;
   - writes the greeting (Lilly's framed ready message) to Audi's connection
     only after the bridge reported READY, then sends GO. The bridge moves no
     byte before GO, so guest bytes never precede the greeting.
   The BEAM then closes its own copy. Editor and nested HTTPS bindings, which
   need a preface or a ready frame from the guest, keep ADR-0184's op 13 and
   BEAM relay.
   *Amended by [ADR-0192](0192-staged-detached-ingress.md) (2026-10-17):*
   the editor and nested HTTPS now take this path too. op 14 carries a
   preface and an exact expected frame that Lilly derives; hostd writes the
   one to the guest and compares the other before starting the bridge.
2. **The bridge lives outside both services.** hostd places each detached
   bridge in its own transient scope, `systemd-run --scope
   --unit=lilly-ingress-<key>.scope --slice=lilly_ingress.slice
   --property=RuntimeMaxSec=30d`. The detached bridge sets no parent-death
   signal. Restarting or stopping `lilly-hostd.service` or `lilly.service`
   therefore leaves it, and the guest session, running. The dedicated
   top-level slice keeps bridges out of the guest capacity slice, bounds them
   (1 GiB, 1100 tasks) and is never restarted on deployment. hostd refuses a
   1025th live bridge.
3. **hostd keeps no bridge state.** `ListIngressBridges` (op 15) returns the
   keys of populated `lilly-ingress-<32 hex>.scope` cgroups in the slice, and
   `EndIngressBridge` (op 16) writes that scope's `cgroup.kill` and confirms
   it empty. Neither touches any other cgroup.
4. **Lilly keeps the fence.** The BEAM picks a random 128-bit key, records
   the exact connector binding under it in a private 0700 directory
   (`<ingress socket>.bridges/<key>`) *before* asking hostd, and hands the
   started bridge to a keeper process under the connector. A keeper holds an
   ingress guardian for the recorded binding and ends the bridge through
   hostd as soon as that guardian dies; the record goes once hostd confirms
   the bridge ended. A bridge Audi closed ends by itself, and the connector's
   2-second sweep stops its keeper.
5. **Re-adoption after a restart.** When the connector starts, it lists live
   bridges. A live bridge with a readable record gets a keeper with a
   30-second adoption grace for its execution to become current again; a live
   bridge with no readable record is ended at once; records of bridges that
   are gone are dropped. Thereafter any live bridge nobody keeps is ended.
6. **Custody.** The BEAM still holds only descriptors it created: it sends
   Audi's accepted connection and closes its own copy, and hostd sends none
   back (ADR-0184 decision 1). The bridge still drops to the service uid with
   no supplementary groups and `no_new_privs`, and logs nothing.

## Alternatives

- **systemd's file-descriptor store.** hostd would push each bridge's two
  descriptors with `FDSTORE=1` and re-adopt them after a restart. Rejected:
  bytes would stop flowing while hostd is down (no process splices them), the
  BEAM relay would still be in the byte path and die with Lilly, which
  restarts with hostd, and hostd would need durable per-bridge state to know
  which stored descriptors belong together and to which execution.
- **Keep the BEAM relay, survive only hostd.** Pointless while
  `BindsTo=` restarts the BEAM with hostd. Removing `BindsTo=` would require
  Lilly to outlive its hostd session and re-acquire every lease, a far larger
  change to ADR-0176 decision 4.
- **A long-lived bridge daemon.** One unprivileged process holding every
  bridge would survive restarts too, but would be a new always-on service with
  its own protocol and one failure domain for every session. A scope per
  bridge reuses systemd's custody and keeps one connection per process, as
  before.
- **Move the bridge into Lilly's cgroup, or keep it in hostd's.** Either
  service's restart would still kill it (`KillMode=control-group`).

## Consequences

- A live guest SSH session survives a restart of `lilly-hostd`, of Lilly, or
  of both, including a deployment that restarts them. One splice hop (the BEAM
  relay) is removed from the ingress path.
- The fence has a bounded gap. While Lilly is down nothing ends a bridge
  whose authority changes; when Lilly returns, a recorded bridge whose
  execution is not current within 30 seconds is ended. A Lilly restart can
  therefore keep a revoked execution's live session up to the downtime plus
  30 seconds. Audi's own account-key revocation still ends sessions at Audi.
  Lilly also cannot change execution authority while it is down: Marshall's
  commands wait for it.
- If the connector never runs again (Lilly removed or its ingress disabled),
  bridges persist until Audi closes them or their 30-day `RuntimeMaxSec`.
- The BEAM no longer bounds live bridges by its relay workers. The connector
  bounds kept and pending bridges by its connection limit, and hostd and the
  slice bound them host-wide.
- hostd gains three typed requests and one more received-descriptor form; the
  generic `Run` still cannot reach `systemd-run` or the bridge.

### Correction: SSH renewal across restarts (2026-10-17)

A surviving bridge is not enough for a surviving session: Audi also renews
the session's 30-second lease with Marshall about every 15 seconds. Marshall's
SSH renewal (`Marshall.Ingress.Sessions`, `host!/1` and `ready!/2`) refused
with `unauthorized`, a conclusive revocation, whenever the host had no
provisioner session or a new session that had not reported yet. A Lilly
restart produces exactly that window, so a guest SSH session whose renewal
(or a hint-driven renewal) fell inside it was cut even though its bridge
lived. The user-SSH journey subtest passed because its renewals happened to
miss the window; the editor subtest of
[ADR-0192](0192-staged-detached-ingress.md) hit the same class of refusal.

SSH renewal now follows ADR-0192 decision 6: it rechecks the gateway, the
key and its owner, current write membership, the VM's placement, epoch,
generation, running state, readiness and completed start, and the session's
own binding, all conclusively; only then, if the provisioner is merely
reconnecting, it answers `temporarily_unavailable` and leaves the lease
unchanged (`ingress-ssh-renewal-no-resurrection`,
`ingress-renewal-host-reconnecting`). Marshall's Audi channel reports that as
`unavailable`; Audi's SSH channel already treats it as inconclusive and
retries until the lease deadline (`Audi.Authority.Renewal`,
`Audi.SSH.Channel`). Admission still requires a live, reported host. Nested
`porsche_ssh` and `audi_ssh` streams renew through Inception publication
authority, not this path, and are unchanged (see ADR-0192).

## Invariants and verification

- hostd bridges only Audi's connection: a connected, non-listening AF_UNIX
  stream whose peer uid is Audi's (`ingress-client-is-audi`).
- Guest bytes never precede the greeting, and a bridge hostd abandons before
  GO moves no byte (`bridge-detached-handshake`, `hostd-detached-ingress-bridge`).
- hostd lists and kills only `lilly-ingress-<32 hex>.scope` cgroups in its
  configured top-level slice (`ingress-scope-names-closed`,
  `ingress-bridges-listed-from-cgroups`, `ingress-bridge-ended-by-scope`).
- A detached bridge sets no parent-death signal and is in no hostd command
  cgroup (`hostd-detached-spawn`, `hostd-child-pinned`, `ingress-bridge-slice`).
- Every bridge's binding is recorded before it exists, every live bridge has
  a keeper or is ended, and a keeper ends its bridge when its guardian dies
  (`ingress-bridge-recorded-before-start`, `ingress-bridge-keeper-fence`,
  `ingress-bridges-readopted`, `ingress-detached-handoff`).
- The machine test must show the same bridge process and live session across
  a hostd restart and a Lilly restart, the adoption, the adoption grace
  passing, and an unrecorded bridge ended
  (`journey-hostd-restart-keeps-bridges`).
- SSH renewal while Lilly reconnects is inconclusive and then keeps the
  binding; key removal, write revocation and a stop with a newer generation
  stay conclusive in that window; Audi's SSH channel retries an unavailable
  renewal inside the lease (`ssh-renewal-across-lilly-restart`,
  `ssh-renewal-revocation-stays-conclusive`,
  `audi-ssh-renewal-across-lilly-restart`).

## Implementation evidence

- `lilly-ingress-bridge` detached mode:
  [`lib.rs`](../../../lilly/native/ingress-bridge/src/lib.rs) (`--detached`,
  `handshake`, no parent-death signal), with a Hegel command-line oracle in
  [`tests.rs`](../../../lilly/native/ingress-bridge/src/tests.rs) and the
  handshake process fixture in
  [`tests/bridge.rs`](../../../lilly/native/ingress-bridge/tests/bridge.rs).
- hostd: [`ingress.rs`](../../../lilly/native/hostd/src/ingress.rs) (client
  check, scope names, list, end, start handshake),
  [`protocol.rs`](../../../lilly/native/hostd/src/protocol.rs) (ops 14 to 16),
  [`session.rs`](../../../lilly/native/hostd/src/session.rs)
  (`bridge_ingress`), [`exec.rs`](../../../lilly/native/hostd/src/exec.rs)
  (`spawn_detached`), [`lib.rs`](../../../lilly/native/hostd/src/lib.rs)
  (`--ingress-peer-user`, `--ingress-slice`, `passwd_uid`). Tests in
  [`ingress_tests.rs`](../../../lilly/native/hostd/src/ingress_tests.rs): a
  Hegel decoding model for ops 14 to 16, a Hegel scope-name round trip, list
  and end against fake cgroups, the client check, and the start handshake
  with a fake helper.
- Lilly: [`Lilly.Ingress.Bridges`](../../../lilly/lib/lilly/ingress/bridges.ex)
  (records, keepers), [`Lilly.Ingress.Server`](../../../lilly/lib/lilly/ingress/server.ex)
  (reservation, handoff, re-adoption, sweep),
  [`Lilly.Ingress.Backend`](../../../lilly/lib/lilly/ingress/backend.ex),
  [`Lilly.Network.Ingress`](../../../lilly/lib/lilly/network/ingress.ex),
  [`Lilly.VM.Executor`](../../../lilly/lib/lilly/vm/executor.ex) and
  [`Lilly.Host.Hostd`](../../../lilly/lib/lilly/host/hostd.ex). Tests in
  [`ingress_bridges_test.exs`](../../../lilly/test/ingress_bridges_test.exs):
  handoff, guardian-death fencing, re-adoption, unknown and unadoptable
  bridges.
- NixOS: [the Lilly module](../../../nix/domains/system/lilly.nix) passes
  `--ingress-peer-user audi --ingress-slice lilly_ingress.slice` whenever an
  Audi connector exists, and declares `lilly_ingress.slice`.
- Machine test: the user-SSH journey subtest "live guest SSH survives
  lilly-hostd and Lilly restarts until its bridge is fenced"
  ([`user-ssh-journey.py`](../../../nix/verification/tests/machines/fleet/scenarios/user-ssh-journey.py))
  passed in a native `user-ssh-journey-fleet` run on 2026-10-17 (64.99 s
  within 16 passing subtests).
- Machine test: the Audi fleet subtest "Lilly process crash preserves live
  ingress bridges and the guest"
  ([`audi.py`](../../../nix/verification/tests/machines/fleet/scenarios/audi.py),
  `audi-lilly-crash-preserves-live-ingress`) SIGKILLs the packaged Lilly with a
  live public HTTP stream and a live strict-profile SSH stream through Audi,
  and asserts the same bridge processes in `lilly_ingress.slice`, bytes still
  arriving after re-adoption and past the 30-second grace, the unchanged guest
  VMM, and fresh admission afterwards. It replaced an older assertion that a
  Lilly crash closes live ingress, which contradicted decision 2 here. It
  passed in a native `audi-fleet` run on 2026-10-30 (62.60 s within 19
  passing subtests).

- SSH renewal correction: [`Sessions`](../../../marshall/lib/marshall/ingress/sessions.ex)
  (`:renew_ssh`), tests in
  [`sessions_test.exs`](../../../marshall/test/marshall/ingress/sessions_test.exs)
  and Audi's
  [`ssh_transport_test.exs`](../../../audi/test/ssh_transport_test.exs).

Remaining: the adoption grace is unmeasured on a heavily loaded production
host. No machine run yet forces an SSH renewal into the Lilly restart
window. Editor and nested HTTPS moved to this path under
[ADR-0192](0192-staged-detached-ingress.md), whose machine evidence is
pending. The review is
[2026-10-17 detached ingress bridges](../reviews/2026-10-17-detached-ingress-bridges.md).

## Open questions

- Whether the 30-second adoption grace is right for a loaded host whose
  actors take longer to make executions current after a restart. A bridge
  ended by the grace is a lost session, not a security failure; the grace is
  measured by the first machine run.

## Related decisions

- [ADR-0184](0184-lilly-owns-every-socket.md): decision 3 is amended here for
  preface-free services; custody and op 13 for the rest stand.
- [ADR-0192](0192-staged-detached-ingress.md): amends decision 1 so the
  editor and nested HTTPS also use detached bridges, with a hostd-executed
  stage.
- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): Lilly stays
  bound to its hostd session; only bridges leave it.
- [ADR-0182](0182-unprivileged-lilly-beam.md): the unprivileged BEAM and hostd
  as the only root component.
