"""Real resize forms over verified HTTPS; private file barriers expose durable state."""

import json
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-resize")
ORIGIN = "https://control.example.test"
FRACTION = "5.000003814697265625"
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
    for key, field in value.items():
        assert isinstance(key, str)
        validated[key] = field
    result: dict[str, str] = {}
    for key in ("owner_token", "stranger_token"):
        field = validated.get(key)
        assert isinstance(field, str)
        result[key] = field
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def barrier(page: Page, name: str) -> None:
    (ROOT / (name + ".ready")).touch()
    deadline = time.monotonic() + 600
    while not (ROOT / (name + ".go")).exists():
        assert time.monotonic() < deadline, "Resize browser barrier timed out"
        page.wait_for_timeout(250)


def fill(page: Page, cpu: str, memory: str, disk: str) -> None:
    for name, value in (("vcpu", cpu), ("memory_mib", memory), ("disk_gib", disk)):
        page.locator("#resize_" + name).fill(value)
        page.locator("#resize_" + name).blur()
        page.wait_for_function(
            "([key, value]) => new URL(location.href).searchParams.get('resize[' + key + ']') === value",
            arg=[name, value],
        )


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] resize-native-browser-authority
    Accepted resize MUST enter the actual browser form with retained draft identity.
    Reload, stale submission and foreign authority MUST be observed through the UI.
    Authentication tokens, URLs and arbitrary browser exception messages stay private.
    """
    global stage
    users = fields()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context = browser.new_context()
            page = context.new_page()
            stage = "owner login"
            page.goto(ORIGIN + "/magic_link/" + users["owner_token"])
            connected(page)
            page.wait_for_url("**/overview")
            stage = "create guest"
            page.goto(ORIGIN + "/machines/new")
            connected(page)
            page.locator("#machine_vcpu").fill("1")
            page.locator("#machine_memory_mib").fill("512")
            page.locator("#machine_disk_gib").fill("5")
            page.locator("#provision-submit").click()
            # Submission lands on the thread-keyed provisioning receipt,
            # which opens the machine detail once the thread binds it.
            page.wait_for_url(machine_detail, timeout=120000)
            vm_id = urlsplit(page.url).path.split("/")[-1]
            assert str(uuid.UUID(vm_id)) == vm_id
            (ROOT / "vm-id").write_text(vm_id)
            barrier(page, "created")
            stage = "retained resize draft"
            page.goto(ORIGIN + "/machines/" + vm_id + "/resize")
            connected(page)
            fill(page, "2", "768", FRACTION)
            key = page.locator("#resize_request_key").input_value()
            generation = page.locator("#resize_expected_generation").input_value()
            stale = context.new_page()
            stale.goto(ORIGIN + "/machines/" + vm_id + "/resize")
            connected(stale)
            fill(stale, "1", "512", "6")
            draft_url = stale.url
            stale.close()
            page.reload()
            connected(page)
            expect(page.locator("#resize_request_key")).to_have_value(key)
            expect(page.locator("#resize_expected_generation")).to_have_value(generation)
            expect(page.locator("#resize_disk_gib")).to_have_value(FRACTION)
            stage = "running resize"
            page.locator("#submit-resize").click()
            expect(page.locator("#confirmed-resources")).to_contain_text(
                FRACTION + " GiB", timeout=300000
            )
            expect(page.locator("#resize-form")).to_be_visible(timeout=300000)
            expect(page.locator("#resize_vcpu")).to_have_value("2")
            page.reload()
            connected(page)
            expect(page.locator("#confirmed-resources")).to_contain_text(FRACTION + " GiB")
            barrier(page, "resized")
            stage = "stale draft refusal"
            page.goto(draft_url)
            connected(page)
            expect(page.locator("#resize-stale-draft")).to_be_visible()
            expect(page.locator("#resize_expected_generation")).to_have_value(generation)
            page.locator("#submit-resize").click()
            expect(page.locator("#flash-error")).to_contain_text("Resize could not be accepted")
            expect(page.locator("#resize-progress")).to_have_count(0)
            barrier(page, "refused")
            stage = "stopped resize"
            page.goto(ORIGIN + "/machines/" + vm_id + "/resize")
            connected(page)
            fill(page, "1", "512", "6")
            expect(page.locator("#submit-resize")).to_have_text("Resize machine")
            page.locator("#submit-resize").click()
            expect(page.locator("#confirmed-resources")).to_contain_text("6 GiB", timeout=180000)
            expect(page.locator("#resize-form")).to_be_visible(timeout=180000)
            barrier(page, "stopped")
            stage = "foreign resize refusal"
            stranger = browser.new_context()
            denied = stranger.new_page()
            denied.goto(ORIGIN + "/magic_link/" + users["stranger_token"])
            connected(denied)
            denied.wait_for_url("**/overview")
            denied.goto(ORIGIN + "/machines/" + vm_id + "/resize")
            connected(denied)
            expect(denied.locator("#resize-unavailable")).to_be_visible()
            expect(denied.locator("#resize-form")).to_have_count(0)
        finally:
            browser.close()
        (ROOT / "done").touch()


try:
    run()
except Exception as error:
    print(
        json.dumps(
            {"event": "resize_browser_failed", "stage": stage, "category": type(error).__name__}
        ),
        file=sys.stderr,
    )
    sys.exit(1)
