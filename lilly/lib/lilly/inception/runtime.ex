defmodule Lilly.Inception.Runtime do
  @moduledoc "Independent bounded publication polls; slow guests never block execution control."
  use GenServer
  alias Lilly.Control.{Client, Store}
  alias Lilly.VM.{Driver, Executor}

  @poll_budget_ms 14_000
  @poll_retry_ms 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)
    {:ok, Map.merge(Map.new(options), %{tasks: %{}, cursor: nil, proof_cursors: %{}})}
  end

  # @cc [owner:ghuntley,label:security;recovery] inception-poll-worker-bound
  # At most sixteen placement polls may run concurrently and at most one per
  # placement. Each task MUST be killed after fifteen seconds. Polls MUST remain
  # separate from lifecycle sampling; loss of the authenticated control runtime
  # MUST stop these tasks without stopping VMs. No task payload may be logged.
  @impl true
  def handle_info(:tick, state) do
    state =
      case Store.all(state.store) do
        {:ok, commands} ->
          placements =
            commands
            |> Enum.filter(&(&1.profile == :inception and &1.kind in [:provision, :start]))
            |> Enum.map(& &1.placement_id)

          state = %{state | proof_cursors: Map.take(state.proof_cursors, placements)}
          active = MapSet.new(state.tasks, fn {_, {_, placement}} -> placement end)

          eligible =
            commands
            |> Enum.filter(fn command ->
              command.profile == :inception and command.kind in [:provision, :start] and
                command.host_id == state.config.client.host_id and
                not MapSet.member?(active, command.placement_id)
            end)
            |> Enum.sort_by(& &1.placement_id)

          {before, after_cursor} =
            Enum.split_while(eligible, &(state.cursor != nil and &1.placement_id <= state.cursor))

          Enum.take(after_cursor ++ before, 16 - map_size(state.tasks))
          |> Enum.reduce(state, fn command, state ->
            proof_cursor = Map.get(state.proof_cursors, command.placement_id, 0)

            task =
              Task.async(fn ->
                Process.flag(:sensitive, true)
                poll(state.config, state.session, command, proof_cursor)
                :ok
              end)

            Process.send_after(self(), {:expire, task.ref}, 15_000)

            %{
              state
              | tasks: Map.put(state.tasks, task.ref, {task, command.placement_id}),
                cursor: command.placement_id,
                proof_cursors:
                  Map.put(
                    state.proof_cursors,
                    command.placement_id,
                    rem(proof_cursor + 16, 65_536)
                  )
            }
          end)

        _ ->
          state
      end

    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end

  def handle_info({ref, :ok}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}

  def handle_info({:expire, ref}, state) do
    if entry = state.tasks[ref], do: Task.shutdown(elem(entry, 0), :brutal_kill)
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.tasks, fn {_, {task, _}} -> Task.shutdown(task, :brutal_kill) end)
    :ok
  end

  # @cc [owner:ghuntley,label:protocol;recovery] inception-final-publication-commit
  # A child publication is collected over a guest vsock and may consume most
  # of the five-second parent offer before it is ready to submit. Refresh the
  # offer after each collection; submitting against the offer used to discover
  # the namespace would make a still-valid child heartbeat appear expired.
  # After host DNS observations are accepted by the child, the final child
  # publication MUST be submitted with the refreshed parent offer before its
  # deadline. The first publication may contain only a proof or a not-ready
  # control record; dropping this final exchange leaves the parent with stale
  # DNS and prevents a newly issued control certificate from becoming reachable.
  # A rejected exchange MUST retry the complete poll with a new offer and fresh
  # child publication while the bounded task lease remains. Retrying a stale
  # result is forbidden because it could extend an expired child heartbeat.
  # After the bootstrap publication is accepted, a second child sample MUST be
  # committed against the returned offer before observation; deriving the DNS
  # deadline from the first offer would make a five-second heartbeat stale while
  # the parent exchange is still completing. This second sample also captures
  # the child's transition from proof-only to a ready control route.
  defp poll(config, session, command, proof_cursor) do
    deadline = System.monotonic_time(:millisecond) + @poll_budget_ms
    poll_until(config, session, command, proof_cursor, deadline)
  end

  @spec poll_until(map(), map(), map(), non_neg_integer(), integer()) :: :ok
  defp poll_until(config, session, command, proof_cursor, deadline) do
    case poll_once(config, session, command, proof_cursor) do
      :ok ->
        :ok

      _failure ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@poll_retry_ms, remaining))
          poll_until(config, session, command, proof_cursor, deadline)
        else
          :ok
        end
    end
  end

  @spec poll_once(map(), map(), map(), non_neg_integer()) :: :ok | {:error, atom()} | nil
  defp poll_once(config, session, command, proof_cursor) do
    with {:ok, offer} <- Client.exchange_inception(config.client, session, command, nil),
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)),
         {:ok, publication} <-
           Driver.inception_publication(
             config.execution,
             pool,
             spec,
             %{
               label: offer.label,
               zone: offer.zone,
               generation: offer.environment_generation,
               parent: offer.parent,
               public: offer.public
             },
             execution_epoch: command.execution_epoch,
             generation: command.generation
           ),
         {:ok, publication_offer} <-
           Client.exchange_inception(config.client, session, command, nil),
         true <- System.monotonic_time(:millisecond) < publication_offer.deadline do
      with {:ok, next_offer} <-
             Client.exchange_inception(config.client, session, command, %{
               "offer_id" => publication_offer.offer_id,
               "publication" => publication
             }),
           true <- is_map(publication_offer.public),
           true <-
             Map.take(publication_offer, [:label, :zone, :environment_generation, :public]) ==
               Map.take(offer, [:label, :zone, :environment_generation, :public]),
           {:ok, refreshed_publication} <-
             Driver.inception_publication(
               config.execution,
               pool,
               spec,
               %{
                 label: next_offer.label,
                 zone: next_offer.zone,
                 generation: next_offer.environment_generation,
                 parent: next_offer.parent,
                 public: next_offer.public
               },
               execution_epoch: command.execution_epoch,
               generation: command.generation
             ),
           {:ok, refreshed_offer} <-
             Client.exchange_inception(config.client, session, command, nil),
           true <- System.monotonic_time(:millisecond) < refreshed_offer.deadline,
           {:ok, observed_offer} <-
             Client.exchange_inception(config.client, session, command, %{
               "offer_id" => refreshed_offer.offer_id,
               "publication" => refreshed_publication
             }),
           true <-
             Map.take(refreshed_offer, [:label, :zone, :environment_generation, :public]) ==
               Map.take(next_offer, [:label, :zone, :environment_generation, :public]) do
        # Parent publication happens before querying the physical authoritative
        # replicas. The result is returned only through the same owned boot.
        namespace = %{
          label: refreshed_offer.label,
          zone: refreshed_offer.zone,
          generation: refreshed_offer.environment_generation,
          parent: refreshed_offer.parent,
          public: refreshed_offer.public
        }

        source_deadline = refreshed_offer.deadline + refreshed_publication["ttl_ms"] - 5000

        if source_deadline > System.monotonic_time(:millisecond) + 1200 and
             System.monotonic_time(:millisecond) < observed_offer.deadline do
          observations =
            Lilly.Inception.Propagation.observe(
              namespace,
              refreshed_publication,
              source_deadline,
              proof_cursor
            )

          with {:ok, final_publication} <-
                 Driver.inception_publication(
                   config.execution,
                   pool,
                   spec,
                   Map.put(namespace, :observations, observations),
                   execution_epoch: command.execution_epoch,
                   generation: command.generation
                 ),
               {:ok, final_offer} <-
                 Client.exchange_inception(config.client, session, command, nil),
               true <- System.monotonic_time(:millisecond) < final_offer.deadline,
               true <-
                 Map.take(final_offer, [:label, :zone, :environment_generation, :public]) ==
                   Map.take(refreshed_offer, [:label, :zone, :environment_generation, :public]),
               {:ok, _committed_offer} <-
                 Client.exchange_inception(config.client, session, command, %{
                   "offer_id" => final_offer.offer_id,
                   "publication" => final_publication
                 }) do
            :ok
          end
        else
          {:error, :stale_publication}
        end
      end
    end
  end
end
