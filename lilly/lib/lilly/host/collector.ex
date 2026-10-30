defmodule Lilly.Host.Collector do
  @moduledoc "Complete capacity snapshots, distinct from reservations and from the control connection."
  require Lilly.Events
  alias Lilly.Host.{Image, Inventory, Limits, Pool, PoolObserver, Usage}

  @type previous :: %{
          usage: Usage.previous()
        }

  # @cc [owner:ghuntley,label:capacity] collection-failure-is-scoped
  # sample/6 MUST withhold the host report when inventory or effective limits fail.
  # A failed pool snapshot MUST instead produce an explicit unavailable entry with
  # configured identity and no counters/credit, preserving independent pool samples.
  # Every configured pool remains represented; unknown capacity MUST NOT become zero.
  @spec sample(
          [Pool.t()],
          Path.t(),
          previous() | nil,
          pos_integer(),
          [Image.t()],
          map(),
          %{String.t() => map()},
          OverallsProtocol.View.view()
        ) ::
          {:ok, OverallsProtocol.report(), previous()} | {:error, atom()}
  def sample(
        pools,
        cgroup_path,
        previous,
        sequence,
        images \\ [],
        coverage \\ %{},
        native_io \\ %{},
        observer \\ PoolObserver.view()
      ) do
    collect(
      pools,
      cgroup_path,
      previous,
      sequence,
      images,
      DateTime.utc_now(),
      native_io,
      coverage,
      observer
    )
  end

  # @cc [owner:ghuntley,label:capacity] diagnostics-do-not-delay-sample
  # Capacity collection MUST NOT wait for native I/O or attach diagnostic
  # counters to control reports. Source-owned observability samples independently.

  # @cc [owner:ghuntley,label:capacity] pool-reads-do-not-delay-sample
  # Collection MUST take pool entries from the background pool observer
  # (PoolObserver.report/2) and MUST NOT read a pool inline while that observer
  # runs, so a slow pool read cannot delay the host report or its sampled_at.
  defp collect(
         pools,
         cgroup_path,
         previous,
         sequence,
         images,
         sampled_at,
         _native_io,
         coverage,
         observer
       ) do
    with true <- Pool.distinct?(pools),
         {:ok, inventory} <- Inventory.read(),
         {:ok, limits} <- Limits.read("/sys/fs/cgroup", cgroup_path, inventory) do
      snapshots = Enum.map(pools, &PoolObserver.report(&1, observer))

      {capacity, usage} =
        Usage.sample(
          "/sys/fs/cgroup",
          cgroup_path,
          inventory,
          limits,
          if(previous, do: Map.get(previous, :usage)),
          coverage
        )

      report = %{
        capacity: capacity,
        sequence: sequence,
        sampled_at: sampled_at,
        effective_cores: limits.effective_cores,
        effective_memory_bytes: limits.effective_memory_bytes,
        inventory: %{
          "architecture" => inventory.architecture,
          "images" => Image.available_ids(images),
          "execution_ready" => false,
          "terminal_protocol" => 0,
          "inception_image_id" => nil,
          "checkpoint_image_ids" => [],
          "checkpoint_compatibility" => nil
        },
        pools: snapshots
      }

      {:ok, report, %{usage: usage}}
    else
      failure ->
        Lilly.Events.emit("lilly.collection_failed", reason: collection_reason(failure))
        {:error, :collection_failed}
    end
  end

  # @cc [owner:ghuntley,label:capacity;observability] collection-failure-closed
  # Collection failures MUST report only a closed local reason atom; inventory,
  # limits and counter payloads MUST NOT enter diagnostics and the unavailable
  # report result MUST be preserved.
  defp collection_reason(false), do: :pools_indistinct

  defp collection_reason({:error, reason}), do: reason
end
