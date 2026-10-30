"""Real Marshall sessions, WebAuthn enrollment, OAuth consent and owner controls."""

import json
import re
import sys
import time
import uuid
from pathlib import Path
from typing import Literal
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import ConsoleMessage, Page, Request, Response, expect, sync_playwright

ROOT = Path("/var/lib/fleet-default-oss")
ORIGIN = "https://control.example.test"
stage = "arguments"
observations: dict[str, bool | int] = {}
SharedWriterStep = Literal[
    "shell", "identity", "sudo", "cli_available", "dns", "trust", "gh_exit", "owner_match"
]


def machine_detail(url: str) -> bool:
    """True only for /machines/<uuid>, not the form or provisioning receipt."""
    parts = urlsplit(url).path.split("/")
    if len(parts) != 3 or parts[1] != "machines":
        return False
    try:
        return str(uuid.UUID(parts[2])) == parts[2]
    except ValueError:
        return False


def observe_console(message: ConsoleMessage) -> None:
    if message.type == "error" and "form-action" in message.text:
        observations["form_action_refused"] = True


def observe_request(request: Request) -> None:
    destination = urlsplit(request.url)
    if (
        destination.hostname == "control.example.test"
        and destination.path == "/auth/github-com/start"
    ):
        observations["start_requested"] = True
        observations["start_post"] = request.method == "POST"
    elif destination.hostname == "github.com" and destination.path == "/login/oauth/authorize":
        observations["provider_requested"] = True


def observe_response(response: Response) -> None:
    destination = urlsplit(response.url)
    if (
        destination.hostname == "control.example.test"
        and destination.path == "/auth/github-com/start"
    ):
        observations["start_status"] = response.status
    elif destination.hostname == "github.com" and destination.path == "/login/oauth/authorize":
        observations["provider_status"] = response.status


def fields(path: Path) -> dict[str, str]:
    value: object = json.loads(path.read_text())
    assert isinstance(value, dict)
    result: dict[str, str] = {}
    for key, item in value.items():
        if isinstance(key, str) and isinstance(item, str):
            result[key] = item
    return result


def connected(page: Page) -> None:
    # LiveView roots use display: contents and therefore have no visible box.
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1, timeout=30000)


