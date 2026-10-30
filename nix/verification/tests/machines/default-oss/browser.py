"""Ordinary installed-system owner saves an OSS preset and creates a machine."""

import json
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-default-oss")
ORIGIN = "https://control.example.test"
stage = "launch"
page_state: dict[str, object] = {}


def fields() -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification] default-oss-fixture-field-types
    Fixture JSON MUST provide string owner/member/stranger tokens and image ID
    before browser use; missing or non-string required fields MUST fail the
    journey.
    """
    value: object = json.loads((ROOT / "users.json").read_text())
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for name, item in value.items():
        assert isinstance(name, str)
        fields[name] = item
    result: dict[str, str] = {}
    for key in ("owner_token", "member_token", "stranger_token", "image_id"):
        field = fields.get(key)
        assert isinstance(field, str)
        result[key] = field
    return result


def machine_detail(url: str) -> bool:
    """True only for /machines/<uuid>, not the form or provisioning receipt."""
    parts = urlsplit(url).path.split("/")
    if len(parts) != 3 or parts[1] != "machines":
        return False
    try:
        return str(uuid.UUID(parts[2])) == parts[2]
    except ValueError:
        return False


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] default-oss-browser-entry
    The browser MUST save its machine preset through account settings, leave that
    preset untouched in the creation form, preserve its request across reload,
    and submit through the real form. Registered keys MUST use
    the actual key settings UI. Login tokens and failure URLs stay private.
    """
    global stage
    users = fields()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        current: Page | None = None
        try:
            for role in ("owner", "member", "stranger"):
                stage = role + " login"
                context = browser.new_context()
                page = context.new_page()
                current = page
                page.goto(ORIGIN + "/magic_link/" + users[role + "_token"])
                connected(page)
                page.wait_for_url("**/overview")
                stage = role + " key registration"
                page.goto(ORIGIN + "/settings")
                connected(page)
                page.get_by_label("Public key", exact=True).fill(
                    (ROOT / (role + ".pub")).read_text()
                )
                page.get_by_label("Label (optional)", exact=True).fill("default-profile-" + role)
                page.locator("#add-ssh-key").click()
                expect(page.locator("article")).to_contain_text("default-profile-" + role)
                if role == "owner":
                    stage = "account machine preset"
                    expect(page.locator("#launch_defaults_profile")).to_have_value("oss")
                    expect(page.locator("#machine_defaults_profile")).to_have_value("standard")
                    expect(page.locator("#thread_defaults_profile")).to_have_value("standard")
                    page.locator("#machine_defaults_profile").select_option("oss")
                    page.locator("#machine_defaults_image_id").select_option(users["image_id"])
                    page.locator("#machine-defaults-form button[type=submit]").click()
                    expect(page.locator("#flash-info")).to_contain_text("Machine defaults saved.")
                    page.reload()
                    connected(page)
                    expect(page.locator("#machine_defaults_profile")).to_have_value("oss")
                    expect(page.locator("#launch_defaults_profile")).to_have_value("oss")
                    expect(page.locator("#thread_defaults_profile")).to_have_value("standard")
                    stage = "saved OSS preset form"
                    page.goto(ORIGIN + "/machines/new")
                    connected(page)
                    expect(page.locator("#machine_profile")).to_have_value("oss")
                    expect(page.locator("#machine_image_id")).to_have_value(users["image_id"])
                    key = page.locator("#machine_request_key").input_value()
                    stage = "draft reload"
                    page.reload()
                    connected(page)
                    expect(page.locator("#machine_profile")).to_have_value("oss")
                    # The initial draft receives its key in the URL on mount.
                    expect(page.locator("#machine_request_key")).to_have_value(key)
                    stage = "default OSS admission"
                    page.locator("#provision-submit").click()
                    # Submission lands on the thread-keyed provisioning receipt,
                    # which opens the machine detail once the thread binds it.
                    page.wait_for_url(machine_detail, timeout=120000)
                    vm_id = urlsplit(page.url).path.split("/")[-1]
                    assert str(uuid.UUID(vm_id)) == vm_id
                    (ROOT / "browser-vm").write_text(vm_id)
                context.close()
        except Exception:
            if current is not None and not current.is_closed():
                observe(current)
            raise
        finally:
            browser.close()


def observe(page: Page) -> None:
    """Record booleans and counts only: no URL, token or page text leaves the VM."""
    page_state["on_settings"] = urlsplit(page.url).path == "/settings"
    page_state["connected"] = page.locator("[data-phx-main].phx-connected").count() > 0
    page_state["key_articles"] = page.locator("#ssh-keys article").count()
    page_state["keys_empty"] = page.locator("#ssh-keys-empty").count() > 0
    page_state["flash_error"] = page.locator("#flash-error").count() > 0
    page_state["flash_info"] = page.locator("#flash-info").count() > 0


def refusal() -> None:
    """@cc [owner:ghuntley,label:verification;security] default-oss-member-refusal
    The member's real browser login MUST NOT list the Customer machine and
    direct detail URLs MUST land on the machines index with the fixed
    unavailable notice. Login tokens and page HTML stay inside this helper.
    """
    global stage
    users = fields()
    customer = (ROOT / "customer-vm").read_text().strip()
    assert str(uuid.UUID(customer)) == customer
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        page: Page | None = None
        try:
            stage = "member refusal login"
            context = browser.new_context()
            page = context.new_page()
            page.goto(ORIGIN + "/magic_link/" + users["member_token"])
            connected(page)
            page.wait_for_url("**/overview")
            stage = "member list exclusion"
            page.goto(ORIGIN + "/machines")
            connected(page)
            expect(page.locator("#machines-empty")).to_be_visible(timeout=20000)
            expect(page.locator("#machines-" + customer)).to_have_count(0)
            stage = "member customer detail refusal"
            for path, notice in (
                ("/machines/" + customer, "Machine not found"),
                ("/machines/" + customer + "/settings", "unavailable"),
            ):
                page.goto(ORIGIN + path)
                page.wait_for_url("**/machines", timeout=60000)
                connected(page)
                expect(page.locator("#flash-group")).not_to_be_empty(timeout=20000)
                flash_text = page.locator("#flash-group").inner_text()
                detail_count = page.locator("#machine-detail").count()
                assert notice in flash_text and detail_count == 0, json.dumps(
                    {
                        "notice_seen": notice in flash_text,
                        "detail_count": detail_count,
                        "on_machines_index": page.url.rstrip("/").endswith("/machines"),
                        "path_kind": "settings" if path.endswith("/settings") else "detail",
                    }
                )
            context.close()
        except Exception as error:
            # Failure diagnostics expose only booleans and the fixed stage
            # marker; the page URL path and texts stay inside the VM.
            detail: dict[str, object] = {
                "stage": stage,
                "category": type(error).__name__,
            }
            if page is not None:
                detail["on_machines_index"] = bool(page.url.rstrip("/").endswith("/machines"))
                detail["flash_present"] = page.locator("#flash-group").count() > 0
                detail["detail_present"] = page.locator("#machine-detail").count() > 0
            print(json.dumps(detail), file=sys.stderr)
            raise
        finally:
            browser.close()


mode = sys.argv[1] if len(sys.argv) > 1 else "create"

try:
    if mode == "refusal":
        refusal()
    else:
        run()
except Exception as error:
    failure: dict[str, object] = {
        "event": "default_profile_browser_failed",
        "mode": mode,
        "stage": stage,
        "category": type(error).__name__,
    }
    failure.update(page_state)
    print(json.dumps(failure), file=sys.stderr)
    sys.exit(1)
