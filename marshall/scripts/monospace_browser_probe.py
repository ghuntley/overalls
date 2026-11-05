"""Exercise the Monospace Web presentation against its disposable local fixture."""

import json
import os
import re
import sys
import traceback
from pathlib import Path
from typing import Literal, TypedDict
from urllib.parse import urlsplit

from playwright.sync_api import (
    Browser,
    BrowserContext,
    ConsoleMessage,
    Page,
    Request,
    expect,
    sync_playwright,
)
from playwright.sync_api import (
    TimeoutError as PlaywrightTimeoutError,
)


class Context(TypedDict):
    origin: str
    vm_id: str
    owner: str
    admin: str
    empty: str
    viewer: str
    operator: str
    manager: str
    owner_email: str
    viewer_email: str
    operator_email: str
    manager_email: str
    ready_thread_id: str
    archived_thread_id: str
    pending_thread_id: str
    provisioning_thread_id: str
    failed_thread_id: str


class OffGrid(TypedDict):
    selector: str
    offset: float


def read_context(path: Path) -> Context:
    """Validate the external fixture data before using browser destinations."""
    data: object = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("Invalid fixture context")

    def field(key: str) -> str:
        value: object = data.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError("Invalid fixture context field")
        return value

    origin = field("origin")
    if (
        not origin.startswith("http://localhost:")
        or not origin.removeprefix("http://localhost:").isdigit()
    ):
        raise ValueError("Fixture must use localhost")
    return Context(
        origin=origin,
        vm_id=field("vm_id"),
        owner=field("owner"),
        admin=field("admin"),
        empty=field("empty"),
        viewer=field("viewer"),
        operator=field("operator"),
        manager=field("manager"),
        owner_email=field("owner_email"),
        viewer_email=field("viewer_email"),
        operator_email=field("operator_email"),
        manager_email=field("manager_email"),
        ready_thread_id=field("ready_thread_id"),
        archived_thread_id=field("archived_thread_id"),
        pending_thread_id=field("pending_thread_id"),
        provisioning_thread_id=field("provisioning_thread_id"),
        failed_thread_id=field("failed_thread_id"),
    )


# Forwards every Content-Security-Policy violation of a document (including
# iframes) to the console with a fixed prefix, so one context-level console
# listener sees violations from every page without reading page state.
CSP_VIOLATION_PREFIX = "overalls-csp-violation"
CSP_INIT_SCRIPT = (
    "document.addEventListener('securitypolicyviolation', (event) => {"
    f"  console.error('{CSP_VIOLATION_PREFIX}', event.violatedDirective, "
    "    event.blockedURI, new URL(event.documentURI).pathname);"
    "});"
)


def redact_path(text: str) -> str:
    """Replace token-like path segments so a violation record never carries a credential."""
    return re.sub(r"[A-Za-z0-9_-]{20,}", "<redacted>", text)


class OriginWatch:
    """@cc [owner:ghuntley,label:security;product] presentation-no-external-resources
    Every stylesheet, script, font and image MUST load from the application origin.
    A request to any other host fails the probe regardless of its outcome; this
    recorder keeps every cross-origin request URL for the final assertion.
    """

    def __init__(self, origin: str) -> None:
        self.host = urlsplit(origin).netloc
        self.urls: list[str] = []
        self.csp_violations: list[str] = []

    def observe(self, request: Request) -> None:
        if urlsplit(request.url).netloc != self.host:
            self.urls.append(request.url)

    def observe_console(self, message: ConsoleMessage) -> None:
        """@cc [owner:ghuntley,label:security;verification] presentation-no-csp-violations
        Every document the probe opens MUST render under the production
        Content-Security-Policy without a violation: neither the forwarded
        `securitypolicyviolation` event nor Chromium's own "Content Security
        Policy" console report may occur. Records keep directives and
        redacted paths only, never page text or credential-bearing URLs.
        """
        text = message.text
        if text.startswith(CSP_VIOLATION_PREFIX):
            self.csp_violations.append(redact_path(text))
        elif "Content Security Policy" in text:
            self.csp_violations.append("console: " + redact_path(text)[:200])

    def attach(self, context: BrowserContext) -> None:
        context.on("request", self.observe)
        context.add_init_script(CSP_INIT_SCRIPT)
        context.on("console", self.observe_console)


def sign_in(
    browser: Browser,
    fixture: Context,
    role: Literal["owner", "admin", "empty", "viewer", "operator", "manager"],
    watch: OriginWatch,
) -> BrowserContext:
    context = browser.new_context(
        viewport={"width": 1440, "height": 1000},
        # Keep touch input available for the phone-width composer probe while
        # retaining the same authenticated context for desktop checks.
        has_touch=True,
    )
    watch.attach(context)
    page = context.new_page()
    login = fixture[role]
    page.goto(fixture["origin"] + login)
    # The magic-link page submits itself once connected; the button is the
    # JavaScript-free fallback and must not race that navigation.
    try:
        page.wait_for_url("**/overview", timeout=10_000)
    except PlaywrightTimeoutError:
        page.locator("form button[type=submit]").click(no_wait_after=True)
        page.wait_for_url("**/overview")
    expect(page.locator("#overview")).to_be_visible()
    check_browser_extension_presence(page)
    return context


def check_browser_extension_presence(page: Page) -> None:
    """@cc [owner:ghuntley,label:product;verification] browser-extension-setup-discovery
    Setup entry points MUST remain visible without the local extension marker
    and MUST be hidden after the marker is added. Removing the marker MUST make
    the entry points visible again; this presentation signal grants no access.
    """
    setup = page.locator("[data-overalls-extension-setup]")
    expect(setup).to_have_count(2)
    expect(setup.nth(0)).to_be_visible()
    expect(setup.nth(1)).to_be_visible()
    evaluate(
        page,
        "document.documentElement.setAttribute('data-overalls-browser-extension', 'installed')",
    )
    expect(setup.nth(0)).not_to_be_visible()
    expect(setup.nth(1)).not_to_be_visible()
    evaluate(page, "document.documentElement.removeAttribute('data-overalls-browser-extension')")
    expect(setup.nth(0)).to_be_visible()
    expect(setup.nth(1)).to_be_visible()