def run(*, create: bool = True) -> None:
    """@cc [owner:ghuntley,label:verification;security] github-fleet-browser-ceremony
    Each owner MUST sign in through the real magic-link handler, register its
    key and passkey through settings, and submit OAuth through Integrations and
    the synthetic provider consent page. Only browser-produced state/callbacks
    may create the connection; no fixture may write domain credentials.
    """
    global stage
    users = fields(ROOT / "users.json")
    machines: dict[str, str] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            for role, owner in (("owner", "1"), ("member", "2")):
                context = browser.new_context()
                page = context.new_page()
                observations.clear()
                page.on("request", observe_request)
                page.on("response", observe_response)
                page.on("console", observe_console)
                stage = role + " sign in"
                page.goto(ORIGIN + "/magic_link/" + users[role + "_token"])
                page.wait_for_url("**/overview", timeout=60000)
                stage = role + " account settings response"
                settings_response = page.goto(ORIGIN + "/settings")
                assert settings_response is not None and settings_response.status == 200
                stage = role + " account settings live connection"
                connected(page)
                stage = role + " register public key"
                page.get_by_label("Public key", exact=True).fill(
                    (ROOT / (role + ".pub")).read_text()
                )
                page.get_by_label("Label (optional)", exact=True).fill("github-fleet-" + role)
                page.locator("#add-ssh-key").click()
                expect(page.locator("article")).to_contain_text("github-fleet-" + role)
                stage = role + " enroll passkey"
                session = context.new_cdp_session(page)
                session.send("WebAuthn.enable")
                session.send(
                    "WebAuthn.addVirtualAuthenticator",
                    {
                        "options": {
                            "protocol": "ctap2",
                            "transport": "internal",
                            "hasResidentKey": True,
                            "hasUserVerification": True,
                            "isUserVerified": True,
                            "automaticPresenceSimulation": True,
                        }
                    },
                )
                page.locator("#add-passkey").click()
                expect(page.locator("#passkey-list > div")).to_have_count(1)
                stage = role + " start OAuth"
                page.goto(ORIGIN + "/integrations")
                stage = role + " integrations live connection"
                connected(page)
                stage = role + " connect control enabled"
                expect(page.locator("#github-com-connect button")).to_be_enabled(timeout=30000)
                stage = role + " submit OAuth start"
                form = page.locator("#github-com-connect")
                observations["form_post"] = form.get_attribute("method") == "post"
                observations["form_action"] = (
                    form.get_attribute("action") == "/auth/github-com/start"
                )
                observations["form_valid"] = bool(
                    form.evaluate("element => element.checkValidity()")
                )
                with page.expect_response(
                    lambda response: (
                        response.request.method == "POST"
                        and urlsplit(response.url).path == "/auth/github-com/start"
                    )
                ) as started:
                    page.locator("#github-com-connect button").click()
                stage = role + " OAuth start redirect response"
                assert started.value.status == 302
                stage = role + " provider authorization redirect"
                try:
                    page.wait_for_url("https://github.com/login/oauth/authorize?**", timeout=30000)
                except Exception:
                    destination = urlsplit(page.url)
                    if destination.hostname == "github.com":
                        stage = role + " provider authorization document"
                    elif destination.hostname == "control.example.test":
                        if destination.path == "/integrations":
                            stage = role + " OAuth start returned to integrations"
                        elif destination.path == "/sign-in":
                            stage = role + " OAuth start returned to sign in"
                    raise
                stage = role + " provider consent and callback"
                page.get_by_label("Fixture owner", exact=True).fill(owner)
                page.locator("#authorize").click()
                page.wait_for_url(ORIGIN + "/integrations", timeout=60000)
                connected(page)
                expect(page.locator("#github-com-state")).to_have_text("Connected", timeout=30000)
                expect(page.locator("#github-com-identity")).to_contain_text("owner-" + owner)
                assert urlsplit(page.url).query == ""
                if not create:
                    context.storage_state(path=str(ROOT / (role + "-github-session.json")))
                    context.close()
                    continue
                stage = role + " create real machine"
                page.goto(ORIGIN + "/machines/new")
                connected(page)
                # The /machines/new preset defaults to Work (ADR-0240); choose
                # OSS explicitly and wait for the draft to record each choice.
                page.locator("#machine_profile").select_option("oss")
                page.wait_for_url(
                    lambda url: parse_qs(urlsplit(url).query).get("machine[profile]") == ["oss"]
                )
                page.locator("#machine_image_id").select_option(users["image_id"])
                page.wait_for_url(
                    lambda url: (
                        parse_qs(urlsplit(url).query).get("machine[image_id]")
                        == [users["image_id"]]
                    )
                )
                expect(page.locator("#machine_profile")).to_have_value("oss")
                expect(page.locator("#machine_image_id")).to_have_value(users["image_id"])
                page.locator("#provision-submit").click()
                # Submission lands on the thread-keyed provisioning receipt,
                # which opens the machine detail once the thread binds it.
                page.wait_for_url(machine_detail, timeout=120000)
                identifier = urlsplit(page.url).path.split("/")[-1]
                assert str(uuid.UUID(identifier)) == identifier
                machines[role] = identifier
                # This journey verifies owner identity, not concurrent storage
                # preparation. Let each real boot settle before the next owner
                # creates a machine on the same native pool.
                stage = role + " real machine running"
                page.goto(ORIGIN + "/machines")
                connected(page)
                expect(page.locator("#machines-" + identifier + " [data-state]")).to_have_attribute(
                    "data-state", "running", timeout=180000
                )
                context.storage_state(path=str(ROOT / (role + "-github-session.json")))
                context.close()
        finally:
            browser.close()
    (ROOT / "github-machines.json").write_text(json.dumps(machines))


