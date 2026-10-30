# Ubuntu guests built with Nix

Ubuntu 26.04 LTS is an additional image choice alongside the default NixOS guest.
The builder uses official Ubuntu Base 26.04.1 amd64, Ubuntu packages and the pinned
Nix-built Linux kernel. Nix runs on the builder; users get an ordinary writable
Ubuntu system with APT. Existing VMs are not rewritten when an image is rebuilt.

Both standard images ship the reviewed default toolset (see
[ADR-0076](../architecture/decisions/0076-default-guest-toolset.md)): rootful Podman
with Docker compatibility (`docker` alias, `/run/docker.sock`, Podman Compose),
the GitHub CLI with `git`, `curl`, `wget`, `tmux`, `vim`, Neovim, `lsof`, `jq`,
Mercurial, `atop`, `btop`, `iotop`, `ncdu`, `sqlite3`, `less`, ripgrep and
DNS/network tools (`nslookup`, `dig`, `ping`). The Ubuntu image additionally
installs Nix from the Ubuntu archive with the `nix-daemon` enabled. Container
egress follows the selected profile like any other guest traffic.

Both images also install pinned Codex 0.149.0 (`codex`) and Claude Code 2.1.238
(`claude`). Ubuntu embeds their complete pinned Nix application closure alongside
`devenv`, registers it in the guest's Nix database and retains a GC root during
offline assembly. Commands are exposed through `/usr/local/bin`. This is the
explicit application exception in
[ADR-0167](../architecture/decisions/0167-native-guest-coding-clis.md); the Ubuntu
archive lock remains authoritative for ordinary Ubuntu packages.

Codex's `/etc/codex/config.toml` selects Ziggy at
`https://llm.internal/openai/v1` using HTTP Responses, without OpenAI login or
WebSockets. Claude's `/etc/claude-code/managed-settings.json` selects
`https://llm.internal/anthropic` with a nonsecret authentication sentinel.
Automatic client updates are disabled. Ubuntu's profile/Bash startup and PAM
environment export the verified `/etc/ssl/certs/ca-certificates.crt` bundle,
including `CODEX_CA_CERTIFICATE` and `NODE_EXTRA_CA_CERTS`, for native terminal and
SSH sessions. Users retain normal client sessions and model selection; native
catalogs may differ from Ziggy's available models. No launcher or model-catalog
synchronizer is installed.

These are user-run guest tools, separate from the Marshall-owned platform agent.
Provider secrets remain with Ziggy. Customer guests cannot use private inference
despite having the commands installed. Production Anthropic remains disabled, so
Claude receives `provider_unavailable` until a separate provider enablement; see
[Ziggy](../services/ziggy.md). New images affect future provisioning and preserve existing
writable guest disks.

Both images use Bash with the stock Starship prompt for interactive users,
including root and accounts created after boot. NixOS enables its global Starship
module; Ubuntu installs the locked native package and initializes it through
`/etc/bash.bashrc` and `/etc/profile.d/overalls-starship.sh`. Login and nested
interactive Bash receive the prompt. The native NixOS module skips
`TERM=dumb`; Ubuntu initializes all interactive Bash through its guarded startup.
Noninteractive command output stays unchanged.
Users may configure Starship normally through `~/.config/starship.toml`; image
assembly and reconciliation do not overwrite personal dotfiles.

Personal SSH and browser accounts share `overalls-ssh-authorize` reconciliation.
It selects executable `/run/current-system/sw/bin/bash` on NixOS or `/bin/bash`
on Ubuntu, both when creating an account and on every active-account refresh.
Missing Bash refuses reconciliation; manually changing a managed account's shell
is reverted at the next successful refresh. UID, home and sudo policy are retained.
Ubuntu's `useradd` default also selects Bash for ordinary manually created accounts;
service accounts retain their non-login shell policy. These defaults apply to new
images only. See [ADR-0150](../architecture/decisions/0150-default-guest-starship.md).

## Build the standard image

```sh
nix build .#ubuntu-guest
# kernel, initrd, rootfs.ext4, manifest.json
ls result/
```

The build requires an x86-64 Linux Nix builder with KVM. Dependencies are fetched
by hash first; package installation runs offline inside an isolated build VM.
The image retains the existing platform serial-console, networking and readiness
contracts. SSH and password-based remote root login are disabled. Network access follows the
selected profile: Customer has no outbound access, including APT or DNS.

## Define a customized image

The package set exports `mkUbuntuGuest`, also available as the flake's
`lib.mkUbuntuGuest`. Add a named derivation to your repository configuration:

