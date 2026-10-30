defmodule Marshall.CommittedFixtureCleanup do
  @moduledoc "Exact committed test-fixture teardown; never a production lifecycle operation."
  alias Marshall.Repo

  @type failure :: {Exception.kind(), term(), Exception.stacktrace()}
  @type outcome(value) :: {:ok, value} | {:raised, failure()}

  # @cc [owner:ghuntley,label:verification] committed-fixture-primary-failure
  # Teardown MUST run after the body. A failed body MUST retain its original
  # exception and stack; a simultaneous teardown failure MUST be reported as a
  # second ExUnit error. On failure, supplied peer processes MUST stop before any
  # fixture rows are deleted. Failure to observe peer termination forbids cleanup.
  @spec protect(keyword(Macro.t())) :: Macro.t()
  defmacro protect(blocks) do
    quote do
      Marshall.CommittedFixtureCleanup.run(
        fn -> unquote(Keyword.fetch!(blocks, :do)) end,
        fn -> unquote(Keyword.fetch!(blocks, :after)) end
      )
    end
  end

  @spec protect(Macro.t(), keyword(Macro.t())) :: Macro.t()
  defmacro protect(peers, blocks) do
    quote do
      Marshall.CommittedFixtureCleanup.run(
        fn -> unquote(Keyword.fetch!(blocks, :do)) end,
        fn -> unquote(Keyword.fetch!(blocks, :after)) end,
        unquote(peers)
      )
    end
  end

  @spec run((-> value), (-> term()), [pid()]) :: value when value: term()
  def run(body, cleanup, peers \\ []) do
    result = capture(body)

    teardown =
      capture(fn ->
        if match?({:raised, _}, result), do: Enum.each(peers, &stop_peer!/1)
        cleanup.()
      end)

    case {result, teardown} do
      {{:ok, value}, {:ok, _}} ->
        value

      {{:raised, {kind, reason, stack}}, {:ok, _}} ->
        :erlang.raise(kind, reason, stack)

      {{:ok, _}, {:raised, {kind, reason, stack}}} ->
        :erlang.raise(kind, reason, stack)

      {{:raised, original}, {:raised, secondary}} ->
        raise ExUnit.MultiError, errors: [original, secondary]
    end
  end

  @spec capture((-> value)) :: outcome(value) when value: term()
  defp capture(body) do
    try do
      {:ok, body.()}
    catch
      kind, reason -> {:raised, {kind, reason, __STACKTRACE__}}
    end
  end

  @spec stop_peer!(pid()) :: :ok
  defp stop_peer!(peer) do
    reference = Process.monitor(peer)

    try do
      :peer.stop(peer)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
    end

    receive do
      {:DOWN, ^reference, :process, ^peer, _} -> :ok
    after
      5_000 -> raise "Fixture peer did not stop before cleanup"
    end
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-initial-agent-history
  # Only roots selected by exact captured VM IDs and their thread/version IDs
  # may be deleted. Richer referenced agent work MUST fail the transaction rather
  # than broaden deletion. Unrelated and detached historical roots remain intact.
  @spec agent_history!([String.t()]) :: :ok
  def agent_history!(vm_ids) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        vms = Enum.map(vm_ids, &Ecto.UUID.dump!/1)
        %{rows: roots} = query("SELECT id FROM agent_roots WHERE vm_id=ANY($1::uuid[])", [vms])
        roots = Enum.map(roots, fn [id] -> id end)

        %{rows: threads} =
          query("SELECT id FROM agent_threads WHERE root_id=ANY($1::uuid[])", [roots])

        threads = Enum.map(threads, fn [id] -> id end)

        for {table, column, ids} <- [
              {"agent_audit_events", "vm_id", vms},
              {"agent_threads_versions", "version_source_id", threads},
              {"agent_threads", "id", threads},
              {"agent_roots_versions", "version_source_id", roots},
              {"agent_roots", "id", roots}
            ] do
          query("DELETE FROM #{table} WHERE #{column}=ANY($1::uuid[])", [ids])
        end

        :ok
      end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-job-trigger-order
  # A fixture's raw job deletion MUST capture its exact returned job IDs and then
  # delete only their retained events/snapshots after the real Oban DELETE trigger.
  # The predicate is trusted test SQL; all fixture values MUST use bound parameters.
  @spec jobs!(String.t(), [term()]) :: :ok
  def jobs!(predicate, params \\ []) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        %{rows: rows} = query("DELETE FROM oban_jobs WHERE #{predicate} RETURNING id", params)
        ids = Enum.map(rows, fn [id] -> id end)
        query("DELETE FROM admin_job_events WHERE job_id=ANY($1::bigint[])", [ids])
        query("DELETE FROM admin_job_snapshots WHERE id=ANY($1::bigint[])", [ids])
        :ok
      end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-subscription-reviews
  # Account and membership changes enqueue thread-subscription reviews keyed by
  # owner. Teardown MAY delete only reviews naming the fixture's exact user IDs,
  # through jobs!/2 so their retained events and snapshots go too.
  @spec subscription_reviews!([String.t()]) :: :ok
  def subscription_reviews!(user_ids) do
    jobs!(
      "worker='Marshall.Threads.SubscriptionRevokeJob' AND args->>'owner_id'=ANY($1::text[])",
      [user_ids]
    )
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-lifecycle-scope
  # Lifecycle cleanup MUST match only the fixture's exact VM or dedicated host
  # IDs. It MUST NOT delete by actor, age, job kind, or a database-wide predicate.
  @spec lifecycle!([String.t()], [String.t()]) :: :ok
  def lifecycle!(host_ids, vm_ids) do
    query(
      "DELETE FROM compute_lifecycle_events WHERE host_id=ANY($1::uuid[]) OR vm_id=ANY($2::uuid[])",
      [Enum.map(host_ids, &Ecto.UUID.dump!/1), Enum.map(vm_ids, &Ecto.UUID.dump!/1)]
    )

    :ok
  end

  # @cc [owner:ghuntley,label:verification] committed-fixture-relocation-history
  # Relocation teardown MUST capture workflow IDs while fixture relocations still
  # exist. Events without VM/host fields may be deleted only by those exact
  # workflow IDs or their CleanupRequest resource identity.
  @spec relocation_history!(String.t()) :: :ok
  def relocation_history!(vm_id) do
    %{rows: rows} =
      query("SELECT id FROM compute_relocations WHERE vm_id=$1", [Ecto.UUID.dump!(vm_id)])

    ids = Enum.map(rows, fn [id] -> id end)

    query(
      "DELETE FROM compute_lifecycle_events WHERE workflow_id=ANY($1::uuid[]) OR (resource_type='CleanupRequest' AND resource_id=ANY($1::uuid[]))",
      [ids]
    )

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  defp query(sql, params), do: Repo.query!(sql, params, log: false)

  # @cc [owner:ghuntley,label:verification] committed-fixture-image-ownership
  # Callers MUST capture existing fixture image IDs before public creation and
  # pass only newly created IDs to images!/1. Existing unreferenced images and
  # versions MUST survive; a remaining VM reference MUST prevent deletion.
  @spec fixture_image_ids() :: [String.t()]
  def fixture_image_ids do
    %{rows: rows} =
      query("SELECT id FROM compute_images WHERE id=$1", [Marshall.ComputeFixtures.image_id()])

    Enum.map(rows, fn [id] -> id end)
  end

  @spec images!([String.t()]) :: :ok
  def images!(ids) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        for id <- Enum.uniq(ids) do
          query(
            "DELETE FROM compute_images_versions WHERE version_source_id=$1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE image_id=$1)",
            [id]
          )

          query(
            "DELETE FROM compute_images WHERE id=$1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE image_id=$1)",
            [id]
          )
        end

        :ok
      end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] committed-compute-fixture-ownership
  # Callers MUST own the captured host and actor and finish or stop every remote
  # caller before teardown. Cleanup MUST remove only VMs placed on that host and
  # their captured history. Image ownership is separate: callers MUST dispose
  # only their captured newly created image IDs after removing their final VMs.
  @spec cleanup_compute(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def cleanup_compute(host_id, owner_id) do
    # Each test deletes only its committed fixture records, in FK order.
    # SQL is appropriate for test teardown, not a production lifecycle action.
    {:ok, _} =
      Repo.transaction(fn ->
        %{rows: placements} =
          query("SELECT DISTINCT vm_id::text FROM compute_workload_placements WHERE host_id=$1", [
            Ecto.UUID.dump!(host_id)
          ])

        vm_ids = Enum.map(placements, fn [id] -> id end)
        agent_history!(vm_ids)
        lifecycle!([host_id], vm_ids)

        jobs!(
          "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_operations WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_physical_outcomes WHERE host_id = $1",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_operations WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_resize_requests WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_reservations WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_network_addresses WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        for {table, where} <- [
              {"ingress_endpoints_versions",
               "version_source_id IN (SELECT id FROM ingress_endpoints WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"ingress_endpoints",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"terminal_tickets",
               "session_id IN (SELECT id FROM terminal_sessions WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"terminal_events",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"terminal_sessions_versions",
               "version_source_id IN (SELECT id FROM terminal_sessions WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"terminal_sessions",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"access_changes",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"},
              {"access_grants_versions",
               "version_source_id IN (SELECT id FROM access_grants WHERE vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1))"},
              {"access_grants",
               "vm_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)"}
            ] do
          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table} WHERE #{where}", [
            Ecto.UUID.dump!(host_id)
          ])
        end

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_virtual_machines_versions WHERE version_source_id IN (SELECT vm_id FROM compute_workload_placements WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "WITH removed AS (DELETE FROM compute_workload_placements WHERE host_id = $1 RETURNING vm_id) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_storage_pools WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_credentials_versions WHERE version_source_id IN (SELECT id FROM compute_host_credentials WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_credentials WHERE host_id = $1",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_host_sessions WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        jobs!(
          "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_host_drains WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM compute_host_drains_versions WHERE version_source_id IN (SELECT id FROM compute_host_drains WHERE host_id = $1)",
          [Ecto.UUID.dump!(host_id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_host_drains WHERE host_id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM compute_hosts WHERE id = $1", [
          Ecto.UUID.dump!(host_id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE subject = $1", [
          "user?id=" <> owner_id
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM users WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE owner_id = $1)",
          [
            Ecto.UUID.dump!(owner_id)
          ]
        )
      end)
  end
end
