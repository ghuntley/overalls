# eMudhra distrust backout and coordinated pin bump review (2026-10-29)

## Scope

This review covers the backout of the temporary fleet blacklist added after
the October 2026 eMudhra intermediate-key compromise, together with the pin
bump that makes the backout safe. The base is `origin/trunk` at `543a147fe`.
Changed areas:

- `flake.lock`, `devenv.yaml` and `devenv.lock`:
  - root `nixpkgs` moves to `nixos-26.05` `08d3a975`, which contains the
    backported `security/ca.nix` distrust (`7816d39`), cacert 3.131.1, Go
    1.26.10 and Node.js 24.22.1;
  - `buildNixpkgs` (devenv-nixpkgs rolling) moves to `d97234e`;
  - `nix-compact` moves to `84475ca76`.
  These moved together because nix-compact accepts exactly one Nix version,
  and both nixpkgs pins now ship Nix 2.34.9.
- Removal of `nix/domains/system/public-trust.nix` (contract
  `fleet-distrust-emudhra-roots`) and its imports from the system catalog, the
  NixOS guest configuration, the Inception image builder and the `host-kexec`
  modules.
- castore 1.0.22, which trunk already carries from `66f67b6c6`.
- Rust 1.99 lint fixes:
  - `fetch_update` is replaced with explicit `compare_exchange_weak` loops in
    the terminald session budget and the VS Code broker window model;
  - `as_chunks` is used in terminald's SHA-256 block expansion.
- A test-only `openat2` probe in `lilly/native/hostd`.
- The eMudhra reminder in `AGENTS.md`, cut down to the non-NixOS guest images
  item.

Marshall's system-store TLS defaults (`runtime-postgres-system-trust`,
`mail-smtp-system-trust`) and the `rustls-webpki` update are unchanged.

## Findings

1. **Upstream distrust replaces the local blacklist (resolved).** The
   blacklist named "Comodo AAA Services root" and three emSign roots.
   - On trunk, the built host, guest and kexec bundles still carried all four
     roots, as OpenSSL `TRUSTED CERTIFICATE` blocks with reject rules.
   - On the new pins, the three emSign roots are absent from the host, guest,
     kexec and stand-alone cacert bundles in every form. "AAA Certificate
     Services" appears only as the `TRUSTED CERTIFICATE` block that NSS 3.131.1
     ships, which rejects `serverAuth` and `clientAuth`.
   - The no-trust-rules PEM bundle that most TLS clients read contains none of
     the four roots.
2. **The bump is coordinated (resolved).** The first root-only bump broke
   host evaluation, because nix-compact `9e43798` accepts only Nix 2.34.8.
   Moving nix-compact, `buildNixpkgs` and devenv together keeps one Nix version
   across the host module, the build toolchain and the development shell.
3. **Rust 1.99 lints (resolved).** `buildNixpkgs` brings Rust 1.99, which
   deprecates `AtomicUsize::fetch_update` and adds
   `clippy::chunks_exact_to_as_chunks`; the broker and terminald deny
   warnings. The replacements keep the same checked-add, limit-filtered,
   sequentially consistent reservation, and the same big-endian word
   expansion.
4. **hostd tests in sandboxes that refuse `openat2` (accepted gap).** The Nix
   build sandbox on the remote builders returns `ENOSYS` for `openat2`. This
   failure predates the bump: trunk's own `lilly-hostd` derivation fails the
   same way when it is rebuilt, rather than substituted.
   - Production code fails closed there, which is the documented behavior.
   - Eleven tests that need beneath-root resolution now skip, with an explicit
     message, only when a probe gets `ENOSYS`.
   - `cargo test` on a host still runs all 62, and so do the machine tests on
     real kernels.
   - The sandbox build therefore no longer proves beneath-root resolution.
5. **castore and Node.js (resolved).** castore 1.0.22 and the Node.js 24.22.1
   bundled root store both lack the three emSign roots; castore 1.0.21 and
   Node.js 24.19.0 had them. Neither one contains "AAA Certificate Services".
   The GitHub guest tools (`nix/domains/artifacts/guest/github`) build with
   `buildGo127Module`, and both pins now ship Go 1.27.3.
