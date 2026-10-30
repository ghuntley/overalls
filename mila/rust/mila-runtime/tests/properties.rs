use hegel::{generators as gs, TestCase};
use mila_model::RequestId;
use mila_protocol::{Receipt, ReceiptStatus, Reply};
use mila_runtime::{
    AppLock, LockAvailability, LockDelay, LockEvent, LockPhase, MachineSnapshot, SnapshotMachine,
    MAX_SNAPSHOT_BYTES,
};
use mila_runtime::{AttachHeader, AttachMode};
use mila_runtime::{AttachOutcome, AttachPhase, TerminalAttach};
use mila_runtime::{MutationPhase, MutationTracker, NextAction};
use mila_runtime::{MutationRequest, SessionBackend, SessionRuntime};
use mila_runtime::{PokeEnvelope, RuntimeError, SnapshotStore};
use mila_runtime::{PushEnvironment, PushProvider, PushRegistrationReply, PushRegistrationRequest};

#[hegel::test(test_cases = 64)]
fn terminal_output_never_advances_before_connection(tc: TestCase) {
    let generation = tc.draw(gs::default::<u64>());
    let bytes = tc.draw(gs::default::<u8>());
    let mut state = TerminalAttach::initial();
    assert!(!state.output(generation, bytes as usize));
    assert_eq!(state.phase(), AttachPhase::Idle);
    assert!(state.request());
    assert!(state.connected(state.generation(), 0));
    assert_eq!(state.output(state.generation(), bytes as usize), bytes > 0);
    assert!(state.ended(state.generation(), AttachOutcome::Closed));
}

#[hegel::test(test_cases = 128)]
fn mutation_uncertainty_never_allocates_a_second_request(tc: TestCase) {
    let suffix = tc.draw(gs::default::<u64>());
    let id = RequestId::parse(&format!("porsche-{suffix:032x}")).expect("request id");
    let mut tracker = MutationTracker::submitted(id.clone());
    tracker.uncertain();
    let polls = tc.draw(gs::default::<u8>()) as usize;
    for _ in 0..polls {
        tracker.polled().expect("poll");
    }
    assert_eq!(tracker.request_id, id);
    assert_eq!(tracker.phase, MutationPhase::Uncertain);
    assert_eq!(tracker.next_action(), NextAction::Poll);
}

#[hegel::test(test_cases = 128)]
fn terminal_reconnect_rejects_stale_generation_output(tc: TestCase) {
    let bytes = tc.draw(gs::default::<u8>()).max(1) as usize;
    let mut state = TerminalAttach::initial();
    assert!(state.request());
    let first = state.generation();
    assert!(state.connected(first, 0));
    assert!(state.output(first, bytes));
    let cursor_before_reconnect = state.cursor();
    assert!(state.ended(first, AttachOutcome::Transport));
    assert!(state.request());
    let second = state.generation();
    assert_ne!(first, second);
    assert!(state.connected(second, cursor_before_reconnect));
    let cursor_before_stale = state.cursor();
    assert!(!state.output(first, bytes));
    assert_eq!(state.cursor(), cursor_before_stale);
    assert!(state.output(second, bytes));
}

#[hegel::test(test_cases = 128)]
fn terminal_write_capability_tracks_current_grant_and_user_restriction(tc: TestCase) {
    let requested_read_only = tc.draw(gs::default::<bool>());
    let mode = if tc.draw(gs::default::<bool>()) {
        AttachMode::ReadWrite
    } else {
        AttachMode::ReadOnly
    };
    let mut state = TerminalAttach::initial();
    state.set_read_only(requested_read_only);
    assert!(!state.can_send_input());
    assert!(!state.can_resize());
    assert!(state.request());
    let generation = state.generation();
    assert!(state.header(generation, Some(AttachHeader::Attached { from: 0, mode }),));
    let expected_write = mode == AttachMode::ReadWrite && !requested_read_only;
    assert_eq!(state.can_send_input(), expected_write);
    assert_eq!(state.can_resize(), expected_write);
    assert_eq!(
        state.read_only(),
        requested_read_only || mode == AttachMode::ReadOnly
    );
}

#[derive(Default)]
struct MemoryStore {
    bytes: std::cell::RefCell<Option<Vec<u8>>>,
}

impl SnapshotStore for MemoryStore {
    fn read(&self, _deployment: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
        Ok(self.bytes.borrow().clone())
    }

    fn write(&self, _deployment: &str, bytes: &[u8]) -> Result<(), RuntimeError> {
        *self.bytes.borrow_mut() = Some(bytes.to_vec());
        Ok(())
    }
}

#[hegel::test(test_cases = 64)]
fn arbitrary_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(2_000));
    let _ = MachineSnapshot::decode(&bytes, "control.example.test", None);
}

