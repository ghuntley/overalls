use reqwest::blocking::Client;
use reqwest::header::{ACCEPT, CONTENT_TYPE};
use reqwest::{redirect::Policy, Method, StatusCode, Url};
use std::io::{self, Read};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RequestStage {
    Validation,
    Client,
    Send,
    Status,
    Body,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RequestFailure {
    pub stage: RequestStage,
    pub kind: io::ErrorKind,
}

impl RequestFailure {
    pub(crate) fn diagnostic_code(self) -> i32 {
        let stage = match self.stage {
            RequestStage::Validation => 0,
            RequestStage::Client => 1,
            RequestStage::Send => 2,
            RequestStage::Status => 3,
            RequestStage::Body => 4,
        };
        let kind = match self.kind {
            io::ErrorKind::TimedOut => 0,
            io::ErrorKind::UnexpectedEof => 1,
            io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::NotConnected => 2,
            io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput => 3,
            io::ErrorKind::PermissionDenied => 4,
            _ => 5,
        };
        80 + stage * 6 + kind
    }
}

struct Observation<'a> {
    expected: Option<StatusCode>,
    failed: &'a mut dyn FnMut(RequestFailure),
}

fn valid_https(url: &str) -> bool {
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    parsed.scheme() == "https"
        && parsed.host().is_some()
        && parsed.username().is_empty()
        && parsed.password().is_none()
        && parsed.fragment().is_none()
}

fn accepted_status(status: StatusCode, expected: Option<StatusCode>) -> bool {
    expected.map_or_else(|| status.is_success(), |required| status == required)
}

#[cfg(any(
    test,
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris"
))]
fn native_executor_url(url: &str) -> bool {
    valid_https(url)
        && Url::parse(url).is_ok_and(|parsed| {
            parsed.host_str() == Some("llm.internal")
                && parsed.port_or_known_default() == Some(443)
                && ((parsed.query().is_none()
                    && matches!(
                        parsed.path(),
                        "/agent/v1/register"
                            | "/agent/v1/heartbeat"
                            | "/agent/v1/claim"
                            | "/agent/v1/transition"
                            | "/agent/v1/maintenance/claim"
                            | "/agent/v1/maintenance/transition"
                    ))
                    || crate::agent::maintenance::artifact_url(&parsed))
        })
}

fn client(url: &str, timeout: Duration) -> io::Result<Client> {
    #[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
    if Url::parse(url).is_ok_and(|parsed| parsed.host_str() == Some("llm.internal")) {
        if !native_executor_url(url) {
            return Err(io::Error::other("invalid private executor request"));
        }
        return crate::private_http::executor_client(timeout);
    }
    #[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
    let _ = url;
    Client::builder()
        .use_rustls_tls()
        .no_proxy()
        .redirect(Policy::none())
        .connect_timeout(timeout)
        .timeout(timeout)
        .build()
        .map_err(|_| io::Error::other("HTTPS client unavailable"))
}

// @cc [owner:ghuntley,label:security] lyra-bounded-verified-https
// Private and public control fetches MUST verify HTTPS, ignore proxy settings,
// refuse redirects, enforce a deadline and cap bytes while streaming. Secret
// headers and response bodies MUST never enter process arguments or diagnostics.
pub fn request(
    url: &str,
    method: Method,
    body: Option<&[u8]>,
    bearer: Option<&str>,
    maximum: usize,
    timeout: Duration,
) -> io::Result<Vec<u8>> {
    request_observed(url, method, body, bearer, maximum, timeout, &mut |_| {})
}

// @cc [owner:ghuntley,label:security] lyra-closed-http-failure-observation
// Observation MUST contain only fixed stages and ErrorKind categories, never
// error text or request data. It MUST NOT alter request bounds or failure flow.
pub(crate) fn request_observed(
    url: &str,
    method: Method,
    body: Option<&[u8]>,
    bearer: Option<&str>,
    maximum: usize,
    timeout: Duration,
    failed: &mut impl FnMut(RequestFailure),
) -> io::Result<Vec<u8>> {
    request_with_status(
        url,
        method,
        body,
        bearer,
        maximum,
        timeout,
        Observation {
            expected: None,
            failed,
        },
    )
}