def evaluate(page: Page, expression: str) -> object:
    """Evaluate an expression in the page's main world through the inspector.

    The production Content-Security-Policy forbids `eval`, which Playwright's own
    `page.evaluate` relies on. An inspector-compiled expression is not page
    `eval`, so the policy stays fully enforced for the application's scripts
    while the probe reads page state. Promises are awaited; the value must be
    JSON-serialisable or it is returned as `None`.
    """
    session = page.context.new_cdp_session(page)
    try:
        reply: object = session.send(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
    finally:
        session.detach()
    if not isinstance(reply, dict):
        raise ValueError("Inspector reply is not an object")
    if "exceptionDetails" in reply:
        # The exception text can quote page content; report only the failure.
        raise RuntimeError("Page evaluation failed")
    result: object = reply.get("result")
    if not isinstance(result, dict):
        raise ValueError("Inspector result is not an object")
    return result.get("value")


def evaluate_on(page: Page, selector: str, body: str) -> object:
    """Call `(node) => body` on the first element matching `selector`."""
    return evaluate(page, f"((node) => {body})(document.querySelector({json.dumps(selector)}))")


def visit(page: Page, origin: str, route: str) -> None:
    response = page.goto(origin + route)
    # Every document is served under the strict production policy; the CSP
    # violation watch then proves the page renders within it.
    assert response is not None, "Navigation produced no response"
    policy = response.headers.get("content-security-policy", "")
    assert (
        "script-src 'self' 'wasm-unsafe-eval';" in policy and "frame-ancestors 'self';" in policy
    ), f"Missing strict Content-Security-Policy on {route}"
    expect(page.locator("#main-content")).to_be_visible()
    page.locator("[data-phx-main]").wait_for(state="attached")
    page.locator("[data-phx-main].phx-connected").wait_for(state="attached")
    evaluate(page, "document.fonts.ready.then(() => true)")


def check_overflow(page: Page) -> None:
    assert evaluate(page, "document.documentElement.scrollWidth <= window.innerWidth + 1"), (
        "Page overflows the viewport"
    )


def check_font(page: Page) -> None:
    assert evaluate(page, "document.fonts.check('16px \"JetBrains Mono\"')"), (
        "JetBrains Mono is not available from the application origin"
    )


def check_machine_tabs(page: Page) -> None:
    """Wrapped machine tabs must remain within their navigation box."""
    tabs = page.locator("nav[aria-label='Machine workspace']")
    bounds = tabs.bounding_box()
    assert bounds is not None, "Machine navigation is missing"
    for link in tabs.locator("a, button").all():
        item = link.bounding_box()
        assert item is not None, "Machine navigation control is hidden"
        assert bounds["y"] - 0.1 <= item["y"], "Machine tab begins outside its navigation"
        assert item["y"] + item["height"] <= bounds["y"] + bounds["height"] + 0.1, (
            "Wrapped machine tab escapes its navigation"
        )


def check_machine_header(page: Page) -> None:
    """The heading box shows name, state and operating system, then facts and the ID with Copy."""
    heading = page.locator("#machine-workspace-header .machine-heading")
    expect(heading).to_be_visible()
    expect(heading.locator("h1")).to_be_visible()
    expect(page.locator("#machine-state")).to_be_visible()
    expect(page.locator("#machine-os")).to_be_visible()
    os_name = page.locator("#machine-os").text_content()
    assert os_name is not None and os_name.strip() not in ("", "nil"), "Operating system is blank"
    expect(page.locator("#machine-id")).to_be_visible()
    expect(page.locator("[data-copy-command='machine-id']")).to_be_visible()
    expect(heading.locator("button.pin-toggle")).to_have_attribute("aria-pressed", "false")
    bounds = heading.bounding_box()
    assert bounds is not None, "Machine heading is missing"
    for selector in ("h1", "#machine-state", "#machine-os", "#machine-id", "#lifecycle-actions"):
        if selector == "#lifecycle-actions" and heading.locator(selector).count() == 0:
            continue  # power actions render only for managers
        item = heading.locator(selector).first.bounding_box()
        assert item is not None, f"{selector} is hidden in the machine heading"
        assert bounds["y"] - 0.1 <= item["y"], f"{selector} begins above the heading box"
        assert item["y"] + item["height"] <= bounds["y"] + bounds["height"] + 0.1, (
            f"{selector} escapes the heading box"
        )
        assert item["x"] + item["width"] <= bounds["x"] + bounds["width"] + 0.1, (
            f"{selector} overflows the heading box"
        )
    title = heading.locator("h1").bounding_box()
    state = page.locator("#machine-state").bounding_box()
    assert title is not None and state is not None
    assert abs(title["y"] - state["y"]) < 0.1 or state["y"] > title["y"], (
        "State label sits above the machine name"
    )


def label_style(page: Page, selector: str) -> dict[str, object]:
    """Computed presentation of the first status label matching `selector`."""
    value: object = evaluate_on(
        page,
        selector,
        """({
          text: node.textContent,
          color: getComputedStyle(node).color,
          background: getComputedStyle(node).backgroundColor,
          weight: getComputedStyle(node).fontWeight,
          style: getComputedStyle(node).fontStyle,
          height: node.getBoundingClientRect().height,
          page: getComputedStyle(document.documentElement).color,
          pageBackground: getComputedStyle(document.documentElement).backgroundColor,
        })""",
    )
    assert isinstance(value, dict), f"No status label matches {selector}"
    return value


def check_status_labels(page: Page) -> None:
    """@cc [owner:ghuntley,label:product;verification] status-label-severity-presentation
    Machine status labels MUST name the state in text and carry severity
    without colour-only meaning: Failed is bold inverse video exactly one grid
    row tall, Running is bold on the page colours, Stopped is plain weight on
    the page colours, and the pinned/OS labels keep the secondary colour. The
    fixture seeds these observations; they are not guest execution evidence.
    """
    row = line_height(page)
    failed = label_style(page, ".status-label[data-state='failed']")
    running = label_style(page, ".status-label[data-state='running'][data-tone='success']")
    stopped = label_style(page, ".status-label[data-state='stopped']:not([data-tone])")
    assert failed["text"] == "Failed" and running["text"] == "Running", "State text differs"
    assert stopped["text"] == "Stopped", "Stopped label text differs"
    assert failed["background"] == failed["page"] and failed["color"] == failed["pageBackground"], (
        "Failed label is not inverse video"
    )
    assert failed["weight"] == "800" and failed["style"] == "normal", "Failed label weight differs"
    height = failed["height"]
    assert isinstance(height, (int, float)) and abs(float(height) - row) < 0.1, (
        "Failed label is not one grid row tall"
    )
    assert running["background"] == "rgba(0, 0, 0, 0)" and running["weight"] == "800", (
        "Running label is not bold on the page background"
    )
    assert stopped["background"] == "rgba(0, 0, 0, 0)" and stopped["weight"] == "500", (
        "Stopped label is not plain weight on the page background"
    )
    assert stopped["color"] == stopped["page"], "Stopped label is not the page text colour"
    assert running["color"] == running["page"], "Running label is not the page text colour"
    assert failed["color"] != stopped["color"], "Failed and Stopped labels share a colour"


def check_machine_pins(page: Page) -> None:
    """@cc [owner:ghuntley,label:product;verification] machines-pin-toggle-order
    Pinning a later row that offers a Pin control MUST move it to the first row
    with its Pinned label and pressed toggle, keep every row exactly once, and
    unpinning MUST restore the id order. Failed machines offer no Pin control,
    so the probe picks the first pinnable row after the first; it waits for the
    LiveView connection before clicking.
    """
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1)
    rows = page.locator("#machines tr.machine-row")
    before = row_ids(page)
    assert len(before) >= 2, "The fixture owner needs at least two listed machines"
    pinnable = [
        index
        for index in range(1, len(before))
        if rows.nth(index).locator("button.pin-toggle[aria-pressed='false']").count() == 1
    ]
    assert pinnable, "No later machine row offers a Pin control"
    second = before[pinnable[0]]
    toggle = rows.nth(pinnable[0]).locator("button.pin-toggle")
    expect(toggle).to_have_attribute("aria-pressed", "false")
    expect(toggle).to_have_text("Pin")
    toggle.click()
    first = page.locator("#machines tr.machine-row").first
    expect(first).to_have_id(second)
    expect(first).to_have_attribute("data-pinned", "true")
    expect(first.locator(".pinned-label")).to_have_text("Pinned")
    expect(first.locator("button.pin-toggle")).to_have_attribute("aria-pressed", "true")
    expect(rows).to_have_count(len(before))
    assert row_ids(page) == [second, *[row for row in before if row != second]], (
        "Pinned machine is not first with the rest in their original order"
    )
    check_overflow(page)
    first.locator("button.pin-toggle").click()
    expect(page.locator("#machines tr.machine-row").first).to_have_id(before[0])
    expect(page.locator("#machines tr.machine-row[data-pinned='true']")).to_have_count(0)
    assert row_ids(page) == before, "Unpinning did not restore the id order"


