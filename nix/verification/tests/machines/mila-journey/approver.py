"""Bearer-protected HTTPS hook that approves one pending Mila device key.

The hook completes the real browser approval: it signs the fixture approver in
through a fresh Marshall magic link, opens the Porsche approval link in
Chromium, checks the displayed fingerprint and submits the approval form. It
never logs tokens, approval links or fingerprints.
"""

import hmac
import json
import re
import secrets
import ssl
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

ROOT = Path("/run/mila-fixture")
LOCK = threading.Lock()
FINGERPRINT = re.compile(r"\ASHA256:[A-Za-z0-9+/]{43}\Z")
TOKEN_PATH = re.compile(r"\A/ssh/approve/[A-Za-z0-9_-]{16,256}\Z")


def as_object(value: object) -> dict[str, object] | None:
    """Narrows parsed JSON to a string-keyed object, or None."""
    if not isinstance(value, dict):
        return None
    narrowed: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            return None
        narrowed[key] = item
    return narrowed


class Settings:
    """Startup configuration shared by request handlers."""

    origin: str = ""
    login_command: str = ""
    token: str = ""


def approve(approval_url: str, fingerprint: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] mila-approver-real-browser
    Approval MUST go through Marshall's authenticated approval page in a real
    browser as the fixture owner, after comparing the displayed fingerprint
    with the requested one. The hook MUST NOT write Marshall state directly.
    """
    login = ROOT / "login.json"
    login.unlink(missing_ok=True)
    subprocess.run([Settings.login_command, "login"], check=True, timeout=180)
    raw = as_object(json.loads(login.read_text()))
    login.unlink(missing_ok=True)
    token = raw.get("token") if raw is not None else None
    if not isinstance(token, str):
        raise RuntimeError("login token unavailable")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            page = browser.new_context().new_page()
            page.goto(Settings.origin + "/magic_link/" + token)
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
            page.wait_for_url("**/overview", timeout=30000)
            page.goto(approval_url)
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
            expect(page.locator("#ssh-approval-fingerprint")).to_have_text(fingerprint)
            page.locator("#approve-ssh-key").click()
            expect(page.locator("#ssh-approval-approved")).to_be_visible(timeout=30000)
        finally:
            browser.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass

    def reply(self, status: int, body: dict[str, object]) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self) -> None:
        supplied = self.headers.get("authorization", "")
        if self.path != "/approve" or not hmac.compare_digest(
            supplied.encode(), ("Bearer " + Settings.token).encode()
        ):
            return self.reply(403, {"approved": False, "error": "forbidden"})
        length = int(self.headers.get("content-length", "0") or "0")
        if length < 1 or length > 4096:
            return self.reply(400, {"approved": False, "error": "invalid_request"})
        try:
            body = as_object(json.loads(self.rfile.read(length)))
        except ValueError:
            return self.reply(400, {"approved": False, "error": "invalid_request"})
        if body is None:
            return self.reply(400, {"approved": False, "error": "invalid_request"})
        url = body.get("approval_url")
        fingerprint = body.get("fingerprint")
        if (
            not isinstance(url, str)
            or not isinstance(fingerprint, str)
            or not url.startswith(Settings.origin + "/")
            or not TOKEN_PATH.match(url[len(Settings.origin) :])
            or not FINGERPRINT.match(fingerprint)
        ):
            return self.reply(400, {"approved": False, "error": "invalid_request"})
        with LOCK:
            try:
                approve(url, fingerprint)
            except Exception as error:
                print(
                    json.dumps({"event": "mila_approval_failed", "category": type(error).__name__}),
                    file=sys.stderr,
                    flush=True,
                )
                return self.reply(502, {"approved": False, "error": "approval_failed"})
        return self.reply(200, {"approved": True})


def main() -> None:
    origin, login_command, port, certificate, key = sys.argv[1:6]
    Settings.origin = origin
    Settings.login_command = login_command
    token_file = ROOT / "approver.token"
    if not token_file.exists():
        token_file.touch(mode=0o600)
        token_file.write_text(secrets.token_urlsafe(32))
    Settings.token = token_file.read_text().strip()
    server = ThreadingHTTPServer(("0.0.0.0", int(port)), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
