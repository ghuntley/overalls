# Per-host observability

Each machine runs its own Fluent Bit process and connects directly to its selected
outputs. There is no fleet log relay. Applications, guest consoles and VM lifetimes
do not depend on the collector. Export is disabled until explicitly configured.

The enrolled Panterloons/Dungarees fleet enables independent OpenTelemetry collection
through `services.overallsOtelFleet`. Panterloons stores ninety-day Prometheus metrics
and ninety-day Tempo traces within its monitored trace quota, plus authenticated
Grafana and the fleet VictoriaLogs store. Dungarees exports over the pinned fleet
tunnel. Seven-day objectives retain their existing targets and unknown-data guards;
store retention does not change their horizon. The ten-second fleet scrape cadence
requires 60,480 observations for seven-day coverage and uses 8,640 per history day.
Each application source exports exactly one duration histogram whose bounds the
receiver fixes per service; Underclass's fifteen bounds extend to twenty-four hours
under the ordinary `overalls_outer_underclass_proxy_duration_seconds` name.

Protocol v4 carries control authority, command receipts and current readiness.
Diagnostic uploads, lifecycle audit batches and relocation progress frames are
removed. Marshall retains security/business audit, PaperTrail and durable SLO
accounting; Grafana reads diagnostic logs, traces, resources and source status from
the observability stores. Its retired `/admin/fleet`, `/admin/logs` and `/admin/slos`
readers return not found. Neither a span nor its absence changes execution authority.

Reviewed application event catalogs emit safe structured logs and trace spans.
Each exact application unit has an independent producer-authenticated trace spool
with private durable custody, a two-GiB logical archive budget, a 256-MiB pending
admission budget and ninety-day retention. The reviewed aggregate host archive
allocation defaults to 32 GiB; configuration refuses an inventory that exceeds it.
Pending admission must fit the archive budget. Validated spans acquire fixed
service/host/application provenance.
An acknowledgment follows durable archive custody; Collector acknowledgment follows
its persistent application exporter queue without an asynchronous batch first.
Pending delivery retries independently; acknowledged records remain retained until
expiry. Normal restart sends only pending data; explicit replay can duplicate
traces. Diagnostic failure or saturation cannot block lifecycle progress.
Native helper stdout remains its existing private data protocol.

Guest processes may send OTLP/HTTP protobuf metrics or traces to
`https://otel.integration.internal` in an eligible guest. Audi supplies the current
Lilly binding; the Rust receiver admits only the Audi Unix peer, replaces resource
provenance and strips guest dimensions. Its reviewed guest metric names cannot
define authoritative outer SLO arithmetic. Per-VM and host minute budgets precede
export. Customer guests remain outside the private integration zone. Guest and
application traces use separate bounded Collector queues.

Import `nixosModules.default`, or the standalone `logging`, `security-audit` and
`cloudwatch` modules. A CloudWatch writer can use:

```nix
services.overallsLogging = {
  enable = true;
  environment = "production";
  aws.mode = "ec2"; # Explicit IMDSv2 instance-role authentication.
  queueBudgetBytes = 4 * 1024 * 1024 * 1024;
  outputs.aws = {
    type = "cloudwatch";
    region = "us-east-1";
    sources = [ "marshall" "lilly" "porsche" "haproxy" "auth" "kernel" "storage"
                "mail" "operations" "system" "metrics" ];
    queueBytes = 256 * 1024 * 1024; # EACH selected source at this destination.
  };
};
```

With three deployments, apply the writer configuration on all three machines.
Group names default to `/overalls/production/SOURCE`; streams contain the hostname,
EC2 instance ID (or persistent machine ID), and input tag. Each envelope separately
records trusted hostname, machine ID, environment, unit, boot and invocation IDs,
plus EC2 identity when available. Message fields cannot overwrite this metadata.
CloudWatch supports tags on groups, not individual log events or log streams;
source/environment/sensitivity tags belong on groups, host identity in streams
and records. Hosts sharing a hostname remain distinguishable by their machine ID.

The source categories cover applications, HAProxy, SSH/authentication, kernel and
OOM messages, systemd/boot/syslog, storage/ZFS, mail, updates, secrets preparation,
ACME and collector operations. Persistent journald captures early boot; initial
activation starts at the beginning of the current boot. A persisted cursor resumes
across collector restarts and reboots, including unread previous-boot messages.
HAProxy emits generated request IDs, backend/server names and timing fields without
URLs, query strings or headers. Application OTP reports retain fixed categories,
not process arguments, state, mail contents or terminal data. Physical outcome logs
are emitted after the control transaction returns successfully.

