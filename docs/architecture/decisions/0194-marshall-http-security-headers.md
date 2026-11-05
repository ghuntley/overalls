# ADR-0194: Marshall HTTP security headers, no-index and session cookie hardening

- ID: ADR-0194
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: marshall, fleet
- Supersedes: none
- Superseded by: none

## Context

Marshall is served at the apex `https://ghuntley.dev` behind the HAProxy public
proxy ([ADR-0038](0038-http01-validation-and-peer-routing.md),
[ADR-0181](0181-public-proxy-http01-ingress.md)). User machine applications and
the browser editor are served by Audi under `*.apps.ghuntley.dev`
([ADR-0052](0052-fenced-local-guest-ingress.md)), which is a subdomain of the
same registrable domain, so every user application is *same-site* with the
control plane. The thread page embeds `/machines/:id/terminals` in a
same-origin iframe, the terminal reads and writes the clipboard, passkeys use
WebAuthn, and the handbook renders Mermaid diagrams.

Observed before this decision:

- Phoenix's `put_secure_browser_headers/2` ran only in the `:browser` and
  `:public_documentation` pipelines and sent a minimal
  `content-security-policy: base-uri 'self'; frame-ancestors 'self';`. Static
  files, health probes, the early `/api` refusals, the JSON agent API and
  error pages carried no browser policy.
- `force_ssl: [hsts: true]` sent `max-age=31536000` for the apex only.
- The session cookie `_marshall_key` was signed but not encrypted, had no
  `secure` flag, used the default name and `SameSite=Lax`. Any
  `*.apps.ghuntley.dev` origin could set a cookie with that name scoped to
  `ghuntley.dev` and the browser would send it to the apex.
- The remember-me cookie was already `Secure`, `HttpOnly` and `Lax`, with the
  default name `remember_me`.
- `robots.txt` disallowed all crawling, but nothing told a crawler that fetched
  a page anyway not to index it.
- The vendor renderers inject inline styles: `assets/vendor/xterm/xterm.mjs`
  creates `<style>` elements and sets `style` attributes, and
  `assets/vendor/mermaid/mermaid.mjs` does the same; Marshall's own templates
  contain no inline `<script>`, `<style>` or `style=` attribute.
- Authentication strategies are `magic_link` and `remember_me` only; there is
  no OAuth redirect to a foreign origin. The browser editor launch and return
  are GET redirect chains, and the editor opens with `noopener,noreferrer`.

## Decision

1. **One endpoint-level header plug.** `MarshallWeb.SecurityHeaders` runs
   immediately after `MarshallWeb.AuthenticationPrivacy`, before health,
   static files, `MarshallWeb.PublicIngress`, body parsing and the router, so
   every response of the browser endpoint carries exactly one copy of:

   | Header | Value |
   | --- | --- |
   | `content-security-policy` | `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'; frame-src 'self'; worker-src 'self'; manifest-src 'self'` |
   | `permissions-policy` | every sensor, media, payment, USB, serial, HID, geolocation and similar feature denied (`=()`); `clipboard-read=(self)` and `clipboard-write=(self)` allowed because the terminal pastes from and the copy buttons write to the clipboard; passkeys and fullscreen keep their default `self` allowlists |
   | `cross-origin-opener-policy` | `same-origin` |
   | `cross-origin-resource-policy` | `same-origin` |
   | `referrer-policy` | `strict-origin-when-cross-origin` (routes may tighten to `no-referrer`, as the editor controller does) |
   | `x-content-type-options` | `nosniff` |
   | `x-frame-options` | `SAMEORIGIN` (legacy browsers; `frame-ancestors` is authoritative) |
   | `x-permitted-cross-domain-policies` | `none` |

   [ADR-0205](0205-overview-newsletter.md) amends only the original
   `form-action 'self'` clause above: the current policy additionally permits
   the fixed `https://ghuntley.com` origin for the native newsletter fallback
   form. It permits no unrestricted `https:` source; scripts, connections and
   the other directives retain their original restrictions.

   [ADR-0230](0230-terminal-image-decoder-webassembly.md) amends only the
   `script-src` clause: the current policy is `script-src 'self'
   'wasm-unsafe-eval'` so the vendored xterm image addon can compile its sixel
   WebAssembly decoder. JavaScript `eval`, inline and foreign script remain
   refused.

   [ADR-0202](0202-github-com-owner-integration.md) additionally permits the
   fixed `https://github.com` form destination for the CSRF-protected OAuth
   start POST and its provider redirect. Browsers can apply `form-action` to
   that redirect even though the initial POST is same-origin. No wildcard,
   arbitrary HTTPS destination or additional script/connection origin is allowed.

   `put_secure_browser_headers` is removed from both pipelines. The only
   relaxation is `'unsafe-inline'` in `style-src`, required by xterm.js and
   Mermaid's `setAttribute("style")` calls, which a nonce cannot cover.
   `script-src` stays `'self'` alone. `connect-src 'self'` covers the
   same-origin LiveView and terminal WebSockets (CSP Level 3 matches `ws:`/`wss:`
   for `'self'`). `cross-origin-resource-policy` only affects browser no-cors
   subresource loads, so `curl`/PowerShell installer downloads and the
   extension archive navigations are unaffected.