#[hegel::test(test_cases = 64)]
fn encoded_snapshots_round_trip(tc: TestCase) {
    let name_bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(32));
    let id_bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(32));
    let name = String::from_utf8_lossy(&name_bytes).into_owned();
    let id = String::from_utf8_lossy(&id_bytes).into_owned();
    let machine = SnapshotMachine {
        id,
        name,
        desired_state: "running".into(),
        observed_state: None,
        pinned: false,
        owner: None,
        read: true,
        write: false,
        manage: false,
    };
    let snapshot = MachineSnapshot::new("control.example.test".into(), None, 10, vec![machine])
        .expect("valid");
    let encoded = snapshot.encode().expect("encode");
    assert!(encoded.len() <= MAX_SNAPSHOT_BYTES);
    assert_eq!(
        MachineSnapshot::decode(&encoded, "control.example.test", None).expect("decode"),
        snapshot
    );
}

#[hegel::test(test_cases = 64)]
fn arbitrary_registration_inputs_never_panic(tc: TestCase) {
    let token =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(800))).into_owned();
    let app =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(300))).into_owned();
    let host =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(300))).into_owned();
    let _ = PushRegistrationRequest::new(
        PushProvider::Fcm,
        token,
        app,
        PushEnvironment::Production,
        host,
        None,
    );
}

#[hegel::test(test_cases = 128)]
fn push_replies_never_accept_expired_or_unbounded_values(tc: TestCase) {
    let raw_key = tc.draw(gs::vecs(gs::default::<u8>()).max_size(900));
    let push_key = "A".repeat(16 + raw_key.len().min(684));
    let key_id =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(180))).into_owned();
    let now = tc.draw(gs::default::<u64>());
    let expires = tc.draw(gs::default::<u64>());
    if let Ok(reply) = PushRegistrationReply::new(push_key, key_id, expires, now) {
        assert!(reply.expires_at > now);
        assert!((16..=700).contains(&reply.push_key.len()));
        assert_ne!(reply.key_id, "");
        assert!(reply.key_id.len() <= 128);
    }
}

#[hegel::test(test_cases = 64)]
fn arbitrary_poke_metadata_never_panics(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(5_000));
    let text = String::from_utf8_lossy(&bytes);
    let envelope = PokeEnvelope {
        deployment: text.to_string(),
        push_key: text.to_string(),
        delivery_id: text.to_string(),
        collapse_id: text.to_string(),
        kind: text.to_string(),
        issued_at: tc.draw(gs::default::<u64>()),
        nonce: text.to_string(),
        ciphertext: text.to_string(),
    };
    let _ = envelope.validate(1_000);
}

#[test]
fn registration_restricts_origins_and_secrets() {
    let token = "a".repeat(32);
    let req = PushRegistrationRequest::new(
        PushProvider::Apns,
        token,
        "com.example.mila".into(),
        PushEnvironment::Production,
        "mila.example.test".into(),
        None,
    )
    .expect("valid");
    assert_eq!(PushProvider::Apns.origin(), "https://api.push.apple.com");
    assert!(!format!("{req:?}").contains("aaaa"));
    assert!(PushRegistrationRequest::new(
        PushProvider::Fcm,
        "a".repeat(32),
        "app".into(),
        PushEnvironment::Development,
        "mila.example.test".into(),
        None
    )
    .is_err());
    assert!(PushRegistrationRequest::new(
        PushProvider::Wns,
        "https://evil.example/channel".into(),
        "app".into(),
        PushEnvironment::Production,
        "mila.example.test".into(),
        Some("https://evil.example/channel".into())
    )
    .is_err());
}

fn wns(channel: &str) -> bool {
    PushRegistrationRequest::new(
        PushProvider::Wns,
        channel.into(),
        "dev.overalls.mila".into(),
        PushEnvironment::Production,
        "mgmt.example.test".into(),
        Some(channel.into()),
    )
    .is_ok()
}

/// Mirrors Susan's `susan-wns-channel-shape` so a channel Mila sends is one
/// Susan's key issuance accepts (and nothing Susan would refuse is sent).
#[test]
fn wns_channel_shape_matches_susan() {
    assert!(wns(
        "https://wns2-par02p.notify.windows.com/w/?token=AwYAAAB%2bQk1%3d"
    ));
    assert!(wns("https://push.notify.windows.com/channel/abc"));
    for refused in [
        "https://wns2-par02p.notify.windows.com:443/w/?token=abc",
        "https://wns2-par02p.notify.windows.com:8443/w/?token=abc",
        "http://wns2-par02p.notify.windows.com/w/?token=abc",
        "https://notify.windows.com/w/?token=abc",
        "https://WNS2.notify.windows.com/w/?token=abc",
        "https://wns2.notify.windows.com",
        "https://wns2.notify.windows.com/",
        "https://wns2.notify.windows.com/w/?token=a%00b",
        "https://wns2.notify.windows.com/w/#fragment",
        "https://user@wns2.notify.windows.com/w/",
        "https://wns2.notify.windows.com/w/a b",
        "https://wns2.notify.windows.com.evil.example/w/",
        "https://evil.example/wns2.notify.windows.com/w/",
        "https://-bad.notify.windows.com/w/",
    ] {
        assert!(!wns(refused), "accepted {refused}");
    }
    let long = format!("https://wns2.notify.windows.com/{}", "a".repeat(1024));
    assert!(!wns(&long));
}

