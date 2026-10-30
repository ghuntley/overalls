# @cc [owner:ghuntley,label:verification;security] mila-terminal-journey-native
# The Mila terminal journey MUST drive the Mila Rust core's C ABI (through the
# headless `mila-journey` driver) into a real guest PTY through Porsche at the
# deployment's public host: browser approval of a new device key, `terminal
# new`, a named `terminal attach`, output, input, resize, detach and reattach
# with replay, and a server-side kill. Marshall's ledger MUST record the kill
# intent. Terminal bytes MUST stay in the driver; its result carries booleans.
with subtest("Mila core enrolls a device key through the browser approval page"):
    mila_root = porsche_root + "/mila"
    client.succeed(f"install -d -m 700 -o tester -g users {mila_root}")
    client.succeed(f"rm -f {porsche_root}/pending.json")
    ca_pem = client.succeed(f"cat {porsche_root}/ca.crt")
    mila_descriptor = {
        "version": 1,
        "deployment": {"host": "control.example.test", "ssh_port": 2222, "https_port": 443},
        "tls": {"ca_pem": ca_pem, "server_name": "control.example.test"},
        # The harness's browser approves the owner through pending.json.
        "approver": {"url": "file://" + porsche_root + "/pending.json", "bearer_token": "unused"},
    }
    client.succeed(
        "sudo -u tester sh -c "
        + shlex.quote(
            "umask 077; printf %s "
            + shlex.quote(json.dumps(mila_descriptor))
            + f" > {mila_root}/descriptor.json"
        )
    )

    def mila_object(value: object) -> dict[str, object]:
        """Narrows parsed JSON to a string-keyed object."""
        assert isinstance(value, dict), "expected a JSON object"
        narrowed: dict[str, object] = {}
        for key, item in value.items():
            assert isinstance(key, str), "expected string keys"
            narrowed[key] = item
        return narrowed

    def mila_command(step: str) -> str:
        return (
            f"/run/current-system/sw/bin/mila-journey --descriptor {mila_root}/descriptor.json --state {mila_root}/state "
            + step
        )

    def mila_result(path: str) -> dict[str, object]:
        lines = client.succeed(f"cat {path}").strip().splitlines()
        assert lines, path
        return mila_object(json.loads(lines[-1]))

    client.succeed(
        "systemd-run --quiet --no-block --unit=mila-enroll --property=User=tester "
        "--property=Environment=HOME=/home/tester "
        "--property=Environment=PATH=/run/current-system/sw/bin "
        f"--property=StandardOutput=file:{mila_root}/enroll.json "
        "--property=StandardError=null /bin/sh -c " + shlex.quote(mila_command("enroll"))
    )
    client.wait_until_succeeds(
        f"test -s {porsche_root}/pending.json || ! systemctl is-active --quiet mila-enroll",
        timeout=120,
    )
    # The driver's result carries only a stage and a closed reason.
    assert client.execute(f"test -s {porsche_root}/pending.json")[0] == 0, client.execute(
        f"cat {mila_root}/enroll.json"
    )[1]
    pending = mila_object(json.loads(client.succeed(f"cat {porsche_root}/pending.json")))
    public_key = pending["public_key"]
    assert isinstance(public_key, str) and public_key.startswith("ecdsa-sha2-nistp256 ")
    client.succeed(
        "sudo -u tester sh -c "
        + shlex.quote(
            f"umask 077; printf '%s\\n' {shlex.quote(public_key)} > {porsche_root}/mila.pub"
        )
    )
    porsche_browser("approve-mila")
    client.wait_until_succeeds(
        f"test -s {mila_root}/enroll.json && ! systemctl is-active --quiet mila-enroll",
        timeout=180,
    )
    enrolled = mila_result(mila_root + "/enroll.json")
    assert enrolled.get("ok") is True, enrolled
    enrolled_value = mila_object(enrolled["value"])
    assert enrolled_value["approved_by_browser"] is True, enrolled_value
    assert enrolled_value["public_key_matches"] is True, enrolled_value
    assert enrolled_value["account_id"] == users["owner_id"], enrolled_value

with subtest("Mila core drives a real guest PTY: output, input, resize, reattach and kill"):
    client.succeed(
        "sudo -u tester sh -c "
        + shlex.quote(
            mila_command("terminal " + terminal_vm["vm_id"]) + f" > {mila_root}/terminal.json"
        ),
        timeout=420,
    )
    terminal_result = mila_result(mila_root + "/terminal.json")
    assert terminal_result.get("ok") is True, terminal_result
    terminal_value = mila_object(terminal_result["value"])
    for evidence in ("output_seen", "resized", "replayed_after_reconnect", "killed"):
        assert terminal_value[evidence] is True, (evidence, terminal_value)
    mila_session = terminal_value["session_id"]
    assert isinstance(mila_session, str) and str(uuid.UUID(mila_session)) == mila_session
    assert sql(
        "SELECT kill_status FROM terminal_sessions WHERE id = '"
        + mila_session
        + "' AND vm_id = '"
        + terminal_vm["vm_id"]
        + "'"
    ) in ("pending", "confirmed"), mila_session
    eventually(
        lambda: (
            sql(f"SELECT kill_status FROM terminal_sessions WHERE id = '{mila_session}'")
            == "confirmed"
        ),
        timeout=120,
    )