2. **Development tooling relaxation is compile-time only.** `config :marshall,
   MarshallWeb.SecurityHeaders, development_tooling: true` (set in `dev.exs`)
   adds `'unsafe-inline' 'unsafe-eval' http://localhost:*` to `script-src` and
   `http://localhost:*`/`ws://localhost:*` to style, connect, frame and image
   sources for live reload, LiveDashboard, Oban Web, AshAdmin and
   `live_debugger`. Test builds compile the production policy so the browser
   probe exercises what production sends.

3. **No-index on every response.** `MarshallWeb.NoIndex` sends `X-Robots-Tag:
   noindex, nofollow, noarchive, nosnippet, noimageindex` on every
   browser-endpoint response and the root layout repeats it as a robots meta
   tag; `robots.txt` keeps `Disallow: /`. Crawlers blocked by `robots.txt`
   never fetch a page and so never see `noindex`; already-indexed URLs are
   removed through each search engine's webmaster removal tool.

4. **HSTS with subdomains.** Production `force_ssl` sends
   `strict-transport-security: max-age=63072000; includeSubDomains` (two
   years). `preload` is not set; preload-list submission is a separate,
   effectively irreversible decision. Audit of the names this repository
   serves under `ghuntley.dev`: the apex (HAProxy, Let's Encrypt HTTP-01, port
   80 serves only challenges and a permanent HTTPS redirect), `*.apps.ghuntley.dev`
   (Audi, wildcard Let's Encrypt DNS-01 certificate, port 80 answers `308` to
   HTTPS for recognised hosts and `421` otherwise), `ns1`/`ns2.ghuntley.dev`
   (DNS-only names at Audi's address; Audi fails TLS closed for them and
   answers `421` over HTTP, so no browser service exists to break), and the
   service-CA ports `4443`/`5443` on the apex (non-browser clients). No other
   subdomain is declared in `fleet/` or `nix/`. The apex DNS zone is managed
   outside this repository: any HTTP-only name created there would be forced
   to HTTPS by browsers that have visited the apex.

