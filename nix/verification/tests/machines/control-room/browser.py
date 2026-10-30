"""Packaged browser authority over verified TLS with a virtual WebAuthn device."""

import subprocess
from pathlib import Path
from uuid import UUID

from playwright.sync_api import Dialog, Error, Page, expect, sync_playwright

ORIGIN = "https://localhost"


def sql(statement: str) -> str:
    """Query or fault-inject only the isolated VM's disposable fixture database."""
    return subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "marshall"],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def fixture_id(name: str) -> str:
    assert name in {"reader", "admin", "target"}
    return str(UUID(sql(f"SELECT id FROM users WHERE email = '{name}@example.test';")))


def sign_in(page: Page, name: str) -> None:
    token = Path(f"/run/overalls-test/control-room-{name}").read_text().strip()
    try:
        page.goto(ORIGIN + "/magic_link/" + token)
    except Error:
        raise AssertionError("Fixture magic-link navigation failed") from None
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
    page.wait_for_url("**/overview")


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page).to_have_url(ORIGIN + path)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def export_status(page: Page) -> int:
    status: object = page.evaluate("async () => (await fetch('/admin/usage/export')).status")
    assert isinstance(status, int)
    return status


def accept_dialog(dialog: Dialog) -> None:
    dialog.accept()


def forge_role(page: Page, target: str) -> None:
    """Send an actual LiveView event even when the mutation control is hidden."""
    page.evaluate(
        """target => window.liveSocket.main.pushHookEvent(
          document.querySelector("[data-phx-main]"), null, "set-role",
          {id: target, enabled: "true"})""",
        target,
    )
    expect(page.locator("#flash-error")).to_contain_text(
        "Administrative changes require an administrator"
    )


def main() -> None:
    """@cc [owner:ghuntley,label:verification] native-control-room-authority
    Browsing MUST use the packaged application with verified TLS. Allowed role
    changes MUST follow browser WebAuthn; refused writes MUST preserve stored
    roles and audit state. Revoked or expired logins MUST lose reads and exports.
    Fresh-request refusal after login expiry MUST establish remembered revocation.
    """
    reader_id, admin_id, target_id = (fixture_id(name) for name in ["reader", "admin", "target"])
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        reader_context = browser.new_context()
        reader = reader_context.new_page()
        reader.goto(ORIGIN + "/admin/users")
        expect(reader).to_have_url(ORIGIN + "/sign-in")
        sign_in(reader, "reader")
        assert sql(f"SELECT administrator FROM users WHERE id = '{reader_id}';") == "f"
        for path in [
            "users",
            "nodes",
            "jobs",
            "access",
            "workloads",
            "operations",
            "usage",
            "audit",
            "git",
        ]:
            visit(reader, "/admin/" + path)
            expect(reader.locator("#main-content")).to_be_visible()
            expect(reader.locator("a[href='/admin/nodes']").first).to_be_visible()
            expect(reader.locator("#flash-error")).to_have_count(0)
        assert export_status(reader) == 200
        reader.locator("a[href='/admin/users']").last.click()
        expect(reader).to_have_url(ORIGIN + "/admin/users")
        expect(reader.locator("[data-phx-main].phx-connected")).to_be_visible()
        expect(reader.locator("#invite-user")).to_have_count(0)
        before = sql("SELECT count(*) FROM account_admin_events;")
        forge_role(reader, target_id)
        assert sql(f"SELECT administrator FROM users WHERE id = '{target_id}';") == "f"
        assert sql("SELECT count(*) FROM account_admin_events;") == before

        admin_context = browser.new_context()
        admin = admin_context.new_page()
        admin.on("dialog", accept_dialog)
        cdp = admin_context.new_cdp_session(admin)
        cdp.send("WebAuthn.enable")
        cdp.send(
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
        sign_in(admin, "admin")
        visit(admin, "/admin/users")
        admin.locator(f"#role-{target_id}").click()
        admin.wait_for_url("**/settings?*")
        expect(admin.locator("[data-phx-main].phx-connected")).to_be_visible()
        assert sql(f"SELECT administrator FROM users WHERE id = '{target_id}';") == "f"
        admin.locator("#add-passkey").click()
        expect(admin.locator("#passkey-list > div")).to_have_count(1)
        admin.locator("#verify-passkey").click()
        expect(admin.locator("#verification-status")).to_contain_text("Passkey verified")
        admin.locator("#security-continue").click()
        expect(admin).to_have_url(ORIGIN + "/admin/users")
        expect(admin.locator("[data-phx-main].phx-connected")).to_be_visible()
        admin.locator(f"#role-{target_id}").click()
        expect(admin.locator(f"#role-{target_id}")).to_have_text("Remove administrator")
        assert (
            sql(
                f"SELECT count(*) FROM account_admin_events WHERE kind = 'grant' AND actor_id = '{admin_id}' AND target_id = '{target_id}';"
            )
            == "1"
        )
        admin.locator(f"#role-{target_id}").click()
        expect(admin.locator(f"#role-{target_id}")).to_have_text("Make administrator")

        # Real administrative revocation must invalidate an already mounted reader.
        admin.locator(f"#sessions-{reader_id}").click()
        expect(admin.locator("#flash-info")).to_contain_text("Browser sessions revoked")
        expect(reader).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        assert export_status(reader) == 404
        reader.goto(ORIGIN + "/admin/users")
        expect(reader).to_have_url(ORIGIN + "/sign-in")

        # Inject durable demotion while an elevated socket still holds an old actor.
        sql(f"UPDATE users SET administrator = false WHERE id = '{admin_id}';")
        before = sql("SELECT count(*) FROM account_admin_events;")
        forge_role(admin, target_id)
        assert sql(f"SELECT administrator FROM users WHERE id = '{target_id}';") == "f"
        assert sql("SELECT count(*) FROM account_admin_events;") == before
        visit(admin, "/admin/users")
        expect(admin.locator("#invite-user")).to_have_count(0)
        assert export_status(admin) == 200

        # Deterministic database expiry avoids sleeping for the login lifetime.
        sql(
            f"UPDATE tokens SET expires_at = clock_timestamp() - interval '1 second' WHERE subject = 'user?id={admin_id}' AND purpose = 'user';"
        )
        expect(admin).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        # The mounted socket refused the expired login and the sign-in request
        # dropped it from the session. Independent remembered authority then
        # resumes a new stored login for an ordinary read (ADR-0123, carried
        # forward by ADR-0160); it is neither email authentication nor elevation.
        assert (
            sql(
                f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose = 'remember_me';"
            )
            == "1"
        )
        assert export_status(admin) == 200
        assert (
            int(
                sql(
                    f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose = 'user' AND expires_at > clock_timestamp();"
                )
            )
            >= 1
        )
        # Revoke remembered authority through the real sign-out before fresh refusal.
        revoked_before = int(
            sql(
                f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose = 'revocation' AND expires_at > clock_timestamp();"
            )
        )
        admin.goto(ORIGIN + "/sign-out")
        admin.locator("form[action='/sign-out'] button[type=submit]").click()
        expect(admin).to_have_url(ORIGIN + "/sign-in")
        assert (
            sql(
                f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose = 'remember_me';"
            )
            == "0"
        )
        assert (
            int(
                sql(
                    f"SELECT count(*) FROM tokens WHERE subject = 'user?id={admin_id}' AND purpose = 'revocation' AND expires_at > clock_timestamp();"
                )
            )
            > revoked_before
        )
        admin.goto(ORIGIN + "/admin/users")
        expect(admin).to_have_url(ORIGIN + "/sign-in")
        assert export_status(admin) == 404
        browser.close()


if __name__ == "__main__":
    main()
