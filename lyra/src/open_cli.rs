//! `overalls open <repository-url> [-- command...]`: create an OSS machine that clones
//! a public repository in the guest, then open SSH in the checkout (ADR-0157).
use crate::config;
use lyra::workspace_source::{self, WorkspaceSource};
use serde::Deserialize;
use std::ffi::OsStr;
use std::io;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const MAXIMUM_RESPONSE: usize = 1_048_576;
/// Porsche's physical wait; creation normally completes well within this.
const CREATE_TIMEOUT_SECONDS: &str = "600";

#[derive(Deserialize)]
struct Envelope {
    version: u8,
    request_id: String,
    status: String,
    result: Created,
}

#[derive(Deserialize)]
struct Created {
    id: String,
    name: String,
    outcome: Option<String>,
    ssh_host: Option<String>,
}

/// The created machine, reduced to validated identity fields.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Machine {
    pub id: String,
    pub name: String,
    /// The guest SSH host Marshall reported, when an ingress zone exists.
    pub ssh_host: Option<String>,
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

/// `OverallsProtocol.MachineName.valid?/1`.
fn valid_machine_name(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=63).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && !(valid_uuid(value) && value.bytes().all(|byte| !byte.is_ascii_uppercase()))
        && value.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

/// Parse Porsche's `new --json` result for this request.
pub(crate) fn parse_created(bytes: &[u8], request_id: &str) -> io::Result<Machine> {
    if bytes.len() > MAXIMUM_RESPONSE {
        return Err(io::Error::other("response too large"));
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| io::Error::other("invalid response"))?;
    let created = envelope.result;
    if envelope.version != 1
        || envelope.request_id != request_id
        || envelope.status != "succeeded"
        || created.outcome.as_deref() != Some("running")
        || !valid_uuid(&created.id)
        || !valid_machine_name(&created.name)
    {
        return Err(io::Error::other("machine not running"));
    }
    Ok(Machine {
        id: created.id,
        name: created.name,
        ssh_host: created.ssh_host,
    })
}

/// `OverallsProtocol.IngressName.label/2`: the SSH label persisted at creation.
pub(crate) fn ingress_label(machine: &Machine) -> Option<String> {
    let prefix = machine.name.get(..machine.name.len().min(22))?;
    let label = format!(
        "v-{}-{}",
        prefix.trim_end_matches('-'),
        machine.id.to_ascii_lowercase().replace('-', "")
    );
    config::valid_label(&label).then_some(label)
}

/// Prefer Marshall's reported SSH host within the configured zone; otherwise
/// derive the persisted ingress label.
pub(crate) fn guest_host(machine: &Machine, zone: &str) -> Option<String> {
    match machine.ssh_host.as_deref() {
        Some(host) => {
            let label = config::label_for(host, zone)?;
            (config::valid_label(label) && config::valid_host(host)).then(|| host.to_owned())
        }
        None => ingress_label(machine).map(|label| format!("{label}.{zone}")),
    }
}

/// Porsche listens on the configured origin's host at port 22 (ADR-0046).
pub(crate) fn porsche_host(origin: &str) -> Option<&str> {
    let authority = origin.strip_prefix("https://")?;
    let host = authority
        .split_once(':')
        .map_or(authority, |(host, _)| host);
    config::valid_host(host).then_some(host)
}

fn fresh_request_id() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    lyra::platform::random_bytes(&mut bytes)?;
    Ok(format!("overalls-open-{}", hex::encode(bytes)))
}

// @cc [owner:ghuntley,label:security] lyra-open-validated-argv
// `overalls open` MUST validate the URL with the shared grammar before any
// process runs. Porsche receives only the canonical re-encoded URL and a fresh
// request ID; the guest SSH argv contains only a label derived from Porsche's
// validated machine identity, the configured zone and a fixed remote script
// whose sole interpolation is the grammar-restricted repository name. User
// command words are single-quoted, never evaluated locally, and never logged.
pub(crate) fn porsche_arguments(
    host: &str,
    source: &WorkspaceSource,
    request_id: &str,
) -> Vec<String> {
    [
        "-T",
        "-p",
        "22",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "--",
        host,
        "new",
        "--source",
        &source.to_url(),
        "--profile",
        "oss",
        "--request-id",
        request_id,
        "--timeout",
        CREATE_TIMEOUT_SECONDS,
        "--json",
    ]
    .iter()
    .map(|value| (*value).to_owned())
    .collect()
}