5. **Session cookie.** `MarshallWeb.BrowserSession` owns the options for
   `Plug.Session`, the LiveView socket `connect_info` and every test or probe
   that forges a session. `config :marshall, browser_session: :secure`
   (production, compile-time) names the cookie `__Host-marshall` with
   `secure`, `http_only`, `path: "/"`, no `domain`, `same_site: "Lax"`, a
   signing salt and an encryption salt, so the cookie is encrypted and a
   sibling `*.apps.ghuntley.dev` origin can neither read, plant nor shadow it
   (the `__Host-` prefix is enforced by browsers). The default `:plain` mode
   keeps `_marshall_key` without `secure` for `http://localhost` development
   and tests, with the same salts. `SameSite` stays `Lax`: a magic-link landing
   from a mail client is a cross-site top-level navigation that `Strict` would
   leave signed out. CSRF tokens remain the CSRF control because user
   applications on `*.apps.ghuntley.dev` are same-site with Marshall and
   `SameSite` gives no protection against them.

6. **Remember-me cookie.** The AshAuthentication remember-me strategy names its
   cookie `__Host-remember_me`. Its helper already emits `path=/`, `secure`,
   `HttpOnly` and `SameSite=Lax` without a domain, which satisfies the
   `__Host-` requirements in every environment (localhost is a secure
   context).

7. **Legacy cookie expiry.** `MarshallWeb.BrowserSession` also runs as a plug
   after `Plug.Session`: a request that still carries a cookie under a legacy
   name (`_marshall_key` when the current key differs, `remember_me`) receives
   an expiring `Set-Cookie` for that name. Current names are never expired by
   it and no cookie value is read.

Authorization: the task that requested both the no-index commit and the
header/HSTS/cookie hardening, including the `__Host-` remember-me name and the
`includeSubDomains` directive with its stated impact.

## Alternatives

- **Per-pipeline headers.** Leaves static files, health, refusals, JSON and
  error pages without a policy and risks duplicate CSP headers. Rejected.
- **A nonce for styles.** xterm.js and Mermaid set `style` attributes, which
  no nonce or hash can authorise short of `'unsafe-hashes'` for every
  generated value. Rejected; `'unsafe-inline'` is confined to `style-src`.
- **Per-route relaxed policy for the handbook and terminal pages.** LiveView
  navigation keeps the first document's policy, so a per-route header is not
  reliable for pages reached by live navigation. Rejected.
- **`SameSite=Strict`.** Breaks the magic-link landing from mail clients and
  gives no additional protection against same-site user applications.
  Rejected.
- **HSTS `preload`.** Irreversible for months and binds every future
  subdomain; left as a separate decision.
- **A separate registrable domain for user applications.** The real fix for
  same-site cookie and CSRF exposure; out of scope here and recorded as a gap.

## Consequences

- Browsers refuse foreign and inline scripts, plugins, foreign frames and
  cross-origin framing of Marshall; foreign sites cannot read Marshall
  resources or keep an opener reference.
- The cookie rename and encryption sign every existing browser out once after
  deployment; the remember-me rename means remembered browsers also need one
  fresh sign-in. Legacy cookies are expired by the next response.
- `includeSubDomains` commits every `ghuntley.dev` subdomain to HTTPS for two
  years in browsers that visited the apex.
- Vendor renderer upgrades that start injecting scripts, or templates that add
  inline scripts, fail the browser probe.
- The credential-rotation machine probe reads the cookie name from the
  release instead of hard-coding `_marshall_key`.

## Invariants and verification

- Every browser-endpoint response carries the header set exactly once:
  `marshall/test/marshall_web/security_headers_test.exs`,
  `marshall/test/marshall_web/public_endpoint_test.exs`, Covenant
  `marshall.web_surface.I7`.
- The production policy's `script-src` is `'self'` alone and development
  additions come only from the compile-time flag: `security_headers_test.exs`.
- `:secure` session options are `__Host-marshall`, Secure, HttpOnly, Path=/,
  Lax, domain-less and encrypted: `marshall/test/marshall_web/browser_session_test.exs`,
  Covenant `marshall.web_surface.I8`.
- The remember-me cookie is `__Host-remember_me` with the required attributes:
  `marshall/test/marshall_web/remember_me_login_test.exs`.
