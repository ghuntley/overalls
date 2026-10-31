defmodule FleetTerminal do
  @moduledoc "Privileged machine-test PTY adapter; browser authority is tested separately."
  alias Lilly.Terminal.Vsock

  @type t :: %{socket: Vsock.socket(), control: Vsock.socket(), session_id: pos_integer()}

  @type boot_observation :: %{
          intent_readable: boolean(),
          boot_readable: boolean(),
          intent_present: boolean(),
          boot_present: boolean(),
          intent_running: boolean(),
          placement_matches: boolean(),
          epoch_matches: boolean(),
          generation_matches: boolean(),
          current_boot: boolean()
        }

  # @cc [owner:ghuntley,label:verification;security] fixture-boot-observation-boundary
  # Observations MUST expose only these nine booleans from validated native
  # readers. They MUST NOT emit boot challenges or file contents, mutate launch
  # state, or confer authority: unlocked observations may race a transition.
  @spec observe_boot(String.t()) :: boot_observation()
  def observe_boot(placement) do
    true = OverallsProtocol.uuid?(placement)
    directory = "/var/lib/lilly/vms/" <> placement
    intent_result = Lilly.VM.Intent.read(directory)
    boot_result = Lilly.VM.Boot.read(directory)

    observation = %{
      intent_readable: match?({:ok, _}, intent_result),
      boot_readable: match?({:ok, _}, boot_result),
      intent_present: match?({:ok, %{}}, intent_result),
      boot_present: match?({:ok, %{}}, boot_result),
      intent_running: match?({:ok, %{state: :running}}, intent_result),
      placement_matches: false,
      epoch_matches: false,
      generation_matches: false,
      current_boot: false
    }

    case {intent_result, boot_result} do
      {{:ok, %{} = intent}, {:ok, %{} = boot}} ->
        %{
          observation
          | placement_matches:
              intent.placement_id == placement and boot.placement_id == placement,
            epoch_matches: intent.execution_epoch == boot.execution_epoch,
            generation_matches: intent.generation == boot.generation,
            current_boot:
              match?(
                {:ok, _},
                Lilly.VM.Boot.current(directory, placement, {
                  intent.execution_epoch,
                  intent.generation
                })
              )
        }

      _ ->
        observation
    end
  end

  # @cc [owner:ghuntley,label:verification;security] fleet-terminal-current-boot
  # Fixture connections MUST authenticate the persisted running boot through
  # Firecracker/vsock and create an isolated test PTY for the explicitly selected
  # account, defaulting to root. They MUST NOT restore serial autologin or print
  # boot challenges, tokens or terminal bytes.
  @spec connect(String.t(), String.t()) :: {:ok, t()}
  def connect(placement, username \\ "root") do
    true = OverallsProtocol.uuid?(placement)
    true = Regex.match?(~r/\A[a-z][a-z0-9_-]{0,30}\z/, username)
    directory = "/var/lib/lilly/vms/" <> placement
    Process.put(:fixture_stage, :terminal_intent)
    {:ok, intent} = Lilly.VM.Intent.read(directory)

    Process.put(:fixture_stage, :terminal_boot)

    {:ok, boot} =
      Lilly.VM.Boot.current(directory, placement, {intent.execution_epoch, intent.generation})

    Process.put(:fixture_stage, :terminal_claim)
    {:ok, bytes} = Lilly.Host.PrivateFiles.read_secret(Path.join(directory, "vm.json"))
    %{"pool_path" => pool} = JSON.decode!(bytes)
    true = is_binary(pool) and Path.type(pool) == :absolute

    identity =
      Map.put(
        boot,
        :uds_path,
        Path.join([pool, ".lilly-jails", "firecracker", placement, "root", "v.sock"])
      )

    Process.put(:fixture_stage, :terminal_vsock)
    control =
      case Vsock.connect(identity) do
        {:ok, socket} -> socket
        {:error, reason} when reason in [:connect_failed, :handshake_failed, :timeout, :closed, :rejected] ->
          Process.put(:fixture_stage, {:terminal_vsock, reason})
          raise "Fixture terminal vsock unavailable"
      end

    try do
      Process.put(:fixture_stage, :terminal_create)

      {:ok, created} =
        Vsock.create(control, username, "xterm-256color", 80, 24,
          timeout: create_timeout(username)
        )

      Process.put(:fixture_stage, :terminal_attach)

      case Vsock.attach(identity, created.guest_session_id, created.attach_token, :rw, 0) do
        {:ok, attached} ->
          {:ok,
           %{socket: attached.socket, control: control, session_id: created.guest_session_id}}

        _ ->
          Vsock.kill(control, created.guest_session_id)
          raise "Fixture terminal attachment failed"
      end
    rescue
      _ ->
        Vsock.close(control)
        raise "Fixture terminal unavailable"
    end
  end

  # @cc [owner:ghuntley,label:verification] fleet-terminal-account-create-deadline
  # Non-root creation MUST wait past terminald's 10 s account-helper bound:
  # the guest runs `overalls-ssh-authorize ensure` (a Ziggy roster round trip)
  # before it replies, so Vsock.create's 2 s default fails a healthy create.
  # Root creation keeps the default because terminald runs no helper for root.
  @account_create_timeout_ms 15_000
  @spec create_timeout(String.t()) :: pos_integer()
  defp create_timeout("root"), do: 2_000
  defp create_timeout(_username), do: @account_create_timeout_ms

  @spec write(t(), binary()) :: :ok | {:error, term()}
  def write(terminal, bytes), do: Vsock.write(terminal.socket, bytes)

  @spec read(t(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(terminal, timeout), do: :gen_tcp.recv(terminal.socket, 0, timeout)

  # @cc [owner:ghuntley,label:verification;security] fixture-shell-executed-readiness
  # Shell readiness MUST require a newline-delimited random marker printed by
  # the live PTY, independent of prompt appearance and input echo. Failure MUST
  # expose no terminal bytes; retained matching state MUST remain bounded.
  @spec ready(t(), pos_integer()) :: :ok
  def ready(terminal, timeout) do
    marker = "SHELL_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    :ok = write(terminal, "\nprintf '\\n%s%s\\n' #{marker} _READY\n")

    await_ready(
      terminal,
      "\n#{marker}_READY\n",
      System.monotonic_time(:millisecond) + timeout,
      ""
    )
  end

  @spec await_ready(t(), binary(), integer(), binary()) :: :ok
  defp await_ready(terminal, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until,
      do: raise("Fixture shell readiness timed out; terminal bytes withheld")

    case read(terminal, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          await_ready(terminal, marker, until, binary_part(body, byte_size(body) - count, count))
        else
          :ok
        end

      {:error, :timeout} ->
        await_ready(terminal, marker, until, tail)

      _ ->
        raise "Fixture shell unavailable; terminal bytes withheld"
    end
  end

  @spec close(t()) :: :ok
  def close(terminal) do
    _ = Vsock.kill(terminal.control, terminal.session_id)
    Vsock.close(terminal.socket)
    Vsock.close(terminal.control)
  end
end