#[test]
fn susan_key_request_body_is_closed() {
    let channel = "https://wns2-par02p.notify.windows.com/w/?token=abc";
    let request = PushRegistrationRequest::new(
        PushProvider::Wns,
        channel.into(),
        "dev.overalls.mila".into(),
        PushEnvironment::Production,
        "localhost".into(),
        Some(channel.into()),
    )
    .expect("valid");
    let body: serde_json::Value = serde_json::from_slice(&request.susan_body()).unwrap();
    let mut keys: Vec<_> = body.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(
        keys,
        ["app_id", "deployment", "environment", "provider", "token"]
    );
    assert_eq!(body["provider"], "wns");
    assert_eq!(body["environment"], "production");
    assert_eq!(body["token"], channel);
}

fn susan_reply(expires_at: &str) -> Vec<u8> {
    format!(
        r#"{{"push_key":"{}","key_id":"k1","expires_at":"{expires_at}"}}"#,
        "A".repeat(40)
    )
    .into_bytes()
}

#[test]
fn susan_key_reply_decodes_iso_timestamps() {
    for (text, seconds) in [
        ("2026-11-29T00:00:00Z", 1_795_910_400),
        ("2000-02-29T12:34:56Z", 951_827_696),
        ("2100-03-01T00:00:00Z", 4_107_542_400),
        ("2026-11-29T00:00:00.000000Z", 1_795_910_400),
    ] {
        let reply = PushRegistrationReply::decode_susan(&susan_reply(text), 1).expect(text);
        assert_eq!(reply.expires_at, seconds, "{text}");
        assert_eq!(reply.key_id, "k1");
    }
    for refused in [
        "2026-11-29T00:00:00+00:00",
        "2026-02-30T00:00:00Z",
        "2100-02-29T00:00:00Z",
        "2026-11-29 00:00:00Z",
        "2026-11-29T24:00:00Z",
        "2026-11-29T00:00:00.Z",
        "1969-12-31T23:59:59Z",
    ] {
        assert!(
            PushRegistrationReply::decode_susan(&susan_reply(refused), 1).is_err(),
            "{refused}"
        );
    }
    assert!(PushRegistrationReply::decode_susan(
        &susan_reply("2026-11-29T00:00:00Z"),
        1_795_910_400
    )
    .is_err());
    assert!(PushRegistrationReply::decode_susan(br#"{"push_key":"AAAAAAAAAAAAAAAAAAAA","key_id":"k","expires_at":"2026-11-29T00:00:00Z","extra":1}"#, 1).is_err());
    assert!(PushRegistrationReply::decode_susan(
        br#"{"push_key":"bad key!","key_id":"k","expires_at":"2026-11-29T00:00:00Z"}"#,
        1
    )
    .is_err());
}

#[hegel::test(test_cases = 128)]
fn arbitrary_susan_replies_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(512));
    let now = tc.draw(gs::default::<u64>());
    let _ = PushRegistrationReply::decode_susan(&bytes, now);
}

#[hegel::test(test_cases = 64)]
fn lock_never_unlocks_from_stale_or_failed_results(tc: TestCase) {
    let generated = tc.draw(gs::default::<u32>());
    let lock = AppLock::start(true, LockDelay::Immediate)
        .apply(LockEvent::Availability(LockAvailability::Available))
        .apply(LockEvent::UnlockRequested);
    assert_eq!(lock.phase, LockPhase::Authenticating);
    let stale_attempt = if generated == lock.attempt {
        generated.wrapping_add(1)
    } else {
        generated
    };
    let stale = lock.apply(LockEvent::UnlockFinished {
        attempt: stale_attempt,
        success: true,
    });
    assert_eq!(stale.phase, LockPhase::Authenticating);
    let failed = stale.apply(LockEvent::UnlockFinished {
        attempt: stale.attempt,
        success: false,
    });
    assert_eq!(failed.phase, LockPhase::Locked);
    assert!(failed.obscured());
}

#[test]
fn lock_relocks_after_elapsed_background_delay() {
    let lock = AppLock::start(false, LockDelay::OneMinute)
        .apply(LockEvent::Availability(LockAvailability::Available))
        .apply(LockEvent::Enable)
        .apply(LockEvent::Backgrounded(10))
        .apply(LockEvent::Foregrounded(60_010));
    assert_eq!(lock.phase, LockPhase::Locked);
}

#[hegel::test(test_cases = 64)]
fn snapshot_persistence_never_replaces_newer_data(tc: TestCase) {
    let old = tc.draw(gs::default::<u64>());
    let delta = u64::from(tc.draw(gs::default::<u16>()));
    let newer = old.saturating_add(delta);
    let store = MemoryStore::default();
    let cached =
        MachineSnapshot::new("control.example.test".into(), None, old, vec![]).expect("valid");
    let _ = mila_runtime::save_snapshot_if_newer(&store, None, cached.clone()).expect("save");
    let incoming =
        MachineSnapshot::new("control.example.test".into(), None, newer, vec![]).expect("valid");
    let selected = mila_runtime::save_snapshot_if_newer(&store, None, incoming).expect("save");
    assert_eq!(selected.saved_at, newer.max(old));
    let loaded = mila_runtime::load_snapshot(&store, "control.example.test", None)
        .expect("load")
        .expect("snapshot");
    assert_eq!(loaded.saved_at, newer.max(old));
}

