[![build and publish: cache](https://github.com/ghuntley/overalls/actions/workflows/publish-cache.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/publish-cache.yml)
[![automatic nix upgrades](https://github.com/ghuntley/overalls/actions/workflows/nix-upgrades.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/nix-upgrades.yml)
[![mix security upgrades](https://github.com/ghuntley/overalls/actions/workflows/mix-security-upgrades.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/mix-security-upgrades.yml)
[![cargo security upgrades](https://github.com/ghuntley/overalls/actions/workflows/cargo-security-upgrades.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/cargo-security-upgrades.yml)
[![nixos machine tests](https://github.com/ghuntley/overalls/actions/workflows/nixos-machine-tests.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/nixos-machine-tests.yml)
[![project glasswing oss scanner](https://github.com/ghuntley/overalls/actions/workflows/oss-scanner.yml/badge.svg)](https://github.com/ghuntley/overalls/actions/workflows/oss-scanner.yml)

# Overalls

**An AI-first developer platform that you own.**

> **Research preview.** Not for consumption. Overalls launches on 3 November 2026.
> [Get notified](https://overalls.dev/#newsletter).

Overalls is a self-hosted platform for development machines and the AI agents
that work on them. Every machine is a persistent Firecracker microVM running
NixOS, Ubuntu or Windows, and it keeps its disk, name and address when you
stop, start, resize, clone or move it.

Overalls has its own agent built in: start a thread on any machine from the
browser or the CLI, and it keeps working after you close your laptop, waking
the machine if it was stopped. Claude Code and Codex come pre-installed too,
with no API keys on the machine and every token accounted for.

Open any repository, branch or pull request in a fresh machine with one click,
share it with your coworkers, and work from the browser, SSH, VS Code or the
`overalls` CLI, or from your phone with the Mila app. Put hosts in every region your team works in.

There is no hosted version to sign up for: you install it and run it yourself.

- Website: <https://overalls.dev>
- Self-hosting guide: <https://overalls.dev/self-host/>
- Architecture: <https://overalls.dev/architecture.html>

## Security

Please report vulnerabilities through a
[private security advisory](https://github.com/ghuntley/overalls/security/advisories/new),
not a public issue. See [SECURITY.md](SECURITY.md) for the full policy.

## Who is behind Overalls

Overalls is built by
[Geoffrey Huntley](https://ghuntley.com/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls),
with support from
[Antithesis](https://antithesis.com/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls),
[Cachix](https://www.cachix.org/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls)
and
[Namespace Labs](https://namespace.so/?utm_source=ghuntley&utm_medium=referral&utm_campaign=overalls).

## Licence

Overalls is open source under the [MIT licence](LICENSE).
