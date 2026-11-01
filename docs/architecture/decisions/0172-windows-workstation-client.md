# ADR-0172: Windows workstation client

- ID: ADR-0172
- Date: 2026-10-15
- Status: proposed
- Implementation: partial
- Components: Lyra, Marshall, nix-packages
- Supersedes: none
- Superseded by: none

## Context

Users install the `overalls` CLI from a machine's page with
`curl -fsSL <origin>/bin/install.sh | bash -s -- <origin> <zone> <host>`. The
installer, the published artifacts (`linux-amd64`, `linux-arm64`,
`darwin-amd64`, `darwin-arm64`), the background updater and the page covered
only Linux and macOS ([ADR-0096](0096-lyra-developer-ssh.md), superseded
in its account model but not in its platform set). A Windows user could not
install the CLI, so could not reach Linux or Windows guests through Audi.

The CLI drives the system OpenSSH client for every step (`ssh -G` probes, the
Porsche account proof, `ssh-keygen -y` key matching, and `overalls proxy`, which
runs `ssh -l audi … connect <label>` with inherited stdio). `config-ssh` refuses
a client without OpenSSH 9.6 hostname protection, because the wildcard profile
places `%h` in ProxyCommand. Windows 10, 11 and Server 2025 ship Win32-OpenSSH
9.5p1, which lacks it. The bin-only modules used `std::os::unix`, `libc`
(`O_NOFOLLOW`, `gmtime_r`, `geteuid`, `setsid`), `exec`, `$HOME`, `id -un`,
`/dev/null`, `/dev/urandom` and POSIX shell quoting; the updater activated an
update by renaming over the running binary, which Windows forbids.

## Decision

1. **One more artifact.** The same pinned toolchain zigbuilds `overalls` for
   `x86_64-pc-windows-gnu`; the release publishes it as `bin/windows-amd64`
   (≤ 100 MiB) in the same SHA-256 manifest, and Marshall allowlists it beside
   the four Unix targets. x86_64 only: Windows on Arm runs it under x64
   emulation. No signature is added; the trust model is the existing HTTPS
   origin plus digest, as on Linux and macOS.
2. **Native Windows paths.** The managed binary is
   `%LOCALAPPDATA%\Overalls\bin\overalls.exe`, configuration
   `%APPDATA%\Overalls\config.json`, state and logs `%LOCALAPPDATA%\Overalls\state`;
   SSH files stay in `%USERPROFILE%\.ssh`, which Win32-OpenSSH reads, and the
   system known hosts are `%ProgramData%\ssh\ssh_known_hosts`. Owner-only modes
   apply on Unix; Windows files inherit the profile ACL (owner, SYSTEM,
   Administrators), which OpenSSH accepts. Final-component links are refused on
   both (`O_NOFOLLOW`, `FILE_FLAG_OPEN_REPARSE_POINT`).
3. **Keep the OpenSSH 9.6 gate.** The PowerShell installer looks for a client
   that refuses `invalid;hostname` (`%ProgramFiles%\OpenSSH\ssh.exe`, then PATH);
   when there is none it offers `winget install Microsoft.OpenSSH.Preview` and
   otherwise stops with the manual step. The verified client's absolute path is
   recorded in `config.json` (`ssh_program`, Windows only) and used by
   `config-ssh`, `proxy`, `open` and the new `overalls ssh`, because the in-box
   `C:\Windows\System32\OpenSSH` precedes any user PATH entry.
4. **ProxyCommand without a shell.** Win32-OpenSSH starts ProxyCommand with
   `CreateProcess`, so the managed block quotes the executable as one
   double-quoted absolute path with `%` doubled and refuses `"`; the rest of the
   block is identical to Unix (no `UseKeychain`).
5. **Updates by rename-aside.** The background worker runs detached
   (`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`). Activation
   on the next run renames the running `overalls.exe` to `overalls.old`, moves the
   verified pending binary into place with a write-through rename (restoring the
   original if that fails) and continues the invocation in a child whose exit
   code becomes the process's; `overalls.old` is deleted on a later start.
   Freshness and verification rules are unchanged (digest identity, staged
   digest, rejection cooldown).
6. **`install.ps1` and the page.** `GET /bin/install.ps1` serves a Windows
   PowerShell 5.1 / PowerShell 7 installer templated with the same deployment
   trust as `install.sh` (503 without it). It validates origin, zone and host
   against the issued values, verifies the download's SHA-256, runs
   `config-ssh --staged-installer` with the downloaded binary before installing
   it, adds the binary directory to the user PATH and connects with
   `overalls ssh <host>`. The machine page keeps its Linux/macOS installer and
   adds the equivalent Windows PowerShell installer beside it (originally a
   collapsible section). See the 2026-10-18 amendment below for the single
   `ssh <host>` reconnect command.

## Amendment (2026-10-18): one reconnect command

