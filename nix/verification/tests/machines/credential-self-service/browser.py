"""Packaged browser passkey self-service over verified TLS with virtual WebAuthn."""

import subprocess
import time
from pathlib import Path
from uuid import UUID

from playwright.sync_api import (
    Browser,
    CDPSession,
    Dialog,
    Error,
    Page,
    expect,
    sync_playwright,
)

ORIGIN = "https://localhost"


def sql(statement: str) -> str:
    """Read only the disposable VM's fixture database."""
    return subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "marshall"],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def sql_eventually(statement: str, expected: str, timeout_ms: int = 15000) -> None:
    """Poll a read until the server effect is visible, since browser events are async."""
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        actual = sql(statement)
        if actual == expected:
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f"Timed out: {actual!r} != {expected!r}")
        time.sleep(0.25)


def fixture_id(name: str) -> str:
    assert name in {"ordinary", "admin", "target"}
    return str(UUID(sql(f"SELECT id FROM users WHERE email = '{name}@example.test';")))


def passkey_ids(user_id: str) -> list[str]:
    rows = sql(
        f"SELECT string_agg(id::text, ',' ORDER BY inserted_at, id) FROM account_passkeys WHERE user_id = '{user_id}';"
    )
    return [] if rows == "" else rows.split(",")


def inventory(user_id: str, target_id: str) -> str:
    """Hash complete fixture rows; comparisons must include hidden credential state."""
    return sql(f"""
      SELECT md5(jsonb_build_object(
        'user', (SELECT to_jsonb(t) FROM users t WHERE id = '{user_id}'),
        'target_role', (SELECT administrator FROM users t WHERE id = '{target_id}'),
        'passkeys', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_passkeys t WHERE user_id = '{user_id}'),
        'proofs', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_verifications t WHERE user_id = '{user_id}'),
        'challenges', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_passkey_challenges t WHERE user_id = '{user_id}'),
        'audit', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_admin_events t),
        'tokens', (SELECT jsonb_agg(to_jsonb(t) ORDER BY jti) FROM tokens t WHERE subject = 'user?id={user_id}')
      )::text);
    """)


# Chrome supports exactly one internal virtual authenticator per environment, so
# each fresh enrollment swaps the previous authenticator out first.
def add_authenticator(cdp: CDPSession) -> str:
    response: dict[str, str] = cdp.send(
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
    return response["authenticatorId"]


def remove_authenticator(cdp: CDPSession, authenticator_id: str) -> None:
    cdp.send("WebAuthn.removeVirtualAuthenticator", {"authenticatorId": authenticator_id})


def enroll(page: Page) -> None:
    page.bring_to_front()
    visit(page, "/settings")
    page.evaluate(
        """() => {
          const create = navigator.credentials.create.bind(navigator.credentials);
          navigator.credentials.create = (options) => create(options).then(
            (credential) => credential,
            (error) => { window.__weberr = error.name + ': ' + error.message; throw error; },
          );
        }"""
    )
    page.locator("#add-passkey").click()


def verify_now(page: Page) -> None:
    page.bring_to_front()
    visit(page, "/settings")
    page.locator("#verify-passkey").click()
    expect(page.locator("#verification-status")).to_contain_text("Passkey verified")


def flash_or_empty(page: Page) -> str:
    error = page.locator("#flash-error")
    info = page.locator("#flash-info")
    return (
        (error.text_content() if error.count() else "")
        or (info.text_content() if info.count() else "")
        or ""
    )


def expect_count(page: Page, count: int) -> None:
    try:
        expect(page.locator("#passkey-list > div")).to_have_count(count)
    except AssertionError:
        detail = page.evaluate("() => Reflect.get(window, '__weberr') || ''")
        raise AssertionError(
            f"Expected {count} passkeys; flash: {flash_or_empty(page)} js: {detail}"
        ) from None


def accept_dialog(dialog: Dialog) -> None:
    dialog.accept()


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page).to_have_url(ORIGIN + path)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def rename(page: Page, key_id: str, label: str) -> None:
    """@cc [owner:ghuntley,label:verification] passkey-rename-submit-only
    Renaming MUST click the form's submit control, never its removal control,
    and verify the resulting persisted label.
    """
    page.locator(f"#label-{key_id} input[name='label']").fill(label)
    page.locator(f"#label-{key_id}").locator("button:not([type]), button[type='submit']").click()
    expect(page.locator(f"#label-{key_id} input[name='label']")).to_have_value(label)
    sql_eventually(f"SELECT label FROM account_passkeys WHERE id = '{key_id}';", label)


def enrolled(browser: Browser, name: str) -> tuple[Page, CDPSession, str]:
    """Sign in through the real magic link and register the first passkey."""
    context = browser.new_context()
    page = context.new_page()
    page.on("dialog", accept_dialog)
    cdp = context.new_cdp_session(page)
    cdp.send("WebAuthn.enable")
    first = add_authenticator(cdp)
    token = Path(f"/run/overalls-test/credential-self-service-{name}").read_text().strip()
    try:
        page.goto(ORIGIN + "/magic_link/" + token)
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
    except (Error, AssertionError):
        raise AssertionError("Fixture sign-in navigation failed") from None
    enroll(page)
    expect_count(page, 1)
    verify_now(page)
    return page, cdp, first


