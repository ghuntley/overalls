use hegel::{generators as gs, TestCase};
use mila_model::MilaRoute;
use mila_protocol::Command;
use serde::Deserialize;
use serde_json::Value;
use std::sync::OnceLock;

#[derive(Debug, Deserialize)]
struct Routes {
    version: u8,
    accepted: Vec<RouteAccepted>,
    refused: Vec<String>,
}
#[derive(Debug, Clone, Deserialize)]
struct RouteAccepted {
    input: String,
    canonical: String,
    route: Value,
}
#[derive(Debug, Deserialize)]
struct Commands {
    version: u8,
    accepted: Vec<CommandAccepted>,
    refused: Vec<String>,
}
#[derive(Debug, Clone, Deserialize)]
struct CommandAccepted {
    line: String,
    command: Value,
}

fn fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../protocol/test/fixtures")
        .join(name);
    std::fs::read_to_string(path).expect("shared fixture")
}
fn routes() -> &'static Routes {
    static VALUE: OnceLock<Routes> = OnceLock::new();
    VALUE.get_or_init(|| serde_json::from_str(&fixture("app_routes.json")).expect("route fixture"))
}
fn commands() -> &'static Commands {
    static VALUE: OnceLock<Commands> = OnceLock::new();
    VALUE.get_or_init(|| {
        serde_json::from_str(&fixture("ssh_command_lines.json")).expect("command fixture")
    })
}

#[test]
fn app_route_fixture_agreement() {
    assert_eq!(routes().version, 1);
    for vector in &routes().accepted {
        let route = MilaRoute::parse(&vector.input).expect("accepted route");
        assert_eq!(route.format(), vector.canonical);
        assert_eq!(route.describe(), vector.route);
    }
    for input in &routes().refused {
        assert!(
            MilaRoute::parse(input).is_err(),
            "accepted refused route {input}"
        );
    }
}

#[test]
fn command_fixture_agreement() {
    assert_eq!(commands().version, 1);
    for vector in &commands().accepted {
        let command = Command::parse(&vector.line)
            .unwrap_or_else(|error| panic!("accepted command {error}: {}", vector.line));
        let actual = serde_json::json!({ "command": command.command, "arguments": command.arguments, "options": command.options });
        assert_eq!(actual, vector.command, "{}", vector.line);
    }
    for input in &commands().refused {
        assert!(
            Command::parse(input).is_err(),
            "accepted refused command {input}"
        );
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-protocol-route-roundtrip
/// Every accepted shared route MUST survive parse/format and every sampled refused
/// route MUST remain refused, preserving the Elixir and legacy language fixture contract.
#[hegel::test(test_cases = 32)]
fn sampled_routes_agree(tc: TestCase) {
    let accepted = tc.draw(gs::sampled_from(routes().accepted.clone()));
    let route = MilaRoute::parse(&accepted.input).expect("accepted route");
    assert_eq!(MilaRoute::parse(&route.format()), Ok(route));
    let refused = tc.draw(gs::sampled_from(routes().refused.clone()));
    assert!(MilaRoute::parse(&refused).is_err());
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-protocol-command-vectors
/// Generated fixture selections MUST parse to exactly the protocol command object;
/// refused lines must never be interpreted as executable command data.
#[hegel::test(test_cases = 32)]
fn sampled_commands_agree(tc: TestCase) {
    let accepted = tc.draw(gs::sampled_from(commands().accepted.clone()));
    let command = Command::parse(&accepted.line).expect("accepted command");
    let actual = serde_json::json!({ "command": command.command, "arguments": command.arguments, "options": command.options });
    assert_eq!(actual, accepted.command);
    let refused = tc.draw(gs::sampled_from(commands().refused.clone()));
    assert!(Command::parse(&refused).is_err());
}

/// Every device command line in the shared Porsche device fixture parses under
/// the Rust grammar and formats back to a line that parses identically, so the
/// Rust session can issue the commands Marshall and Porsche test against.
#[test]
fn porsche_device_fixture_commands_parse() {
    let value: Value =
        serde_json::from_str(&fixture("porsche_device_results.json")).expect("device fixture");
    let mut lines: Vec<String> = value["commands"]
        .as_object()
        .expect("commands")
        .values()
        .map(|entry| entry["command"].as_str().expect("command").to_owned())
        .collect();
    lines.extend(
        value["refusals"]
            .as_array()
            .expect("refusals")
            .iter()
            .map(|entry| entry["command"].as_str().expect("command").to_owned()),
    );
    assert!(lines.len() >= 4);
    for line in lines {
        let command = Command::parse(&line).unwrap_or_else(|_| panic!("refused {line}"));
        let canonical = command.format().expect("format");
        assert_eq!(
            Command::parse(&canonical).expect("reparse"),
            command,
            "{line}"
        );
    }
    for refused in [
        "device register --platform linux --push-key - --enc-pubkey BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU --json",
        "device register --platform windows --push-key literal-secret-key-value --enc-pubkey BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU --json",
        "device register --platform windows --push-key - --enc-pubkey BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQV --json",
        "device register --platform windows --push-key - --json",
        "device prefs 5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b --enabled maybe --json",
        "device prefs 5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b --json",
        "device rm not-an-id --json",
    ] {
        assert!(Command::parse(refused).is_err(), "accepted {refused}");
    }
    assert!(Command::parse("ssh-key list --json").is_ok());
}
