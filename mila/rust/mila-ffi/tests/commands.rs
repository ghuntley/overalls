use hegel::{generators as gs, TestCase};
use mila_ffi::{mila_session_command_format, MilaFfiStatus, MilaRouteOutput};
use std::ffi::CString;

const MACHINE: &str = "123e4567-e89b-12d3-a456-426614174000";
const REQUEST: &str = "porsche-0123456789abcdef0123456789abcdef";
const ACTIONS: [&str; 9] = [
    "show", "start", "stop", "pause", "resume", "unpause", "pin", "unpin", "rm",
];

#[expect(
    clippy::unwrap_used,
    reason = "integration-test helper outside #[test]; a failed fixture must abort the calling test"
)]
fn invoke(action: &str, request: Option<&str>, capacity: usize) -> (MilaFfiStatus, Vec<u8>, usize) {
    let action = CString::new(action).unwrap();
    let machine = CString::new(MACHINE).unwrap();
    let request = request.map(|s| CString::new(s).unwrap());
    let mut buffer = vec![0xa5; capacity + 8];
    let mut written = usize::MAX;
    // SAFETY: all C strings and the caller-owned buffer remain live throughout the call.
    let status = unsafe {
        mila_session_command_format(
            action.as_ptr(),
            machine.as_ptr(),
            request.as_ref().map_or(std::ptr::null(), |r| r.as_ptr()),
            MilaRouteOutput {
                bytes: buffer.as_mut_ptr(),
                capacity,
                written: &raw mut written,
            },
        )
    };
    assert!(buffer[capacity..].iter().all(|b| *b == 0xa5));
    (status, buffer, written)
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-command-format-capacity
/// Every catalogued machine action MUST format to its canonical line within the
/// caller's capacity, leave the buffer and `written` untouched when it is too
/// small, and require a request id for mutations.
#[hegel::test(test_cases = 128)]
fn commands_require_identity_and_respect_capacity(tc: TestCase) {
    let action = ACTIONS[usize::from(tc.draw(gs::default::<u8>())) % ACTIONS.len()];
    let capacity = usize::from(tc.draw(gs::default::<u8>()));
    let expected = if action == "show" {
        format!("show {MACHINE} --json")
    } else {
        format!("{action} {MACHINE} --json --request-id={REQUEST}")
    };
    let (status, bytes, written) = invoke(action, Some(REQUEST), capacity);
    if capacity < expected.len() {
        assert_eq!(status, MilaFfiStatus::OutputTooSmall);
        assert_eq!(written, usize::MAX);
        assert!(bytes.iter().all(|b| *b == 0xa5));
    } else {
        assert_eq!(status, MilaFfiStatus::Ok);
        assert_eq!(written, expected.len());
        assert_eq!(&bytes[..written], expected.as_bytes());
    }
    if action != "show" {
        assert_eq!(invoke(action, None, 256).0, MilaFfiStatus::InvalidRequest);
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-command-format-injection
/// An action token carrying whitespace or option text MUST be refused without
/// writing caller storage.
#[hegel::test(test_cases = 128)]
fn action_tokens_cannot_inject_options(tc: TestCase) {
    let action = ACTIONS[usize::from(tc.draw(gs::default::<u8>())) % ACTIONS.len()];
    for suffix in [
        " --json",
        " --request-id=porsche-0123456789abcdef0123456789abcdef",
        "\t",
        " ",
    ] {
        let (status, bytes, written) = invoke(&format!("{action}{suffix}"), None, 256);
        assert_eq!(status, MilaFfiStatus::InvalidRequest);
        assert_eq!(written, usize::MAX);
        assert!(bytes.iter().all(|b| *b == 0xa5));
    }
}
