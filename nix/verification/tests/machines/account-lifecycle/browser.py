"""Invited browser identity, elevated retirement and fresh same-email signup."""

import json
import sys
import time
from pathlib import Path
from uuid import UUID, uuid4

from playwright._impl._api_structures import SetCookieParam
from playwright.sync_api import CDPSession, Cookie, Dialog, Error, Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-account-lifecycle")
ORIGIN = "https://control.example.test"
EMAIL = "retirement-invited@example.test"
stage = "launch"


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def signal(name: str) -> None:
    (ROOT / name).write_text("ready")


def wait(name: str) -> None:
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        if (ROOT / name).is_file():
            return
        time.sleep(0.2)
    raise AssertionError("Native lifecycle coordination timed out")


def sign_in(page: Page, name: str, refused: bool = False) -> None:
    """@cc [owner:ghuntley,label:security] lifecycle-browser-login-redaction
    The complete token-bearing interaction MUST suppress error URLs and tokens,
    including navigation, socket connection, form submission and refusal checks.
    """
    token = (ROOT / name).read_text().strip()
    try:
        page.goto(ORIGIN + "/magic_link/" + token)
        connected(page)
        page.wait_for_url("**/sign-in" if refused else "**/overview")
    except (Error, AssertionError):
        raise AssertionError("Native account lifecycle sign-in failed") from None
    connected(page)


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page).to_have_url(ORIGIN + path)
    connected(page)


def authenticator(session: CDPSession) -> None:
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


def verify(page: Page, enroll: bool = False) -> None:
    visit(page, "/settings")
    if enroll:
        page.locator("#add-passkey").click()
        expect(page.locator("#passkey-list > div")).to_have_count(1)
    page.locator("#verify-passkey").click()
    expect(page.locator("#verification-status")).to_contain_text("Passkey verified")


def accept(dialog: Dialog) -> None:
    dialog.accept()


def copy_cookie(cookie: Cookie) -> SetCookieParam:
    return {
        "name": cookie["name"],
        "value": cookie["value"],
        "domain": cookie["domain"],
        "path": cookie["path"],
        "expires": cookie["expires"],
        "httpOnly": cookie["httpOnly"],
        "secure": cookie["secure"],
        "sameSite": cookie["sameSite"],
    }


def register_key(page: Page, role: str) -> None:
    visit(page, "/settings")
    page.get_by_label("Public key", exact=True).fill((ROOT / (role + ".pub")).read_text())
    page.get_by_label("Label (optional)", exact=True).fill("retirement-" + role)
    page.locator("#add-ssh-key").click()
    expect(page.locator("article")).to_contain_text("retirement-" + role)


