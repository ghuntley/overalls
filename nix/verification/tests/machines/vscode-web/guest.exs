defmodule EditorGuestFixture do
  @moduledoc "Privileged native observation/fault adapter; browser authority is exercised separately."
  alias FleetTerminal, as: Terminal
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.VM.{Boot, Driver, Intent, Spec}

  @type terminal_operation ::
          :prepare | :custody | :broker_restart | :worker_stop | :saved | :policy
  @type operation ::
          terminal_operation() | :boot_capture | :boot_changed | :diagnose | :journal
  @stages [
    :arguments,
    :terminal,
    :root_shell,
    :diagnostics,
    :intent,
    :configuration,
    :metadata,
    :specification,
    :pool,
    :native_proof,
    :lock,
    :current_intent,
    :current_boot,
    :provisioning,
    :snapshot,
    :fixture_write,
    :fixture_read,
    :snapshot_match
  ]
  @type stage ::
          :arguments
          | :terminal
          | :root_shell
          | :diagnostics
          | :intent
          | :configuration
          | :metadata
          | :specification
          | :pool
          | :native_proof
          | :lock
          | :current_intent
          | :current_boot
          | :provisioning
          | :snapshot
          | :fixture_write
          | :fixture_read
          | :snapshot_match
  @type boot_snapshot :: %{
          host_id: OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          challenge_digest: String.t(),
          guest_boot_digest: String.t()
        }
  @diagnostic_keys [
    :native_boot,
    :root_shell,
    :broker_active,
    :broker_root,
    :broker_exec_failed,
    :broker_package_failed,
    :worker_loaded,
    :worker_active,
    :worker_failed,
    :worker_uid,
    :worker_socket,
    :worker_exec_failed,
    :worker_version,
    :personal_launcher,
    :node_as_account,
    :guest_memory_observed,
    :guest_memory_low,
    :guest_oom_observed,
    :guest_oom,
    :broker_pids_observed,
    :broker_pids_limited,
    :worker_memory_observed,
    :worker_oom,
    :worker_oom_kill,
    :worker_pids_observed,
    :worker_pids_limited,
    :refusal_package,
    :refusal_account,
    :refusal_custody,
    :refusal_startup,
    :refusal_readiness,
    :refusal_transport
  ]
  @type diagnostic_key ::
          :native_boot
          | :root_shell
          | :broker_active
          | :broker_root
          | :broker_exec_failed
          | :broker_package_failed
          | :worker_loaded
          | :worker_active
          | :worker_failed
          | :worker_uid
          | :worker_socket
          | :worker_exec_failed
          | :worker_version
          | :personal_launcher
          | :node_as_account
          | :guest_memory_observed
          | :guest_memory_low
          | :guest_oom_observed
          | :guest_oom
          | :broker_pids_observed
          | :broker_pids_limited
          | :worker_memory_observed
          | :worker_oom
          | :worker_oom_kill
          | :worker_pids_observed
          | :worker_pids_limited
          | :refusal_package
          | :refusal_account
          | :refusal_custody
          | :refusal_startup
          | :refusal_readiness
          | :refusal_transport

  # @cc [owner:ghuntley,label:verification;security] editor-fixture-current-native-boot
  # Operations MUST use the persisted current Firecracker boot and a validated
  # current guest account. They MUST NOT install editor authority, mutate host
  # observations or print terminal bytes. Faults are confined to guest systemd.
  @spec run(operation(), String.t(), String.t(), integer()) :: :ok
  def run(operation, placement, username, uid) do
    :ok = mark(:arguments)
    true = OverallsProtocol.uuid?(placement)
    true = OverallsProtocol.EditorConnect.username?(username)
    true = uid in 200_000..999_999

    case operation do
      :boot_capture -> capture_boot(placement)
      :boot_changed -> changed_boot(placement)
      :diagnose -> diagnose(placement, username, uid)
      :journal -> journal(placement, uid)
      terminal_operation -> run_terminal(terminal_operation, placement, username, uid)
    end
  end

  @spec run_terminal(terminal_operation(), String.t(), String.t(), integer()) :: :ok
  defp run_terminal(operation, placement, username, uid) do
    :ok = mark(:terminal)
    home = "/home/" <> username
    unit = "overalls-vscode-u#{uid}.service"

    commands =
      case operation do
        :prepare ->
          [
            "overalls-ssh-authorize ensure #{username}",
            "test \"$(id -u #{username})\" = #{uid}",
            "test \"$(stat -c %u:%g:%a #{home})\" = #{uid}:#{uid}:700",
            "mkdir -p #{home}/workspace && printf '# Overalls browser editor fixture\\n\\nPersistent local workspace.\\n' > #{home}/workspace/browser-fixture.md && chown -R #{uid}:#{uid} #{home}/workspace",
            "for workspace in #{home}/workspace /opt/overalls-editor-#{username}; do mkdir -p \"$workspace\"; printf 'root = true\\n\\n[*]\\nindent_style = space\\nindent_size = 3\\n' > \"$workspace/.editorconfig\"; printf 'EditorConfig fixture\\n' > \"$workspace/indent.txt\"; printf 'printf \"approved\\\\n\" > \"$PWD/direnv-executed.marker\"\\nexport OVERALLS_FIXTURE_DIRENV=approved\\n' > \"$workspace/.envrc\"; chown -R #{uid}:#{uid} \"$workspace\"; done",
            "install -d -m 700 -o #{uid} -g #{uid} #{home}/.local/share/overalls/vscode-web/data/Machine && install -m 600 -o #{uid} -g #{uid} /opt/overalls-editor-fixture/conflicting-settings.json #{home}/.local/share/overalls/vscode-web/data/Machine/settings.json && chown -R #{uid}:#{uid} #{home}/.local",
            "runuser -u #{username} -- overalls-code --install-extension /opt/overalls-editor-fixture/native-fixture.vsix --server-data-dir #{home}/.local/share/overalls/vscode-web --disable-telemetry >/dev/null 2>&1"
          ]

        :custody ->
          [
            "test \"$(stat -c %u:%a /run/overalls-vscode/u#{uid}/editor.sock)\" = #{uid}:600",
            "pid=$(systemctl show -p MainPID --value #{unit}); test \"$pid\" -gt 0 && test \"$(stat -c %u /proc/$pid)\" = #{uid}"
          ]

        :broker_restart ->
          [
            "before=$(systemctl show -p MainPID --value #{unit}); test \"$before\" -gt 0 && systemctl restart overalls-vscode-web.service && test \"$(systemctl show -p MainPID --value #{unit})\" = \"$before\""
          ]

        :worker_stop ->
          ["systemctl stop #{unit}"]

        :saved ->
          [
            "test -s #{home}/workspace/browser-fixture.md && test \"$(stat -c %u #{home}/workspace/browser-fixture.md)\" = #{uid}"
          ]

        :policy ->
          [
            "valid=0; for workspace in #{home}/workspace /opt/overalls-editor-#{username}; do grep -Fxq passed \"$workspace/native-policy.marker\" && test \"$(stat -c %u \"$workspace/native-policy.marker\")\" = #{uid} || valid=1; done; test \"$valid\" = 0",
            "grep -Fxq passed #{home}/workspace/native-direnv.marker && grep -Fxq approved #{home}/workspace/direnv-executed.marker && test \"$(stat -c %u #{home}/workspace/direnv-executed.marker)\" = #{uid}",
            "test ! -e /opt/overalls-editor-#{username}/direnv-executed.marker",
            "grep -Fxq passed #{home}/workspace/native-disabled.marker && grep -Fxq passed #{home}/workspace/native-overrides.marker"
          ]
      end

    {:ok, terminal} = Terminal.connect(placement)

    try do
      :ok = mark(:root_shell)
      :ok = ready_root(terminal, deadline())
      :ok = mark(:terminal)

      for command <- commands do
        marker = "EDITOR_" <> Base.encode16(:crypto.strong_rand_bytes(12))

        :ok =
          Terminal.write(
            terminal,
            command <> "; result=$?; printf '\\n#{marker}:%s\\n' \"$result\"\n"
          )

        wait(terminal, Regex.compile!("\\n#{marker}:0\\n"), deadline(), "")
      end

      :ok
    after
      Terminal.close(terminal)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] editor-fixture-executed-root-shell
  # Console initialization MUST require a fresh newline-delimited result from
  # an executed root UID assertion. Prompt appearance and input echo MUST NOT
  # establish readiness. Failure MUST retain the 120-second bound and withhold
  # all terminal bytes.
  @spec ready_root(Terminal.t(), integer()) :: :ok
  defp ready_root(terminal, until) do
    marker = "EDITOR_ROOT_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(
        terminal,
        "\ntest \"$(id -u)\" = 0; result=$?; printf '\\n%s%s:%s\\n' #{marker} _READY \"$result\"\n"
      )

    wait(terminal, Regex.compile!("\\n#{marker}_READY:0\\n"), until, "")
  end

  # @cc [owner:ghuntley,label:verification;security] editor-fixture-failed-worker-observation
  # Failure diagnosis MUST first prove the current physical boot and an executed
  # root console assertion. Its subsequent read-only checks MUST emit only the
  # fixed boolean keys below, never unit metadata, journal bodies, terminal
  # bytes or worker arguments. Node may execute only the editor package's own
  # runtime with --version as the reconciled personal user. Resource sources
  # MUST be captured once and their numeric fields validated before separate
  # observability and pressure flags consume that same snapshot. Unreadable
  # counters MUST NOT establish absence of OOM or PID exhaustion. Low memory
  # means MemAvailable below 256 MiB. Diagnosis MUST NOT launch an editor or
  # replace failed browser acceptance. Console checks MUST share one 30-second
  # deadline.
  @spec diagnose(String.t(), String.t(), integer()) :: :ok
  defp diagnose(placement, username, uid) do
    _snapshot = snapshot_boot(placement)
    :ok = print_diagnostic(:native_boot, true)
    :ok = mark(:diagnostics)
    node = System.fetch_env!("FLEET_EDITOR_NODE")
    commit = System.fetch_env!("FLEET_EDITOR_COMMIT")

    true =
      Regex.match?(~r|\A/nix/store/[a-z0-9]{32}-overalls-vscode-web-[-a-zA-Z0-9_.]+/node\z|, node)

    true = Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)
    unit = "overalls-vscode-u#{uid}.service"
    socket = "/run/overalls-vscode/u#{uid}/editor.sock"
    worker_cgroup = "/sys/fs/cgroup/system.slice/#{unit}"
    broker_cgroup = "/sys/fs/cgroup/system.slice/overalls-vscode-web.service"

    probes = [
      {:broker_active, "systemctl is-active --quiet overalls-vscode-web.service"},
      {:broker_root,
       "pid=$(systemctl show -p MainPID --value overalls-vscode-web.service); test \"$pid\" -gt 0 && test \"$(stat -c %u /proc/$pid)\" = 0"},
      {:broker_exec_failed,
       "test \"$(systemctl show -p ExecMainStatus --value overalls-vscode-web.service)\" = 203"},
      {:broker_package_failed,
       "journalctl -u overalls-vscode-web.service -b -n 128 --no-pager -o cat 2>/dev/null | grep -F '\"event\":\"editor.broker_failed\",\"reason\":\"package\"' >/dev/null"},
      {:worker_loaded, "test \"$(systemctl show -p LoadState --value #{unit})\" = loaded"},
      {:worker_active, "systemctl is-active --quiet #{unit}"},
      {:worker_failed, "systemctl is-failed --quiet #{unit}"},
      {:worker_uid,
       "pid=$(systemctl show -p MainPID --value #{unit}); test \"$pid\" -gt 0 && test \"$(stat -c %u /proc/$pid)\" = #{uid}"},
      {:worker_socket, "test -S #{socket} && test \"$(stat -c %u:%a #{socket})\" = #{uid}:600"},
      {:worker_exec_failed, "test \"$(systemctl show -p ExecMainStatus --value #{unit})\" = 203"},
      {:worker_version,
       "test \"$(curl --silent --fail --max-time 2 --max-filesize 64 --unix-socket #{socket} http://localhost/version 2>/dev/null)\" = #{commit}"},
      {:personal_launcher, "command -v runuser >/dev/null"},
      {:node_as_account, "runuser -u #{username} -- #{node} --version >/dev/null 2>&1"},
      {:guest_memory_observed,
       "overalls_editor_memory_snapshot=$(cat /proc/meminfo 2>/dev/null) && command -v awk >/dev/null && printf '%s\\n' \"$overalls_editor_memory_snapshot\" | grep -Eq '^MemAvailable:[[:space:]]+[0-9]+ kB$'"},
      {:guest_memory_low,
       "printf '%s\\n' \"$overalls_editor_memory_snapshot\" | awk '$1 == \"MemAvailable:\" && $2 < 262144 {low=1} END {exit !low}'"},
      {:guest_oom_observed,
       "overalls_editor_vmstat_snapshot=$(cat /proc/vmstat 2>/dev/null) && command -v awk >/dev/null && printf '%s\\n' \"$overalls_editor_vmstat_snapshot\" | grep -Eq '^oom_kill [0-9]+$'"},
      {:guest_oom,
       "printf '%s\\n' \"$overalls_editor_vmstat_snapshot\" | awk '$1 == \"oom_kill\" && $2 > 0 {found=1} END {exit !found}'"},
      {:broker_pids_observed,
       "overalls_editor_broker_pids_snapshot=$(cat #{broker_cgroup}/pids.events 2>/dev/null) && command -v awk >/dev/null && printf '%s\\n' \"$overalls_editor_broker_pids_snapshot\" | grep -Eq '^max [0-9]+$'"},
      {:broker_pids_limited,
       "printf '%s\\n' \"$overalls_editor_broker_pids_snapshot\" | awk '$1 == \"max\" && $2 > 0 {found=1} END {exit !found}'"},
      {:worker_memory_observed,
       "overalls_editor_worker_memory_snapshot=$(cat #{worker_cgroup}/memory.events 2>/dev/null) && command -v awk >/dev/null && printf '%s\\n' \"$overalls_editor_worker_memory_snapshot\" | grep -Eq '^oom [0-9]+$' && printf '%s\\n' \"$overalls_editor_worker_memory_snapshot\" | grep -Eq '^oom_kill [0-9]+$'"},
      {:worker_oom,
       "printf '%s\\n' \"$overalls_editor_worker_memory_snapshot\" | awk '$1 == \"oom\" && $2 > 0 {found=1} END {exit !found}'"},
      {:worker_oom_kill,
       "printf '%s\\n' \"$overalls_editor_worker_memory_snapshot\" | awk '$1 == \"oom_kill\" && $2 > 0 {found=1} END {exit !found}'"},
      {:worker_pids_observed,
       "overalls_editor_worker_pids_snapshot=$(cat #{worker_cgroup}/pids.events 2>/dev/null) && command -v awk >/dev/null && printf '%s\\n' \"$overalls_editor_worker_pids_snapshot\" | grep -Eq '^max [0-9]+$'"},
      {:worker_pids_limited,
       "printf '%s\\n' \"$overalls_editor_worker_pids_snapshot\" | awk '$1 == \"max\" && $2 > 0 {found=1} END {exit !found}'"}
    ]

    refusals = [
      {:refusal_package, "package"},
      {:refusal_account, "account"},
      {:refusal_custody, "custody"},
      {:refusal_startup, "startup"},
      {:refusal_readiness, "readiness"},
      {:refusal_transport, "transport"}
    ]

    journal_probes =
      Enum.map(refusals, fn {key, reason} ->
        {key,
         "journalctl -u overalls-vscode-web.service -b -n 128 --no-pager -o cat 2>/dev/null | grep -F '\"event\":\"editor.refused\",\"reason\":\"#{reason}\"' >/dev/null"}
      end)

    {:ok, terminal} = Terminal.connect(placement)

    try do
      until = System.monotonic_time(:millisecond) + 30_000
      :ok = ready_root(terminal, until)
      :ok = print_diagnostic(:root_shell, true)

      for {key, command} <- probes ++ journal_probes do
        value = probe_result(terminal, command, until)
        :ok = print_diagnostic(key, value)
      end

      :ok
    after
      Terminal.close(terminal)
    end
  end

  # @cc [owner:ghuntley,label:verification;privacy] editor-fixture-broker-journal
  # Failure capture MUST first prove the current physical boot and an executed
  # root console assertion, then read only this boot's journal of the editor
  # broker and the personal worker unit. The guest reduces each line to a
  # short closed record (timestamp, unit, event token) before it crosses the
  # console, so console wrapping cannot split it; lines matching neither the
  # broker's closed event schema nor fixed systemd lifecycle phrases are
  # dropped in the guest, and unit descriptions, PIDs, paths and request data
  # never leave it. From the worker's own log only the timestamp of its fixed
  # auto-shutdown phrase is kept. Capture is bounded in lines, bytes and a
  # 30-second deadline and MUST NOT change guest state.
  @journal_lines 400
  @journal_scan 5000
  @journal_bytes 262_144
  @journal_program """
  s/^([0-9]{10}\\.[0-9]{6}) [^ ]+ [^ ]+: [{]"service":"overalls-vscode-web-broker","event":"editor[.]([a-z_]{1,32})"(,"reason":"([a-z]{1,16})")?[}]$/J \\1 broker \\2 \\4/p
  s/^([0-9]{10}\\.[0-9]{6}) [^ ]+ systemd\\[1\\]: overalls-vscode-(web|u[0-9]+)[.]service: (Deactivated successfully|Main process exited|Failed with result|Scheduled restart job).*$/J \\1 \\2 \\3/p
  s/^([0-9]{10}\\.[0-9]{6}) [^ ]+ systemd\\[1\\]: (Started|Starting|Stopping|Stopped) overalls-vscode-(web|u[0-9]+)[.]service.*$/J \\1 \\3 \\2/p
  """
  @journal_tokens %{
    "Started" => "started",
    "Starting" => "starting",
    "Stopping" => "stopping",
    "Stopped" => "stopped",
    "Deactivated successfully" => "deactivated",
    "Main process exited" => "main_exited",
    "Failed with result" => "failed",
    "Scheduled restart job" => "restart_scheduled"
  }
  @spec journal(String.t(), integer()) :: :ok
  defp journal(placement, uid) do
    _snapshot = snapshot_boot(placement)
    :ok = mark(:diagnostics)
    worker = "overalls-vscode-u#{uid}.service"
    program = Base.encode64(@journal_program)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      until = System.monotonic_time(:millisecond) + 30_000
      :ok = ready_root(terminal, until)
      marker = "EDITOR_JOURNAL_" <> Base.encode16(:crypto.strong_rand_bytes(12))

      :ok =
        Terminal.write(
          terminal,
          "overalls_editor_journal_program=$(printf %s #{program} | base64 -d); printf '\\n%s%s\\n' #{marker} _BEGIN; journalctl -b --no-pager -q -o short-unix -n #{@journal_scan} -u overalls-vscode-web.service -u #{worker} 2>/dev/null | tr -cd '\\11\\12\\40-\\176' | sed -n -E -e \"$overalls_editor_journal_program\"; find /home -path '*/.local/share/overalls/vscode-web/*' -name remoteagent.log -type f -print0 2>/dev/null | xargs -0 -r grep -h -F 'ServerLifetime: all consumers inactive, shutting down' 2>/dev/null | cut -c1-23 | sed 's/^/LIFETIME /'; unset overalls_editor_journal_program; printf '\\n%s%s\\n' #{marker} _END\n"
        )

      lines = terminal |> collect(marker, until, "") |> String.split("\n", trim: true)
      kept = lines |> Enum.flat_map(&journal_entry(&1, uid)) |> Enum.take(-@journal_lines)
      Enum.each(kept, &IO.puts/1)
      IO.puts("Editor broker journal summary lines=#{length(lines)} kept=#{length(kept)}")
    after
      Terminal.close(terminal)
    end
  end

  @spec journal_entry(String.t(), integer()) :: [String.t()]
  defp journal_entry(line, uid) do
    record =
      ~r/\AJ (?<seconds>\d{10})\.(?<micros>\d{6}) (?<unit>web|u\d+|broker) (?<rest>[A-Za-z_ ]{1,40})\z/

    shutdown =
      ~r/\ALIFETIME (?<date>\d{4}-\d\d-\d\d) (?<clock>\d\d:\d\d:\d\d\.\d{3})\z/

    worker = "u#{uid}"

    cond do
      captures = Regex.named_captures(shutdown, line) ->
        ["Editor broker journal #{captures["date"]}T#{captures["clock"]}000 worker auto_shutdown"]

      captures = Regex.named_captures(record, line) ->
        time =
          captures["seconds"]
          |> String.to_integer()
          |> DateTime.from_unix!()
          |> DateTime.to_iso8601()
          |> String.replace_suffix("Z", ".#{captures["micros"]}Z")

        kind =
          case captures["unit"] do
            "broker" -> :event
            "web" -> "broker"
            ^worker -> "worker"
            _ -> nil
          end

        words = String.split(captures["rest"], " ", trim: true)

        {token, reason} =
          case {kind, words} do
            {:event, [event]} -> {event, ""}
            {:event, [event, reason]} -> {event, " " <> reason}
            {:event, _} -> {nil, ""}
            {nil, _} -> {nil, ""}
            _ -> {Map.get(@journal_tokens, Enum.join(words, " ")), ""}
          end

        cond do
          token == nil or not Regex.match?(~r/\A[a-z_]{1,32}\z/, token) or
              not Regex.match?(~r/\A( [a-z]{1,16})?\z/, reason) ->
            []

          kind == :event ->
            ["Editor broker journal #{time} broker editor.#{token}#{reason}"]

          true ->
            ["Editor broker journal #{time} #{kind} #{token}"]
        end

      true ->
        []
    end
  end

  @spec collect(Terminal.t(), String.t(), integer(), binary()) :: binary()
  defp collect(terminal, marker, until, body) do
    true = System.monotonic_time(:millisecond) < until
    true = byte_size(body) <= @journal_bytes

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = String.replace(body <> bytes, "\r", "")

        case Regex.run(~r/\n#{marker}_BEGIN\n(?<lines>.*)\n#{marker}_END\n/s, body,
               capture: :all_but_first
             ) do
          [lines] -> lines
          _ -> collect(terminal, marker, until, body)
        end

      {:error, :timeout} ->
        collect(terminal, marker, until, body)

      _ ->
        raise "Editor guest journal transport closed"
    end
  end

  @spec print_diagnostic(diagnostic_key(), boolean()) :: :ok
  defp print_diagnostic(key, value) when key in @diagnostic_keys and is_boolean(value) do
    IO.puts("Editor native diagnostic #{key}=#{value}")
  end

  @spec probe_result(Terminal.t(), String.t(), integer()) :: boolean()
  defp probe_result(terminal, command, until) do
    marker = "EDITOR_DIAGNOSTIC_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(
        terminal,
        "if { #{command}; }; then result=0; else result=1; fi; printf '\\n%s%s:%s\\n' #{marker} _RESULT \"$result\"\n"
      )

    await_probe(terminal, Regex.compile!("\\n#{marker}_RESULT:(?<exit>[01])\\n"), until, "")
  end

  @spec await_probe(Terminal.t(), Regex.t(), integer(), binary()) :: boolean()
  defp await_probe(terminal, pattern, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = String.replace(tail <> bytes, "\r", "")

        case Regex.named_captures(pattern, body) do
          %{"exit" => "0"} ->
            true

          %{"exit" => "1"} ->
            false

          _ ->
            count = min(byte_size(body), 512)

            await_probe(
              terminal,
              pattern,
              until,
              binary_part(body, byte_size(body) - count, count)
            )
        end

      {:error, :timeout} ->
        await_probe(terminal, pattern, until, tail)

      _ ->
        raise "Editor guest diagnostic transport closed"
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery;security] editor-native-fresh-boot-proof
  # Boot evidence MUST verify native confinement through Driver, then reacquire
  # the placement lock and match current running intent, Boot.current and the
  # ready Provisioning journal, including its attested guest boot UUID.
  # Before/after snapshots MUST retain host, placement and epoch, advance
  # generation, and change both challenge and guest boot UUID digests. Only
  # digests enter separate root-private fixture files; no production journal
  # mutation or challenge/terminal output is permitted.
  @spec snapshot_boot(String.t()) :: boot_snapshot()
  defp snapshot_boot(placement) do
    directory = "/var/lib/lilly/vms/" <> placement
    :ok = mark(:intent)
    {:ok, intent} = Intent.read(directory)
    :ok = mark(:configuration)
    {:ok, runtime} = Lilly.Control.Config.load("/run/lilly-release/config.json")
    :ok = mark(:metadata)
    {:ok, bytes} = PrivateFiles.read_secret(Path.join(directory, "vm.json"))
    %{"pool_path" => pool_path, "spec" => shape} = JSON.decode!(bytes)

    :ok = mark(:specification)

    {:ok, spec} =
      Spec.new(%{
        id: shape["id"],
        image_id: shape["image_id"],
        pool_id: shape["pool_id"],
        profile: Map.fetch!(%{"oss" => :oss}, shape["profile"]),
        slot: shape["slot"],
        vcpu: shape["vcpu"],
        memory_bytes: shape["memory_bytes"],
        disk_bytes: shape["disk_bytes"]
      })

    :ok = mark(:pool)
    pool = Enum.find(runtime.pools, &(&1.id == spec.pool_id))
    true = pool.path == pool_path and spec.id == placement
    options = [execution_epoch: intent.execution_epoch, generation: intent.generation]
    :ok = mark(:native_proof)
    {:ok, %{pid: pid, cgroup: cgroup}} = Driver.boot_proof(runtime.execution, pool, spec, options)
    true = is_integer(pid) and pid > 0 and is_binary(cgroup) and Path.type(cgroup) == :absolute
    :ok = mark(:lock)
    {:ok, lock} = Lock.acquire(Path.join(directory, "lock"), 2000)

    try do
      :ok = mark(:current_intent)
      {:ok, ^intent} = Intent.read(directory)

      :ok = mark(:current_boot)

      {:ok, boot} =
        Boot.current(directory, placement, {intent.execution_epoch, intent.generation})

      :ok = mark(:provisioning)

      {:ok, record} =
        Lilly.Lifecycle.Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

      true = record.state == :ready
      true = record.payload["host_id"] == runtime.execution.network.host_id
      # Lilly records the readiness-attested guest boot UUID in boot.json as
      # guest_boot_id; the Provisioning journal names the same value boot_id.
      {guest_boot_id, launch} = Map.pop(boot, :guest_boot_id, record.payload["boot_id"])

      true =
        Enum.all?(launch, fn {key, value} -> record.payload[Atom.to_string(key)] == value end)

      true = OverallsProtocol.uuid?(record.payload["boot_id"])
      true = guest_boot_id == record.payload["boot_id"]

      :ok = mark(:snapshot)

      %{
        host_id: runtime.execution.network.host_id,
        placement_id: placement,
        execution_epoch: boot.execution_epoch,
        generation: boot.generation,
        challenge_digest: digest(boot.boot_challenge),
        guest_boot_digest: digest(record.payload["boot_id"])
      }
    after
      :ok = Lock.release(lock)
    end
  end

  @spec fixture_path() :: Path.t()
  defp fixture_path, do: "/var/lib/fleet-editor-boot"

  @spec capture_boot(String.t()) :: :ok
  defp capture_boot(placement) do
    snapshot = snapshot_boot(placement)
    :ok = mark(:fixture_write)
    :ok = PrivateFiles.directory(fixture_path())
    {:error, :enoent} = File.lstat(Path.join(fixture_path(), placement <> ".json"))
    :ok = PrivateFiles.write(fixture_path(), placement <> ".json", JSON.encode!(snapshot))
  end

  @spec changed_boot(String.t()) :: :ok
  defp changed_boot(placement) do
    :ok = mark(:fixture_read)
    {:ok, bytes} = PrivateFiles.read_secret(Path.join(fixture_path(), placement <> ".json"))

    %{
      "host_id" => host,
      "placement_id" => ^placement,
      "execution_epoch" => epoch,
      "generation" => generation,
      "challenge_digest" => challenge,
      "guest_boot_digest" => guest
    } = previous = JSON.decode!(bytes)

    true = map_size(previous) == 6 and OverallsProtocol.uuid?(host)
    true = is_integer(epoch) and epoch > 0 and is_integer(generation) and generation > 0
    true = is_binary(challenge) and Regex.match?(~r/\A[0-9a-f]{64}\z/, challenge)
    true = is_binary(guest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, guest)
    current = snapshot_boot(placement)
    :ok = mark(:snapshot_match)
    true = current.host_id == host and current.execution_epoch == epoch
    true = current.generation > generation
    true = current.challenge_digest != challenge and current.guest_boot_digest != guest
    :ok
  end

  # @cc [owner:ghuntley,label:verification;privacy] editor-fixture-finite-diagnostics
  # Failure classification MUST contain only a stage from this closed catalog.
  # Raw errors, native boot challenges, configuration and journals MUST stay
  # private. Separately catalogued boolean probes MUST NOT establish acceptance.
  @spec failure_stage() :: stage()
  def failure_stage do
    case Process.get({__MODULE__, :stage}, :arguments) do
      stage when stage in @stages -> stage
      _ -> :arguments
    end
  end

  @spec mark(stage()) :: :ok
  defp mark(stage) when stage in @stages do
    Process.put({__MODULE__, :stage}, stage)
    :ok
  end

  @spec digest(binary()) :: String.t()
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @spec deadline() :: integer()
  defp deadline, do: System.monotonic_time(:millisecond) + 120_000

  @spec wait(Terminal.t(), Regex.t(), integer(), binary()) :: :ok
  defp wait(terminal, pattern, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = String.replace(tail <> bytes, "\r", "")

        if Regex.match?(pattern, body) do
          :ok
        else
          count = min(byte_size(body), 512)
          wait(terminal, pattern, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(terminal, pattern, until, tail)

      _ ->
        raise "Editor guest fixture transport closed"
    end
  end
end

try do
  [operation, placement, username, uid] = System.argv()

  mode =
    Map.fetch!(
      %{
        "prepare" => :prepare,
        "custody" => :custody,
        "broker-restart" => :broker_restart,
        "worker-stop" => :worker_stop,
        "saved" => :saved,
        "policy" => :policy,
        "boot-capture" => :boot_capture,
        "boot-changed" => :boot_changed,
        "diagnose" => :diagnose,
        "journal" => :journal
      },
      operation
    )

  :ok = EditorGuestFixture.run(mode, placement, username, String.to_integer(uid))
  IO.puts("Editor native guest assertions passed")
rescue
  _ ->
    IO.puts(
      :stderr,
      "Editor native guest assertions failed at #{EditorGuestFixture.failure_stage()}; terminal bytes withheld"
    )

    System.halt(1)
end
