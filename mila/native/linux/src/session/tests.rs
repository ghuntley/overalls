// See the `linux-complete-machine-read` contract.
#[test]
fn complete_machine_read_follows_pages_and_refuses_failed_continuation() {
    use super::connection::complete_machine_pages;
    let first = br#"{"machines":[{}],"has_more":true}"#;
    let complete = br#"{"machines":[{},{}],"has_more":false}"#;
    let mut calls = Vec::new();
    let result = complete_machine_pages(|more| {
        calls.push(more);
        Ok(if more {
            complete.to_vec()
        } else {
            first.to_vec()
        })
    });
    assert_eq!(result, Ok(complete.to_vec()));
    assert_eq!(calls, vec![false, true]);
    let result = complete_machine_pages(|more| {
        if more {
            Err(SessionError::Transport)
        } else {
            Ok(first.to_vec())
        }
    });
    assert_eq!(result, Err(SessionError::Transport));
}

#[test]
fn complete_machine_read_refuses_invalid_or_unbounded_pages() {
    use super::connection::complete_machine_pages;
    for bytes in [
        br#"{"machines":[]}"#.as_slice(),
        br#"{"machines":[],"has_more":"false"}"#.as_slice(),
        br#"{"machines":{},"has_more":false}"#.as_slice(),
    ] {
        assert_eq!(
            complete_machine_pages(|_| Ok(bytes.to_vec())),
            Err(SessionError::InvalidInput)
        );
    }
    let oversized = format!(
        r#"{{"machines":[{}],"has_more":false}}"#,
        vec!["{}"; 501].join(",")
    );
    assert_eq!(
        complete_machine_pages(|_| Ok(oversized.as_bytes().to_vec())),
        Err(SessionError::InvalidInput)
    );
    let mut calls = 0;
    let result = complete_machine_pages(|_| {
        calls += 1;
        Ok(br#"{"machines":[],"has_more":true}"#.to_vec())
    });
    assert_eq!(result, Err(SessionError::InvalidInput));
    assert_eq!(calls, 500);
}

// See the `linux-session-terminal-end` contract.
#[test]
fn terminal_end_requires_marshall_to_close_that_exact_session() {
    let closed = br#"{"version":1,"status":"succeeded","result":{"machine_id":"m","session_id":"s-1","closed":true}}"#;
    assert!(terminal_closed(closed, "s-1"));
    assert!(!terminal_closed(closed, "s-2"));
    let open =
        br#"{"version":1,"status":"succeeded","result":{"session_id":"s-1","closed":false}}"#;
    assert!(!terminal_closed(open, "s-1"));
    let refused = br#"{"version":1,"status":"refused","error":"forbidden"}"#;
    assert!(!terminal_closed(refused, "s-1"));
    assert!(!terminal_closed(b"", "s-1"));
}

#[test]
fn output_is_copied_with_exactly_one_ffi_call() {
    use mila_ffi::session::SessionStatus;
    let mut calls = 0;
    let bytes = copy_output(|out, capacity, written| {
        calls += 1;
        let data = b"{\"ok\":true}";
        assert!(capacity >= data.len());
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes,
        // checked above to hold `data`, which is a distinct static buffer.
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), out, data.len()) };
        // SAFETY: `copy_output` passes a writable `written` local.
        unsafe { *written = data.len() };
        SessionStatus::Ok
    })
    .unwrap();
    assert_eq!(calls, 1);
    assert_eq!(bytes, b"{\"ok\":true}");
    // A response over the bound fails without a second (re-executing) call.
    let mut calls = 0;
    let refused = copy_output(|_, capacity, written| {
        calls += 1;
        // SAFETY: `copy_output` passes a writable `written` local.
        unsafe { *written = capacity + 1 };
        SessionStatus::SmallBuffer
    });
    assert!(refused.is_err());
    assert_eq!(calls, 1);
}

use super::connection::parse_whoami;
use super::*;
use p256::ecdsa::Signature;
use std::cell::RefCell;
use std::fs;
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

struct MemoryStore {
    pinned: Option<Vec<u8>>,
    reads: Rc<RefCell<usize>>,
    writes: Rc<RefCell<Vec<Vec<u8>>>>,
}