pub fn request_exact(
    url: &str,
    expected: StatusCode,
    maximum: usize,
    timeout: Duration,
) -> io::Result<Vec<u8>> {
    request_with_status(
        url,
        Method::GET,
        None,
        None,
        maximum,
        timeout,
        Observation {
            expected: Some(expected),
            failed: &mut |_| {},
        },
    )
}

/// Stream a verified, bounded artifact without retaining its complete body.
/// The caller's lease callback MUST remain true before each write.
pub fn download(
    url: &str,
    maximum: usize,
    destination: &mut impl io::Write,
    lease: &mut impl FnMut() -> bool,
) -> io::Result<usize> {
    if !valid_https(url) || maximum == 0 || !lease() {
        return Err(io::Error::other("invalid artifact request"));
    }
    let mut response = client(url, Duration::from_secs(10))?
        .get(url)
        .send()
        .map_err(|_| io::Error::other("artifact unavailable"))?;
    if response.status() != StatusCode::OK
        || response
            .content_length()
            .is_some_and(|length| length > maximum as u64)
    {
        return Err(io::Error::other("artifact unavailable"));
    }
    let mut bytes = 0usize;
    let mut buffer = [0u8; 65_536];
    loop {
        let count = response.read(&mut buffer)?;
        if count == 0 {
            return Ok(bytes);
        }
        bytes = bytes
            .checked_add(count)
            .filter(|total| *total <= maximum)
            .ok_or_else(|| io::Error::other("artifact too large"))?;
        if !lease() {
            return Err(io::Error::other("artifact authority unavailable"));
        }
        destination.write_all(&buffer[..count])?;
    }
}

fn request_with_status(
    url: &str,
    method: Method,
    body: Option<&[u8]>,
    bearer: Option<&str>,
    maximum: usize,
    timeout: Duration,
    observation: Observation<'_>,
) -> io::Result<Vec<u8>> {
    if !valid_https(url) || maximum == 0 || timeout.is_zero() {
        (observation.failed)(RequestFailure {
            stage: RequestStage::Validation,
            kind: io::ErrorKind::InvalidInput,
        });
        return Err(io::Error::other("invalid HTTPS request"));
    }
    let client = client(url, timeout).inspect_err(|error| {
        (observation.failed)(RequestFailure {
            stage: RequestStage::Client,
            kind: error.kind(),
        })
    })?;
    let mut outbound = client.request(method, url);
    if let Some(secret) = bearer {
        outbound = outbound
            .bearer_auth(secret)
            .header(ACCEPT, "application/json");
    }
    if let Some(bytes) = body {
        outbound = outbound
            .header(CONTENT_TYPE, "application/json")
            .body(bytes.to_vec());
    }
    let response = outbound.send().map_err(|error| {
        (observation.failed)(RequestFailure {
            stage: RequestStage::Send,
            kind: if error.is_timeout() {
                io::ErrorKind::TimedOut
            } else if error.is_connect() {
                io::ErrorKind::ConnectionAborted
            } else {
                io::ErrorKind::Other
            },
        });
        io::Error::other("HTTPS request failed")
    })?;
    if !accepted_status(response.status(), observation.expected)
        || response
            .content_length()
            .is_some_and(|length| length > maximum as u64)
    {
        (observation.failed)(RequestFailure {
            stage: RequestStage::Status,
            kind: io::ErrorKind::PermissionDenied,
        });
        return Err(io::Error::other("HTTPS response unavailable"));
    }
    bounded_body(response, maximum).inspect_err(|error| {
        (observation.failed)(RequestFailure {
            stage: RequestStage::Body,
            kind: error.kind(),
        })
    })
}

