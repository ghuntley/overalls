# Overalls browser editor

The source-built workbench remains a Linux release. `windows-runtime.nix`
stages hash-pinned native Windows Node 24 and ripgrep executables for guest
bring-up, with a digest inventory that explicitly declares
`editor_capability: false`. `windowsGuestRuntime` can carry those inert inputs
beside the Windows v1 agents; it registers no editor task or network listener
and retains the version-5 manifest. This is an executable runtime staging step,
not Windows VS Code Web acceptance. A native Code OSS bundle, Windows PTY and
watcher dependencies, an account-bound broker, service supervision and a real
browser journey remain required.

This package builds Microsoft's MIT-licensed Code OSS source at the exact commit
in `inputs.nix`. It runs the native remote extension host, file service, watcher
and terminal service in the signed guest, with the browser workbench from that
same build. It does not repackage Microsoft VS Code, VSCodium, code-server or
OpenVSCode Server binaries.

`inputs.nix` pins the Linux Node source version and hash independently of
Nixpkgs package updates. `node-runtime.nix` uses the supplied pinned Nixpkgs
builder and patches, including its matching npm/corepack outputs. The editor,
extension updater and maintenance check share that runtime; Windows inputs
retain the same reviewed Node version with their own archive hashes.

OpenVSCode Server's Nix source-build recipe informed the offline npm cache and
REH-web build layout. The maintained patch is applied directly to official
Microsoft source. Code OSS uses MIT (`LICENSE.txt`); the output retains upstream
`ThirdPartyNotices.txt` and dependency notices. Marketplace-only bundled add-ons,
the Copilot extension, agent host entry points, optional SDK runtimes and the
desktop Microsoft-authentication/MSAL extension are omitted. Source-maintained
built-in language extensions remain available. Products without a default chat
agent use inert onboarding and default-account services, so optional AI startup
cannot prevent the workbench from starting or leave account requests waiting.
No default authentication provider is created. Trusted extension authentication
grants are empty.

Bundled Copilot and core AI/chat features are permanently disabled; conflicting
settings cannot restore them. Independently installed extensions remain under
the user's control. The bundle starts with workspace trust disabled, so guest
folders do not enter Restricted Mode. This does not approve `.envrc` files or
change Marshall authorization, the personal guest UID or operating-system
isolation.

Fresh workbenches open directly into the workspace. The ordinary configuration
defaults set `workbench.startupEditor` to `none` and
`workbench.welcomePage.walkthroughs.openOnInstall` to `false`; users can override
them. Existing restored editors remain governed by upstream restoration.

The immutable builtin defaults are pinned in `extensions.lock.json`:

| Extension | Version | Project requirement |
| --- | --- | --- |
| `elixir-lsp.elixir-ls` | `0.31.1` | Compatible Elixir/OTP, `elixir-ls` and `elixir-debug-adapter` |
| `EditorConfig.EditorConfig` | `0.18.2` | Project `.editorconfig` |
| `rust-lang.rust-analyzer` | `0.3.3073` | Compatible `rust-analyzer`, Cargo/rustc and standard-library sources |
| `cab404.vscode-direnv` | `1.0.0` | Explicit approval of project `.envrc` using the existing guest `direnv` |