impl TrustStore for MemoryStore {
    fn read(&self, _host: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
        *self.reads.borrow_mut() += 1;
        Ok(self.pinned.clone())
    }

    fn write(&self, _host: &str, document: &[u8]) -> Result<(), RuntimeError> {
        self.writes.borrow_mut().push(document.to_vec());
        Ok(())
    }
}

struct StaticFetcher {
    response: Result<Vec<u8>, RuntimeError>,
    calls: Rc<RefCell<usize>>,
}

impl TrustFetcher for StaticFetcher {
    fn fetch(&self, _host: &str) -> Result<Vec<u8>, RuntimeError> {
        *self.calls.borrow_mut() += 1;
        self.response.clone()
    }
}

struct CountingSigner {
    calls: Arc<AtomicUsize>,
}

#[test]
fn file_signer_requires_owner_only_key_and_verifies_signature() {
    use p256::ecdsa::signature::Verifier;
    use std::os::unix::fs::PermissionsExt;

    let path = std::env::temp_dir().join(format!(
        "mila-signer-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    fs::write(&path, [7_u8; 32]).expect("key");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");
    let signer = FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()).unwrap();
    let message = b"certificate challenge";
    let signature = signer.sign(message).unwrap();
    let parsed = Signature::from_slice(&signature).unwrap();
    signer.key.verifying_key().verify(message, &parsed).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).expect("permissions");
    assert!(matches!(
        FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()),
        Err(SignerError::InsecurePermissions)
    ));
    fs::remove_file(path).expect("cleanup");
}

impl DeviceSigner for CountingSigner {
    fn public_key(&self) -> &'static str {
        "ssh-test-public-key"
    }

    fn sign(&self, _message: &[u8]) -> Result<[u8; 64], RuntimeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok([0; 64])
    }
}

fn ca(index: usize) -> String {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../rust/mila-transport/tests/fixtures/ssh_host_certificates.json"
    ))
    .expect("certificate fixture");
    fixture["certificates"][index]["ca"]
        .as_str()
        .expect("certificate CA")
        .to_owned()
}

fn trust(ca: &str, retirement: u64) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "version": 1,
        "ca": ca,
        "management_host": "overalls.example",
        "zone": "apps.overalls.example",
        "retirement": retirement,
    }))
    .expect("trust document")
}

/// The coordinator under test plus its read, write and signer counters.
type CoordinatorHarness = (
    SignInCoordinator<CountingSigner, MemoryStore, StaticFetcher>,
    Rc<RefCell<usize>>,
    Rc<RefCell<Vec<Vec<u8>>>>,
    Arc<AtomicUsize>,
);

fn coordinator(
    pinned: Option<Vec<u8>>,
    response: Result<Vec<u8>, RuntimeError>,
) -> CoordinatorHarness {
    let reads = Rc::new(RefCell::new(0));
    let writes = Rc::new(RefCell::new(Vec::new()));
    let calls = Rc::new(RefCell::new(0));
    let signer_calls = Arc::new(AtomicUsize::new(0));
    (
        SignInCoordinator::new(
            CountingSigner {
                calls: signer_calls.clone(),
            },
            MemoryStore {
                pinned,
                reads,
                writes: writes.clone(),
            },
            StaticFetcher {
                response,
                calls: calls.clone(),
            },
        ),
        calls,
        writes,
        signer_calls,
    )
}

#[test]
fn coordinator_reconciles_fetched_trust_and_persists_canonical_bytes() {
    let pinned = trust(&ca(0), 2_000);
    let fetched = trust(&ca(0), 3_000);
    let (coordinator, fetch_calls, writes, _) = coordinator(Some(pinned), Ok(fetched));
    let config = coordinator
        .prepare_connect("overalls.example", 443, 30_000, 1_000)
        .expect("trust should reconcile");
    let selected: serde_json::Value =
        serde_json::from_slice(&config.trust_document).expect("canonical trust");
    assert_eq!(selected["retirement"], 3_000);
    assert_eq!(*fetch_calls.borrow(), 1);
    assert_eq!(writes.borrow().len(), 1);
    assert_eq!(writes.borrow()[0], config.trust_document);
}