def control(mode: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] github-fleet-browser-withdrawal
    Detach, reattach, disconnect and reconnect MUST use the signed-in owner's
    visible controls. Reconnection MUST preserve the excluded machine row. This helper MUST NOT mutate SQL, jobs, generations or credentials.
    Browser URLs/documents and raw exceptions MUST stay inside the client VM.
    """
    global stage
    machines = fields(ROOT / "github-machines.json")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context = browser.new_context(storage_state=str(ROOT / "owner-github-session.json"))
            page = context.new_page()
            stage = mode + " owner controls"
            page.goto(ORIGIN + "/integrations")
            connected(page)
            if mode == "reconnect":
                stage = "reconnect disconnect current owner"
                expect(page.locator("#github-com-state")).to_have_text("Connected")
                page.on("dialog", lambda dialog: dialog.accept())
                page.locator("#github-com-disconnect").click()
                expect(page.locator("#github-com-state")).to_have_text(
                    "Disconnected", timeout=90000
                )
                stage = "reconnect disconnected owner"
                expect(page.locator("#github-com-connect button")).to_be_enabled(timeout=30000)
                with page.expect_response(
                    lambda response: (
                        response.request.method == "POST"
                        and urlsplit(response.url).path == "/auth/github-com/start"
                    )
                ) as started:
                    page.locator("#github-com-connect button").click()
                assert started.value.status == 302
                stage = "reconnect provider consent"
                page.wait_for_url("https://github.com/login/oauth/authorize?**", timeout=30000)
                page.get_by_label("Fixture owner", exact=True).fill("1")
                page.locator("#authorize").click()
                page.wait_for_url(ORIGIN + "/integrations", timeout=60000)
                connected(page)
                expect(page.locator("#github-com-state")).to_have_text("Connected", timeout=30000)
                expect(page.locator("#github-com-identity")).to_contain_text("owner-1")
                assert urlsplit(page.url).query == ""
                stage = "reconnect exclusion persists"
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                expect(page.locator("#github-com-excluded-" + machines["owner"])).to_be_visible()
                context.storage_state(path=str(ROOT / "owner-github-session.json"))
            elif mode == "excluded":
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                expect(page.locator("#github-com-excluded-" + machines["owner"])).to_be_visible()
            elif mode == "detach":
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                page.locator('#github-com-detach input[name="github_machine[vm_id]"]').fill(
                    machines["owner"]
                )
                page.locator("#github-com-detach button").click()
                expect(page.locator("#github-com-excluded-" + machines["owner"])).to_be_visible()
            elif mode == "attach":
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                row = page.locator("#github-com-excluded-" + machines["owner"])
                row.locator("button").click()
                expect(row).to_have_count(0)
            else:
                assert mode == "disconnect"
                page.on("dialog", lambda dialog: dialog.accept())
                page.locator("#github-com-disconnect").click()
                expect(page.locator("#github-com-state")).to_have_text(
                    "Disconnected", timeout=90000
                )
            context.close()
        finally:
            browser.close()


def shared_writer(family: str, expected_username: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] github-fleet-shared-owner-identity
    A separately authenticated member MUST execute managed gh in its own
    writable browser terminal on the shared machine and observe the machine
    owner's GitHub identity, despite its separate connected GitHub identity.
    Windows MUST run as the member's exact durable guest account, never an
    owner or system shell. Success MUST require a guest-produced marker; raw
    terminal text stays private. Closed per-step markers MUST distinguish shell,
    durable account, sudo and CLI/DNS/trust where applicable, CLI exit and owner match within one
    aggregate 90-second completion bound; echoed input MUST NOT satisfy them.
    """
    global stage
    machines = fields(ROOT / "github-machines.json")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context = browser.new_context(storage_state=str(ROOT / "member-github-session.json"))
            page = context.new_page()
            stage = "shared member owner terminal"
            page.goto(ORIGIN + "/machines/" + machines["owner"] + "/terminals")
            connected(page)
            expect(page.locator("#terminal-status")).to_have_attribute(
                "data-status", "live", timeout=90000
            )
            page.locator("#terminal-pane-holder > div:not(.hidden) .xterm-helper-textarea").focus()
            # Split the marker so echoed input cannot satisfy the assertion.
            suffix = uuid.uuid4().hex
            assert re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", expected_username)

            def marker(step: SharedWriterStep) -> str:
                return "GITHUB_SHARED_" + suffix + "_" + step

            def shell_mark(step: SharedWriterStep) -> str:
                return "printf '\\nGITHUB_SHARED_%s_" + step + "\\n' '" + suffix + "'"

            def powershell_mark(step: SharedWriterStep) -> str:
                return "[Console]::WriteLine(('GITHUB_SHARED_' + '" + suffix + "_" + step + "'))"

            steps: tuple[SharedWriterStep, ...]
            if family == "windows":
                steps = ("shell", "identity", "gh_exit", "owner_match")
                command = (
                    "& { $ErrorActionPreference = 'Stop'; " + powershell_mark("shell") + "; "
                    "if ($env:USERNAME -ine '"
                    + expected_username
                    + "') { throw 'guest_identity' }; "
                    + powershell_mark("identity")
                    + "; "
                    "$v = & 'C:\\Program Files\\GitHub CLI\\gh.exe' api user --jq .login; "
                    "if ($LASTEXITCODE -ne 0) { throw 'github_exit' }; "
                    + powershell_mark("gh_exit")
                    + "; "
                    "if ($v -ne 'owner-1') { throw 'github_identity' }; "
                    + powershell_mark("owner_match")
                    + " }"
                )
            else:
                steps = (
                    "shell",
                    "identity",
                    "sudo",
                    "cli_available",
                    "dns",
                    "trust",
                    "gh_exit",
                    "owner_match",
                )
                command = (
                    shell_mark("shell")
                    + ' && test "$(id -un)" = '
                    + expected_username
                    + " && "
                    + shell_mark("identity")
                    + " && sudo -n true && "
                    + shell_mark("sudo")
                    + " && command -v gh >/dev/null 2>&1 && gh --version >/dev/null 2>&1 && "
                    + shell_mark("cli_available")
                    + " && getent hosts com-github.integration.internal >/dev/null 2>&1 && "
                    + shell_mark("dns")
                    + " && test -r /etc/ssl/certs/ca-certificates.crt && "
                    + shell_mark("trust")
                    + " && v=$(gh api user --jq .login 2>/dev/null) && "
                    + shell_mark("gh_exit")
                    + ' && test "$v" = owner-1 && '
                    + shell_mark("owner_match")
                )
            stage = "shared member command send"
            page.keyboard.type(command, delay=2)
            page.keyboard.press("Enter")
            deadline = time.monotonic() + 90
            output = page.locator(
                "#terminal-pane-holder > div:not(.hidden) .xterm-accessibility-tree"
            )
            for step in steps:
                stage = "shared member " + step
                remaining_ms = max(1, int((deadline - time.monotonic()) * 1000))
                expect(output).to_contain_text(marker(step), timeout=remaining_ms)
                observations["shared_" + step] = True
            context.close()
        finally:
            browser.close()


try:
    assert len(sys.argv) <= 4
    mode = sys.argv[1] if len(sys.argv) >= 2 else "create"
    family = sys.argv[2] if len(sys.argv) >= 3 else "nixos"
    expected_username = sys.argv[3] if len(sys.argv) == 4 else ""
    assert family in {"nixos", "ubuntu", "arch", "almalinux", "windows"}
    assert mode in {
        "create",
        "connect",
        "shared-writer",
        "detach",
        "attach",
        "disconnect",
        "reconnect",
        "excluded",
    }
    if mode in {"create", "connect"}:
        run(create=mode == "create")
    elif mode == "shared-writer":
        shared_writer(family, expected_username)
    else:
        control(mode)
except Exception as error:
    print(
        json.dumps(
            {
                "event": "github_fleet_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
                "observations": observations,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