def personal_terminal(page: Page, role: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] lifecycle-personal-guest-identity
    Browser shells MUST prove the persisted username, UID and own writable home.
    Only a success marker may escape the terminal; failures MUST withhold bytes.
    """
    value: object = json.loads((ROOT / (role + "-terminal.json")).read_text())
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        fields[key] = field
    assert set(fields) == {"vm", "name", "uid"}
    vm = fields["vm"]
    name = fields["name"]
    uid = fields["uid"]
    assert isinstance(vm, str) and str(UUID(vm)) == vm
    assert isinstance(name, str) and 1 <= len(name) <= 32
    assert all(character in "abcdefghijklmnopqrstuvwxyz0123456789_.-" for character in name)
    assert isinstance(uid, int) and 200000 <= uid <= 999999
    visit(page, "/machines/" + vm + "/terminals")
    expect(page.locator("#terminal-status")).to_have_attribute("data-status", "live", timeout=60000)
    expect(page.locator("[data-terminal-select]")).to_have_count(1)
    session = page.locator("[data-terminal-select]").get_attribute("data-terminal-select")
    assert session is not None and str(UUID(session)) == session
    suffix = uuid4().hex
    command = (
        f'test "$(id -un)" = {name} && test "$(id -u)" = {uid} '
        f'&& test "$HOME" = /home/{name} && test "$PWD" = "$HOME" '
        f'&& touch "$HOME/{role}-terminal"'
    )
    page.locator("#terminal-pane-holder > div:not(.hidden) .xterm-helper-textarea").focus()
    page.keyboard.type("(" + command + ") && printf '\\nLIFECYCLE_%s\\n' '" + suffix + "'", delay=2)
    page.keyboard.press("Enter")
    try:
        expect(
            page.locator("#terminal-pane-holder > div:not(.hidden) .xterm-accessibility-tree")
        ).to_contain_text("LIFECYCLE_" + suffix, timeout=30000)
    except (Error, AssertionError):
        raise AssertionError("Personal terminal identity assertion failed") from None
    (ROOT / (role + "-terminal-session")).write_text(session)
    return session


def run() -> None:
    """@cc [owner:ghuntley,label:verification] native-account-lifecycle-journey
    Invitation MUST precede actual registration. Retirement MUST require browser
    WebAuthn and typed confirmation, revoke the mounted user and copied cookies,
    reject a pre-retirement email link, and allow a fresh same-email signup while
    the old physical cleanup remains blocked. No guest contents enter the admin UI.
    """
    global stage
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        admin_context = browser.new_context()
        admin = admin_context.new_page()
        admin.on("dialog", accept)
        authenticator(admin_context.new_cdp_session(admin))
        stage = "administrator enrollment"
        sign_in(admin, "admin-token")
        verify(admin, enroll=True)
        visit(admin, "/admin/users")
        stage = "invitation"
        admin.locator("#invite-user input[name='email']").fill(EMAIL)
        admin.locator("#invite-user button").click()
        expect(admin.locator("#flash-info")).to_contain_text("Account request accepted")
        signal("invitation-sent")
        wait("invitation-ready")

        stage = "invited ordinary registration"
        invited_context = browser.new_context()
        invited = invited_context.new_page()
        authenticator(invited_context.new_cdp_session(invited))
        sign_in(invited, "invitation-token")
        verify(invited, enroll=True)
        register_key(invited, "invited")
        survivor_context = browser.new_context()
        survivor = survivor_context.new_page()
        sign_in(survivor, "survivor-token")
        register_key(survivor, "survivor")
        stage = "owned Customer creation"
        signal("owned-create-ready")
        wait("owned-create-go")
        # The driver admits the invited user's Customer machine as that user;
        # the form offers only agent profiles. Prove the owner can open it.
        owned = str(UUID((ROOT / "owned-id").read_text().strip()))
        visit(invited, "/machines/" + owned + "/access")
        expect(invited.locator("#machine-detail")).to_have_count(1)
        expect(invited.locator("#customer-isolation")).to_have_count(1)
        stage = "ordinary administration refusal"
        visit(invited, "/admin/users")
        expect(invited.locator("#invite-user")).to_have_count(0)
        stage = "remembered authority"
        # Prove remembered authority works before testing its retirement. Keep
        # the virtual authenticator but discard the completed browser session.
        remembered = [
            copy_cookie(cookie)
            for cookie in invited_context.cookies()
            if "remember" in cookie["name"]
        ]
        assert len(remembered) == 1
        invited_context.clear_cookies()
        invited_context.add_cookies(remembered)
        # A remembered credential establishes an ordinary login without passkey
        # proof: the account page offers no continue link until it re-verifies.
        visit(invited, "/overview")
        expect(invited.locator("#main-content")).to_have_count(1)
        visit(invited, "/settings")
        expect(invited.locator("#security-continue")).to_have_count(0)
        verify(invited)
        visit(invited, "/admin/users")
        cookies = [copy_cookie(cookie) for cookie in invited_context.cookies()]
        assert len([cookie for cookie in cookies if "remember" in cookie["name"]]) == 1
        signal("owned-admitted")
        wait("invited-terminal-ready")
        stage = "original personal guest identity"
        old_session = personal_terminal(invited, "invited")
        signal("invited-terminal-passed")
        wait("retire-now")

        stage = "typed retirement refusal"
        old_id = str(UUID((ROOT / "old-id").read_text().strip()))
        verify(admin)
        visit(admin, "/admin/users")
        form = admin.locator(f"#delete-user-{old_id}")
        form.locator("input[name='confirmation']").fill("wrong@example.test")
        form.locator("button").click()
        expect(admin.locator("#flash-error")).to_contain_text(
            "Could not accept this account change"
        )
        signal("wrong-confirmation-refused")
        wait("confirm-retire")

        stage = "accepted retirement and mounted revocation"
        form.locator("input[name='confirmation']").fill(EMAIL)
        form.locator("button").click()
        expect(admin.locator("#flash-info")).to_contain_text("Account request accepted")
        expect(invited).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        copied_context = browser.new_context()
        copied_context.add_cookies(cookies)
        copied = copied_context.new_page()
        copied.goto(ORIGIN + "/admin/users")
        expect(copied).to_have_url(ORIGIN + "/sign-in")
        copied_context.clear_cookies()
        copied_context.add_cookies([cookie for cookie in cookies if "remember" in cookie["name"]])
        copied.goto(ORIGIN + "/overview")
        expect(copied).to_have_url(ORIGIN + "/sign-in")
        stage = "stale email link refusal"
        sign_in(copied, "stale-token", refused=True)
        signal("retired")
        wait("request-replacement")

        stage = "fresh invitation while cleanup is pending"
        admin.locator("#invite-user input[name='email']").fill(EMAIL)
        admin.locator("#invite-user button").click()
        expect(admin.locator("#flash-info")).to_contain_text("Account request accepted")
        signal("replacement-invited")
        wait("replacement-ready")
        fresh_context = browser.new_context()
        fresh = fresh_context.new_page()
        sign_in(fresh, "replacement-token")
        visit(fresh, "/settings")
        expect(fresh.locator("#passkey-list > div")).to_have_count(0)
        visit(fresh, "/settings")
        expect(fresh.locator("#ssh-keys-empty")).to_be_visible()
        visit(fresh, "/admin/users")
        expect(fresh.locator("#invite-user")).to_have_count(0)
        signal("replacement-registered")
        wait("fresh-key-now")
        stage = "fresh distinct SSH key registration"
        register_key(fresh, "fresh")
        signal("fresh-key-registered")
        wait("fresh-terminal-ready")
        stage = "fresh personal guest identity"
        fresh_session = personal_terminal(fresh, "fresh")
        assert fresh_session != old_session
        expect(fresh.locator(f"[data-terminal-select='{old_session}']")).to_have_count(0)
        signal("fresh-terminal-passed")
        wait("cleanup-complete")
        visit(fresh, "/overview")
        signal("browser-passed")
        browser.close()


try:
    run()
except Exception as error:
    (ROOT / "failure-stage").write_text(stage + " (" + type(error).__name__ + ")")
    print(
        json.dumps(
            {
                "event": "account_lifecycle_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
