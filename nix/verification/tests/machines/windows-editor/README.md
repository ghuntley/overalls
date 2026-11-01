# Windows native editor acceptance

This harness exercises a source-built Windows editor candidate in an explicitly
isolated VM. Building the harness compiles its local native extension against
the pinned editor API, checks the Python runner and input refusals, and parses
the controller with pinned PowerShell 7. Windows PowerShell 5.1 execution remains
part of the native run. A harness
build is **not** a recorded native Windows pass.

Prerequisites:

- A fully installed source-built candidate, including the real production
  `overalls-ssh-sync-windows.exe` authorizer and supervised SYSTEM broker task.
- A current real Lyra-authorized canonical SAM account with a loaded profile.
  Use a fresh test account: the fixture refuses an existing personal editor data
  directory and creates an outside-HOME workspace with only fixed test data.
- The complete current bounded broker preface JSON, including its exact package,
  placement, execution epoch, account and admitted HTTPS origin.
- Administrative OpenSSH configuration for the isolated VM. Administrative SSH
  only stages and inspects this fixture; it is not ordinary Overalls CLI proof.
- A loopback TCP tunnel to the real guest broker through its authorized gateway.
  The tunnel must retain the actual authorized guest-network source; never
  weaken peer checks or replace the account authorizer to run this fixture.

Build `//:check-windows-editor-acceptance-harness`, then run:

```sh
result/bin/windows-editor-acceptance \
  --isolated-vm --binding current-editor-binding.json \
  --ssh-config isolated-vm-ssh.conf --ssh-target windows-editor-fixture \
  --ssh-identity isolated-fixture-key \
  --gateway-relay-port 14444 --result native-editor-result.json
```

The adapter binds loopback, injects only the supplied binding and consumes the
broker's readiness frame before relaying HTTP/WebSockets. The browser uses a
locally generated TLS key with an exact SPKI pin and rejects other origins;
blanket TLS bypasses and gallery downloads are not used. No request URL,
credential, terminal output, command payload or browser exception enters logs.

The fixture verifies real native extension execution, personal HOME and SAM SID,
an outside-HOME trusted workspace despite conflicting personal trust settings,
effective disabled AI settings, editor document save and a real PowerShell PTY.
SYSTEM verifies the exact worker executable, PID, creation time, account SID,
private receipt binding and named-pipe server PID. The current physical-boot
receipt namespace is derived from fresh fixed-endpoint MMDS v2 metadata, never
selected by directory age. Disposable ACL probes accept
the reviewed public package policy, reject foreign writes and non-SYSTEM private
access, and permit the exact TrustedInstaller SID only on ancestors.

It then kills only the verified broker, waits for automatic Task Scheduler
recovery and requires the same worker and saved data. Killing the verified worker
must instead produce a distinct process under the same account with saved data.
Each stage repeats the real browser command and terminal assertions. A passing
result contains fixed booleans and hashes, with `ordinary_cli_acceptance=false`
and `capability_promotion=false` explicitly retained.

The fixture intentionally leaves its fixed test data and controller directory for
inspection. Dispose of the isolated VM after collecting evidence. Do not run it
on a customer machine. Separate reviewed Marshall/Cedar/Audi/ordinary CLI,
multi-host recovery and admission evidence remain required before Windows editor
capability can be enabled.