fn quote(value: &str) -> io::Result<String> {
    if value.contains('\0') {
        return Err(io::Error::other("invalid command"));
    }
    Ok(format!("'{}'", value.replace('\'', "'\\''")))
}

/// The fixed guest script: wait for the clone status, enter the checkout,
/// then start a login shell or the quoted user command.
pub(crate) fn remote_script(source: &WorkspaceSource, command: &[String]) -> io::Result<String> {
    let run = if command.is_empty() {
        "exec \"${SHELL:-/bin/sh}\" -l".to_owned()
    } else {
        let words = command
            .iter()
            .map(|word| quote(word))
            .collect::<io::Result<Vec<_>>>()?;
        format!(
            "exec \"${{SHELL:-/bin/sh}}\" -l -c 'exec \"$@\"' overalls-open {}",
            words.join(" ")
        )
    };
    Ok(format!(
        r#"status_file=/run/overalls-workspace/status
waited=0
last=
while :; do
  state=$(cat "$status_file" 2>/dev/null) || state=waiting
  case "$state" in
    done) break ;;
    failed) echo 'overalls: the repository clone failed' >&2; exit 1 ;;
    cloning) ;;
    *) state=waiting ;;
  esac
  if [ "$state" != "$last" ]; then echo "overalls: repository $state" >&2; last=$state; fi
  if [ "$waited" -ge 900 ]; then echo 'overalls: timed out waiting for the repository clone' >&2; exit 1; fi
  sleep 2
  waited=$((waited + 2))
done
cd -- /workspace/{repo} || exit 1
{run}
"#,
        repo = quote(source.repository())?,
    ))
}

/// Guest SSH argv (without the program name).
pub(crate) fn guest_arguments(host: &str, script: &str) -> Vec<String> {
    vec!["-t".into(), "--".into(), host.into(), script.into()]
}

/// A non-interactive login that only proves the new guest accepts SSH.
pub(crate) fn probe_arguments(host: &str) -> Vec<String> {
    vec![
        "-o".into(),
        "BatchMode=yes".into(),
        "-o".into(),
        "ConnectTimeout=10".into(),
        "--".into(),
        host.into(),
        "true".into(),
    ]
}

/// How long to wait for a freshly created guest to accept SSH.
pub(crate) fn ready_timeout(value: Option<&str>) -> Duration {
    let seconds = value
        .and_then(|text| text.parse::<u64>().ok())
        .filter(|seconds| (1..=3600).contains(seconds))
        .unwrap_or(180);
    Duration::from_secs(seconds)
}

// @cc [owner:ghuntley,label:product;recovery] lyra-open-waits-for-guest-ssh
// A newly running machine's SSH name and route can take a short while to
// propagate. `open` MUST probe with a non-interactive login until the guest
// accepts SSH or the bounded wait ends, and MUST NOT start the interactive
// session (or report success) before that; exhaustion exits non-zero.
fn wait_for_guest(ssh: &OsStr, host: &str, timeout: Duration) -> Result<(), &'static str> {
    let started = Instant::now();
    let mut announced = false;
    loop {
        let ready = Command::new(ssh)
            .args(probe_arguments(host))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|_| "SSH unavailable")?
            .success();
        if ready {
            return Ok(());
        }
        let elapsed = started.elapsed();
        if elapsed >= timeout {
            return Err("guest SSH did not become ready");
        }
        if !announced {
            eprintln!("overalls: waiting for the machine to accept SSH");
            announced = true;
        }
        thread::sleep(timeout.saturating_sub(elapsed).min(Duration::from_secs(5)));
    }
}

