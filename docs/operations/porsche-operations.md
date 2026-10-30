# Porsche gateway credentials

## Installer host trust

The public installer and `overalls config-ssh` fetch `/bin/ssh-trust.json` through
verified HTTPS and install one scoped SSH CA in `~/.ssh/known_hosts`. Porsche,
Audi and new NixOS/Ubuntu guests present native OpenSSH host certificates. User
SSH keys still prove account identity; the host CA grants no login access.

Configure `services.marshall.sshHostCa.publicKey`, `keyFile` and `retirement`.
Only Marshall receives the private signer through systemd credentials. Manual
releases use `MARSHALL_SSH_HOST_TRUST` (the public JSON policy) and
`MARSHALL_SSH_HOST_CA_KEY_FILE` (a private runtime path). Missing policy disables
the installer. The dedicated production CA retires on 2046-09-25; host
certificates last 3650 days, capped at that date, and renew within 30 days of expiry.
Gateways ask Marshall on every daily renewal run even while their certificate is
valid, so a changed management host (as in the rename from
`overalls.dev`) reaches Porsche and Audi within a day; Marshall returns the
existing generation while its principal still matches.
See [secret custody](../../secrets/README.md#ssh-host-ca).

Gateways retain their own service-owned host keys. Guests generate a new key
under `/run/overalls-ssh-host` each boot, so clones never share a private host key.
Certificate and account-roster installation precede guest SSH readiness. A valid
installed certificate survives a renewal outage; expiry rejects new connections.
OpenSSH reloads atomically renewed certificates, while gateways read them on each
handshake. Gateway renewal timers receive their own systemd credentials.

The client trusts exact management and guest principals. For Audi it additionally
fetches the current route key over HTTPS and derives an exact key-bound alias,
so a certificate for another gateway cannot substitute for the selected route.
The isolated proxy preserves user and system known-host revocations. Trust
installation preserves unrelated entries and refuses a changed or revoked
managed CA; rotation requires explicit client reconciliation after independently
verifying the replacement. `~/.ssh/overalls-trust.json` is public policy, not a
secret. Administrative OpenSSH on port 2222 retains its separate host identity.
CA replacement also requires reissuing installed server certificates. A gateway
restart retains a still-valid cached certificate; replacing the signer alone
does not move that gateway to the new authority. Coordinate signer delivery,
server certificate reissuance and independently verified client trust updates.
Existing guest disks are outside this development migration; create new disks
to use the certified images.

## Gateway authority

Marshall owns gateway authority through its Ash SSH domain. Each Porsche gateway
uses its own credential, separate from user SSH keys and Lilly credentials.
Run these commands from a configured Marshall release with its normal database
and signing environment. The operator entry point suppresses application listeners
and background workers. Keep the working directory private, owned by the operator,
and mode 0700; credential files must be owned by that user and mode 0600.

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' gateway-prepare /private/porsche.token
bin/marshall eval 'Marshall.Operations.CLI.main()' gateway-configure edge-one /private/porsche.token
```

Preparation exclusively creates and syncs the file before any gateway authority
changes. Configuration returns only the gateway ID, name, generation and enabled
state. Reapplying the same file to the same enabled gateway is idempotent, including
after an uncertain response. A failed preparation retains its destination for
inspection; it never overwrites a previous credential.

Supply the prepared file using `services.porsche.credentialFile` on the gateway
host through the deployment's private secret delivery. Do not put the token in
command arguments, source control, the Nix store or logs. The Porsche module uses
systemd credentials and creates its own service-owned private runtime copy.

To rotate, prepare a fresh file and configure the existing gateway name with it.
Then deliver that file and restart Porsche. Rotation immediately invalidates old
gateway authentication and existing sessions, so allow for an interruption until
the service loads the new credential. Reapplying an old file would rotate authority
back to that credential; retain the intended current file for recovery.

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' gateway-prepare /private/porsche-next.token
bin/marshall eval 'Marshall.Operations.CLI.main()' gateway-configure edge-one /private/porsche-next.token
bin/marshall eval 'Marshall.Operations.CLI.main()' gateway-disable GATEWAY_UUID
```

Disabling invalidates gateway sessions. It does not cancel accepted machine jobs.
Configuring a disabled gateway explicitly re-enables it with a new generation.
This operator workflow does not migrate administrative SSH ports or establish
service readiness; those deployment checks remain separate.

The NixOS service publishes `/run/porsche/status.sock`, mode 0600 beneath its
mode-0700 runtime directory. Each connection receives one newline-terminated
`{"version":1,"ready":true}` or false response. Readiness checks the managed SSH
daemon and makes a fresh authenticated HTTPS request to Marshall, which requires
a writable, migrated database. It creates no user session. Service activity alone
does not mean readiness; revoked credentials and an unavailable control plane
produce false. The updater requires this check before recording a healthy release
and includes Porsche in secret-consumer ordering and encrypted-dump preflight.


Before handing port 22 to Porsche, activate administrative OpenSSH on both 22 and
2222 with Porsche disabled. Verify a new pinned administrator connection on 2222,
including passwordless sudo if required by the host tools. Then activate a second
configuration with administrative ports excluding 22 and Porsche enabled. Verify
administrative access again. Preserve the administrative host key throughout;
Porsche maintains a separate persistent management host key. Host CLI commands use
`--ssh-port 2222`; remote Marshall preparation can independently use
`--marshall-ssh-port 2222`. The tools do not fall back to another port on failure.

Set `services.porsche.openFirewall = true` to allow remote clients through the
NixOS firewall on the configured management port. The option defaults to false;
verify access from another host as part of the port handoff.


Use the normal [SSH-derived secret bundles](nixos.md#ssh-derived-secrets) for
runtime delivery. Register the ciphertext for its authenticated host and recovery
recipients in the [fleet secret inventory](fleet-users.md), and encrypt a private
JSON input with the existing `secrets encrypt` command. Its plaintext shape is
`{"overalls-porsche":{"production":{"PORSCHE_GATEWAY_TOKEN":"<prepared token>"}}}`;
keep that input outside the repository and read the prepared token from its file.

```nix
{ config, ... }:
{
  services.overallsSecrets = {
    enable = true;
    bundles.porsche = {
      encryptedFile = "${./secrets/porsche.enc.json}"; # Ciphertext only.
      outputs.token = {
        format = "raw";
        secrets = [ "PORSCHE_GATEWAY_TOKEN" ];
      };
    };
  };
  services.porsche = {
    credentialFile = "${config.services.overallsSecrets.bundles.porsche.directory}/token";
    secretUnits = [ config.services.overallsSecrets.bundles.porsche.unit ];
  };
}
```

Combine this with the Porsche listener and HTTPS options. Root resolves and
atomically publishes the selected token; systemd delivers it to Porsche's private
runtime file. A failed bundle update preserves the previous publication and blocks
startup. For a gateway rotation, apply the new private file through Ash, publish
its encrypted replacement, then stop Porsche, restart the bundle preparation unit,
and start Porsche. Expect readiness to remain false between authority rotation
and loading the replacement. The updater uses the same descriptors and service
ordering when applying candidate generations.

The control plane enables this module on port 22 and administrative OpenSSH on 2222.
Its `overalls-porsche-authority.service` applies the encrypted gateway credential
through the Ash operator before Porsche starts. Repeating an unchanged active
credential preserves its generation. This declaration is authoritative: starting
the bootstrap after an operator disable re-enables the gateway. To keep it disabled,
also disable the declared Porsche service. Credential rotation must update the
host's encrypted bundle, not just the database.

## Interactive prompt

A new interactive shell displays the static Overalls banner, help hint and docs
URL once. Exec commands (including JSON) never display the banner. No Figlet
program or terminal colors are required.

Left/Right move by Unicode grapheme; Backspace removes the grapheme before the
cursor. Up/Down browse this channel's submitted commands, with Down past the
newest entry restoring the original draft and cursor. Recalling a command does
not execute it: press Enter. CSI and SS3 arrows may span SSH packets. Unsupported
complete escape sequences are ignored; malformed or overlong input fails closed.
Ctrl-C closes the channel with status 130; Ctrl-D closes with status 0. Neither
cancels admitted machine work. Transport EOF retains the existing final-line
behavior for typed text, discards incomplete UTF-8/escape bytes, and does not
submit a recalled entry without Enter.

History exists only in the channel process, is never persisted or logged, and
is limited to 100 entries and 64 KiB of command text. Pending submitted lines and
the editable line share an 8192-byte limit; escape decoding has a separate
64-byte limit. The saved history draft is bounded by the same line limit.

PTY sessions redraw edits and wrap long lines, use CRLF output and respond to
window-size changes. Lines taller than the terminal use a viewport that follows
the cursor. Tabs retain their command bytes and display as one space. Input received while a command runs remains editable;
submitted commands run in order after it completes. Progress and results redraw
the unfinished draft. Non-PTY streams retain line-oriented output without ANSI
redraw sequences. Terminal rendering assumes conventional one-cell text and
two-cell CJK/emoji widths; font-specific or ambiguous Unicode widths can differ.
EOF handling and command authorization are shared with the existing SSH runner.