- Legacy cookies are expired only when present: `browser_session_test.exs`.
- Pages render without a CSP violation in a real browser:
  `marshall/scripts/monospace_browser_probe.py` fails on any
  `securitypolicyviolation` or console CSP report across every route it visits.
- Failure cases that would disprove the design: a CSP violation on any probe
  route; a `Set-Cookie` without `__Host-`/`secure` in a production build; a
  second `content-security-policy` header; an HTTP-only user-facing
  `ghuntley.dev` subdomain.

## Implementation evidence

- Plug and policy: [`security_headers.ex`](../../../marshall/lib/marshall_web/security_headers.ex),
  [`endpoint.ex`](../../../marshall/lib/marshall_web/endpoint.ex),
  [`router.ex`](../../../marshall/lib/marshall_web/router.ex).
- No-index: [`no_index.ex`](../../../marshall/lib/marshall_web/no_index.ex),
  [`root.html.heex`](../../../marshall/lib/marshall_web/components/layouts/root.html.heex),
  [`robots.txt`](../../../marshall/priv/static/robots.txt).
- HSTS and session mode: [`prod.exs`](../../../marshall/config/prod.exs);
  development relaxation [`dev.exs`](../../../marshall/config/dev.exs).
- Cookies: [`browser_session.ex`](../../../marshall/lib/marshall_web/browser_session.ex),
  [`user.ex`](../../../marshall/lib/marshall/accounts/user.ex)
  (`cookie_name :"__Host-remember_me"`).
- Forged-session consumers:
  [`repository_launch_controller_test.exs`](../../../marshall/test/marshall_web/controllers/repository_launch_controller_test.exs),
  [`probe.exs`](../../../nix/verification/tests/machines/credential-rotation/probe.exs),
  [`fixture.py`](../../../nix/verification/tests/machines/credential-rotation/fixture.py).
- Tests: [`security_headers_test.exs`](../../../marshall/test/marshall_web/security_headers_test.exs),
  [`browser_session_test.exs`](../../../marshall/test/marshall_web/browser_session_test.exs),
  [`public_endpoint_test.exs`](../../../marshall/test/marshall_web/public_endpoint_test.exs),
  [`remember_me_login_test.exs`](../../../marshall/test/marshall_web/remember_me_login_test.exs),
  Covenant [`web_surface.obligations.md`](../../../marshall/contracts/marshall/web_surface.obligations.md)
  (`I7`, `I8`) and the browser probe
  [`monospace_browser_probe.py`](../../../marshall/scripts/monospace_browser_probe.py).
  The [review](../reviews/2026-10-18-marshall-security-headers.md) records the
  checks actually run.

Remaining gaps (why `partial`): no NixOS machine test asserts the headers,
HSTS or cookie attributes over the production TLS path; the production
deployment has not yet been observed sending them; the credential-rotation and
mfa-login machine tests were not re-run after the cookie rename; user
applications remain same-site with the control plane.

## Open questions

- Whether to move user applications to a separate registrable domain, which
  would make `SameSite` meaningful against them and allow HSTS preload.
- Whether `clipboard-read` should narrow to the terminal routes once a
  per-document policy can be expressed for them.

## Related decisions

[ADR-0022](0022-browser-terminal-and-live-login-checks.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0038](0038-http01-validation-and-peer-routing.md),
[ADR-0052](0052-fenced-local-guest-ingress.md),
[ADR-0065](0065-passkey-administration.md),
[ADR-0161](0161-monospace-web-presentation.md),
[ADR-0181](0181-public-proxy-http01-ingress.md);
[ADR-0205](0205-overview-newsletter.md) amends the form-action clause only;
[ADR-0202](0202-github-com-owner-integration.md) adds the fixed GitHub OAuth
form origin without changing other directives;
[ADR-0230](0230-terminal-image-decoder-webassembly.md) adds
`'wasm-unsafe-eval'` to the script-src clause only;
[review 2026-10-18](../reviews/2026-10-18-marshall-security-headers.md).
