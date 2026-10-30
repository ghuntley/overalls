defmodule Marshall.Administration.JobHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Administration
  alias Marshall.Compute.Ledger
  alias Marshall.JobHistoryFixture, as: Fixture
  alias Marshall.PasskeyFixture, as: Passkeys

  @moduletag timeout: 120_000
  @typep projection :: %{
           state: atom(),
           attempt: non_neg_integer(),
           error_count: non_neg_integer()
         }
  @typep job_model :: %{
           id: pos_integer(),
           current: projection(),
           events: [projection()],
           raw: boolean()
         }
  @typep action ::
           :lock
           | :elevate
           | :demote
           | :promote
           | :revoke
           | {:retry, 0 | 1, 0 | 1 | 2}
           | {:fail, 0 | 1}
  @typep authority :: %{
           role: boolean(),
           elevated: boolean(),
           live: boolean(),
           receipts: %{optional(non_neg_integer()) => non_neg_integer()}
         }

  # @cc [owner:ghuntley,label:verification] job-history-independent-capture-model
  # Generated raw transitions MUST be compared with an independent event model
  # through ordinary-user projections. Pruning MUST preserve the exact history
  # without preserving retry authority; raw fixture transitions prove no worker execution.
  @tag :hegel_case_sandbox
  property "generated transitions retain exact redacted history through pruning and expiry",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    transitions =
      draw(
        "transitions",
        list_of(
          tuple(
            {member_of([
               :available,
               :suspended,
               :scheduled,
               :executing,
               :retryable,
               :completed,
               :discarded,
               :cancelled
             ]), integer(0..2), integer(0..3)}
          ),
          min_length: 1,
          max_length: 12
        )
      )

    reader = Passkeys.user()
    # Queue counts are installation-wide. Raw jobs committed by other partitions'
    # fixtures stay visible through the per-case sandbox, so the pruned job is
    # proven not to inflate counts against this case's own baseline, not against zero.
    assert {:ok, %{counts: baseline}} = Administration.jobs(%{}, actor: reader)
    job = Fixture.insert("history_#{System.unique_integer([:positive])}")
    initial = %{state: :available, attempt: 0, error_count: 0}
    model = %{id: job.id, current: initial, events: [initial], raw: true}

    model =
      Enum.reduce(transitions, model, fn {state, attempt, errors}, model ->
        current = %{state: state, attempt: attempt, error_count: errors}
        Fixture.transition(job.id, Atom.to_string(state), attempt, errors)
        model = %{model | current: current, events: append_event(model, current)}
        assert_projection(model, reader)
        model
      end)

    Fixture.act(:prune, job.id, reader, reader, Ash.UUID.generate())
    assert_projection(%{model | raw: false}, reader)
    assert {:ok, page} = Administration.jobs(%{queue: job.queue}, actor: reader)
    assert Enum.map(page.items, & &1.id) == [job.id]
    assert page.counts == baseline

    Fixture.query(
      "UPDATE admin_job_snapshots SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [job.id]
    )

    Fixture.query(
      "UPDATE admin_job_events SET expires_at=clock_timestamp()-interval '1 second' WHERE job_id=$1",
      [job.id]
    )

    assert {:error, _} = Administration.job(%{id: job.id}, actor: reader)
    assert {:ok, %{items: []}} = Administration.jobs(%{queue: job.queue}, actor: reader)

    assert {:ok, _} =
             Administration.JobSnapshot
             |> Ash.ActionInput.for_action(:expire, %{},
               actor: Marshall.Authorization.SystemActor.compute()
             )
             |> Ash.run_action()

    assert Ledger.read!(Administration.JobSnapshot, id: job.id) == []
    assert Ledger.read!(Administration.JobEvent, job_id: job.id) == []
  end

  # @cc [owner:ghuntley,label:verification] job-retry-generated-current-authority
  # The model MUST derive retry acceptance from its own role, elevation, login,
  # raw-state and receipt history. Refused and replayed requests MUST preserve
  # every job/history/audit row; changed request meaning MUST never mutate another job.
  @tag :hegel_case_sandbox
  property "retry histories bind receipts while role elevation and login authority change",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    actions =
      draw(
        "actions",
        list_of(
          one_of([
            member_of([:lock, :elevate, :demote, :promote, :revoke]),
            tuple({constant(:retry), integer(0..1), integer(0..2)}),
            tuple({constant(:fail), integer(0..1)})
          ]),
          max_length: 5
        )
      )

    admin = Passkeys.elevate(Passkeys.user(true))
    operator = Passkeys.elevate(Passkeys.user(true))
    reader = Passkeys.user()

    jobs =
      for _ <- 1..2 do
        job = Fixture.insert("retry_history_#{System.unique_integer([:positive])}")
        Fixture.transition(job.id, "discarded", 2, 1)
        first = %{state: :available, attempt: 0, error_count: 0}
        last = %{state: :discarded, attempt: 2, error_count: 1}
        %{id: job.id, current: last, events: [first, last], raw: true}
      end

    requests = for _ <- 1..3, do: Ash.UUID.generate()
    initial = %{role: true, elevated: true, live: true, receipts: %{}}

    fixed = [
      {:retry, 0, 0},
      {:retry, 1, 0},
      :lock,
      {:retry, 0, 0},
      :elevate,
      {:retry, 0, 0},
      :demote,
      {:retry, 1, 1},
      :promote
    ]

    {models, authority} =
      Enum.reduce(fixed ++ actions, {jobs, initial}, fn action, {models, authority} ->
        {models, authority} = step(action, admin, operator, requests, models, authority)
        for model <- models, do: assert_projection(model, reader)
        assert_receipts(admin, requests, models, authority)
        {models, authority}
      end)

    Enum.reduce(0..1, models, fn index, models ->
      model = Enum.at(models, index)
      Fixture.act(:prune, model.id, admin, operator, Ash.UUID.generate())
      models = List.replace_at(models, index, %{model | raw: false})

      for request <- 0..2 do
        {_, _} = step({:retry, index, request}, admin, operator, requests, models, authority)
      end

      for retained <- models, do: assert_projection(retained, reader)
      models
    end)
  end

  @spec step(action(), User.t(), User.t(), [String.t()], [job_model()], authority()) ::
          {[job_model()], authority()}
  defp step({:retry, index, request}, admin, _operator, requests, models, authority) do
    model = Enum.at(models, index)
    before = Enum.map(models, &Fixture.snapshot(&1.id, admin.id))
    receipt = Map.get(authority.receipts, request)
    permitted = authority.role and authority.elevated and authority.live

    accepted =
      permitted and
        (receipt == index or
           (receipt == nil and model.raw and model.current.state in [:retryable, :discarded]))

    result =
      Administration.retry_job(%{id: model.id, request_id: Enum.at(requests, request)},
        actor: admin
      )

    assert match?({:ok, %{accepted: true}}, result) == accepted

    if accepted and receipt == nil do
      current = %{model.current | state: :available}
      model = %{model | current: current, events: append_event(model, current)}
      assert Repo.get!(Oban.Job, model.id).max_attempts == 3

      {List.replace_at(models, index, model),
       %{authority | receipts: Map.put(authority.receipts, request, index)}}
    else
      assert Enum.map(models, &Fixture.snapshot(&1.id, admin.id)) == before
      {models, authority}
    end
  end

  defp step({:fail, index}, _admin, _operator, _requests, models, authority) do
    model = Enum.at(models, index)
    Fixture.transition(model.id, "discarded", 2, 1)
    current = %{state: :discarded, attempt: 2, error_count: 1}

    {List.replace_at(models, index, %{
       model
       | current: current,
         events: append_event(model, current)
     }), authority}
  end

  defp step(action, admin, operator, _requests, models, authority) do
    authority =
      case action do
        :lock ->
          result = Passkeys.action(admin, :lock)
          assert match?({:ok, %{locked: true}}, result) == authority.live
          %{authority | elevated: false}

        :elevate ->
          if authority.live do
            assert {:ok, %{verified: true}} =
                     Passkeys.verify(admin, admin.__metadata__.test_authenticator)

            %{authority | elevated: true}
          else
            assert {:error, _} = Passkeys.action(admin, :begin_verify)
            authority
          end

        :revoke ->
          :ok =
            AshAuthentication.TokenResource.Actions.revoke(
              Marshall.Accounts.Token,
              admin.__metadata__.token
            )

          %{authority | live: false, elevated: false}

        role when role in [:promote, :demote] ->
          enabled = role == :promote
          assert {:ok, %{administrator: ^enabled}} = Fixture.role(operator, admin, enabled)
          %{authority | role: enabled}
      end

    assert Security.recent?(admin) == (authority.elevated and authority.live)
    {models, authority}
  end

  @spec append_event(job_model(), projection()) :: [projection()]
  defp append_event(model, current),
    do: if(model.current == current, do: model.events, else: model.events ++ [current])

  @spec assert_projection(job_model(), User.t()) :: :ok
  defp assert_projection(model, reader) do
    assert {:ok, detail} = Administration.job(%{id: model.id}, actor: reader)
    assert Map.take(detail.job, [:state, :attempt, :error_count]) == model.current
    assert detail.job.raw_present == model.raw
    assert detail.job.retryable == (model.raw and model.current.state in [:retryable, :discarded])

    assert Enum.map(Enum.reverse(detail.events), &Map.take(&1, [:state, :attempt, :error_count])) ==
             model.events

    refute inspect(detail) =~ "job-history-private-fixture"
    refute Map.has_key?(detail.job, :args)
    refute Map.has_key?(detail.job, :errors)
    :ok
  end

  @spec assert_receipts(User.t(), [String.t()], [job_model()], authority()) :: :ok
  defp assert_receipts(admin, requests, models, authority) do
    actual =
      Ledger.read!(Administration.AuditEvent, actor_id: admin.id)
      |> Enum.map(&{&1.request_id, &1.resource_id, &1.action})
      |> Enum.sort()

    expected =
      authority.receipts
      |> Enum.map(fn {request, index} ->
        {Enum.at(requests, request), to_string(Enum.at(models, index).id), :retry_job}
      end)
      |> Enum.sort()

    assert actual == expected
    :ok
  end
end
