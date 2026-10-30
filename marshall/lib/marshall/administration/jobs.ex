defmodule Marshall.Administration.Jobs do
  @moduledoc "Cedar-authorized job views and retries with no raw job payload projection."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Administration.{AuditEvent, JobEvent, JobSnapshot}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Operation, Relocation, HostDrain}
  require Ash.Query
  require Marshall.Events

  @states [
    :available,
    :suspended,
    :scheduled,
    :executing,
    :retryable,
    :completed,
    :discarded,
    :cancelled
  ]
  @fields [
    :id,
    :state,
    :queue,
    :worker,
    :attempt,
    :max_attempts,
    :priority,
    :error_count,
    :inserted_at,
    :scheduled_at,
    :attempted_at,
    :completed_at,
    :discarded_at,
    :cancelled_at,
    :captured_at,
    :expires_at,
    :raw_present,
    :subject_kind,
    :subject_id
  ]

  @impl true
  def run(input, options, %{actor: %Marshall.Accounts.User{} = actor}) do
    Ledger.transaction(fn ->
      unless Marshall.Authorization.control_plane?(actor, "admin_read"),
        do: Ledger.rollback(:forbidden)

      if options[:operation] == :retry, do: require_admin!(actor)

      case options[:operation] do
        :list -> list(input.arguments)
        :get -> get(input.arguments)
        :retry -> retry(input.arguments, actor)
      end
    end)
    |> case do
      {:ok, {value, event}} ->
        unless Marshall.Repo.in_transaction?(), do: emit_event(event)
        {:ok, value}

      {:ok, value} ->
        {:ok, value}

      error ->
        error
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;capacity] job-admin-safe-bounded-pages
  # Job reads MUST use redacted snapshots and exclude expired records with database
  # time. Query at most limit+1 snapshots and 51 events. Counts describe retained
  # raw jobs only; pruned history MUST NOT inflate current queue counts.
  defp list(request) do
    request = Map.merge(%{state: nil, queue: nil, worker: nil, since: nil, before: nil}, request)
    query = retained(JobSnapshot)
    query = if request.state, do: Ash.Query.filter(query, state == ^request.state), else: query
    query = if request.queue, do: Ash.Query.filter(query, queue == ^request.queue), else: query
    query = if request.worker, do: Ash.Query.filter(query, worker == ^request.worker), else: query

    query =
      if request.since, do: Ash.Query.filter(query, captured_at >= ^request.since), else: query

    query = if request.before, do: Ash.Query.filter(query, id < ^request.before), else: query

    rows =
      query
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(request.limit + 1)
      |> Ash.read!(actor: SystemActor.compute())

    counts =
      retained(JobSnapshot)
      |> Ash.Query.filter(raw_present == true)
      |> Ash.aggregate!(Enum.map(@states, &{&1, :count, [query: [filter: [state: &1]]]}),
        actor: SystemActor.compute()
      )

    now = Ledger.now()

    %{
      items: Enum.map(Enum.take(rows, request.limit), &view(&1, now)),
      counts: counts,
      next_cursor: if(length(rows) > request.limit, do: Enum.at(rows, request.limit - 1).id)
    }
  end

  defp get(request) do
    request = Map.put_new(request, :events_before, nil)

    job =
      retained(JobSnapshot)
      |> Ash.Query.filter(id == ^request.id)
      |> Ash.read_one!(actor: SystemActor.compute())

    unless job, do: Ledger.rollback(:unknown_job)

    query = retained(JobEvent) |> Ash.Query.filter(job_id == ^job.id)
    # Database sequence IDs provide stable transition pagination.
    query =
      if request.events_before,
        do: Ash.Query.filter(query, id < ^request.events_before),
        else: query

    events =
      query
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(51)
      |> Ash.read!(actor: SystemActor.compute())

    %{
      job: view(job, Ledger.now()),
      subject: subject(job),
      events:
        events
        |> Enum.take(50)
        |> Enum.map(&Map.take(&1, [:id, :state, :attempt, :error_count, :captured_at])),
      next_events_cursor: if(length(events) > 50, do: Enum.at(events, 49).id)
    }
  end

  # @cc [owner:ghuntley,label:concurrency;security] job-retry-audited-current-state
  # Retry MUST serialize with account demotion and account-locked elevation/login
  # revocation, recheck Cedar after admission locks, lock the raw job
  # and accept only retryable/discarded states. Use Oban's retry API and commit an
  # actor/request-bound audit receipt in the same transaction. Exact retries reuse
  # receipts; changed request meaning fails. No raw args/errors may be read back.
  defp retry(request, actor) do
    Ledger.lock!(Marshall.Accounts.AdminBootstrap, "installation") || Ledger.rollback(:forbidden)
    Marshall.Accounts.Security.lock_user!(actor.id)
    require_admin!(actor)
    resource_id = Integer.to_string(request.id)

    case Ledger.read!(AuditEvent, actor_id: actor.id, request_id: request.request_id) do
      [event] ->
        unless event.action == :retry_job and event.resource_id == resource_id,
          do: Ledger.rollback(:idempotency_conflict)

        {%{id: request.id, accepted: true}, nil}

      [] ->
        result =
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "SELECT state FROM oban_jobs WHERE id = $1 FOR UPDATE",
            [request.id],
            log: false
          )

        case result.rows do
          [[state]] when state in ["retryable", "discarded"] -> :ok
          [] -> Ledger.rollback(:job_archived)
          _ -> Ledger.rollback(:job_not_retryable)
        end

        require_admin!(actor)
        :ok = Oban.retry_job(request.id)

        Ledger.create!(AuditEvent, :record, %{
          actor_id: actor.id,
          request_id: request.request_id,
          action: :retry_job,
          resource_type: :job,
          resource_id: resource_id
        })

        {%{id: request.id, accepted: true}, {:job_retried, request.id, actor.id}}
    end
  end

  defp emit_event({:job_retried, job_id, actor_id}),
    do: Marshall.Events.emit("admin.job_retried", job_id: job_id, actor_id: actor_id)

  defp emit_event(nil), do: :ok

  defp retained(resource),
    do:
      resource
      |> Ash.Query.filter(
        is_nil(expires_at) or expires_at > fragment("(statement_timestamp() AT TIME ZONE 'UTC')")
      )

  defp require_admin!(actor) do
    unless Marshall.Authorization.control_plane?(actor, "admin_jobs"),
      do: Ledger.rollback(:forbidden)
  end

  defp view(job, now) do
    ended =
      case job.state do
        :completed -> job.completed_at
        :discarded -> job.discarded_at
        :cancelled -> job.cancelled_at
        _ -> nil
      end

    Map.merge(Map.take(job, @fields), %{
      retryable: job.raw_present and job.state in [:retryable, :discarded],
      duration_ms:
        if(ended && job.attempted_at,
          do: max(0, DateTime.diff(ended, job.attempted_at, :millisecond))
        ),
      queue_age_seconds:
        if(job.state in [:available, :suspended, :scheduled, :retryable],
          do: max(0, DateTime.diff(now, job.scheduled_at || job.inserted_at))
        ),
      failure:
        if(job.error_count > 0,
          do:
            "An execution attempt failed. Raw exception details are excluded from administrative history."
        )
    })
  end

  defp subject(%{subject_kind: :operation, subject_id: id}) when not is_nil(id) do
    case Ledger.read!(Operation, id: id) do
      [op] -> %{kind: :operation, id: id, vm_id: op.vm_id, status: op.status}
      _ -> nil
    end
  end

  defp subject(%{subject_kind: :relocation, subject_id: id}) when not is_nil(id) do
    case Ledger.read!(Relocation, id: id) do
      [r] -> %{kind: :relocation, id: id, vm_id: r.vm_id, finished: not is_nil(r.finished_at)}
      _ -> nil
    end
  end

  defp subject(%{subject_kind: :drain, subject_id: id}) when not is_nil(id) do
    case Ledger.read!(HostDrain, id: id) do
      [d] -> %{kind: :drain, id: id, host_id: d.host_id, status: d.status}
      _ -> nil
    end
  end

  defp subject(_), do: nil
end