Package assembly verifies complete VSIX signatures and exact hashes before
extracting bounded, identity-checked archives. It preserves the VSIX payload
bytes and license notices and rejects undeclared extension dependencies/packs.
Users can disable builtin defaults and install newer personal versions; upstream
builtins have no Uninstall action. The exact four third-party IDs use ordinary
personal update settings, with no forced automatic updates. Core builtin update
guards remain in place. Imports below the bundled version are refused; a newer
personal builtin copy can be removed with the CLI's `--uninstall-extension ID
--force`, restoring the immutable system version. Installed extensions and server data remain
in account-owned guest directories. Disable state follows upstream browser
profile storage on the account's separate editor origin; it does not imply
cross-device synchronization. Shared extension payloads remain immutable.

The guest toolset gains no global language compilers or servers. Supply compatible
tools through the project's environment, for example an explicitly approved
`direnv`/`devenv` environment. The default Rust server path resolves
`rust-analyzer` from project PATH. The default ElixirLS override directory contains
three small adapters: language-server and debugger requests execute project PATH
`elixir-ls` and `elixir-debug-adapter`; the Elixir check executes project PATH
`elixir` with its original arguments. Missing Elixir adapter commands return 127
with fixed stderr; absent `rust-analyzer` retains the direct spawn's ENOENT error.
These defaults never launch the ElixirLS `Mix.install` bootstrap or rust-analyzer's
NixOS patch installer. Original signed extension payloads remain unchanged.
After loading a project environment, restart the language extension if its server
was started with the previous environment. Projects can explicitly configure
their own server paths. Such overrides and project dependency fetching remain
subject to the personal process and existing guest egress policy.

An installed language extension does not prove usable language diagnostics.
Offline editor startup and shipped extension availability are separate from
project-provided server/toolchain/dependency availability. Native language tests
must observe real diagnostics with prepared project fixtures; they must not add
language tooling to the base guest merely to satisfy a test.

Open VSX gallery packages, including dependencies and WEB-targeted packages, go
through the guest installer. The whole VSIX is verified against the packaged
Ed25519 key ring before extraction. User settings cannot disable this gate.
The reviewed production key is Open VSX key
[`14ccb407-4e79-41ed-be5a-6d608325c45a`](https://open-vsx.org/api/-/public-key/14ccb407-4e79-41ed-be5a-6d608325c45a); its SPKI SHA-256 is
`ffd108d00f4dac32e52b358a3452e15fe09815607b9d74d7ea39a3db49d4b623`.
Registry responses cannot supply trust keys. Explicit local VSIX imports remain
an unverified user operation and never fetch dependencies or extension packs.
Registry/key fixture overrides are Nix build
arguments and change the release identity.

The broker supplies `OVERALLS_EDITOR_ORIGIN`, a canonical HTTPS origin with the
`e-<vm-base32>-<account-base32>` hostname. Missing or invalid configuration fails
startup. The workbench authority ignores forwarded host headers. Webviews use
separate hash origins under the same editor zone and the package's immutable
`/code-assets/<release-id>/out/vs/workbench/contrib/webview/browser/pre/` URL.
Audi serves only `index.html`, `fake.html` and `service-worker.js` from
`passthru.assetRootRelative`. No Microsoft CDN asset fallback is configured.

`bin/overalls-code` starts the pinned Node runtime and source-built server. The
broker selects its fixed Unix socket and data directory flags; the listener sets
its own socket to 0600. `overalls-editor-release.json` contains `source_commit`,
`editor_protocol` and `release_id`. Passthru fields expose the same tuple and
asset/descriptor paths. The release ID binds source and npm hashes, concrete Nix
native runtime and build toolchain paths, the patch stack, product/gallery
settings, trusted keys, build recipe and pinned browser verification inputs.
It also binds the extension lock, validation/extraction recipe and project-PATH
adapters.

Run extension maintenance from the repository root:

```sh
tools/buck2 run //:update-vscode-extensions -- --check
tools/buck2 run //:update-vscode-extensions -- --write
tools/buck2 run //:update-vscode-extensions -- --write --only rust-lang.rust-analyzer --version 0.3.3073
```

`--check` is the default and returns 1 when reviewed pins need updating; `--write`
atomically replaces the complete lock only after all selected downloads pass
the same packaged signature and upstream engine validator used by package builds.
Successful output is JSON containing a closed outcome and the validated selected
IDs, previous/current versions and change flags; failure JSON contains only a
closed reason, without registry response text, paths or artifact contents.
`--only` is repeatable; `--version ID=VERSION` supports explicit versions for
multiple selected extensions. `--lock PATH` selects another review destination.
The updater paginates explicit stable metadata instead of trusting generic
`latest`, rejects incompatible/unsafe/dependency-expanded packages and preserves
the lock on failures before replacement or observed concurrent edits. The complete
temporary file is synchronized before rename; parent-directory synchronization
follows publication. If parent-directory synchronization fails
after rename, `durability_unknown` / `publication_durability_unknown` reports that
the complete new lock may already be visible while crash durability is unproved.
This differs from prepublication validation or observed-concurrency refusal,
which preserves the previous lock. Review the visible lock and rerun validation;
no partial lock bytes are published. The updater cannot replace the
packaged trust inputs or rotate keys, install on the host, run language bootstrap,
update the official editor baseline, commit or deploy. Registry/key changes require
a reviewed package change. Ordinary builds fetch fixed-output inputs and compile
offline; only this maintenance command performs network-enabled resolution.

To update, review the official stable source, its license and native ABI changes;
update the immutable source/hash/version/Node inputs and refresh the recursive
npm cache hash manually; the extension updater does not change these inputs.
Rebase the maintained patch on that unmodified source, inspect
the resulting diff, then run `node check-patches.mts <upstream-source-directory>`
and `tools/buck2 build //:package-tool-vscode-web`. The Nix build runs upstream TypeScript checking and
the REH-web bundle offline. A patch application check alone is not build or
runtime verification. The package also starts its actual workbench in pinned
Chromium through a private TLS-to-Unix fixture, checking visible initialization
without eager page errors. That synthetic fixture does not prove SSO, real
gateway transport or VM isolation. Native guest/browser tests remain required
for acceptance of changed releases and trust-key behavior. An explicitly
authorized early rollout follows required hooks and build/smoke checks, records
the remaining native gaps and continues validation/fixes afterward; deployment
alone does not establish native acceptance. Trust-key rotation remains a reviewed,
coordinated package update.