def check_account(page: Page, origin: str, theme: str) -> None:
    """@cc [owner:ghuntley,label:product;verification] account-page-presentation
    The account page at /settings MUST be the only "Your account" settings
    entry (#nav-account current) and MUST render the profile, sign-in, SSH
    key and Git identity sections in that order with an index whose anchors land each section
    at the top of the viewport. The profile section MUST preselect the
    browser's zone until one is saved, save the chosen zone through the picker
    and show the viewer's local clock in that zone; every converted timestamp
    on the overview MUST end in the saved zone's abbreviation while keeping the
    UTC instant in its title. The probe checks this in both themes and restores
    the detected zone afterwards.
    """
    visit(page, origin, "/settings")
    expect(page.locator("#nav-account")).to_have_attribute("aria-current", "page")
    expect(page.locator("#nav-usage")).to_have_attribute("href", "/usage")
    expect(page.locator("#workspace-sidebar a[href^='/settings/']")).to_have_count(0)
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1)
    sections = ("profile", "security", "ssh-keys", "git-settings", "machine-defaults")
    for anchor in sections:
        expect(page.locator(f"#account-index a[href='#{anchor}']")).to_be_visible()
        expect(page.locator(f"section#{anchor}.account-section")).to_be_visible()
    tops = [section_top(page, anchor) for anchor in sections]
    assert tops == sorted(tops), "Account sections are out of order"
    expect(page.locator("#passkey-ceremony #add-passkey")).to_be_visible()
    expect(page.locator("#passkey-ceremony #verify-passkey")).to_be_visible()
    expect(page.locator("#verification-status")).to_contain_text("[not verified]")
    expect(page.locator("#ssh-key-form #add-ssh-key")).to_be_visible()
    expect(page.locator("article[id^='ssh-key-'] code")).to_have_count(1)
    detected: object = evaluate(page, "Intl.DateTimeFormat().resolvedOptions().timeZone")
    assert isinstance(detected, str) and detected, "Browser must report an Intl zone"
    status = page.locator("#time-zone-status")
    expect(status).to_have_attribute("data-source", "browser")
    expect(page.locator("#profile_time_zone")).to_have_value(detected)
    expect(page.locator("#profile-local-clock")).to_have_attribute("data-zone", detected)
    expect(page.locator("#clear-time-zone")).to_have_count(0)
    option_label: object = page.locator("#profile_time_zone option:checked").text_content()
    assert isinstance(option_label, str) and re.match(r"^\(GMT[+-]\d{2}:\d{2}\) ", option_label), (
        "Picker labels must lead with the current GMT offset"
    )
    page.locator("#profile_time_zone").select_option("Australia/Adelaide")
    page.locator("#save-time-zone").click()
    expect(status).to_have_attribute("data-source", "saved")
    expect(status).to_contain_text("Australia/Adelaide")
    expect(page.locator("#profile-local-clock")).to_have_attribute(
        "data-zone", "Australia/Adelaide"
    )
    expect(page.locator("#profile-local-clock")).to_have_text(re.compile(r"AC[DS]T$"))
    expect(page.locator("#account-local-clock")).to_have_attribute(
        "data-zone", "Australia/Adelaide"
    )
    expect(page.locator("#clear-time-zone")).to_be_visible()
    check_grid(page, "/settings")
    visit(page, origin, "/overview")
    stamp = page.locator(".overview-refresh time.timestamp")
    expect(stamp).to_have_attribute("data-zone", "Australia/Adelaide")
    expect(stamp).to_have_text(re.compile(r"\d{2}:\d{2} AC[DS]T$"))
    title: object = stamp.get_attribute("title")
    assert isinstance(title, str) and title.endswith(" UTC"), "Hover title must keep UTC"
    # The sidebar clock links to the profile anchor; the SSH anchor used by
    # the CLI hint and approval page lands its section at the top.
    expect(page.locator("#account-local-clock + a.nav-hint")).to_have_attribute(
        "href", "/settings#profile"
    )
    visit(page, origin, "/settings#profile")
    assert section_top(page, "profile") <= 2 * line_height(page), (
        "The #profile anchor did not scroll its section into view"
    )
    # A second fragment on the same document would not load a new page.
    visit(page, origin, "/overview")
    visit(page, origin, "/settings#ssh-keys")
    # The last section can be shorter than the viewport; then the page ends
    # scrolled to its bottom with the section fully visible instead.
    assert section_top(page, "ssh-keys") <= 2 * line_height(page) or scrolled_to_end(page), (
        "The #ssh-keys anchor did not scroll its section into view"
    )
    page.locator("#clear-time-zone").click()
    expect(status).to_have_attribute("data-source", "browser")
    expect(page.locator("#profile_time_zone")).to_have_value(detected)
    expect(page.locator("#clear-time-zone")).to_have_count(0)
    if theme == "dark":
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")