pub(crate) fn run(url: &str, command: &[String]) -> Result<i32, &'static str> {
    let source = workspace_source::parse_url(url).map_err(|_| "invalid repository URL")?;
    let settings = config::load().map_err(|_| "Overalls SSH is not configured")?;
    let porsche = porsche_host(&settings.origin).ok_or("invalid configured origin")?;
    let script = remote_script(&source, command).map_err(|_| "invalid command")?;
    let request_id = fresh_request_id().map_err(|_| "request ID unavailable")?;
    let ssh = config::ssh_program(Some(&settings));
    let output = Command::new(&ssh)
        .args(porsche_arguments(porsche, &source, &request_id))
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .map_err(|_| "SSH unavailable")?;
    if !output.status.success() {
        return Err("machine creation failed");
    }
    let machine =
        parse_created(&output.stdout, &request_id).map_err(|_| "machine creation failed")?;
    let host = guest_host(&machine, &settings.zone).ok_or("machine creation failed")?;
    if !config::valid_host(&host) {
        return Err("machine creation failed");
    }
    eprintln!("overalls: machine {} is running", machine.name);
    let timeout = ready_timeout(std::env::var("OVERALLS_OPEN_READY_TIMEOUT").ok().as_deref());
    wait_for_guest(&ssh, &host, timeout)?;
    let mut session = Command::new(&ssh);
    session.args(guest_arguments(&host, &script));
    hand_over(session)
}

/// Replace this process with the interactive SSH session on Unix. Windows has
/// no `exec`: run the session with inherited console handles and exit with
/// its status.
#[cfg(unix)]
fn hand_over(mut session: Command) -> Result<i32, &'static str> {
    use std::os::unix::process::CommandExt;
    drop(session.exec());
    Err("SSH unavailable")
}

#[cfg(windows)]
fn hand_over(mut session: Command) -> Result<i32, &'static str> {
    let status = session.status().map_err(|_| "SSH unavailable")?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123abcd-0000-4000-8000-00000000abcd";

    #[test]
    fn labels_follow_the_ingress_name_rule() {
        let machine = Machine {
            id: ID.into(),
            name: "vm-0123abcd00004000800000000000abcd".into(),
            ssh_host: None,
        };
        assert_eq!(
            ingress_label(&machine).as_deref(),
            Some("v-vm-0123abcd00004000800-0123abcd00004000800000000000abcd")
        );
        let machine = Machine {
            id: ID.into(),
            name: "abcdefghijklmnopqrstu-wxyz".into(),
            ssh_host: None,
        };
        assert_eq!(
            ingress_label(&machine).as_deref(),
            Some("v-abcdefghijklmnopqrstu-0123abcd00004000800000000000abcd")
        );
    }

    #[test]
    fn created_result_requires_this_request_and_running() {
        let body = format!(
            r#"{{"version":1,"request_id":"r1","status":"succeeded","operation_id":"{ID}","result":{{"id":"{ID}","name":"work","outcome":"running"}}}}"#
        );
        assert!(parse_created(body.as_bytes(), "r1").is_ok());
        assert!(parse_created(body.as_bytes(), "r2").is_err());
        assert!(parse_created(body.replace("running", "failed").as_bytes(), "r1").is_err());
        assert!(parse_created(body.replace("\"work\"", "\"-x\"").as_bytes(), "r1").is_err());
    }

    #[test]
    fn reported_ssh_host_must_stay_inside_the_zone() {
        let reported = |host: Option<&str>| Machine {
            id: ID.into(),
            name: "work".into(),
            ssh_host: host.map(str::to_owned),
        };
        let zone = "apps.example.test";
        let host = format!("v-work-{}.{zone}", ID.replace('-', ""));
        assert_eq!(
            guest_host(&reported(Some(&host)), zone).as_deref(),
            Some(host.as_str())
        );
        assert_eq!(guest_host(&reported(Some("evil.example.test")), zone), None);
        assert_eq!(
            guest_host(&reported(Some("-x.apps.example.test")), zone),
            None
        );
        assert_eq!(
            guest_host(&reported(None), zone),
            Some(format!("v-work-{}.{zone}", ID.replace('-', "")))
        );
    }

    #[test]
    fn ready_timeout_is_bounded() {
        assert_eq!(ready_timeout(None), Duration::from_mins(3));
        assert_eq!(ready_timeout(Some("1")), Duration::from_secs(1));
        assert_eq!(ready_timeout(Some("3600")), Duration::from_hours(1));
        for invalid in ["0", "3601", "-1", "x", ""] {
            assert_eq!(ready_timeout(Some(invalid)), Duration::from_mins(3));
        }
    }

    #[test]
    fn porsche_host_is_the_origin_host() {
        assert_eq!(porsche_host("https://ghuntley.dev"), Some("ghuntley.dev"));
        assert_eq!(
            porsche_host("https://ghuntley.dev:8443"),
            Some("ghuntley.dev")
        );
        assert_eq!(porsche_host("http://ghuntley.dev"), None);
    }
}