While this ADR is proposed, items 3 and 6 are amended so the machine page shows
one `ssh <host>` reconnect command on Linux, macOS and Windows instead of
`ssh <host>` beside a Windows-only `overalls ssh <host>`:

- When `%ProgramFiles%\OpenSSH` lacks a 9.6+ client, `install.ps1` installs
  `Microsoft.OpenSSH.Preview` with winget without asking; it still fails with
  the manual step when no verified client exists afterwards.
- Windows searches the machine PATH, which holds the in-box
  `%SystemRoot%\System32\OpenSSH`, before the user PATH, so a user-scope change
  cannot make plain `ssh` resolve to the verified client. The installer asks
  once for administrator approval and, in that elevated process, inserts
  `%ProgramFiles%\OpenSSH` immediately before the in-box entry in the machine
  PATH (`REG_EXPAND_SZ`, other entries preserved) and broadcasts
  `WM_SETTINGCHANGE`. The directory is resolved inside the elevated process and
  is administrator-owned; a user-writable or caller-supplied directory never
  enters the machine PATH, because every account and elevated process on the
  workstation searches it.
- Declined or failed elevation leaves the machine PATH unchanged and the
  installer prints `overalls ssh <host>`, which keeps using the recorded client.

Trade-off: plain `ssh` now means the 9.6+ client for every account on that
workstation, and locked-down machines that refuse elevation keep the
`overalls ssh` fallback. Evidence: [installer](../../../marshall/priv/overalls-install.ps1),
[page command](../../../marshall/lib/marshall_web/machine_workspace.ex); the Nix
`overalls-install-ps1` check parses the script and pins its pre-network
refusals. No execution on a real Windows workstation is recorded yet.

## Alternatives

- Accepting the in-box 9.5 client on Windows (ProxyCommand has no shell there)
  was rejected: it would weaken the shared security argument on one platform.
- Bundling a pinned `ssh.exe` was rejected for now: we would own OpenSSH
  updates for every workstation.
- A native `windows-arm64` artifact was deferred: it needs a new rust-std target
  and an unproven toolchain path.

## Consequences

- Windows users get the same SSH journey (account proof, host CA trust, Audi
  proxy, roster accounts on Linux and Windows guests) and background updates.
- The Lyra Nix check type-checks the `overalls` binary for Windows, so Unix-only
  code cannot return to the client unnoticed.
- `overalls open` still runs a POSIX script on the guest; it targets Linux
  images, as before.

## Invariants and verification

- Unit: Windows ProxyCommand quoting, artifact target names and the portable
  UTC date (`lyra/src/ssh_config.rs`, `lyra/src/update.rs`, `lyra/src/log.rs`);
  the Linux CLI suite and clippy unchanged.
- `checks.lyra` type-checks `--bin overalls` for `x86_64-pc-windows-gnu`;
  `legacyPackages.lyra` publishes a PE32+ `bin/windows-amd64` in the manifest.
- `checks.overalls-install-ps1` parses the installer with PowerShell and pins its
  refusals of non-https origins, foreign hosts and zones and hosts outside the
  zone before any download.
- Marshall: `/bin/install.ps1` templating, `no-store`, 503 without trust; the
  machine page's Windows section (`overalls_controller_test.exs`,
  `machines_live_test.exs`).
- Not yet executed: an install and SSH session from a real Windows workstation
  and a Windows update activation. The planned proof uses a Windows Server 2025
  fleet VM as the workstation.

## Implementation evidence

- CLI: [platform helpers](../../../lyra/src/platform/mod.rs),
  [configuration](../../../lyra/src/config.rs),
  [SSH setup](../../../lyra/src/ssh_config.rs), [proxy](../../../lyra/src/proxy.rs),
  [updater](../../../lyra/src/update.rs), [open](../../../lyra/src/open_cli.rs),
  [logs](../../../lyra/src/log.rs), [trust](../../../lyra/src/trust.rs).
- Packaging: [Lyra release](../../../nix/domains/artifacts/infrastructure/lyra.nix),
  [installer check](../../../nix/verification/tests/overalls-install-ps1.sh).
- Marshall: [installer](../../../marshall/priv/overalls-install.ps1),
  [rendering](../../../marshall/lib/marshall_web/overalls_installer.ex),
  [controller](../../../marshall/lib/marshall_web/controllers/overalls_controller.ex),
  [machine page commands](../../../marshall/lib/marshall_web/machine_workspace.ex).

## Open questions

- Whether `winget` reliably installs Win32-OpenSSH 9.8 on every supported
  Windows edition (it is absent on Server); the installer's manual fallback
  covers the rest.

## Related decisions

- [ADR-0096](0096-lyra-developer-ssh.md): the original developer SSH client.
- [ADR-0124](0124-unified-ssh-host-ca.md): the SSH host CA trust installed by `config-ssh`.
- [ADR-0120](0120-ssh-onboarding-guidance.md): onboarding guidance pointing to the machine page.
- [ADR-0171](0171-windows-guest-agents.md): Windows guests the client can now reach from Windows.