def section_top(page: Page, anchor: str) -> float:
    box = page.locator(f"section#{anchor}").bounding_box()
    assert box is not None, f"Section #{anchor} is not laid out"
    return float(box["y"])


def scrolled_to_end(page: Page) -> bool:
    return (
        evaluate(
            page,
            "window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 1",
        )
        is True
    )


def line_height(page: Page) -> float:
    value: object = evaluate(page, "parseFloat(getComputedStyle(document.body).lineHeight)")
    assert isinstance(value, (int, float)) and value > 0, "Line height must be a number"
    return float(value)


def row_ids(page: Page) -> list[str]:
    ids: list[str] = []
    for row in page.locator("#machines tr.machine-row").all():
        row_id = row.get_attribute("id")
        if not isinstance(row_id, str) or not row_id:
            raise ValueError("Machine row lacks an id")
        ids.append(row_id)
    return ids


def check_grid(page: Page, route: str) -> None:
    """Every laid-out element starts on a half-line boundary (renderer DOM excluded)."""
    result: object = evaluate(page, "window.overallsGrid.check()")
    if not isinstance(result, list):
        raise ValueError("Grid check must return a list")
    offenders: list[OffGrid] = []
    for item in result:
        if not isinstance(item, dict):
            raise ValueError("Grid check entries must be objects")
        selector: object = item.get("selector")
        offset: object = item.get("offset")
        if not isinstance(selector, str) or not isinstance(offset, (int, float)):
            raise ValueError("Grid check entry fields are invalid")
        offenders.append(OffGrid(selector=selector, offset=float(offset)))
    assert offenders == [], f"Off-grid elements on {route}: {offenders[:8]}"


def screenshot(page: Page, artifacts: Path, name: str) -> None:
    page.screenshot(path=str(artifacts / f"{name}.png"), full_page=True)


def check_thread_order(page: Page, *, composer: bool) -> None:
    """@cc [owner:ghuntley,label:product;verification] thread-browser-reading-order
    The ready-thread composer MUST precede the transcript in DOM and visual order.
    Every synthetic transcript event MUST appear newest first in both orders,
    including tool events between assistant messages, with the initial prompt last.
    """
    kinds = (
        "turn_finished",
        "assistant",
        "tool_result",
        "tool_queued",
        "tool_result",
        "tool_queued",
        "assistant",
        "turn_started",
        "prompt",
    )
    articles = page.locator("#thread-transcript article")
    expect(articles).to_have_count(len(kinds))
    previous_bottom: float | None = None
    for index, kind in enumerate(kinds):
        article = articles.nth(index)
        expect(article).to_have_attribute("data-kind", kind)
        bounds = article.bounding_box()
        assert bounds is not None
        if previous_bottom is not None:
            assert previous_bottom <= bounds["y"], "Transcript visual order differs from DOM order"
        previous_bottom = bounds["y"] + bounds["height"]

    if composer:
        form = page.locator("#thread-prompt-form")
        before: object = evaluate_on(
            page,
            "#thread-prompt-form",
            "Boolean(node.compareDocumentPosition("
            "document.querySelector('#thread-transcript')) & Node.DOCUMENT_POSITION_FOLLOWING)",
        )
        assert before is True, "Composer must precede the transcript in DOM order"
        form_bounds = form.bounding_box()
        transcript_bounds = page.locator("#thread-transcript").bounding_box()
        assert form_bounds is not None and transcript_bounds is not None
        assert form_bounds["y"] + form_bounds["height"] <= transcript_bounds["y"], (
            "Composer must appear above the transcript"
        )


def check_thread_share_details(page: Page, fixture: Context) -> None:
    """The manager disclosure shows the immutable owner and current named roles."""
    toggle = page.locator("#thread-share-toggle")
    expect(toggle).to_be_visible()
    if toggle.get_attribute("aria-expanded") != "true":
        toggle.click()
    expect(page.locator("#thread-sharing")).to_be_visible()
    expect(page.locator("#thread-access-form")).to_be_visible()
    expect(page.locator("#thread-grant-owner")).to_contain_text(fixture["owner_email"])
    expect(page.locator("#thread-grant-owner button")).to_have_count(0)
    grants = page.locator("#thread-grant-items > div")
    expect(grants).to_have_count(3)
    for email, role in (
        (fixture["viewer_email"], "viewer"),
        (fixture["operator_email"], "operator"),
        (fixture["manager_email"], "manager"),
    ):
        grant = grants.filter(has_text=email)
        expect(grant).to_have_count(1)
        expect(grant.locator("[data-role]")).to_have_attribute("data-role", role)


