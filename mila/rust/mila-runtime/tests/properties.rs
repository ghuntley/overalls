use hegel::{generators as gs, TestCase};
use mila_model::RequestId;
use mila_runtime::{
    AppLock, LockAvailability, LockDelay, LockEvent, LockPhase, MachineSnapshot, SnapshotMachine,
    MAX_SNAPSHOT_BYTES,
};
use mila_runtime::{AttachHeader, AttachMode};
use mila_runtime::{AttachOutcome, AttachPhase, TerminalAttach};
use mila_runtime::{MutationPhase, MutationTracker, NextAction};
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
    if let Ok(reply) = mila_runtime::PushRegistrationReply::new(push_key, key_id, expires, now) {
        assert!(reply.expires_at > now);
        assert!((16..=700).contains(&reply.push_key.len()));
        assert!(!reply.key_id.is_empty());
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
    let delta = tc.draw(gs::default::<u16>()) as u64;
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
