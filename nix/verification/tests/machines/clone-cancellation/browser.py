"""Public browser cloning, cancellation and manager withdrawal on verified HTTPS."""

import json
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import Browser, Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-clone-cancellation")
ORIGIN = "https://control.example.test"
stage = "launch"


def machine_detail(url: str) -> bool:
    """True only for /machines/<uuid>, not the form or provisioning receipt."""
    parts = urlsplit(url).path.split("/")
    if len(parts) != 3 or parts[1] != "machines":
        return False
    try:
        return str(uuid.UUID(parts[2])) == parts[2]
    except ValueError:
        return False


def fields() -> dict[str, str]:
    value: object = json.loads((ROOT / "users.json").read_text())
    assert isinstance(value, dict)
    validated: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        validated[key] = item
    result: dict[str, str] = {}
    for key in ("owner_token", "member_token", "member_email"):
        item = validated.get(key)
        assert isinstance(item, str)
        result[key] = item
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def barrier(page: Page, name: str) -> None:
    (ROOT / (name + ".ready")).touch()
    deadline = time.monotonic() + 600
    while not (ROOT / (name + ".go")).exists():
        assert time.monotonic() < deadline, "Clone browser checkpoint timed out"
        page.wait_for_timeout(250)


def login(browser: Browser, token: str) -> Page:
    page = browser.new_context().new_page()
    page.goto(ORIGIN + "/magic_link/" + token)
    connected(page)
    page.wait_for_url("**/overview")
    return page


def share(page: Page, vm: str, email: str, role: str) -> None:
    page.goto(ORIGIN + "/machines/" + vm + "/access")
    connected(page)
    page.locator("#access_email").fill(email)
    page.locator("#access_role").select_option(role)
    page.locator("#share-submit").click()
    expect(page.locator("#flash-info")).to_contain_text("Access updated.")


def clone(page: Page, vm: str, name: str) -> None:
    page.goto(ORIGIN + "/machines/" + vm + "/settings")
    connected(page)
    page.get_by_label("New machine name (optional)", exact=True).fill(name)
    page.wait_for_url("**/*" + name + "*")
    page.locator("#submit-clone").click()
    expect(page.locator("#clone-requests")).to_contain_text(name)


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] clone-native-public-authority
    Creation, manager sharing, cancellation and revocation MUST use real browser
    controls. The retained manager tab MUST lose controls after owner revocation;
    token-bearing URLs, browser exceptions and terminal data remain private.
    """
    global stage
    users = fields()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            stage = "owner login and source creation"
            owner = login(browser, users["owner_token"])
            owner.goto(ORIGIN + "/machines/new")
            connected(owner)
            owner.locator("#machine_profile").select_option("standard")
            owner.wait_for_url(
                lambda url: parse_qs(urlsplit(url).query).get("machine[profile]") == ["standard"]
            )
            owner.locator("#machine_vcpu").fill("1")
            owner.locator("#machine_memory_mib").fill("512")
            owner.locator("#machine_disk_gib").fill("5")
            owner.locator("#provision-submit").click()
            # Submission lands on the thread-keyed provisioning receipt,
            # which opens the machine detail once the thread binds it.
            owner.wait_for_url(machine_detail, timeout=120000)
            vm = urlsplit(owner.url).path.split("/")[-1]
            assert str(uuid.UUID(vm)) == vm
            (ROOT / "vm-id").write_text(vm)
            barrier(owner, "created")
            stage = "manager sharing and queued requests"
            share(owner, vm, users["member_email"], "manager")
            manager = login(browser, users["member_token"])
            clone(manager, vm, "cancel-captured-copy")
            clone(manager, vm, "revoked-queued-copy")
            barrier(manager, "submitted")
            stage = "cancel observed captured copy"
            first = (ROOT / "cancel-id").read_text().strip()
            assert str(uuid.UUID(first)) == first
            manager.locator("#clones-" + first + "-cancel").click()
            expect(manager.locator("#clones-" + first)).to_contain_text("Cancelling clone")
            barrier(manager, "cancelled")
            stage = "owner revokes current manager"
            share(owner, vm, users["member_email"], "revoked")
            expect(owner.locator("#grants")).not_to_contain_text(users["member_email"])
            expect(manager.locator("#submit-clone")).to_have_count(0, timeout=20000)
            expect(manager.locator("#clone-requests")).to_have_count(0)
            barrier(owner, "revoked")
            stage = "successful owner copy control"
            clone(owner, vm, "successful-clone-control")
            expect(owner.locator("#clone-requests")).to_contain_text(
                "Clone complete", timeout=300000
            )
            barrier(owner, "complete")
        finally:
            browser.close()
        (ROOT / "done").touch()


try:
    run()
except Exception as error:
    print(
        json.dumps(
            {"event": "clone_browser_failed", "stage": stage, "category": type(error).__name__}
        ),
        file=sys.stderr,
    )
    sys.exit(1)