def check_thread_composer_controls(page: Page, *, mobile: bool) -> None:
    """@cc [owner:ghuntley,label:product;verification] thread-browser-composer-controls
    The ready-thread composer MUST open the command palette when a slash is
    typed at the command position. Palette search MUST autocomplete commands,
    Arrow keys MUST move the active option, and Tab MUST insert the selected
    command into the draft without submitting a prompt. LiveView validation
    patches MUST leave the palette open and keep the current search query.
    Escape MUST close the palette without losing the draft and restore focus to
    the invoking control; IME composition MUST defer palette opening until
    composition ends.
    The same controls MUST be reachable through a mobile tap. Browser actions
    MUST not submit a prompt or invoke a machine operation.
    """
    composer = page.locator("#thread-prompt-form textarea[data-thread-input]")
    commands = page.locator("#thread-prompt-form [data-thread-commands-open]")
    palette = page.locator("#thread-command-palette")
    search = page.locator("#thread-command-search")

    expect(composer).to_have_count(1)
    expect(commands).to_have_count(1)
    expect(composer).to_have_attribute("aria-controls", "thread-command-options")
    expect(search).to_have_attribute("role", "combobox")

    # A slash at byte zero opens the palette; its search receives the command
    # prefix while the draft remains in the composer. Tab only inserts the
    # command and leaves the draft for the user to submit explicitly.
    composer.fill("/")
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    expect(composer).to_have_attribute("aria-expanded", "true")
    expect(page.locator("#thread-command-plan")).to_be_visible()
    page.keyboard.type("pl")
    expect(palette).to_be_visible()
    expect(search).to_have_value("pl")
    expect(page.locator("#thread-command-plan")).to_be_visible()
    expect(page.locator("#thread-command-work")).not_to_be_visible()
    search.fill("")
    search.press("ArrowDown")
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.press("ArrowDown")
    expect(page.locator("#thread-command-compact")).to_have_attribute("aria-selected", "true")
    search.press("ArrowUp")
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.fill("wo")
    expect(page.locator("#thread-command-work")).to_be_visible()
    expect(page.locator("#thread-command-plan")).not_to_be_visible()
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.press("Tab")
    expect(composer).to_have_value("/work ")
    expect(palette).not_to_be_visible()
    expect(composer).to_be_focused()

    # A partially typed slash seeds palette search; Escape closes it and
    # preserves the in-progress composer text.
    composer.fill("/pla")
    expect(palette).to_be_visible()
    expect(search).to_have_value("pla")
    search.press("Escape")
    expect(composer).to_have_value("/pla")
    expect(palette).not_to_be_visible()
    expect(composer).to_have_attribute("aria-expanded", "false")
    expect(composer).to_be_focused()

    # A slash after leading whitespace remains ordinary prompt text.
    composer.fill(" /pla")
    expect(palette).not_to_be_visible()
    expect(composer).to_have_value(" /pla")

    # Ctrl/Cmd+K opens the palette from the composer. Escape restores focus to
    # the composer, while opening from the button restores focus to that button.
    composer.press("Control+k")
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    search.fill("terminal")
    expect(page.locator("#thread-command-terminal")).to_be_visible()
    expect(page.locator("#thread-command-plan")).not_to_be_visible()
    search.press("Escape")
    expect(palette).not_to_be_visible()
    expect(composer).to_be_focused()

    commands.click()
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    page.keyboard.press("Escape")
    expect(palette).not_to_be_visible()
    expect(commands).to_be_focused()

    # During IME composition the input event must not open the palette. The
    # follow-up input after compositionend may open it normally.
    composer.fill("")
    evaluate_on(
        page,
        "#thread-prompt-form textarea[data-thread-input]",
        """{
          node.value = "/";
          node.dispatchEvent(new CompositionEvent("compositionstart", {bubbles: true}));
          node.dispatchEvent(new Event("input", {bubbles: true}));
        }""",
    )
    expect(palette).not_to_be_visible()
    evaluate_on(
        page,
        "#thread-prompt-form textarea[data-thread-input]",
        """{
          node.dispatchEvent(new CompositionEvent("compositionend", {bubbles: true}));
          node.dispatchEvent(new Event("input", {bubbles: true}));
        }""",
    )
    expect(palette).to_be_visible()
    search.press("Escape")
    expect(composer).to_have_value("/")
    expect(composer).to_be_focused()

    if mobile:
        # Tap exercises the touch path at the phone viewport without invoking
        # a command or submitting the prompt.
        commands.tap()
        expect(palette).to_be_visible()
        palette.locator("[data-thread-commands-close]").tap()
        expect(palette).not_to_be_visible()