## Other destinations and credentials

A second destination is independent, including its queues and retries:

```nix
services.overallsLogging.outputs.telemetry = {
  type = "otlp";
  endpoint = "otel.example.net";
  port = 443;
  sources = [ "marshall" "lilly" "porsche" "haproxy" "operations" "system" "metrics" ];
  queueBytes = 128 * 1024 * 1024;
  credentialFiles.header = "/run/overalls-secrets/logging/otlp-header";
};
```

The header file contains `Authorization Bearer TOKEN`. The preset enforces verified
TLS and suppresses provider response bodies. Advanced destinations use
`type = "native"`, `plugin` and `settings`, with an explicit source list and queue
budget. The operator must configure that plugin's TLS/authentication correctly;
managed routing and storage keys cannot be overridden. Never put passwords/tokens
in `settings`: these values enter the Nix store.

Off AWS, select `aws.mode = "file"` and
`aws.credentialsFile = "/run/overalls-secrets/logging/aws-credentials"`. Use exactly
one INI `[default]` profile containing `aws_access_key_id`,
`aws_secret_access_key`, and optionally `aws_session_token`. No ambient environment,
other profile, container identity or instance-role fallback is used. Files must be
root-owned, single-link, mode 0600, with safe directory ancestry and no symlinks.

Use the existing SecretSpec/SOPS bundle mechanism:

```nix
services.overallsSecrets.bundles.logging = {
  encryptedFile = "${./secrets/logging.enc.json}";
  outputs.aws-credentials = { format = "raw"; secrets = [ "AWS_CREDENTIALS" ]; };
  outputs.otlp-header = { format = "raw"; secrets = [ "OTLP_HEADER" ]; };
};
services.overallsLogging.secretUnits = [ "overalls-secrets-logging.service" ];
```

Credentials are materialized into a private runtime configuration. Restart the
collector after rotating a bundle; the existing updater discovers its declared
secret dependency. Temporary credentials must be refreshed before their expiry.
Neither cloud credentials nor their contents belong in application environments,
command arguments or repository files.

## Restricted evidence

`services.overallsSecurityAudit.enable = true` enables full host execution argument
auditing and administrative/security syscall evidence. This deliberately can
capture secrets passed in command arguments. Select `"audit"` separately on every
destination that should receive it; ordinary output examples exclude it. Keep its
CloudWatch reader permissions separate. Native audit retention is eight 128 MiB
files; disk pressure suspends auditing rather than halting the host.

On Lilly hosts, enabling logging also enables native Firecracker collection unless
`services.lilly.firecrackerLogging.enable = false`. Select `"firecracker"` explicitly
on outputs. Firecracker writes Info diagnostics and loss metrics to generation-bound
nonblocking FIFOs. The independent collector never reads guest console sockets.
Native logs are restricted because VMM diagnostics may reveal guest configuration.
Local storage is bounded to eight 16 MiB files per placement across generations,
plus a configurable host cap (1 GiB by default). Stopping either collector does not
stop VM units. FIFO overflow loses diagnostics and is reported by native metrics.

## Queues, metrics and failure behavior

Delivery is at least once: retries can duplicate accepted events. Journal event IDs
combine machine identity with the journal cursor. Destinations require explicit
queue limits whose sum fits the host budget. CloudWatch has a separate queue per
source; native and OTLP platform sources share their destination output queue. Measure each source's rate
and allow at least 24 hours plus 50% headroom; the defaults are caps, not a promise
of 24 hours at an unknown rate. Fluent Bit drops oldest queued chunks at a configured
output limit. Keep free disk capacity for its chunk/index overhead, the journal,
audit files and native VMM logs in addition to the queue budget.

Collector defaults are 512 MiB, one CPU, low CPU/I/O weights and private persistent
state. Destination failures retry independently. CloudWatch HTTP-200 partial
rejections are inspected: future timestamps retry, expired/too-old events are
counted as drops. A mixed accepted/retried batch may duplicate accepted siblings.
Clock synchronization and CloudWatch retention still constrain replay eligibility.

