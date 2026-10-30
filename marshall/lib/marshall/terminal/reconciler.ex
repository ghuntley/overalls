defmodule Marshall.Terminal.Reconciler do
  @moduledoc "Bounded metadata-only recovery of create intents and terminal registry authority."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Terminal.{Creation, Opening, Relay, Session, Termination}
  alias Marshall.Compute.{Host, Ledger, VirtualMachine, WorkloadPlacement}
  require Ash.Query

  # @cc [owner:ghuntley,label:recovery;security] reconcile-authoritative-snapshots
  # Reconciliation MUST capture registry candidates before a successful guest
  # listing; transport failure MUST NOT be interpreted as an empty listing.
  # Completed guest creates are recovered by request identity. Abandoned requests
  # MUST claim cancellation before the guest tombstone and retain that claim until
  # acknowledgement or authoritative retirement of the bound placement/epoch.
  # Closing registry authority MUST NOT release VM reservations
  # or be treated as physical VMM-death proof. Durable work contains IDs only.
  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) ::
          {:ok, non_neg_integer()} | {:error, Exception.t() | atom()}
  def run(input, _options, %{actor: %Marshall.Authorization.SystemActor{purpose: :compute}}) do
    if input.arguments[:vm_id] do
      case reconcile_vm(
             input.arguments.vm_id,
             input.arguments[:after_opening],
             input.arguments[:after_session]
           ) do
        :ok -> {:ok, 1}
        error -> error
      end
    else
      Marshall.Repo.transaction(fn -> schedule_vm_page(input.arguments[:after_vm]) end)
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:capacity] terminal-reconciliation-bounded-work
  # The scheduled fleet scan MUST enqueue at most ten VM jobs per transaction,
  # with an atomic cursor continuation. A VM job MUST attempt at most one pending
  # kill and one opening (query plus cancellation at most), then advance durable
  # ID cursors. A failed request MUST NOT starve later requests in the same VM.
  @spec schedule_vm_page(String.t() | nil) :: non_neg_integer()
  defp schedule_vm_page(cursor) do
    cursor = if cursor, do: Ecto.UUID.dump!(cursor), else: nil

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT DISTINCT vm_id FROM (
          SELECT vm_id FROM terminal_sessions WHERE archived_at IS NULL
          UNION ALL SELECT vm_id FROM terminal_openings WHERE status IN ('pending','cancelling')
        ) candidates WHERE ($1::uuid IS NULL OR vm_id > $1)
        ORDER BY vm_id LIMIT 11
        """,
        [cursor],
        log: false
      )

    ids = Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
    batch = Enum.take(ids, 10)

    Enum.each(batch, fn id ->
      AshOban.schedule(Opening, :reconcile, action_arguments: %{vm_id: id})
    end)

    if length(ids) > 10 do
      AshOban.schedule(Opening, :reconcile, action_arguments: %{after_vm: List.last(batch)})
    end

    prune_receipts()
    length(batch)
  end

  @spec reconcile_vm(String.t()) :: :ok | {:error, atom()}
  @spec reconcile_vm(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, atom()}
  def reconcile_vm(vm_id, after_opening \\ nil, after_session \\ nil) do
    sessions =
      Session
      |> Ash.Query.filter(vm_id == ^vm_id)
      |> Ash.Query.limit(64)
      |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

    opening_query =
      Opening
      |> Ash.Query.filter(vm_id == ^vm_id and status in [:pending, :cancelling])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(2)

    opening_query =
      if after_opening,
        do: Ash.Query.filter(opening_query, id > ^after_opening),
        else: opening_query

    openings = Ash.read!(opening_query, actor: Marshall.Authorization.SystemActor.compute())

    pending =
      sessions
      |> Enum.filter(
        &(&1.kill_status == :pending and (is_nil(after_session) or &1.id > after_session))
      )
      |> Enum.sort_by(& &1.id)

    selected_openings = Enum.take(openings, 1)
    selected_kills = Enum.take(pending, 1)
    query = VirtualMachine |> Ash.Query.filter(id == ^vm_id)

    result =
      case Ash.read_one(query, actor: Marshall.Authorization.SystemActor.compute()) do
        {:ok, %VirtualMachine{desired_state: :deleted}} ->
          retire_authority(sessions, selected_openings)

        {:ok, %VirtualMachine{} = vm} ->
          reconcile_current(vm, sessions, selected_openings, selected_kills)

        {:ok, nil} ->
          retire_authority(sessions, selected_openings)

        _ ->
          {:error, :terminal_unavailable}
      end

    if result == :ok and (length(openings) > 1 or length(pending) > 1) do
      AshOban.schedule(Opening, :reconcile,
        action_arguments: %{
          vm_id: vm_id,
          after_opening: next_cursor(selected_openings, after_opening),
          after_session: next_cursor(selected_kills, after_session)
        }
      )
    end

    result
  end

  defp reconcile_current(vm, sessions, openings, kills) do
    {old, current} = Enum.split_with(sessions, &(not current?(&1, vm)))
    Enum.each(old, &close_registry(&1, true))
    for session <- kills, current?(session, vm), do: Termination.dispatch(session)
    Enum.each(Enum.reject(openings, &Creation.current?(&1, vm)), &retire_opening/1)

    with {:ok, host} <- current_host(vm),
         {:ok, %{type: :listed, sessions: guests}} <-
           control(host.id, %{
             type: :listing,
             vm_id: vm.id,
             placement_id: vm.current_placement_id,
             execution_epoch: vm.execution_epoch
           }) do
      live = MapSet.new(Enum.filter(guests, & &1.alive), & &1.guest_session_id)

      Enum.each(current, fn session ->
        unless MapSet.member?(live, session.guest_session_id), do: close_registry(session)
      end)

      for opening <- openings,
          Creation.current?(opening, vm),
          do: recover_opening(host.id, opening)

      :ok
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  defp recover_opening(host_id, opening) do
    if opening.status == :cancelling or Creation.expired?(opening) do
      cancel(host_id, opening)
    else
      case control(host_id, message(:creation_query, opening)) do
        {:ok, %{type: :creation_status, state: :running, guest_session_id: id}} ->
          Creation.complete(opening.id, id)

        {:ok, %{type: :creation_status, state: :exited}} ->
          cancel(host_id, opening)

        _ ->
          :ok
      end
    end
  end

  defp cancel(host_id, opening) do
    with {:ok, _request} <- Creation.begin_cancel(opening.id),
         {:ok, %{type: :creation_cancelled, ok: true}} <-
           control(host_id, message(:creation_cancel, opening)),
         do: Creation.cancelled(opening.id)
  end

  defp retire_authority(sessions, openings) do
    Enum.each(sessions, &close_registry(&1, true))
    Enum.each(openings, &retire_opening/1)
    :ok
  end

  defp retire_opening(opening) do
    with {:ok, _} <- Creation.begin_cancel(opening.id), do: Creation.cancelled(opening.id)
  end

  defp current?(session, vm),
    do:
      session.placement_id == vm.current_placement_id and
        session.execution_epoch == vm.execution_epoch

  defp current_host(vm) do
    with {:ok, %WorkloadPlacement{} = placement} <-
           Ash.get(WorkloadPlacement, vm.current_placement_id,
             actor: Marshall.Authorization.SystemActor.compute()
           ),
         {:ok, %Host{} = host} <-
           Ash.get(Host, placement.host_id, actor: Marshall.Authorization.SystemActor.compute()),
         true <-
           is_map(host.inventory) and host.inventory["terminal_protocol"] == 2 and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               Ledger.now()
             ),
         do: {:ok, host},
         else: (_ -> {:error, :terminal_unavailable})
  end

  defp control(host_id, message) do
    with {:ok, stream} <- Relay.stream_for(host_id), do: Relay.control(stream, message)
  end

  defp message(type, opening),
    do: %{
      type: type,
      request_id: opening.id,
      vm_id: opening.vm_id,
      placement_id: opening.placement_id,
      execution_epoch: opening.execution_epoch
    }

  @spec close_registry(Session.t(), boolean()) :: :ok | {:error, atom()}
  defp close_registry(session, retired? \\ false),
    do: Termination.observe_absent(session, retired?, nil)

  @spec next_cursor([Opening.t() | Session.t()], String.t() | nil) :: String.t() | nil
  defp next_cursor([record], _), do: record.id
  defp next_cursor([], previous), do: previous

  defp prune_receipts do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      WITH expired AS (
        SELECT o.id FROM terminal_openings o
        WHERE o.inserted_at < clock_timestamp() - interval '24 hours'
        AND (o.status = 'failed' OR (o.status = 'ready' AND NOT EXISTS (
          SELECT 1 FROM terminal_sessions s WHERE s.id = o.session_id AND s.archived_at IS NULL)))
        ORDER BY o.inserted_at, o.id LIMIT 1000 FOR UPDATE SKIP LOCKED
      ) DELETE FROM terminal_openings o USING expired e WHERE o.id = e.id
      """,
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      WITH expired AS (SELECT host_id FROM terminal_stream_locations
        WHERE expires_at < clock_timestamp() - interval '1 hour'
        ORDER BY expires_at, host_id LIMIT 1000 FOR UPDATE SKIP LOCKED)
      DELETE FROM terminal_stream_locations l USING expired e WHERE l.host_id = e.host_id
      """,
      [],
      log: false
    )
  end
end