def check_thread_views(page: Page, fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:verification] thread-browser-lifecycle-coverage
    The probe MUST check list, new, activity and all five fixture lifecycle views
    in both themes at desktop and mobile widths. Archived and unready views MUST
    expose no prompt, terminal or editor control; ready views MUST expose all three.
    Ready views MUST also cover slash completion, the command palette, draft and
    focus preservation, IME composition and mobile touch access. Browser checks
    MUST NOT submit prompts or invoke lifecycle mutations.
    """
    routes = {
        "list": "/threads",
        "new": "/threads/new",
        "activity": "/threads/activity",
        "ready": f"/threads/{fixture['ready_thread_id']}",
        "archived": f"/threads/{fixture['archived_thread_id']}",
        "pending": f"/threads/{fixture['pending_thread_id']}",
        "provisioning": f"/threads/{fixture['provisioning_thread_id']}",
        "failed": f"/threads/{fixture['failed_thread_id']}",
    }
    for width in (1440, 390):
        page.set_viewport_size({"width": width, "height": 1000})
        for theme in ("light", "dark"):
            page.locator("[data-appearance]").select_option(theme, force=True)
            check_contrast(page)
            for name, route in routes.items():
                visit(page, fixture["origin"], route)
                expect(page.locator("html")).to_have_attribute("data-theme", theme)
                expect(page.locator("#threads")).to_be_visible()
                if name == "new":
                    expect(page.locator("#new-thread-form")).to_be_visible()
                    settings = page.locator("#new-thread-form details")
                    expect(settings).not_to_have_attribute("open", "")
                    expect(page.locator("select[name='thread[mode]']")).to_be_visible()
                    expect(page.locator("select[name='thread[profile]']")).not_to_be_visible()
                    settings.locator("summary").click()
                    expect(page.locator("select[name='thread[profile]']")).to_be_visible()
                    expect(page.locator("select[name='thread[image_id]']")).not_to_have_value("")
                    expect(
                        page.locator("select[name='thread[profile]'] option[value='customer']")
                    ).to_have_count(0)
                    check_overflow(page)
                    check_grid(page, route)
                    screenshot(page, artifacts, f"threads-new-expanded-{theme}-{width}")
                    settings.locator("summary").click()
                elif name == "activity":
                    expect(page.locator("#thread-activity-items > a")).to_have_count(5)
                    page.locator("select[name='filter[status]']").select_option("archived")
                    expect(page.locator("#thread-activity-items > a")).to_have_count(1)
                    page.locator("select[name='filter[status]']").select_option("deleting")
                    expect(page.locator("#thread-activity-empty")).to_be_visible()
                    page.locator("select[name='filter[status]']").select_option("all")
                    expect(page.locator("#thread-activity-items > a")).to_have_count(5)
                elif name == "list":
                    expect(page.locator("#thread-list-items > a")).to_have_count(5)
                    page.locator("#thread-status-filter").select_option("archived")
                    expect(page.locator("#thread-list-items > a")).to_have_count(1)
                    page.locator("#thread-status-filter").select_option("active")
                    expect(page.locator("#thread-list-items > a")).to_have_count(4)
                    page.locator("#thread-status-filter").select_option("all")
                    page.locator("#thread-search").fill("nothing should match this")
                    expect(page.locator("#thread-search-empty")).to_be_visible()
                    page.locator("#thread-search").fill("")
                    expect(page.locator("#thread-list-items > a")).to_have_count(5)
                elif name == "ready":
                    check_thread_order(page, composer=True)
                    check_thread_composer_controls(page, mobile=width <= 500)
                    expect(page.locator("#thread-prompt-form")).to_be_visible()
                    expect(page.locator("#thread-terminal a")).to_have_attribute(
                        "href", f"/machines/{fixture['vm_id']}/terminals"
                    )
                    expect(page.locator("#thread-terminal")).to_be_visible()
                    expect(page.locator("#thread-vscode")).to_be_visible()
                    expect(page.locator("#thread-vscode")).to_have_attribute(
                        "href", f"/machines/{fixture['vm_id']}/code"
                    )
                    check_thread_share_details(page, fixture)
                    check_overflow(page)
                    check_grid(page, route)
                    screenshot(page, artifacts, f"threads-sharing-{theme}-{width}")
                    page.locator("#thread-share-toggle").click()
                    expect(page.locator("#thread-sharing")).not_to_be_visible()
                elif name == "archived":
                    check_thread_order(page, composer=False)
                    expect(page.locator("#thread-archived")).to_be_visible()
                    expect(page.get_by_role("button", name="Reopen", exact=True)).to_be_visible()
                elif name in ("pending", "provisioning"):
                    expect(page.locator("#thread-provisioning")).to_be_visible()
                elif name == "failed":
                    expect(page.locator("#thread-provision-error")).to_be_visible()
                    expect(page.get_by_role("button", name="Retry", exact=True)).to_be_visible()

                if name in ("archived", "pending", "provisioning", "failed"):
                    expect(page.locator("#thread-prompt-form")).to_have_count(0)
                    expect(page.locator("#thread-terminal")).to_have_count(0)
                    expect(page.locator("#thread-vscode")).to_have_count(0)
                if name in ("ready", "archived"):
                    expect(
                        page.locator("#thread-transcript article[data-kind='assistant']").first
                    ).to_contain_text("requested changes")
                check_overflow(page)
                check_font(page)
                check_grid(page, route)
                screenshot(page, artifacts, f"threads-{name}-{theme}-{width}")
    page.set_viewport_size({"width": 1440, "height": 1000})


def check_thread_collaborators(
    browser: Browser,
    owner_page: Page,
    fixture: Context,
    artifacts: Path,
    watch: OriginWatch,
    page_errors: list[str],
) -> None:
    """@cc [owner:ghuntley,label:security;verification] thread-browser-role-controls
    Viewers MUST read ready/archived transcripts without mutation controls.
    Operators MUST see ready prompts and eligible machine terminal/editor links;
    only managers may see sharing and lifecycle controls. Revoking a fixture
    viewer through the sharing form MUST remove its mounted transcript on refresh.
    """
    roles: tuple[Literal["viewer", "operator", "manager"], ...] = (
        "viewer",
        "operator",
        "manager",
    )
    contexts: dict[str, BrowserContext] = {}
    try:
        for role in roles:
            context = sign_in(browser, fixture, role, watch)
            contexts[role] = context
            page = context.pages[0]
            page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
            for width in (1440, 390):
                page.set_viewport_size({"width": width, "height": 1000})
                for theme in ("light", "dark"):
                    page.locator("[data-appearance]").select_option(theme, force=True)
                    for state, identifier in (
                        ("ready", fixture["ready_thread_id"]),
                        ("archived", fixture["archived_thread_id"]),
                        ("failed", fixture["failed_thread_id"]),
                    ):
                        route = f"/threads/{identifier}"
                        visit(page, fixture["origin"], route)
                        expect(page.locator("html")).to_have_attribute("data-theme", theme)
                        expect(page.locator("#thread-forbidden")).to_have_count(0)
                        writable = role != "viewer" and state == "ready"
                        for selector in (
                            "#thread-prompt-form",
                            "#thread-terminal",
                            "#thread-vscode",
                        ):
                            if writable:
                                expect(page.locator(selector)).to_be_visible()
                            else:
                                expect(page.locator(selector)).to_have_count(0)
                        expect(page.locator("#thread-share-toggle")).to_have_count(
                            1 if role == "manager" else 0
                        )
                        for action in ("archive", "delete", "retry", "reopen"):
                            allowed = role == "manager" and (
                                (action in ("archive", "delete") and state in ("ready", "failed"))
                                or (action == "retry" and state == "failed")
                                or (action == "reopen" and state == "archived")
                            )
                            expect(page.locator(f"button[phx-click='{action}']")).to_have_count(
                                1 if allowed else 0
                            )
                        if state in ("ready", "archived"):
                            check_thread_order(page, composer=writable)
                        if state == "ready" and role == "viewer":
                            expect(page.locator("#thread-read-only")).to_be_visible()
                        if state == "ready" and role == "manager":
                            check_thread_share_details(page, fixture)
                        check_overflow(page)
                        check_font(page)
                        check_grid(page, route)
                        screenshot(page, artifacts, f"threads-{role}-{state}-{theme}-{width}")

        viewer_page = contexts["viewer"].pages[0]
        route = f"/threads/{fixture['ready_thread_id']}"
        visit(viewer_page, fixture["origin"], route)
        visit(owner_page, fixture["origin"], route)
        check_thread_share_details(owner_page, fixture)
        form = owner_page.locator("#thread-access-form")
        viewer_grant = owner_page.locator("#thread-grant-items > div").filter(
            has_text=fixture["viewer_email"]
        )
        viewer_grant.get_by_role("button", name="Change", exact=True).click()
        expect(form.locator("input[name='access[email]']")).to_have_value(fixture["viewer_email"])
        form.locator("select[name='access[role]']").select_option("revoked")
        form.locator("button[type='submit']").click()
        expect(viewer_grant).to_have_count(0)
        expect(owner_page.locator("#thread-share-error")).to_have_count(0)
        expect(viewer_page.locator("#thread-forbidden")).to_be_visible(timeout=10_000)
        for selector in (
            "#thread-transcript",
            "#thread-prompt-form",
            "#thread-terminal",
            "#thread-vscode",
        ):
            expect(viewer_page.locator(selector)).to_have_count(0)
        screenshot(viewer_page, artifacts, "threads-viewer-revoked")

        form.locator("input[name='access[email]']").fill(fixture["viewer_email"])
        form.locator("select[name='access[role]']").select_option("viewer")
        form.locator("button[type='submit']").click()
        expect(viewer_grant.locator("[data-role]")).to_have_attribute("data-role", "viewer")
        expect(viewer_page.locator("#thread-read-only")).to_be_visible(timeout=10_000)
        check_thread_order(viewer_page, composer=False)
        expect(viewer_page.locator("#thread-prompt-form")).to_have_count(0)
        screenshot(viewer_page, artifacts, "threads-viewer-restored")
    finally:
        for context in contexts.values():
            context.close()


def check_thread_refusal(page: Page, fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:security;verification] thread-browser-refusal
    An unrelated signed-in account MUST see neither thread list entries nor a
    ready or archived transcript, prompt, terminal or editor on direct navigation.
    """
    visit(page, fixture["origin"], "/threads")
    expect(page.locator("#thread-list-items > a")).to_have_count(0)
    for state, identifier in (
        ("ready", fixture["ready_thread_id"]),
        ("archived", fixture["archived_thread_id"]),
    ):
        visit(page, fixture["origin"], f"/threads/{identifier}")
        expect(page.locator("#thread-forbidden")).to_be_visible()
        for selector in (
            "#thread-transcript",
            "#thread-prompt-form",
            "#thread-terminal",
            "#thread-vscode",
        ):
            expect(page.locator(selector)).to_have_count(0)
        check_overflow(page)
        screenshot(page, artifacts, f"threads-{state}-forbidden")


