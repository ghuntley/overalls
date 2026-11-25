defmodule Lilly.VM.Observation do
  @moduledoc "Confirm process identity, confinement and API readiness before reporting a running VMM."
  require Lilly.Events
  alias Lilly.Host.{Command, Pool}
  alias Lilly.VM.{API, Config, Jail, Spec, Unit}
  # @cc [owner:ghuntley,label:isolation] running-means-verified-confinement
  # running?/3 MUST return true only for the expected VMM identity, jail root, network namespace,
  # UID/GID, seccomp/no-new-privileges and resource limits with a matching running API response;
  # unavailable evidence must return false.
  @spec running?(Config.t(), Pool.t(), Spec.t()) :: boolean()
  def running?(config, pool, spec), do: match?({:ok, _}, vmm(config, pool, spec))

  @type check ::
          :unit_not_running
          | :cgroup_unreadable
          | :vmm_process_ambiguous
          | :identity_mismatch
          | :limits_mismatch
          | :api_unavailable
          | :unit_stopped_during_check
  @type vmm :: %{pid: pos_integer(), cgroup: Path.t()}
  @type incarnation :: {pos_integer(), pos_integer()}

  # @cc [owner:ghuntley,label:isolation;recovery] interrupted-restore-same-process-incarnation
  # incarnation/1 requires a separately confined VMM proof. Its kernel start
  # ticks MUST distinguish PID reuse across a resume request; unavailable or
  # malformed proc evidence MUST refuse. Process data MUST NOT enter logs.
  @spec incarnation(vmm()) :: {:ok, incarnation()} | {:error, :physical_identity_unconfirmed}
  def incarnation(%{pid: pid}) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         do: parse_incarnation(pid, stat),
         else: (_ -> {:error, :physical_identity_unconfirmed})
  end

  @doc false
  @spec parse_incarnation(pos_integer(), binary()) ::
          {:ok, incarnation()} | {:error, :physical_identity_unconfirmed}
  def parse_incarnation(pid, stat) when is_integer(pid) and pid > 0 and byte_size(stat) <= 4096 do
    prefix = Integer.to_string(pid) <> " (firecracker) "

    with true <- String.valid?(stat) and String.starts_with?(stat, prefix),
         fields =
           stat
           |> binary_part(byte_size(prefix), byte_size(stat) - byte_size(prefix))
           |> String.split(),
         value when is_binary(value) <- Enum.at(fields, 19),
         {started, ""} when started > 0 <- Integer.parse(value),
         true <- Integer.to_string(started) == value,
         do: {:ok, {pid, started}},
         else: (_ -> {:error, :physical_identity_unconfirmed})
  end

  def parse_incarnation(_, _), do: {:error, :physical_identity_unconfirmed}

  @doc "The verified running VMM's host PID and unit cgroup, under the same checks as running?/3."
  # @cc [owner:ghuntley,label:observability;isolation] observation-failure-is-named
  # vmm/3 MUST return :error exactly when check/3 names a failing check, and
  # MUST emit vm.observation_failed once per distinct consecutive failing check
  # for the placement in the calling process (a success re-arms it), carrying
  # only the placement id and the closed check atom: never paths, PIDs or output.
  @spec vmm(Config.t(), Pool.t(), Spec.t()) :: {:ok, vmm()} | :error
  def vmm(config, pool, spec) do
    key = {__MODULE__, :failed, spec.id}

    case check(config, pool, spec) do
      {:ok, vmm} ->
        Process.delete(key)
        {:ok, vmm}

      {:error, check} ->
        if Process.put(key, check) != check do
          Lilly.Events.emit("vm.observation_failed", placement_id: spec.id, check: check)
        end

        :error
    end
  end

  @doc "The same checks as vmm/3, naming the first one that fails."
  @spec check(Config.t(), Pool.t(), Spec.t()) :: {:ok, vmm()} | {:error, check()}
  def check(config, pool, spec), do: check_state(config, pool, spec, [:running])

  @doc "Full confinement with an explicitly admitted API state for snapshot transitions."
  @spec check_state(Config.t(), Pool.t(), Spec.t(), [API.state()]) ::
          {:ok, vmm()} | {:error, check()}
  def check_state(config, pool, spec, states) do
    check_process(config, pool, spec, states, :configured)
  end

  # @cc [owner:ghuntley,label:isolation;recovery] unconfigured-restore-is-preboot-only
  # Firecracker 1.17.0 installs its main-thread seccomp filter once the builder
  # returns (firecracker/src/api_server_adapter.rs), after snapshot/load.
  # Before that request, this check MUST require an unconfigured API and the
  # exact unfiltered main thread, retaining every other confinement check.
  # This proof MUST NOT establish a paused or running guest. Those require
  # check_state/4 and its configured-thread seccomp filter after snapshot load.
  @spec preboot(Config.t(), Pool.t(), Spec.t()) :: {:ok, vmm()} | {:error, check()}
  def preboot(config, pool, spec),
    do: check_process(config, pool, spec, [:unconfigured], :preboot)

  defp check_process(config, pool, spec, states, phase) do
    with {:unit_not_running, {:ok, :running}} <- {:unit_not_running, Unit.status(spec)},
         {:cgroup_unreadable, {:ok, procs}} <-
           {:cgroup_unreadable, File.read(Path.join(Unit.cgroup(spec), "cgroup.procs"))},
         pids = String.split(procs),
         {:vmm_process_ambiguous, true} <- {:vmm_process_ambiguous, length(pids) in 1..64},
         {:vmm_process_ambiguous, [pid]} <-
           {:vmm_process_ambiguous, Enum.filter(pids, &vmm?(&1, spec, phase))},
         {:identity_mismatch, true} <-
           {:identity_mismatch,
            same_files?([
              {"/proc/#{pid}/root", Jail.root(pool, spec)},
              {"/proc/#{pid}/ns/net", "/run/netns/" <> config.network.namespace},
              {"/proc/#{pid}/exe", Path.join(Jail.root(pool, spec), "firecracker")}
            ])},
         {:limits_mismatch, true} <- {:limits_mismatch, limits?(spec)},
         {:api_unavailable, true} <-
           {:api_unavailable,
            case API.state(Path.join(Jail.root(pool, spec), "api.sock"), spec.id) do
              {:ok, state} -> state in states
              _ -> false
            end},
         {:unit_stopped_during_check, {:ok, :running}} <-
           {:unit_stopped_during_check, Unit.status(spec)} do
      {:ok, %{pid: String.to_integer(pid), cgroup: Unit.cgroup(spec)}}
    else
      {check, _} -> {:error, check}
    end
  end

  defp vmm?(pid, spec, phase) do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, pid),
         {:ok, body} <- File.read("/proc/#{pid}/status") do
      process_status?(body, pid, spec.network.uid, phase)
    else
      _ -> false
    end
  end

  @doc false
  @spec process_status?(binary(), String.t(), pos_integer(), :preboot | :configured) :: boolean()
  def process_status?(body, pid, uid, phase)
      when phase in [:preboot, :configured] and byte_size(body) <= 65_536 do
    if String.valid?(body) do
      fields =
        body
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {k, String.split(v)}
        end)

      fields["Name"] == ["firecracker"] and
        fields["Uid"] == List.duplicate(Integer.to_string(uid), 4) and
        fields["Gid"] == List.duplicate(Integer.to_string(uid), 4) and
        fields["CapEff"] == ["0000000000000000"] and fields["NoNewPrivs"] == ["1"] and
        fields["Seccomp"] == [if(phase == :preboot, do: "0", else: "2")] and
        fields["NSpid"] == [pid, "1"]
    else
      false
    end
  rescue
    _ -> false
  end

  def process_status?(_, _, _, _), do: false

  defp limits?(spec) do
    with {:ok, cpu} <- File.read(Path.join(Unit.cgroup(spec), "cpu.max")),
         [quota, period] <- String.split(cpu),
         {quota, ""} <- Integer.parse(quota),
         {period, ""} <- Integer.parse(period),
         true <- period > 0 and quota == spec.vcpu * period,
         {:ok, memory} <- File.read(Path.join(Unit.cgroup(spec), "memory.max")),
         true <- String.trim(memory) == Integer.to_string(Spec.host_memory(spec)),
         {:ok, swap} <- File.read(Path.join(Unit.cgroup(spec), "memory.swap.max")),
         true <- String.trim(swap) == "0",
         do: true,
         else: (_ -> false)
  end

  # @cc [owner:ghuntley,label:isolation;security] vmm-identity-through-hostd
  # same_files?/1 MUST compare device and inode of each pair. The BEAM, as
  # its service user, lacks the ptrace-level access the VMM's /proc root,
  # network namespace and executable need, so it asks lilly-hostd for one
  # `stat -L` read (ADR-0182). Any missing, malformed or partial answer MUST
  # be false.
  defp same_files?(pairs) do
    paths = Enum.flat_map(pairs, fn {a, b} -> [a, b] end)

    with {:ok, output} <- Command.run(:stat, ["-L", "--format=%d:%i", "--" | paths]),
         identities = String.split(output, "\n", trim: true),
         true <- length(identities) == length(paths),
         true <- Enum.all?(identities, &Regex.match?(~r/\A[0-9]+:[0-9]+\z/, &1)) do
      identities
      |> Enum.chunk_every(2)
      |> Enum.all?(fn [a, b] -> a == b end)
    else
      _ -> false
    end
  end
end
