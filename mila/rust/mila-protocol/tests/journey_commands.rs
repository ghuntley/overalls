//! Grammar for the commands the hermetic Mila journey (ADR-0264) exercises.
use mila_protocol::Command;

#[test]
fn device_and_terminal_commands_round_trip() {
    let enc = "A".repeat(43);
    for line in [
        "ssh-key list --json".to_owned(),
        "device ls --json".to_owned(),
        "device rm 0f2ec797-d7d9-4656-9dbe-2eabb9be850f --json --request-id=porsche-0123456789abcdef0123456789abcdef".to_owned(),
        "device prefs --json --enabled=false 0f2ec797-d7d9-4656-9dbe-2eabb9be850f".to_owned(),
        format!("device register --json --platform=android --push-key=- --enc-pubkey={enc}"),
        "terminal attach --json -- 0f2ec797-d7d9-4656-9dbe-2eabb9be850f 7d8e5b10-9c54-4ee4-92ad-7eefa59b4281".to_owned(),
    ] {
        let command = Command::parse(&line).unwrap_or_else(|error| panic!("{line}: {error:?}"));
        let formatted = command.format().expect("format");
        assert_eq!(
            Command::parse(&formatted).expect("reparse"),
            command,
            "{line}"
        );
    }
}

#[test]
fn journey_commands_refuse_malformed_options() {
    for line in [
        "device prefs --json --enabled=maybe 0f2ec797-d7d9-4656-9dbe-2eabb9be850f",
        "device rm --json --no-wait 0f2ec797-d7d9-4656-9dbe-2eabb9be850f",
        "device register --json --platform=android --push-key=- --enc-pubkey=short",
        "device register --json --platform=pager --push-key=- --enc-pubkey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "terminal attach --json -- 0f2ec797-d7d9-4656-9dbe-2eabb9be850f",
        "ssh-key list --json -- extra",
    ] {
        assert!(Command::parse(line).is_err(), "{line} parsed");
    }
}