def luminance(page: Page, token: str) -> float:
    channels: object = evaluate(
        page,
        """(token => {
          const sample = document.createElement('span');
          sample.style.color = `var(${token})`;
          document.body.append(sample);
          const context = document.createElement('canvas').getContext('2d');
          context.fillStyle = getComputedStyle(sample).color;
          context.fillRect(0, 0, 1, 1);
          sample.remove();
          return Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3);
        })("""
        + json.dumps(token)
        + ")",
    )
    if not isinstance(channels, list) or len(channels) != 3:
        raise ValueError("Expected three color channels")
    total = 0.0
    for channel, weight in zip(channels, (0.2126, 0.7152, 0.0722), strict=True):
        if not isinstance(channel, int) or not 0 <= channel <= 255:
            raise ValueError("Invalid color channel")
        value = channel / 255
        linear = value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
        total += linear * weight
    return total


def check_contrast(page: Page) -> None:
    """The four presentation tokens keep readable contrast in both themes."""
    pairs = [
        ("--text-color", "--background-color", 7.0),
        ("--text-color", "--background-color-alt", 7.0),
        ("--text-color-alt", "--background-color", 4.5),
        ("--text-color-alt", "--background-color-alt", 4.5),
        ("--background-color", "--text-color", 7.0),
    ]
    for foreground, background, minimum in pairs:
        first, second = luminance(page, foreground), luminance(page, background)
        ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
        assert ratio >= minimum, f"Insufficient contrast for {foreground} on {background}"


GRID_ROUTES = (
    "overview",
    "machines",
    "create",
    "machine",
    "boot-log",
    "account",
)