#[test]
fn snapshot_store_rejects_cross_deployment_bytes() {
    let store = MemoryStore::default();
    let snapshot =
        MachineSnapshot::new("control.example.test".into(), None, 1, vec![]).expect("valid");
    let bytes = snapshot.encode().expect("encode");
    *store.bytes.borrow_mut() = Some(bytes);
    assert_eq!(
        mila_runtime::load_snapshot(&store, "other.example.test", None),
        Err(RuntimeError::InvalidSnapshot)
    );
}

#[expect(
    clippy::expect_used,
    reason = "integration-test helper outside #[test]; every generated suffix formats a valid request id"
)]
fn request_id(suffix: u64) -> RequestId {
    RequestId::parse(&format!("porsche-{suffix:032x}")).expect("request id")
}

#[expect(
    clippy::expect_used,
    reason = "integration-test helper outside #[test]; the formatted value is a canonical UUID"
)]
fn operation(value: u32) -> mila_model::Identifier {
    mila_model::Identifier::parse(&format!("{value:08x}-0000-4000-8000-000000000000"))
        .expect("identifier")
}

fn receipt(id: RequestId, status: ReceiptStatus, operation_id: Option<u32>) -> Reply {
    Reply::Receipt(Receipt {
        version: 1,
        request_id: id,
        status,
        operation_id: operation_id.map(operation),
        result: serde_json::Value::Null,
    })
}

const STATUSES: [ReceiptStatus; 4] = [
    ReceiptStatus::Accepted,
    ReceiptStatus::Succeeded,
    ReceiptStatus::Failed,
    ReceiptStatus::Superseded,
];