```nix
ubuntuDevelopment = mkUbuntuGuest {
  imageName = "ubuntu-development";
  packages = [ "git" "build-essential" "python3" "postgresql-client" ];
  packageLock = ./ubuntu-development.lock.json;
  minimumMemoryBytes = 1073741824;

  caCertificates = [ ./certificates/company-root-ca.crt ];

  files."/etc/myapp/config.json" = {
    source = ./config/myapp.json;
    mode = "0644";
  };
};
```

`packages` contains Ubuntu package names, not Nixpkgs attributes. Dependencies
and required guest tools are included automatically. Applications are preinstalled;
root users may remove or change them afterward. Files accept a source and optional
mode (default `0644`) under `/etc`, `/opt`, `/usr/local` or `/root`. Platform boot,
networking, identity and access configuration paths are protected.

`privateServiceRoots = [ ./platform-root.crt ];` additionally enables split DNS
for `.internal` through Audi. The deployment package set supplies its platform
roots automatically. These roots are also installed in Ubuntu’s CA store.

CA inputs are PEM certificates added to Ubuntu's system trust store. Nix store
inputs are public: use public CA certificates, never private keys or credentials.
The executable example in `nix/verification/tests/fixtures/ubuntu` installs `hello`, a configuration
file and a disposable test CA. Do not publish that test CA in production images.

For NixOS variants, use the existing guest builder and NixOS package options:

```nix
nixosDevelopment = import ./nix/domains/artifacts/guest {
  inherit pkgs;
  imageName = "nixos-development";
  extraModules = [{
    environment.systemPackages = [ pkgs.git pkgs.gnumake pkgs.python3 ];
  }];
};
```

Those packages come from the repository's pinned Nixpkgs input. Ubuntu's
`packages` list instead resolves Ubuntu packages into its explicit APT lock.

## Lock packages and update inputs

Generate a lock after changing the requested package list:

```sh
nix run .#ubuntu-lock -- \
  --snapshot 20260918T000000Z \
  --packages git build-essential python3 postgresql-client \
  --output ./ubuntu-development.lock.json
```

The command resolves against signed Ubuntu archive metadata, using the pinned
base's installed-package database and Ubuntu archive keyring. It downloads metadata
without installing anything on the host. Review and commit the lock with the Nix
configuration. A stale package list or base pin fails evaluation.

For the standard image, omit `--packages` and write
`nix/domains/artifacts/guest/ubuntu/packages.lock.json`. Updating the base requires reviewing
`base.json` and regenerating every variant's lock. Snapshot availability is finite;
retain verified input artifacts in your Nix cache for long-term rebuilding.

## Publish and provision

The shared `fleet/guest-images.nix` list declares NixOS, Ubuntu and the additional
families described in the [OS matrix](os-matrix.md), with native admission
filtered by exact reviewed identity. Panterloons and Dungarees stage those same
artifacts on Lilly; Panterloons registers their
manifests through Marshall's existing operator API. NixOS remains the configured
default. Add custom variants to that list with their own names and derivations.

After normal deployment and fresh verified host inventory, select **Ubuntu 26.04
LTS** in the website's **Image** field, or use the existing Porsche management path:

```sh
ssh ghuntley.dev images --json
ssh ghuntley.dev new --image sha256:IMAGE_DIGEST --name ubuntu-work --json
```

Replace the host alias and digest with your configured gateway and catalog ID.
The underlying authenticated management API uses the same `images` and `new`
commands and `image` option. Marshall applies its existing authorization,
idempotency, image minima and host-availability checks. A new image digest affects
new provisioning only; it is not an in-place operating-system conversion.

## Verification

```sh
nix build .#checks.x86_64-linux.ubuntu-guest-unit .#checks.x86_64-linux.ubuntu-build-boundaries
nix build .#ubuntu-guest.rootfs --rebuild
nix build .#checks.x86_64-linux.ubuntu-guest --extra-system-features nested-kvm
nix build .#checks.x86_64-linux.ubuntu-fleet --extra-system-features nested-kvm
```

Unit/evaluation and Hypothesis tests exercise real parsing and builder boundaries.
The native guest suite uses a customized image for boot, CA/package/file checks,
persistence, resize, clone and readiness checks. The fleet suite uses the standard
Ubuntu image with the real management API, browser provisioning and relocation.
Existing StreamData tests cover image identity and admission-size properties.
See the [architecture review](../architecture/reviews/2026-09-18-ubuntu-guests.md) for
executed results and remaining acceptance limits.