def run(fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] monospace-browser-evidence
    Screenshots MUST use disposable accounts and omit token-bearing URL output.
    These checks MUST NOT claim synthetic machines executed guest commands.
    """
    artifacts.mkdir(parents=True, exist_ok=True)
    watch = OriginWatch(fixture["origin"])
    page_errors: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=os.environ.get("CHROMIUM_PATH"),
            headless=True,
            args=["--no-sandbox"],
        )
        context = sign_in(browser, fixture, "owner", watch)
        context.grant_permissions(["clipboard-read", "clipboard-write"])
        page = context.pages[0]
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        routes = {
            "overview": "/overview",
            "machines": "/machines",
            "create": "/machines/new",
            "machine": f"/machines/{fixture['vm_id']}",
            "terminal": f"/machines/{fixture['vm_id']}/terminals",
            "boot-log": f"/machines/{fixture['vm_id']}/terminals?view=boot-log",
            "access": f"/machines/{fixture['vm_id']}/access",
            "machine-settings": f"/machines/{fixture['vm_id']}/settings",
            "agents": f"/machines/{fixture['vm_id']}/threads",
            "resize": f"/machines/{fixture['vm_id']}/resize",
            "integrations": "/integrations",
            "teams": "/teams",
            "git": "/git",
            "usage": "/usage",
            "account": "/settings",
        }
        for theme in ("light", "dark"):
            page.locator("[data-appearance]").select_option(theme)
            check_contrast(page)
            for name, route in routes.items():
                visit(page, fixture["origin"], route)
                expect(page.locator("html")).to_have_attribute("data-theme", theme)
                check_overflow(page)
                check_font(page)
                if name in GRID_ROUTES:
                    check_grid(page, route)
                if name in (
                    "machine",
                    "terminal",
                    "boot-log",
                    "access",
                    "machine-settings",
                    "agents",
                    "resize",
                ):
                    expect(page.locator("#machine-connect")).to_be_visible()
                if name == "boot-log":
                    check_machine_tabs(page)
                    expect(page.locator(".machine-tabs #machine-boot-log")).to_have_count(0)
                    expect(page.locator("#terminal-boot-view")).to_be_visible()
                    expect(page.locator("#terminal-status")).to_have_text("Boot log · read-only")
                    expect(page.locator("#terminal-create")).to_have_count(0)
                if name in ("overview", "machines"):
                    # Failed, running and stopped fixture machines in every theme.
                    check_status_labels(page)
                if name == "machines" and theme == "light":
                    check_machine_pins(page)
                    screenshot(page, artifacts, "machines-pinned")
                if name == "machine":
                    check_machine_header(page)
                    page.locator("[data-copy-command='machine-id']").click()
                    expect(page.locator("#machine-copy-status")).to_have_text("Machine ID copied.")
                    assert (
                        evaluate(page, "navigator.clipboard.readText()")
                        == page.locator("#machine-id").text_content()
                    )
                    # The connect box starts collapsed; open it, then keep it open
                    # across a LiveView update before copying an install command.
                    expect(page.locator("#machine-install-command")).to_be_hidden()
                    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1)
                    page.locator("#machine-connect-details > summary").click()
                    expect(page.locator("#machine-install-command")).to_be_visible()
                    page.locator("[data-copy-command='machine-install-command']").click()
                    expect(page.locator("#machine-copy-status")).to_have_text("Command copied.")
                    assert (
                        evaluate(page, "navigator.clipboard.readText()")
                        == page.locator("#machine-install-command").text_content()
                    )
                if name == "account":
                    expect(page.locator("#git-settings-form")).to_be_visible()
                    page.locator("#settings_git_username").fill("Browser Author")
                    page.locator("#settings_git_email").fill("browser@example.test")
                    page.locator("#settings_commit_trailers_enabled").uncheck()
                    page.locator("#save-git-settings").click()
                    expect(page.locator("#flash-info")).to_contain_text("Git settings saved")
                    page.reload()
                    expect(page.locator("#settings_git_username")).to_have_value("Browser Author")
                    expect(page.locator("#settings_git_email")).to_have_value(
                        "browser@example.test"
                    )
                    expect(page.locator("#settings_commit_trailers_enabled")).not_to_be_checked()
                if name == "account":
                    check_account(page, fixture["origin"], theme)
                    visit(page, fixture["origin"], route)
                screenshot(page, artifacts, f"{name}-{theme}")
            page.set_viewport_size({"width": 390, "height": 844})
            for name in (
                "overview",
                "machines",
                "create",
                "machine",
                "terminal",
                "boot-log",
                "agents",
                "integrations",
                "teams",
                "usage",
                "account",
            ):
                visit(page, fixture["origin"], routes[name])
                check_overflow(page)
                if name == "account":
                    check_grid(page, routes[name])
                    expect(page.locator("#git-settings-form")).to_be_visible()
                if name in ("machine", "terminal", "boot-log"):
                    check_machine_tabs(page)
                    check_machine_header(page)
                    check_grid(page, routes[name])
                    terminal = page.locator("#terminal-display").bounding_box()
                    sidebar = page.locator("#terminal-sidebar-list").bounding_box()
                    assert terminal is not None and sidebar is not None
                    assert terminal["y"] < sidebar["y"]
                screenshot(page, artifacts, f"{name}-{theme}-mobile")
            page.locator("#navigation-open").click()
            expect(page.locator("#navigation-close")).to_be_focused()
            page.keyboard.press("Shift+Tab")
            assert evaluate_on(page, "#workspace-sidebar", "node.contains(document.activeElement)")
            page.keyboard.press("Escape")
            expect(page.locator("#navigation-open")).to_be_focused()
            page.locator("#navigation-open").click()
            screenshot(page, artifacts, f"navigation-{theme}-mobile")
            page.locator("#workspace-sidebar a[href='/git']").click()
            expect(page.locator("#navigation-open")).to_have_attribute("aria-expanded", "false")
            page.set_viewport_size({"width": 1440, "height": 1000})

        check_thread_views(page, fixture, artifacts)
        check_thread_collaborators(browser, page, fixture, artifacts, watch, page_errors)
        visit(page, fixture["origin"], "/machines/new")
        page.locator("#machine_vcpu").fill("3")
        page.locator("#machine_vcpu").press("Tab")
        expect(page).to_have_url(re.compile(r"vcpu.*3"))
        key = page.locator("#machine_request_key").input_value()
        page.reload()
        expect(page.locator("#machine_vcpu")).to_have_value("3")
        expect(page.locator("#machine_request_key")).to_have_value(key)
        page.emulate_media(reduced_motion="reduce")
        assert evaluate_on(
            page,
            ".console-button.primary",
            "parseFloat(getComputedStyle(node).transitionDuration) < 0.01",
        )
        context.close()

        admin = sign_in(browser, fixture, "admin", watch)
        page = admin.pages[0]
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        for route in (
            "nodes",
            "workloads",
            "jobs",
            "operations",
            "users",
            "access",
            "git",
            "audit",
            "usage",
        ):
            visit(page, fixture["origin"], f"/admin/{route}")
            expect(page.locator("nav[aria-label=Administration]")).to_be_visible()
            expect(
                page.locator(f"nav[aria-label=Administration] a[href='/admin/{route}']")
            ).to_have_attribute("aria-current", "page")
            check_overflow(page)
            screenshot(page, artifacts, f"admin-{route}")
        admin.close()

        empty = sign_in(browser, fixture, "empty", watch)
        empty.pages[0].on("pageerror", lambda error: page_errors.append(type(error).__name__))
        expect(empty.pages[0].locator("#overview-machines-empty")).to_be_visible()
        screenshot(empty.pages[0], artifacts, "overview-empty")
        check_thread_refusal(empty.pages[0], fixture, artifacts)
        empty.close()

        public = browser.new_context(color_scheme="dark", viewport={"width": 390, "height": 844})
        watch.attach(public)
        page = public.new_page()
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        page.goto(fixture["origin"] + "/docs")
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        assert public.cookies() == [], "Public docs must remain session-free"
        check_overflow(page)
        check_font(page)
        screenshot(page, artifacts, "docs-dark-mobile")
        page.locator("[data-appearance]").select_option("light")
        page.reload()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        page.goto(fixture["origin"] + "/sign-in")
        check_overflow(page)
        assert not re.search(
            r'class="[^"]*\b(?:dark:|rounded|px-|py-|text-gray)', page.content()
        ), "Sign-in page still renders utility classes"
        screenshot(page, artifacts, "sign-in-mobile")
        public.close()
        browser.close()
    assert watch.urls == [], f"External resources were requested: {sorted(set(watch.urls))[:5]}"
    assert watch.csp_violations == [], (
        f"Content-Security-Policy violations: {sorted(set(watch.csp_violations))[:5]}"
    )
    assert not page_errors, "Browser runtime error"
    print(
        "Monospace presentation passed: layouts, navigation, both themes, grid alignment, "
        "self-hosted font, no external requests, no Content-Security-Policy violations or "
        "browser errors, drafts and public documentation. "
        "Threads passed 32 route/theme/viewport combinations, settings, filters, lifecycle controls, "
        "reading order, 36 collaborator role/state/theme/viewport combinations, sharing, "
        "live revocation and unrelated-account refusals. Synthetic fixtures only."
    )


if __name__ == "__main__":
    try:
        run(read_context(Path(sys.argv[1])), Path(sys.argv[2]))
    except Exception as error:
        # Browser exceptions can contain credential-bearing navigation URLs.
        frames = [
            frame
            for frame in traceback.extract_tb(error.__traceback__)
            if frame.filename == __file__
        ]
        print(
            f"Browser verification failed: {type(error).__name__} at probe line {frames[-1].lineno if frames else 0}."
        )
        raise SystemExit(1) from None
