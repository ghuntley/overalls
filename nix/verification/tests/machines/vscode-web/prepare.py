"""Create the editor fixture through the ordinary signed-in machine form."""

import argparse
import json
import os
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from playwright.sync_api import Error, TimeoutError, expect, sync_playwright

type PreparationStage = Literal[
    "input", "launch", "sign-in", "form", "submit", "custody", "cleanup"
]
type FailureKind = Literal["timeout", "assertion", "browser", "custody", "unexpected"]


def machine_detail(url: str) -> bool:
    """True only for /machines/<uuid>, not the form or provisioning receipt."""
    parts = urlsplit(url).path.split("/")
    if len(parts) != 3 or parts[1] != "machines":
        return False
    try:
        return str(uuid.UUID(parts[2])) == parts[2]
    except ValueError:
        return False


@dataclass
class PreparationProgress:
    stage: PreparationStage = "input"


def failure_kind(error: Exception) -> FailureKind:
    """@cc [owner:ghuntley,label:security] editor-prepare-finite-diagnostics
    Failure diagnostics MUST expose only a fixed preparation stage and fixed
    exception category; exception text, URLs and browser state MUST stay private.
    """
    if isinstance(error, TimeoutError):
        return "timeout"
    if isinstance(error, AssertionError):
        return "assertion"
    if isinstance(error, Error):
        return "browser"
    if isinstance(error, OSError):
        return "custody"
    return "unexpected"


def strings(path: Path) -> dict[str, str]:
    value: object = json.loads(path.read_text())
    assert isinstance(value, dict)
    result: dict[str, str] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        if isinstance(item, str):
            result[key] = item
    for name in ("owner_token", "owner_id", "image_id"):
        assert name in result
    return result


def main(progress: PreparationProgress) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-real-browser-seed
    The fixture MUST log in an ordinary owner and create one VM using the real
    browser form's default image and shape. Private storage state MUST retain
    mode 0600; no editor token or authority may be injected by this helper.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("users", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    users_path, output = arguments.users, arguments.output
    assert isinstance(users_path, Path) and isinstance(output, Path)
    users = strings(users_path)
    progress.stage = "launch"
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        context = browser.new_context()
        page = context.new_page()
        progress.stage = "sign-in"
        page.goto("https://control.example.test/magic_link/" + users["owner_token"])
        page.wait_for_url("**/overview")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        progress.stage = "form"
        page.goto("https://control.example.test/machines/new")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        expect(page.locator("#machine_profile")).to_have_value("oss")
        expect(page.locator("#machine_image_id")).to_have_value(users["image_id"])
        progress.stage = "submit"
        page.locator("#provision-submit").click()
        # Submission lands on the thread-keyed provisioning receipt,
        # which opens the machine detail once the thread binds it.
        page.wait_for_url(machine_detail, timeout=120000)
        vm_id = urlsplit(page.url).path.split("/")[-1]
        assert str(uuid.UUID(vm_id)) == vm_id
        progress.stage = "custody"
        output.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(output, 0o700)
        state = output / "storage-state.json"
        context.storage_state(path=state)
        os.chmod(state, 0o600)
        (output / "vm-id").write_text(vm_id)
        os.chmod(output / "vm-id", 0o600)
        progress.stage = "cleanup"
        context.close()
        browser.close()


if __name__ == "__main__":
    progress = PreparationProgress()
    try:
        main(progress)
    except Exception as error:
        print(
            "Editor fixture preparation failed: "
            + progress.stage
            + "/"
            + failure_kind(error)
            + "; browser details withheld",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