def main() -> None:
    """@cc [owner:ghuntley,label:verification] native-credential-self-service
    Browsing MUST use the packaged application with verified TLS and virtual
    WebAuthn. Removing the proving credential MUST end mounted elevation at
    once; removing an ordinary account's last passkey MUST disable MFA and
    revoke its own mounted session; an administrator's last passkey and any
    change after sign-out MUST refuse without stored-state change.
    """
    admin_id, ordinary_id, target_id = (
        fixture_id(name) for name in ["admin", "ordinary", "target"]
    )
    # Loaded CI runners need longer than Playwright's 5 s expect default for
    # LiveView mounts; explicit tighter timeouts below still apply.
    expect.set_options(timeout=30000)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )

        # Administrator self-service: enroll, rename, proving removal, refusal.
        admin, cdp, first = enrolled(browser, "admin")
        [key1] = passkey_ids(admin_id)
        assert sql(f"SELECT label FROM account_passkeys WHERE id = '{key1}';") == "Passkey"

        mounted = admin.context.new_page()
        mounted.on("dialog", accept_dialog)
        visit(mounted, "/admin/users")
        expect(mounted.locator(f"#role-{target_id}")).to_be_visible()

        # Rename the proving passkey through its real form; elevation survives.
        rename(admin, key1, "Laptop")
        assert sql(f"SELECT label FROM account_passkeys WHERE id = '{key1}';") == "Laptop"

        # Enroll a second passkey on a fresh authenticator.
        remove_authenticator(cdp, first)
        second = add_authenticator(cdp)
        enroll(admin)
        expect_count(admin, 2)
        key1b, key2 = passkey_ids(admin_id)
        assert key1b == key1

        # Removing the proving credential: mounted admin page loses elevation at once.
        admin.locator(f"#remove-{key1}").click()
        expect_count(admin, 1)
        before = inventory(admin_id, target_id)
        mounted.locator(f"#role-{target_id}").click()
        expect(mounted.locator("#admin-elevation-modal")).to_be_visible()
        expect(mounted).to_have_url(ORIGIN + "/admin/users")
        assert sql(f"SELECT administrator FROM users WHERE id = '{target_id}';") == "f"
        assert inventory(admin_id, target_id) == before
        assert sql(f"SELECT count(*) FROM account_passkeys WHERE user_id = '{admin_id}';") == "1"
        mounted.locator("#admin-elevation-cancel").click()
        expect(mounted.locator("#admin-elevation-modal")).not_to_be_visible()

        # Re-elevate with the surviving credential, then enroll and rename a
        # third passkey on a fresh authenticator.
        verify_now(admin)
        remove_authenticator(cdp, second)
        add_authenticator(cdp)
        enroll(admin)
        expect_count(admin, 2)
        key3a = [key for key in passkey_ids(admin_id) if key != key2]
        [key3] = key3a
        rename(admin, key3, "Backup")
        assert sql(f"SELECT label FROM account_passkeys WHERE id = '{key3}';") == "Backup"

        # Removing the non-proving credential keeps the session and elevation.
        admin.locator(f"#remove-{key3}").click()
        expect_count(admin, 1)

        visit(mounted, "/admin/users")
        mounted.locator(f"#role-{target_id}").click()
        expect(mounted.locator(f"#role-{target_id}")).to_have_text("Remove administrator")
        mounted.locator(f"#role-{target_id}").click()
        expect(mounted.locator(f"#role-{target_id}")).to_have_text("Make administrator")
        assert sql(f"SELECT administrator FROM users WHERE id = '{target_id}';") == "f"

        # The last administrator passkey refuses without any stored-state change.
        before = inventory(admin_id, target_id)
        admin.locator(f"#remove-{key2}").click()
        expect(admin.locator("#flash-error")).to_contain_text("at least one passkey")
        expect_count(admin, 1)
        assert inventory(admin_id, target_id) == before
        assert sql(f"SELECT mfa_enabled FROM users WHERE id = '{admin_id}';") == "t"

        # Signed-out stale mounted views refuse without stored-state change.
        visit(mounted, "/admin/users")
        admin.goto(ORIGIN + "/sign-out")
        admin.get_by_role("button", name="Sign out", exact=True).click()
        admin.wait_for_url("**/sign-in")
        expect(mounted).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        after_signout = inventory(admin_id, target_id)
        mounted.goto(ORIGIN + "/admin/users")
        expect(mounted).to_have_url(ORIGIN + "/sign-in")
        mounted.goto(ORIGIN + "/settings")
        expect(mounted).to_have_url(ORIGIN + "/sign-in")
        assert inventory(admin_id, target_id) == after_signout
        sql_eventually(
            f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose != 'revocation';",
            "0",
        )

        # Ordinary account: removing the only passkey disables MFA and revokes
        # the very session the button lived in.
        ordinary, _ordinary_cdp, _ordinary_first = enrolled(browser, "ordinary")
        [only] = passkey_ids(ordinary_id)
        assert (
            sql(f"SELECT mfa_enabled AND mfa_generation = 0 FROM users WHERE id = '{ordinary_id}';")
            == "t"
        )
        ordinary.locator(f"#remove-{only}").click()
        expect(ordinary).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        sql_eventually(
            f"SELECT NOT mfa_enabled AND mfa_generation = 1 FROM users WHERE id = '{ordinary_id}';",
            "t",
        )
        sql_eventually(
            f"SELECT count(*) FROM account_passkeys WHERE user_id = '{ordinary_id}';", "0"
        )
        sql_eventually(
            f"SELECT count(*) FROM tokens WHERE subject = 'user?id={ordinary_id}' AND purpose != 'revocation';",
            "0",
        )
        ordinary.goto(ORIGIN + "/settings")
        expect(ordinary).to_have_url(ORIGIN + "/sign-in")

        browser.close()


if __name__ == "__main__":
    main()