6. **Non-NixOS guest images (open).** Ubuntu, Arch, Alma, FreeBSD and Windows
   guests still use their distributions' trust stores. They stay listed in
   `AGENTS.md` until those images are rebuilt.

Architecture impact: no decision changes. This is a dependency and
configuration update that removes a temporary workaround; the host and guest
trust model stays the same. No ADR is affected.

## Execution

All runs were on 2026-10-29, locally and on the tribuchet remote builders.

- The trust-bundle comparison (host, guest, kexec and cacert bundles, trunk
  against these pins) gave the counts in finding 1.
- These Nix builds passed:
  - the `dungarees`, `panterloons` and `salopettes` toplevels;
  - `installer-trust` and `fleet-guest-trust-configuration`;
  - `terminald`, `terminald-windows` and `vscode-web-broker`;
  - `nix-compact-configuration`, `nix-compact-core`, `nix-compact-native` and
    `nix-compact-native-host`;
  - `lilly-hostd`: 62 passed, the `openat2` tests skipped in the sandbox.
- `devenv shell` builds, with Elixir 1.20.4 on OTP 29.
- `cargo test` passed on the host: hostd 62/62 and the broker. terminald passed
  53 of 55; the remaining two need `TERMINALD_TEST_HEAD`, which only the Nix
  check sets.
- `galileo-fleet` failed its "source relocation" subtest the same way on
  trunk `543a147fe`, so the failure predates this change.
- `fleet-guest-trust` failed on these pins and on trunk `543a147fe` for four
  separate reasons. None was load-related, and none was a product defect in
  guest trust:
  - Trunk `543a147fe`'s subtest-2 timeout: Lilly refused its configuration
    (`invalid LILLY_CONFIG_FILE`) because of the fixture's credential filename.
    `7c4ad7458` and the Lilly restart-sequencing commits had already fixed this.
  - The broken pipe: host-side Ziggy hit its 512 MiB fixture `MemoryMax`, and
    the test kernel's compulsory `panic_on_oom` rebooted the provisioner. This
    happened in 2 of 4 runs. Ziggy's first LLMDB lookup alone peaks near
    460 MiB RSS in a bare release. Every fleet variant now caps Ziggy at
    1024 MiB (`fleet-ziggy-host-startup-budget`). Production's 4096 MiB default
    is unchanged.
  - The receipt stage: the probe compared every boot-record field with the trust
    receipt. Since `9b46af85d`, readiness also records `guest_boot_id`, which the
    receipt does not carry, so this always failed. A temporary closed-stage
    diagnostic identified the field. The probe now compares the four bound fields
    exactly and requires `guest_boot_id` to equal the receipt's boot UUID.
  - After that fix, the NixOS provision failed the operator's minimum-disk check.
    On these pins the NixOS image needs 4.31 GiB, more than the hard-coded 4 GiB
    root. The fixture now derives the NixOS root from the manifest (5 GiB). The
    pool (27 GiB), the expected holds and an over-quota 64 GiB refusal root
    follow from it (`fleet-guest-trust-derived-nixos-shape`).

  With these fixes, two consecutive runs passed all four subtests (the second
  with `--rebuild`, test script 432.6 s and 425.1 s), as did
  `fleet-guest-trust-configuration`.
- Marshall: every failing location of a full suite run was rerun on these pins
  and on trunk.
  - Both trees fail the same tests: documentation inventory, logged-out docs,
    profile drafts, admin language, MFA history, waiting-mail properties,
    roster oracle, account lifecycle, capacity races, Windows and Inception
    machines.
  - `TeamScimPropertyTest` found a counterexample on both trees: an extra
    member, once in one run on these pins and once in three runs on trunk. It
    is a pre-existing intermittent failure.
  - Dialyzer (`--force-check`) reported 0 errors.

- Lilly on these pins: `compile --warnings-as-errors` passed, the test suite
  passed 669 of 669, and Dialyzer (`--force-check`) reported 0 errors.
- Rebased on `66f67b6c6`: the three host toplevels, `installer-trust`,
  `terminald`, `vscode-web-broker` and `nix-compact-native-host` were rebuilt,
  and `check_adrs` passed.