#[test]
fn coordinator_uses_a_current_pin_when_fetch_is_unavailable() {
    let pinned = trust(&ca(0), 2_000);
    let (coordinator, fetch_calls, writes, _) =
        coordinator(Some(pinned.clone()), Err(RuntimeError::Unavailable));
    let config = coordinator
        .prepare_connect("overalls.example", 443, 30_000, 1_000)
        .expect("current pin should be usable");
    let selected: serde_json::Value =
        serde_json::from_slice(&config.trust_document).expect("canonical trust");
    assert_eq!(selected["retirement"], 2_000);
    assert_eq!(
        selected["ca"],
        serde_json::from_slice::<serde_json::Value>(&pinned).unwrap()["ca"]
    );
    assert_eq!(*fetch_calls.borrow(), 1);
    assert_eq!(writes.borrow().len(), 1);
    assert_eq!(writes.borrow()[0], config.trust_document);
}

#[test]
fn coordinator_refuses_malformed_or_conflicting_fetched_trust() {
    let malformed = coordinator(None, Ok(br#"{"version":1,"ca":"bad"}"#.to_vec())).0;
    assert_eq!(
        malformed
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .unwrap_err(),
        RuntimeError::InvalidInput
    );

    let conflicting = coordinator(Some(trust(&ca(0), 2_000)), Ok(trust(&ca(5), 3_000))).0;
    assert_eq!(
        conflicting
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .unwrap_err(),
        RuntimeError::InvalidInput
    );

    let malformed_fetch =
        coordinator(Some(trust(&ca(0), 2_000)), Err(RuntimeError::InvalidInput)).0;
    assert_eq!(
        malformed_fetch
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .unwrap_err(),
        RuntimeError::InvalidInput
    );
}

#[test]
fn invalid_endpoint_is_rejected_before_storage_fetch_or_signer() {
    let (coordinator, fetch_calls, writes, signer_calls) =
        coordinator(None, Err(RuntimeError::Unavailable));
    assert!(matches!(
        coordinator.connect("bad host", 443, 30_000, 1_000),
        Err(SessionError::InvalidInput)
    ));
    assert_eq!(*fetch_calls.borrow(), 0);
    assert!(writes.borrow().is_empty());
    assert_eq!(signer_calls.load(Ordering::SeqCst), 0);
}

#[test]
fn web_set_requires_positive_policy_revision() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(
        session.web_set(
            "01234567-89ab-cdef-0123-456789abcdef",
            8080,
            true,
            0,
            "porsche-0123456789abcdef0123456789abcdef",
        ),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn web_controls_require_an_authenticated_handle_and_bounded_request() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(
        session.web_show("bad machine"),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.web_set(
            "01234567-89ab-cdef-0123-456789abcdef",
            8080,
            true,
            7,
            "request-without-porsche-id"
        ),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.web_set(
            "01234567-89ab-cdef-0123-456789abcdef",
            8080,
            true,
            7,
            "porsche-0123456789abcdef0123456789abcdef"
        ),
        Err(SessionError::StaleHandle)
    );
}

#[test]
fn notification_device_controls_require_authenticated_session() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(session.device_list(), Err(SessionError::StaleHandle));
    assert_eq!(
        session.device_remove("bad device", "porsche-00000000000000000000000000000000"),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.device_preference(
            "device-id",
            false,
            "porsche-00000000000000000000000000000000"
        ),
        Err(SessionError::StaleHandle)
    );
}

#[test]
fn machine_actions_require_authenticated_session_and_canonical_request() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(
        session.machine_action(
            "01234567-89ab-cdef-0123-456789abcdef",
            "start",
            "porsche-00000000000000000000000000000000"
        ),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.machine_action(
            "01234567-89ab-cdef-0123-456789abcdef",
            "start",
            "porsche-00000000000000000000000000000000"
        ),
        Err(SessionError::Busy)
    );
    assert_eq!(
        session.machine_action(
            "01234567-89ab-cdef-0123-456789abcdef",
            "shell",
            "porsche-00000000000000000000000000000000"
        ),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn machine_create_rejects_unsafe_display_names_before_authentication() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    let request = "porsche-00000000000000000000000000000000";
    assert_eq!(
        session.machine_create("Builder\nEast", 2, 1024, 10, request),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.machine_create("Builder East", 2, 1024, 10, request),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.machine_create("Builder.East", 2, 1024, 10, request),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn machine_shape_bounds_match_shared_vm_disk_policy_before_authentication() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    let request = "porsche-00000000000000000000000000000000";
    let machine = "01234567-89ab-cdef-0123-456789abcdef";

    assert_eq!(
        session.machine_create("builder", 2, 256, 500, request),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.machine_create("builder", 2, 256, 501, request),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.machine_create("builder", 2, 255, 500, request),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.machine_resize(machine, 2, 4_194_304, 500, request),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.machine_resize(machine, 2, 4_194_304, 501, request),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.machine_resize(machine, 2, 255, 500, request),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn sharing_requires_authenticated_session_and_typed_role() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    let request = "porsche-00000000000000000000000000000000";
    assert_eq!(
        session.share_mutation(
            "01234567-89ab-cdef-0123-456789abcdef",
            "user@example.com",
            Some("viewer"),
            true,
            request,
        ),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.share_mutation(
            "01234567-89ab-cdef-0123-456789abcdef",
            "user@example.com",
            Some("owner"),
            true,
            request,
        ),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn thread_actions_require_authenticated_session_and_bounded_input() {
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(
        session.thread_action(None, "thread ls", None, None, None),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.thread_action(None, "thread arbitrary", None, None, None),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.thread_action(
            None,
            "thread ls",
            None,
            Some(&"x".repeat(64 * 1024 + 1)),
            None
        ),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.thread_action(
            Some("01234567-89ab-cdef-0123-456789abcdef"),
            "thread plan approve",
            None,
            None,
            None,
        ),
        Err(SessionError::InvalidInput)
    );

    // Native mutations must carry both the proposal/question identity and
    // a canonical Porsche request id before they can reach the FFI handle.
    let thread = "01234567-89ab-cdef-0123-456789abcdef";
    let plan = "fedcba98-7654-3210-fedc-ba9876543210";
    let request = "porsche-0123456789abcdef0123456789abcdef";
    assert_eq!(
        session.thread_action(
            Some(thread),
            "thread plan approve",
            Some(plan),
            None,
            Some("bad")
        ),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.thread_action(
            Some(thread),
            "thread answer",
            Some(plan),
            Some("{}"),
            Some(request)
        ),
        Err(SessionError::StaleHandle)
    );
    assert_eq!(
        session.thread_action(
            Some(thread),
            "thread answer",
            Some(plan),
            Some(&"x".repeat(64 * 1024 + 1)),
            Some(request)
        ),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn plan_commands_have_explicit_input_contract() {
    assert_eq!(
        LiveSession::validate_thread_plan_input("thread plan approve", None),
        Ok(())
    );
    assert_eq!(
        LiveSession::validate_thread_plan_input("thread plan approve", Some("unexpected")),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        LiveSession::validate_thread_plan_input("thread plan revise", Some("updated plan")),
        Ok(())
    );
    assert_eq!(
        LiveSession::validate_thread_plan_input("thread plan revise", Some("")),
        Err(SessionError::InvalidInput)
    );
    let request = "porsche-0123456789abcdef0123456789abcdef";
    assert_eq!(
        LiveSession::validate_thread_plan_input("thread plan approve", None),
        Ok(())
    );
    let mut session = LiveSession {
        handle: None,
        terminal: None,
        submitted_mutations: HashSet::new(),
        read_buffer: Vec::new(),
    };
    assert_eq!(
        session.thread_action(None, "thread prompt", None, Some("q"), Some(request)),
        Err(SessionError::InvalidInput)
    );
    assert_eq!(
        session.thread_action(
            Some("thread"),
            "thread answer",
            None,
            Some("a"),
            Some(request)
        ),
        Err(SessionError::InvalidInput)
    );
}

#[test]
fn approval_is_generation_bound_and_expires() {
    let flow = SignInFlow::default().apply(SignInEvent::Start);
    let generation = flow.generation;
    let flow = flow.apply(SignInEvent::Whoami {
        generation: generation + 1,
        outcome: WhoamiOutcome::Approval {
            url: "https://example.test/approve".into(),
            fingerprint: "SHA256:test".into(),
        },
        at: 1,
    });
    assert_eq!(flow.phase, SignInPhase::Connecting);
    let flow = flow.apply(SignInEvent::Whoami {
        generation,
        outcome: WhoamiOutcome::Approval {
            url: "https://example.test/approve".into(),
            fingerprint: "SHA256:test".into(),
        },
        at: 1,
    });
    assert_eq!(flow.phase, SignInPhase::AwaitingApproval);
    assert_eq!(
        flow.apply(SignInEvent::Tick(601)).phase,
        SignInPhase::Expired
    );
}
#[test]
fn sign_out_fences_late_approval_from_previous_generation() {
    let flow = SignInFlow::default().apply(SignInEvent::Start);
    let generation = flow.generation;
    let signed_out = flow.apply(SignInEvent::SignOut);
    let late = signed_out.apply(SignInEvent::Whoami {
        generation,
        outcome: WhoamiOutcome::Authenticated {
            account: "late@example.test".into(),
        },
        at: 1,
    });
    assert_eq!(late.phase, SignInPhase::SignedOut);
    assert_eq!(late.account, None);
    assert_eq!(late.generation, generation + 1);
}

#[test]
fn reconnect_after_disconnect_starts_fresh_generation() {
    let flow = SignInFlow::default().apply(SignInEvent::Start);
    let generation = flow.generation;
    let flow = flow
        .apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Authenticated {
                account: "operator@example.test".into(),
            },
            at: 1,
        })
        .apply(SignInEvent::Disconnected(generation));
    assert_eq!(flow.phase, SignInPhase::Disconnected);
    let flow = flow.apply(SignInEvent::Start);
    assert_eq!(
        (flow.phase, flow.generation),
        (SignInPhase::Connecting, generation + 1)
    );
}
#[test]
fn approval_url_validation_rejects_userinfo_and_non_https() {
    assert!(ApprovalInfo::validate("http://example.test/a", "fp", 0).is_err());
    assert!(ApprovalInfo::validate("https://user@example.test/a", "fp", 0).is_err());
    assert!(ApprovalInfo::validate("https://?approval", "fp", 0).is_err());
    assert!(ApprovalInfo::validate("https://:443/a", "fp", 0).is_err());
    assert!(ApprovalInfo::validate("https://example.test/a", "fp", 0).is_ok());
}

#[test]
fn approval_url_must_remain_on_selected_deployment() {
    assert!(ApprovalInfo::validate_for_host(
        "https://example.test/ssh/approve/a",
        "fp",
        0,
        "example.test"
    )
    .is_ok());
    assert!(ApprovalInfo::validate_for_host(
        "https://evil.example/ssh/approve/a",
        "fp",
        0,
        "example.test"
    )
    .is_err());
    assert!(ApprovalInfo::validate_for_host(
        "https://example.test.evil/ssh/approve/a",
        "fp",
        0,
        "example.test"
    )
    .is_err());
}

#[test]
fn approval_url_authority_includes_canonical_port() {
    let url = "https://localhost:8443/ssh/approve/a";
    assert!(ApprovalInfo::validate(url, "fp", 0).is_ok());
    assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost:8443").is_ok());
    assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost").is_err());
    assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost:9443").is_err());
    assert!(
        ApprovalInfo::validate_for_host("https://example.test:443/a", "fp", 0, "example.test")
            .is_ok()
    );
    for invalid in [
        "https://localhost:0/a",
        "https://localhost:08443/a",
        "https://localhost:65536/a",
        "https://localhost:/a",
        "https://localhost:8443:1/a",
    ] {
        assert!(
            ApprovalInfo::validate(invalid, "fp", 0).is_err(),
            "{invalid}"
        );
    }
}

#[test]
fn invalid_approval_payload_fails_closed_as_protocol_error() {
    let flow = SignInFlow::default().apply(SignInEvent::Start);
    let generation = flow.generation;
    let flow = flow.apply(SignInEvent::Whoami {
        generation,
        outcome: WhoamiOutcome::Approval {
            url: "http://example.test/approval".into(),
            fingerprint: "fp".into(),
        },
        at: 1,
    });
    assert_eq!(flow.phase, SignInPhase::Failed);
    assert_eq!(flow.failure, Some(SignInFailure::Protocol));
    assert!(flow.approval.is_none());
}

#[test]
fn unreachable_during_approval_fails_closed() {
    let flow = SignInFlow::default().apply(SignInEvent::Start);
    let generation = flow.generation;
    let flow = flow.apply(SignInEvent::Whoami {
        generation,
        outcome: WhoamiOutcome::Approval {
            url: "https://example.test/approval".into(),
            fingerprint: "SHA256:test".into(),
        },
        at: 1,
    });
    assert_eq!(flow.phase, SignInPhase::AwaitingApproval);
    let flow = flow.apply(SignInEvent::Unreachable(generation));
    assert_eq!(flow.phase, SignInPhase::Failed);
    assert_eq!(flow.failure, Some(SignInFailure::Unreachable));
    assert!(flow.approval.is_none());
}

#[test]
fn approval_fingerprint_rejects_control_and_whitespace() {
    assert!(ApprovalInfo::validate("https://example.test/a", "fp\n", 0).is_err());
    assert!(ApprovalInfo::validate("https://example.test/a", "fp value", 0).is_err());
    assert!(ApprovalInfo::validate("https://example.test/a", "SHA256:abc", 0).is_ok());
}

#[test]
fn session_identifier_rejects_every_ascii_control_and_whitespace_byte() {
    for byte in 0_u8..=0x20 {
        let value = format!("machine{}id", char::from(byte));
        assert!(validate_session_identifier(&value).is_err(), "byte {byte}");
    }
    assert!(validate_session_identifier(&"x".repeat(128)).is_ok());
    assert!(validate_session_identifier(&"x".repeat(129)).is_err());
}

#[test]
fn whoami_envelope_is_decoded_with_bounded_approval_fields() {
    let authenticated =
        parse_whoami(br#"{"version":1,"status":"authenticated","account":"alice@example.test"}"#)
            .expect("authenticated envelope");
    assert_eq!(
        authenticated,
        WhoamiOutcome::Authenticated {
            account: "alice@example.test".into()
        }
    );
    let approval = parse_whoami(
        br#"{"version":1,"status":"approval_required","url":"https://example.test/approve","fingerprint":"SHA256:test"}"#,
    )
    .expect("approval envelope");
    assert!(matches!(approval, WhoamiOutcome::Approval { .. }));
    // Porsche's own envelope: `succeeded` with the account in `result`,
    // and `approval_url` while the key is pending.
    assert_eq!(
        parse_whoami(
            br#"{"version":1,"status":"succeeded","result":{"id":"u1","email":"alice@example.test","public_key":"ecdsa-sha2-nistp256 AAAA"}}"#,
        ),
        Some(WhoamiOutcome::Authenticated {
            account: "alice@example.test".into()
        })
    );
    assert!(matches!(
        parse_whoami(
            br#"{"version":1,"status":"approval_required","approval_url":"https://example.test/ssh/approve/abc","fingerprint":"SHA256:test"}"#,
        ),
        Some(WhoamiOutcome::Approval { .. })
    ));
    assert!(parse_whoami(br#"{"version":1,"status":"succeeded","result":{}}"#).is_none());
    assert!(parse_whoami(br#"{"version":2,"status":"authenticated","account":"x"}"#).is_none());
    assert!(parse_whoami(br#"{"version":1,"status":"approval_required","url":"http://example.test","fingerprint":"x"}"#).is_none());
}

#[test]
fn curl_fetcher_rejects_invalid_authority_before_spawning_transport() {
    let fetcher = CurlTrustFetcher { timeout_seconds: 5 };
    assert_eq!(fetcher.fetch("bad host"), Err(RuntimeError::InvalidInput));
    assert_eq!(
        fetcher.fetch("example.test/path"),
        Err(RuntimeError::InvalidInput)
    );
}