/// Independent receipt-status-to-phase table.
fn phase_for(status: ReceiptStatus) -> MutationPhase {
    match status {
        ReceiptStatus::Accepted => MutationPhase::Accepted,
        ReceiptStatus::Succeeded => MutationPhase::Succeeded,
        ReceiptStatus::Failed | ReceiptStatus::Superseded => MutationPhase::Failed,
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-runtime-observe-mismatch
/// A receipt for another request id, or one that changes an already observed
/// operation id, MUST be refused with the matching error and leave the tracker
/// unchanged; a matching receipt MUST keep the request id and take the phase of
/// its status; a terminal tracker MUST absorb every later reply unchanged.
#[hegel::test(test_cases = 256)]
fn mutation_observe_refuses_mismatched_receipts(tc: TestCase) {
    let own = tc.draw(gs::default::<u64>());
    let other = tc.draw(gs::default::<u64>());
    let mut tracker = MutationTracker::submitted(request_id(own));
    let first = tc.draw(gs::booleans());
    let first_operation = tc.draw(gs::integers::<u32>().max_value(3));
    if first {
        tracker
            .observe(receipt(
                request_id(own),
                ReceiptStatus::Accepted,
                Some(first_operation),
            ))
            .expect("first receipt");
        assert_eq!(tracker.phase, MutationPhase::Accepted);
    }
    let status = tc.draw(gs::sampled_from(STATUSES.to_vec()));
    let operation_id = tc.draw(gs::integers::<u32>().max_value(3));
    let carries_operation = tc.draw(gs::booleans());
    let target = if tc.draw(gs::booleans()) { other } else { own };
    let before = tracker.clone();
    let result = tracker.observe(receipt(
        request_id(target),
        status,
        carries_operation.then_some(operation_id),
    ));
    if target != own {
        assert_eq!(result, Err(RuntimeError::RequestMismatch));
        assert_eq!(tracker, before);
    } else if first && carries_operation && operation_id != first_operation {
        assert_eq!(result, Err(RuntimeError::OperationMismatch));
        assert_eq!(tracker, before);
    } else {
        assert_eq!(result, Ok(()));
        assert_eq!(tracker.request_id, request_id(own));
        assert_eq!(tracker.phase, phase_for(status));
        assert_eq!(
            tracker.operation_id,
            carries_operation.then(|| operation(operation_id).to_string())
        );
    }
    if tracker.phase.terminal() {
        let settled = tracker.clone();
        let late = match tc.draw(gs::integers::<u8>().max_value(2)) {
            0 => receipt(request_id(other), status, Some(operation_id)),
            1 => Reply::Error {
                error: "late".into(),
                message: None,
            },
            _ => Reply::Read(serde_json::Value::Null),
        };
        assert_eq!(tracker.observe(late), Ok(()));
        assert_eq!(tracker.polled(), Ok(()));
        tracker.uncertain();
        assert_eq!(tracker, settled);
        assert_eq!(tracker.next_action(), NextAction::Done);
    }
}

/// Scripted backend outcome for one submit or poll.
#[derive(Clone, Copy, Debug)]
enum Scripted {
    Status(ReceiptStatus),
    Refusal,
    Read,
    BackendFailure,
}

#[derive(Debug)]
struct ScriptedBackend {
    script: Vec<Scripted>,
    submits: Vec<MutationRequest>,
    polls: Vec<RequestId>,
}

impl ScriptedBackend {
    fn next(&mut self, id: &RequestId) -> Result<Reply, ()> {
        let step = if self.script.is_empty() {
            Scripted::Read
        } else {
            self.script.remove(0)
        };
        match step {
            Scripted::Status(status) => Ok(receipt(id.clone(), status, None)),
            Scripted::Refusal => Ok(Reply::Error {
                error: "refused".into(),
                message: None,
            }),
            Scripted::Read => Ok(Reply::Read(serde_json::Value::Null)),
            Scripted::BackendFailure => Err(()),
        }
    }
}

impl SessionBackend for ScriptedBackend {
    type Error = ();
    fn submit(&mut self, request: &MutationRequest) -> Result<Reply, ()> {
        self.submits.push(request.clone());
        self.next(&request.request_id)
    }
    fn poll(&mut self, request_id: &RequestId) -> Result<Reply, ()> {
        self.polls.push(request_id.clone());
        self.next(request_id)
    }
}

fn scripted(tc: &TestCase) -> Scripted {
    match tc.draw(gs::integers::<u8>().max_value(6)) {
        0..=3 => Scripted::Status(tc.draw(gs::sampled_from(STATUSES.to_vec()))),
        4 => Scripted::Refusal,
        5 => Scripted::Read,
        _ => Scripted::BackendFailure,
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-runtime-session-submit-once
/// `SessionRuntime` MUST accept only commands of 1..=`MAX_COMMAND_BYTES` bytes,
/// refuse polling before submission, submit at most once whatever the backend
/// returns, poll only the original request id, and stop calling the backend
/// once the tracker is terminal.
#[hegel::test(test_cases = 256)]
fn session_runtime_submits_once_and_polls_the_original_id(tc: TestCase) {
    let length = tc.draw(gs::integers::<usize>().max_value(mila_protocol::MAX_COMMAND_BYTES + 2));
    let id = request_id(tc.draw(gs::default::<u64>()));
    let created = SessionRuntime::new(id.clone(), "a".repeat(length));
    if length == 0 || length > mila_protocol::MAX_COMMAND_BYTES {
        assert_eq!(created, Err(RuntimeError::InvalidCommand));
        return;
    }
    let mut runtime = created.expect("bounded command");
    let steps = tc.draw(gs::integers::<usize>().max_value(8));
    let mut backend = ScriptedBackend {
        script: (0..=steps).map(|_| scripted(&tc)).collect(),
        submits: Vec::new(),
        polls: Vec::new(),
    };
    if tc.draw(gs::booleans()) {
        assert_eq!(runtime.poll(&mut backend), Err(RuntimeError::NotSubmitted));
        assert_eq!(backend.polls, Vec::<RequestId>::new());
    }
    let submitted = runtime.submit(&mut backend);
    assert_eq!(backend.submits.len(), 1);
    assert_eq!(backend.submits[0].request_id, id);
    assert_eq!(backend.submits[0].command.len(), length);
    if submitted == Err(RuntimeError::Backend) {
        assert_eq!(runtime.tracker().phase, MutationPhase::Submitted);
    }
    for _ in 0..steps {
        let terminal = runtime.tracker().phase.terminal();
        let polls = backend.polls.len();
        let result = runtime.poll(&mut backend);
        if terminal {
            assert_eq!(result, Ok(NextAction::Done));
            assert_eq!(backend.polls.len(), polls);
        } else {
            assert_eq!(backend.polls.len(), polls + 1);
        }
        assert_eq!(
            runtime.submit(&mut backend),
            Err(RuntimeError::AlreadySubmitted)
        );
    }
    assert_eq!(backend.submits.len(), 1);
    assert!(backend.polls.iter().all(|polled| polled == &id));
    assert_eq!(runtime.tracker().request_id, id);
}

/// App lock model under arbitrary event sequences. Each rule applies one event,
/// records it, and checks the transition against the previous state.
struct LockMachine {
    lock: AppLock,
    history: Vec<LockEvent>,
}

impl LockMachine {
    fn step(&mut self, event: LockEvent) {
        let before = self.lock;
        let after = before.apply(event);
        self.history.push(event);
        let history = &self.history;
        let unlocking = matches!(
            event,
            LockEvent::UnlockFinished { attempt, success: true }
                if attempt == before.attempt && before.phase == LockPhase::Authenticating
        );
        let unavailable = event == LockEvent::Availability(LockAvailability::Unavailable);
        if before.phase != LockPhase::Unlocked && after.phase == LockPhase::Unlocked {
            assert!(unlocking || unavailable, "unlocked by {history:?}");
        }
        if after.phase == LockPhase::Authenticating && before.phase != LockPhase::Authenticating {
            assert_eq!(event, LockEvent::UnlockRequested, "{history:?}");
            assert_eq!(before.phase, LockPhase::Locked, "{history:?}");
            assert_eq!(
                before.availability,
                LockAvailability::Available,
                "{history:?}"
            );
            assert_eq!(
                after.attempt,
                before.attempt.saturating_add(1),
                "{history:?}"
            );
        } else {
            assert_eq!(after.attempt, before.attempt, "{history:?}");
        }
        if after.enabled != before.enabled || after.delay != before.delay {
            assert_eq!(before.phase, LockPhase::Unlocked, "{history:?}");
        }
        if after.enabled && !before.enabled {
            assert_eq!(
                before.availability,
                LockAvailability::Available,
                "{history:?}"
            );
        }
        if let LockEvent::UnlockFinished { attempt, .. } = event {
            if attempt != before.attempt || before.phase != LockPhase::Authenticating {
                assert_eq!(after, before, "stale result changed {history:?}");
            }
        }
        if before.phase == LockPhase::Authenticating
            && matches!(
                event,
                LockEvent::Backgrounded(_) | LockEvent::Foregrounded(_)
            )
        {
            assert_eq!(after, before, "{history:?}");
        }
        if matches!(event, LockEvent::Backgrounded(_))
            && before.phase != LockPhase::Authenticating
            && before.effective()
            && before.delay == LockDelay::Immediate
        {
            assert_eq!(after.phase, LockPhase::Locked, "{history:?}");
        }
        self.lock = after;
    }

    fn attempt(&self, tc: &TestCase) -> u32 {
        if tc.draw(gs::booleans()) {
            self.lock.attempt
        } else {
            tc.draw(gs::integers::<u32>().max_value(4))
        }
    }
}

fn delay(tc: &TestCase) -> LockDelay {
    tc.draw(gs::sampled_from(vec![
        LockDelay::Immediate,
        LockDelay::OneMinute,
        LockDelay::FiveMinutes,
    ]))
}

#[hegel::state_machine]
impl LockMachine {
    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn availability(&mut self, tc: TestCase) {
        let availability = tc.draw(gs::sampled_from(vec![
            LockAvailability::Unknown,
            LockAvailability::Available,
            LockAvailability::Unavailable,
        ]));
        self.step(LockEvent::Availability(availability));
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn settings(&mut self, tc: TestCase) {
        let event = match tc.draw(gs::integers::<u8>().max_value(2)) {
            0 => LockEvent::Enable,
            1 => LockEvent::Disable,
            _ => LockEvent::Delay(delay(&tc)),
        };
        self.step(event);
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn lifecycle(&mut self, tc: TestCase) {
        let at = tc.draw(gs::integers::<u64>().max_value(1_000_000));
        let event = if tc.draw(gs::booleans()) {
            LockEvent::Backgrounded(at)
        } else {
            LockEvent::Foregrounded(at)
        };
        self.step(event);
    }

    #[rule]
    fn unlock_requested(&mut self, _: TestCase) {
        self.step(LockEvent::UnlockRequested);
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn unlock_finished(&mut self, tc: TestCase) {
        let attempt = self.attempt(&tc);
        let success = tc.draw(gs::booleans());
        self.step(LockEvent::UnlockFinished { attempt, success });
    }

    #[invariant]
    fn presentation_is_fail_closed(&self, _: TestCase) {
        let lock = self.lock;
        let history = &self.history;
        assert_eq!(lock.obscured(), lock.phase != LockPhase::Unlocked);
        if !lock.enabled {
            assert_eq!(lock.phase, LockPhase::Unlocked, "{history:?}");
        }
        if lock.availability == LockAvailability::Unavailable {
            assert_eq!(lock.phase, LockPhase::Unlocked, "{history:?}");
            assert!(!lock.last_failed, "{history:?}");
        }
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-runtime-app-lock-model
/// Under arbitrary event histories the app lock MUST leave a locked or
/// authenticating phase only through a current successful unlock or platform
/// unavailability, enter authentication only from Locked with an available
/// authenticator (incrementing the attempt), change settings only while
/// unlocked, ignore stale results and lifecycle events while authenticating,
/// lock immediately on background when effective with no delay, and stay
/// unlocked while disabled or unavailable.
#[hegel::test(test_cases = 128)]
fn app_lock_event_histories_preserve_the_lock_model(tc: TestCase) {
    let enabled = tc.draw(gs::booleans());
    let machine = LockMachine {
        lock: AppLock::start(enabled, delay(&tc)),
        history: Vec::new(),
    };
    hegel::stateful::run(machine, tc);
}

const MONTH_DAYS: [u64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

fn leap_years_through(year: u64) -> u64 {
    year / 4 - year / 100 + year / 400
}

fn is_leap(year: u64) -> bool {
    leap_years_through(year) != leap_years_through(year - 1)
}

/// Independent civil-time oracle: whole years, then whole months, then days.
fn unix_seconds(fields: [u64; 6]) -> Option<u64> {
    let [year, month, day, hour, minute, second] = fields;
    if !(1970..=9999).contains(&year) || !(1..=12).contains(&month) {
        return None;
    }
    let index = usize::try_from(month - 1).ok()?;
    let length = MONTH_DAYS[index] + u64::from(month == 2 && is_leap(year));
    if day == 0 || day > length || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let leap_days = leap_years_through(year - 1) - leap_years_through(1969);
    let month_days: u64 =
        MONTH_DAYS[..index].iter().sum::<u64>() + u64::from(month > 2 && is_leap(year));
    let days = (year - 1970) * 365 + leap_days + month_days + day - 1;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-runtime-utc-timestamp-oracle
/// Susan's `expires_at` MUST decode to the Unix seconds an independent civil
/// calendar computes for every valid `YYYY-MM-DDTHH:MM:SS[.digits]Z` of at most
/// 32 bytes from 1970 to 9999, and every out-of-range field, empty fraction or
/// over-long value MUST refuse the reply.
#[hegel::test(test_cases = 512)]
fn susan_timestamps_agree_with_a_civil_calendar(tc: TestCase) {
    let fields = [
        tc.draw(gs::integers::<u64>().min_value(1960).max_value(9999)),
        tc.draw(gs::integers::<u64>().max_value(13)),
        tc.draw(gs::integers::<u64>().max_value(32)),
        tc.draw(gs::integers::<u64>().max_value(24)),
        tc.draw(gs::integers::<u64>().max_value(60)),
        tc.draw(gs::integers::<u64>().max_value(60)),
    ];
    let digits = tc.draw(gs::integers::<usize>().max_value(14));
    let dotted = digits > 0 || tc.draw(gs::booleans());
    let [year, month, day, hour, minute, second] = fields;
    let fraction = if dotted {
        format!(".{}", "7".repeat(digits))
    } else {
        String::new()
    };
    let text =
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}{fraction}Z");
    let fraction_valid = !dotted || digits > 0;
    let expected = unix_seconds(fields)
        .filter(|_| fraction_valid && text.len() <= 32)
        .filter(|seconds| *seconds > 0);
    let decoded = PushRegistrationReply::decode_susan(&susan_reply(&text), 0)
        .ok()
        .map(|reply| reply.expires_at);
    assert_eq!(decoded, expected, "{text}");
}

/// A length at, just inside or just outside `low..=high`, or anywhere below `high + 8`.
fn boundary_length(tc: &TestCase, low: usize, high: usize) -> usize {
    if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(vec![
            0,
            low - 1,
            low,
            low + 1,
            high - 1,
            high,
            high + 1,
        ]))
    } else {
        tc.draw(gs::integers::<usize>().max_value(high + 8))
    }
}

fn registration(
    provider: PushProvider,
    token: &str,
    environment: PushEnvironment,
    deployment: &str,
    endpoint: Option<String>,
) -> bool {
    PushRegistrationRequest::new(
        provider,
        token.into(),
        "dev.overalls.mila".into(),
        environment,
        deployment.into(),
        endpoint,
    )
    .is_ok()
}

/// @cc [owner:ghuntley,label:verification;security] mila-runtime-provider-token-lattice
/// APNs tokens MUST be 32..=200 lower-case hex digits and FCM tokens 32..=512
/// bytes of `[A-Za-z0-9_:-]`; only APNs may use the development environment,
/// and neither may carry an endpoint.
#[hegel::test(test_cases = 256)]
fn apns_and_fcm_tokens_follow_the_provider_lattice(tc: TestCase) {
    let apns = tc.draw(gs::booleans());
    let (alphabet, low, high) = if apns {
        ("0123456789abcdefABCDEFg", 32, 200)
    } else {
        ("aZ09_:-+/.", 32, 512)
    };
    let length = boundary_length(&tc, low, high);
    let token = if tc.draw(gs::booleans()) {
        tc.draw(
            gs::text()
                .alphabet(alphabet)
                .min_size(length)
                .max_size(length),
        )
    } else {
        "a".repeat(length)
    };
    let development = tc.draw(gs::booleans());
    let endpoint = tc.draw(gs::booleans());
    let shape = if apns {
        (32..=200).contains(&token.len())
            && token.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
    } else {
        (32..=512).contains(&token.len())
            && token
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '-'))
    };
    let expected = shape && (apns || !development) && !endpoint;
    let provider = if apns {
        PushProvider::Apns
    } else {
        PushProvider::Fcm
    };
    let environment = if development {
        PushEnvironment::Development
    } else {
        PushEnvironment::Production
    };
    let accepted = registration(
        provider,
        &token,
        environment,
        "mila.example.test",
        endpoint.then(|| token.clone()),
    );
    assert_eq!(accepted, expected, "apns={apns} len={}", token.len());
}

fn dns_label_valid(label: &str) -> bool {
    (1..=63).contains(&label.len())
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .chars()
            .all(|c| matches!(c, 'a'..='z' | '0'..='9' | '-'))
}

/// A lower-case label of boundary-biased length; one case in four substitutes one byte.
fn dns_label(tc: &TestCase) -> String {
    let length = boundary_length(tc, 1, 63);
    let mut label: Vec<char> = "a".repeat(length).chars().collect();
    if !label.is_empty() && tc.draw(gs::integers::<u8>().max_value(3)) == 0 {
        let index = tc.draw(gs::integers::<usize>().max_value(label.len() - 1));
        label[index] = tc.draw(gs::sampled_from(vec!['-', 'A', '_', '0', 'z', '.']));
    }
    label.into_iter().collect()
}

/// One or more valid labels followed by the `notify.windows.com` labels.
fn host_under_notify(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    labels.len() > 3
        && labels.ends_with(&["notify", "windows", "com"])
        && labels.iter().all(|label| dns_label_valid(label))
}

/// @cc [owner:ghuntley,label:verification;security] mila-runtime-wns-channel-lattice
/// A WNS registration MUST be accepted exactly when the token is an HTTPS URL
/// on the implicit port whose host is one or more valid lower-case DNS labels
/// under `.notify.windows.com`, whose path is non-empty and free of space,
/// backslash, `#`, `@` and `%00`, of at most 1024 bytes, in the production
/// environment, with an identical endpoint.
#[hegel::test(test_cases = 512)]
fn wns_channels_follow_the_susan_lattice(tc: TestCase) {
    // At most one structural fault per case keeps accepted channels frequent.
    let fault = tc.draw(gs::integers::<u8>().max_value(10));
    let scheme = if fault == 1 {
        tc.draw(gs::sampled_from(vec!["http://", "HTTPS://", "https:/"]))
    } else {
        "https://"
    };
    let suffix = if fault == 2 {
        tc.draw(gs::sampled_from(vec![
            ".notify.windows.com.evil.example",
            "notify.windows.com",
            ".notify.windows.co",
        ]))
    } else {
        ".notify.windows.com"
    };
    let port = if fault == 3 {
        tc.draw(gs::sampled_from(vec![":443", ":8443"]))
    } else {
        ""
    };
    let slash = fault != 4;
    let mismatch = fault == 5;
    let development = fault == 6;
    let count = tc.draw(gs::integers::<usize>().max_value(3));
    let labels: Vec<String> = (0..count).map(|_| dns_label(&tc)).collect();
    let prefix = labels.join(".");
    let mut path = tc.draw(gs::text().alphabet("az09%?=/").max_size(16));
    if fault == 7 {
        let bad = tc.draw(gs::sampled_from(vec![" ", "\\", "#", "@", "%00"]));
        let index = tc.draw(gs::integers::<usize>().max_value(path.len()));
        path.insert_str(index, bad);
    }
    let head = format!("{scheme}{prefix}{suffix}{port}/");
    if tc.draw(gs::booleans()) {
        let target = tc.draw(gs::sampled_from(vec![1_023_usize, 1_024, 1_025, 1_100]));
        let padding = target.saturating_sub(head.len() + path.len());
        path.push_str(&"a".repeat(padding));
    }
    let channel = if slash {
        format!("{head}{path}")
    } else {
        format!("{scheme}{prefix}{suffix}{port}")
    };
    let shape = scheme == "https://"
        && port.is_empty()
        && host_under_notify(&format!("{prefix}{suffix}"))
        && slash
        && !path.is_empty()
        && !path.contains([' ', '\\', '#', '@'])
        && !path.contains("%00")
        && channel.len() <= 1024;
    let endpoint = if mismatch {
        format!("{channel}x")
    } else {
        channel.clone()
    };
    let environment = if development {
        PushEnvironment::Development
    } else {
        PushEnvironment::Production
    };
    let accepted = registration(
        PushProvider::Wns,
        &channel,
        environment,
        "mila.example.test",
        Some(endpoint),
    );
    assert_eq!(accepted, shape && !mismatch && !development, "{channel}");
}

/// @cc [owner:ghuntley,label:verification;security] mila-runtime-deployment-host
/// Snapshot, push registration and poke deployments MUST accept exactly the
/// non-empty hosts of at most 253 bytes whose dot-separated labels are 1..=63
/// lower-case letters, digits or interior hyphens.
#[hegel::test(test_cases = 256)]
fn deployment_hosts_follow_the_dns_lattice(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().max_value(5));
    let labels: Vec<String> = (0..count).map(|_| dns_label(&tc)).collect();
    let mut host = labels.join(".");
    if tc.draw(gs::booleans()) {
        // Pad with whole valid labels towards the 253-byte bound.
        let target = tc.draw(gs::sampled_from(vec![252_usize, 253, 254, 300]));
        while host.len() < target {
            let room = target - host.len() - usize::from(!host.is_empty());
            let label = "b".repeat(room.clamp(1, 63));
            if !host.is_empty() {
                host.push('.');
            }
            host.push_str(&label);
        }
    }
    let expected = !host.is_empty() && host.len() <= 253 && host.split('.').all(dns_label_valid);
    let snapshot = MachineSnapshot::new(host.clone(), None, 1, vec![]);
    assert_eq!(snapshot.is_ok(), expected, "{host}");
    if !expected {
        assert_eq!(snapshot, Err(RuntimeError::InvalidSnapshot));
    }
    assert_eq!(
        registration(
            PushProvider::Apns,
            &"a".repeat(64),
            PushEnvironment::Production,
            &host,
            None,
        ),
        expected,
        "{host}"
    );
    let poke = PokeEnvelope {
        deployment: host.clone(),
        push_key: "A".repeat(16),
        delivery_id: "d".into(),
        collapse_id: "c".into(),
        kind: "machine".into(),
        issued_at: 1_000,
        nonce: "n".into(),
        ciphertext: "QQ".into(),
    };
    assert_eq!(poke.validate(1_000).is_ok(), expected, "{host}");
}