fn bounded_body(reader: impl Read, maximum: usize) -> io::Result<Vec<u8>> {
    let limit = maximum
        .checked_add(1)
        .ok_or_else(|| io::Error::other("invalid HTTPS response limit"))?;
    let mut bytes = Vec::new();
    reader.take(limit as u64).read_to_end(&mut bytes)?;
    if bytes.len() > maximum {
        return Err(io::Error::other("HTTPS response too large"));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    #[test]
    fn failure_observation_is_closed_and_preserves_refusal() {
        let mut failures = Vec::new();
        let error = request_observed(
            "http://invalid.test/private-data",
            Method::GET,
            None,
            None,
            16,
            Duration::from_secs(1),
            &mut |failure| failures.push(failure),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert_eq!(error.to_string(), "invalid HTTPS request");
        assert_eq!(
            failures,
            vec![RequestFailure {
                stage: RequestStage::Validation,
                kind: io::ErrorKind::InvalidInput
            }]
        );
        assert_eq!(failures[0].diagnostic_code(), 83);
        assert_eq!(
            RequestFailure {
                stage: RequestStage::Send,
                kind: io::ErrorKind::TimedOut
            }
            .diagnostic_code(),
            92
        );
        assert_eq!(
            RequestFailure {
                stage: RequestStage::Body,
                kind: io::ErrorKind::UnexpectedEof
            }
            .diagnostic_code(),
            105
        );
        assert_eq!(
            RequestFailure {
                stage: RequestStage::Body,
                kind: io::ErrorKind::BrokenPipe
            }
            .diagnostic_code(),
            106
        );
    }

    #[test]
    fn only_verified_https_origins_are_accepted() {
        assert!(valid_https(
            "https://ghuntley.dev/api/audi/v1/known-hosts/vm-123"
        ));
        for invalid in [
            "http://ghuntley.dev/",
            "https://user@ghuntley.dev/",
            "https://ghuntley.dev/#key",
            "https://",
            "file:///etc/passwd",
        ] {
            assert!(!valid_https(invalid));
        }
    }

    #[test]
    fn native_executor_requires_exact_private_origin_and_closed_routes() {
        for route in ["register", "heartbeat", "claim", "transition"] {
            assert!(native_executor_url(&format!(
                "https://llm.internal/agent/v1/{route}"
            )));
        }
        for url in [
            "http://llm.internal/agent/v1/register",
            "https://llm.internal:444/agent/v1/register",
            "https://llm.internal.evil/agent/v1/register",
            "https://llm.internal/agent/v1/foreign",
            "https://llm.internal/agent/v1/register?other=1",
            "https://user@llm.internal/agent/v1/register",
            "https://llm.internal/agent/v1/register#other",
        ] {
            assert!(!native_executor_url(url));
        }
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_url_acceptance_preserves_https_and_no_credentials(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let value = String::from_utf8_lossy(&bytes);
        if valid_https(&value) {
            let parsed = Url::parse(&value).expect("accepted URL parses");
            assert_eq!(parsed.scheme(), "https");
            assert!(parsed.username().is_empty());
            assert!(parsed.password().is_none());
            assert!(parsed.fragment().is_none());
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_control_urls_reject_scheme_credential_and_fragment_mutations(tc: TestCase) {
        let path = tc.draw(gs::integers::<u128>());
        let url = format!("https://ghuntley.dev/api/{path:x}");
        assert!(valid_https(&url));
        assert!(!valid_https(&url.replacen("https:", "http:", 1)));
        assert!(!valid_https(&url.replacen(
            "ghuntley.dev",
            "user@ghuntley.dev",
            1
        )));
        assert!(!valid_https(&format!("{url}#fragment")));
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_response_is_accepted_exactly_within_limit(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        assert_eq!(bounded_body(bytes.as_slice(), bytes.len()).unwrap(), bytes);
        assert_eq!(
            bounded_body(bytes.as_slice(), bytes.len() + 1).unwrap(),
            bytes
        );
        if !bytes.is_empty() {
            assert!(bounded_body(bytes.as_slice(), bytes.len() - 1).is_err());
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_statuses_only_match_the_required_success_code(tc: TestCase) {
        let code = tc.draw(gs::integers::<u16>());
        if let Ok(status) = StatusCode::from_u16(code) {
            assert_eq!(accepted_status(status, Some(StatusCode::OK)), code == 200);
            assert_eq!(accepted_status(status, None), (200..300).contains(&code));
        }
    }
}