Select `"metrics"` to export minute summaries and native metrics. Fixed numeric
aggregates cover HTTP/control calls, database/queue time, Oban jobs, control errors,
BEAM memory/process/atom/run-queue use and collector queue/free-space/retry/drop
health. Native CloudWatch metrics use EMF; OTLP uses native metric export.
Dimensions are environment and service, never VM, request, user or job identities.
Porsche reports completed HTTP calls and management commands as `http_*` and
`ssh_*` count, duration-in-milliseconds and error totals, plus the four BEAM
gauges. HTTP errors include any returned client error; SSH errors include any
nonzero command result. Counts describe completed invocations, not durable jobs
or connections. Reports contain no account, machine, key, request or command
labels. Source filtering rebuilds metric reports from fixed numeric fields before
any handler can inspect them; arbitrary report fields and metadata are removed.
Select `"porsche"` for its ordinary logs and `"metrics"` for aggregate output.

Marshall and Lilly also validate numeric summaries before translation and strip
private fields and callbacks at the source. The `application-metrics` NixOS check
covers their actual periodic emission through the collector; `porsche-service`
covers Porsche's HTTP error counter through the same path.

Aggregation is not durable domain state; interval metrics can reset on a process
restart. Emitted native metrics and summary logs use bounded filesystem queues.

## Stable journal shards and independent health

Systemd inputs use stable `applications-a`, `applications-b`, `platform` and `edge`
shards, each with at most eight conditional routes and its own cursor database.
An input drops sources outside its evaluated allowlist before routing; each output
also has an explicit source condition. Galileo and Underclass are ordinary
application categories. Restricted tails route only their selected source.

Startup runs a read-only preflight while the reader is stopped: each existing
shard cursor must be private, singly linked and pass SQLite `PRAGMA quick_check`.
Missing cursors start fresh; no retired checkpoint format is read or converted.
Unsafe/corrupt custody refuses startup. Do not delete queues or cursors merely to
clear that refusal.

`overalls-logging-health.service` observes queues, disk, shard checkpoints and allowed
Fluent Bit counters independently on port 9467. The default address is loopback;
fleet collection selects authenticated host addresses. Unavailable counters expose
invalidity and are omitted rather than becoming healthy zeroes. Central Prometheus
scrapes both hosts directly. Fixed numeric trace-spool snapshots add accepted,
refused, pending/retained storage, age and poison state; health readers never open
trace archives. Infrastructure alerts and the Grafana operations dashboard expose
missing/invalid sources, drops, backlog, disk pressure, backup and updater state.
The independent fleet resource exporter listens on loopback 9466 and exports no
Marshall credential, upload or per-placement diagnostic history.

## CloudWatch resource manager

Enable one designated management host per environment. It manages resources but
never receives or forwards another host's logs:

```nix
services.overallsCloudWatch.management = {
  enable = true;
  environment = "production";
  region = "us-east-1";
  accountId = "123456789012";
  groups = {
    marshall = "/overalls/production/marshall";
    lilly = "/overalls/production/lilly";
    operations = "/overalls/production/operations";
    metrics = "/overalls/production/metrics";
    # Include every source selected by writers.
  };
  expectedHosts = [ "0123456789abcdef0123456789abcdef" ]; # /etc/machine-id
  alarmActions = [ "arn:aws:sns:us-east-1:123456789012:operations" ];
};
```

Groups default to 90-day retention, configurable per source through `retentionDays`.
Tags identify project, environment, source, sensitivity and manager. Optional
`kmsKeyArn` uses an existing customer-managed key. Expected-host alarms detect
missing heartbeats; with a metrics group they also cover queue age/size, export
errors and dropped records. Align `queueAlarmBytes` with writer budgets. Missing
heartbeats are observable even if a host cannot export its own failure.

Writers need only `logs:CreateLogStream` and `logs:PutLogEvents` on their selected
groups' stream ARNs (`arn:aws:logs:REGION:ACCOUNT:log-group:GROUP:log-stream:*`).
Grant neither group creation, retention changes, reads nor deletion to writers.
The manager separately needs `logs:CreateLogGroup`, `logs:PutRetentionPolicy`,
`logs:TagResource`, `logs:PutMetricFilter`, and `cloudwatch:PutMetricAlarm`;
add `logs:AssociateKmsKey` when selecting KMS. Scope group operations to the
configured prefix and account, and alarm operations to the environment's names.
If `roleArn` is configured, its source identity also needs `sts:AssumeRole`.
Configure the existing KMS key policy for the regional CloudWatch Logs service
and encryption context for these groups. Provision groups before enabling writers.