The recurring browser probes run on Overalls once every five minutes for NixOS
and Ubuntu, with a 60-second deadline and an independent durable recorder. Their
provisional seven-day objective is 99%. They share the authenticated journey in
`nix/domains/system/otel-guest/browser_journey.py`: Marshall handoff, guest file
edit/save/readback, isolated Markdown preview, and personal guest terminal
identity and OS. They replace the contents of a dedicated existing `.md` file;
provision a disposable probe workspace owned by the operator's personal guest
account. The probe does not create or infer operator accounts or sessions.

Provision each guest's `/var/lib/overalls-browser-probes/nixos/` or `ubuntu/`
directory as root with mode 0700. Put `storage-state.json` there as a root-owned
0600 Playwright storage state captured after a real Marshall operator sign-in.
Do not copy credentials into Nix expressions, source control or logs. The closed
`fixture.json` schema is:

```json
{
  "marshall_origin": "https://marshall.example.org",
  "machine_id": "00000000-0000-4000-8000-000000000001",
  "expected_editor_origin": "https://e-<vm-base32>-<account-base32>.apps.example.org",
  "expected_guest": "nixos",
  "workspace_file": "/home/operator/browser-probe/journey.md",
  "expected_uid": 200001,
  "expected_username": "operator",
  "storage_state_path": "/var/lib/overalls-browser-probes/nixos/storage-state.json"
}
```

Replace example identities/origins with the actual authorized personal account
and guest; Ubuntu uses `expected_guest: "ubuntu"`. The fixture must also be
root-owned 0600, regular, bounded to 64 KiB, and outside the Nix store. systemd
loads both private files as credentials and rewrites only `storage_state_path`
to its private credential path. UID bounds and username restrictions match the
editor protocol. Missing files or unavailable recorders/collectors leave health
unknown. Reprovision expired sessions through a real operator sign-in.

Diagnostics describe only fixed windows: “3 failures with no success in 15m”
and “no completion across 10m.” They require the complete source coverage window,
warmup, fresh producer clocks and both live collectors. They do not claim a
persistent consecutive failure streak. Browser histogram bounds are 100ms,
500ms, 1s, 5s, 10s, 30s and 60s; all older source bounds and the minimum-20-request
burn guards remain in place.