Useful Logs Insights queries:

```text
fields @timestamp, source, origin.hostname, origin.instance_id, payload
| filter origin.machine_id = "0123456789abcdef0123456789abcdef"
| sort @timestamp desc
```

```text
fields @timestamp, payload.metadata.vm_id, payload.metadata.placement_id,
       payload.metadata.execution_epoch, payload.metadata.generation, payload
| filter source in ["marshall", "lilly", "firecracker"]
| sort @timestamp asc
```

## Fleet log store destination

ADR-0127 adds a first-class fleet destination: the control-plane host runs a
VictoriaLogs store behind an authenticated entry bound to the private fleet
network only (`logs.fleet.internal:8443`, WireGuard address `10.90.0.1`). Writers
select application/operations sources for the `otlp` output with the insert
credential; the reader credential is separate and cannot insert:

```nix
services.overallsLogging.outputs.logstore = {
  type = "native";
  plugin = "http";
  sources = [ "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" "underclass"
              "haproxy" "auth" "kernel" "storage" "mail" "operations" "system" ];
  queueBytes = 48 * 1024 * 1024;
  credentialFiles.http_passwd = "/run/overalls-secrets/logstore/insert.password";
  settings = {
    host = "logs.fleet.internal";
    port = 8443;
    uri = "/insert/jsonline?_msg_field=message";
    format = "json_lines";
    http_user = "insert";
    tls = true;
    "tls.verify" = true;
    "tls.verify_hostname" = true;
    "tls.ca_file" = "/etc/overalls/logstore-ca.crt";
  };
};
```

The store entry terminates verified TLS against the committed log-store CA and
enforces `/insert/*` for insert identity and `/select/*` plus health for reader
identity; everything else is refused (401). `audit` and `firecracker` sources
must never be selected for this store; they remain restricted evidence with
their separate custody paths. Store retention is 30 days with a minimum-free-disk
guard and (on the control-plane host) a ZFS quota at `zroot/logstore`. Entry
outages backfill from bounded output queues. Grafana uses the pinned VictoriaLogs
datasource through verified TLS at the reader entry; systemd loads reader-only
credentials and the CA. Its Logs dashboard links validated trace IDs to Tempo;
Tempo can query associated logs by that ID. Delivery is at least once and may
duplicate the envelope event identity. Useful LogsQL:

```text
_msg:"admission refused" AND source:marshall | sort by (_time desc)
origin.hostname:("dungarees") AND payload.event:"vm.admission_refused"
```

## Encrypted Erlang crash dumps

For either application, enable `services.APP.crashDumps.enable` and set
`services.APP.crashDumps.publicKeyFile` to an operator RSA public key of at least
3072 bits. The module selects an encryption-enabled build of the same pinned
OTP/Elixir versions and validates the release metadata/key before startup. Keep the
private key off-host. The public build fixture is used only during compilation;
it is never a production fallback. The encrypted VM refuses to start without a key,
including operator `eval` commands: provide `ERL_CRASH_DUMP_PUBLIC_KEY` explicitly.

Dumps remain in private application state directories, bounded to 256 MiB and ten
seconds per crash, three artifacts and seven days at cleanup. Only artifact name,
size and encryption status are logged. Linux plaintext core storage is disabled
when this option is enabled. Retrieve a dump through an authorized administrative
channel and decrypt off-host with OTP 29's
`crashdump:pem_decrypt(EncryptedPath, PrivateKeyPath, OutputPath)`.
No Fluent Bit input tails dump files.

## Verification

`checks.x86_64-linux.logging` exercises three independent writers, exporter restart,
verified-TLS CloudWatch/OTLP delivery, destination outage, collector SIGKILL,
restricted audit routing and unread journal recovery across reboot. Local provider
fixtures use isolated synthetic credentials; no live AWS account is contacted.
Encrypted-runtime tests create a disposable RSA key, crash the actual pinned VM,
verify ciphertext and decrypt off-host. CloudWatch permissions, KMS, alarms and
retention still need live acceptance in the target account; local fixtures cannot
prove provider-side enforcement.
