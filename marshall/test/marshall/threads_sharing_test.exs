defmodule Marshall.ThreadsSharingTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Accounts.User
  alias Marshall.Access
  alias Marshall.Access.Authorization, as: MachineAuthorization
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads
  alias Marshall.Threads.{AccessChange, Authorization, Grant, ProvisionWorker, Thread}

  @type role :: :viewer | :operator | :manager | :revoked
  @type context :: %{owner: User.t(), member: User.t(), thread: Thread.t()}
  @type access_arguments :: %{
          thread_id: String.t(),
          email: String.t(),
          role: role(),
          idempotency_key: String.t()
        }

  setup do
    owner = user()
    member = user()
    thread = create_thread(owner)
    %{owner: owner, member: member, thread: thread}
  end

  # @cc [owner:ghuntley,label:verification;security] thread-grants-current-role-matrix
  # Role replacement and revocation MUST be checked against fresh authorization
  # and public reads, including after a previously sufficient grant is removed.
  test "persisted roles control thread permissions and visibility", context do
    Hegel.check(
      fn ->
        roles =
          draw(
            "roles",
            list_of(member_of([:viewer, :operator, :manager, :revoked]),
              min_length: 1,
              max_length: 6
            )
          )

        for role <- roles do
          assert {:ok, %AccessChange{}} = share(context, role)

          expected = %{
            read: role != :revoked,
            write: role in [:operator, :manager],
            manage: role == :manager
          }

          assert Authorization.permissions(context.thread, context.member) == expected

          for {action, allowed} <- expected do
            assert Authorization.allowed?(context.thread, context.member, Atom.to_string(action)) ==
                     allowed

            assert Authorization.allowed?(context.thread, context.owner, Atom.to_string(action))
          end

          if expected.read do
            assert {:ok, %{id: id}} =
                     Threads.get_thread(%{thread_id: context.thread.id}, actor: context.member)

            assert id == context.thread.id
            assert {:ok, [%{id: ^id}]} = Threads.list_threads(%{}, actor: context.member)
          else
            assert_error(
              Threads.get_thread(%{thread_id: context.thread.id}, actor: context.member),
              :forbidden
            )

            assert {:ok, []} = Threads.list_threads(%{}, actor: context.member)
          end

          assert length(
                   Ledger.read!(Grant, thread_id: context.thread.id, user_id: context.member.id)
                 ) ==
                   if(role == :revoked, do: 0, else: 1)
        end
      end,
      test_cases: 100
    )
  end

  test "delayed replay retains its receipt without restoring revoked access", context do
    key = Ash.UUID.generate()
    assert {:ok, original} = share(context, :manager, key)
    assert {:ok, _} = share(context, :revoked)
    assert {:ok, replay} = share(context, :manager, key)
    assert replay.id == original.id
    refute Authorization.allowed?(context.thread, context.member, "read")
    assert Ledger.read!(Grant, thread_id: context.thread.id) == []

    assert_error(share(context, :viewer, key), :idempotency_conflict)
    other = user()

    assert_error(
      Threads.set_access(%{params(context, :manager, key) | email: to_string(other.email)},
        actor: context.owner
      ),
      :idempotency_conflict
    )

    assert length(Ledger.read!(AccessChange, thread_id: context.thread.id)) == 2

    assert [%{archived_at: %DateTime{}, revoked_by_id: revoked_by_id}] =
             Ledger.history!(Grant, thread_id: context.thread.id)

    assert revoked_by_id == context.owner.id
    assert Enum.any?(Ledger.read!(Grant.Version), &(&1.version_action_name == :revoke))
  end

  test "only managers can share, retry, archive and reopen", context do
    for role <- [:viewer, :operator] do
      assert {:ok, _} = share(context, role)

      assert_error(
        Threads.set_access(params(context, :manager), actor: context.member),
        :forbidden
      )

      assert_error(
        Threads.list_grants(%{thread_id: context.thread.id}, actor: context.member),
        :forbidden
      )

      assert_error(
        Threads.retry_provisioning(%{thread_id: context.thread.id}, actor: context.member),
        :forbidden
      )

      assert_error(
        Threads.archive_thread(%{thread_id: context.thread.id}, actor: context.member),
        :forbidden
      )
    end

    assert {:ok, _} = share(context, :manager)

    assert {:ok, %{status: :pending}} =
             Threads.retry_provisioning(%{thread_id: context.thread.id}, actor: context.member)

    assert {:ok, %{status: :archived}} =
             Threads.archive_thread(%{thread_id: context.thread.id}, actor: context.member)

    assert {:ok, _} = share(context, :viewer)

    assert_error(
      Threads.reopen_thread(%{thread_id: context.thread.id}, actor: context.member),
      :forbidden
    )

    assert {:ok, _} = share(context, :manager)

    assert {:ok, %{status: :pending}} =
             Threads.reopen_thread(%{thread_id: context.thread.id}, actor: context.member)

    assert {:ok, %{owner: %{role: :owner}, items: [%{role: :manager}]}} =
             Threads.list_grants(%{thread_id: context.thread.id}, actor: context.member)

    assert {:ok, _} = Threads.set_access(params(context, :revoked), actor: context.member)
    refute Authorization.allowed?(context.thread, context.member, "read")
  end

  test "pending and archived grants persist through reopen on the same thread", context do
    assert {:ok, _} = share(context, :viewer)
    assert [%{id: grant_id}] = Ledger.read!(Grant, thread_id: context.thread.id)
    assert context.thread.machine_id == nil

    assert {:ok, archived} =
             Threads.archive_thread(%{thread_id: context.thread.id}, actor: context.owner)

    assert {:ok, %{status: :archived}} =
             Threads.get_thread(%{thread_id: archived.id}, actor: context.member)

    assert [%{id: ^grant_id}] = Ledger.read!(Grant, thread_id: archived.id)

    assert {:ok, reopened} =
             Threads.reopen_thread(%{thread_id: archived.id}, actor: context.owner)

    assert reopened.machine_key != archived.machine_key
    assert reopened.machine_id == nil
    assert [%{id: ^grant_id}] = Ledger.read!(Grant, thread_id: reopened.id)

    assert {:ok, %{id: thread_id, status: :pending}} =
             Threads.get_thread(%{thread_id: reopened.id}, actor: context.member)

    assert thread_id == context.thread.id
    assert {:ok, _} = share(context, :revoked)

    assert_error(
      Threads.get_thread(%{thread_id: reopened.id}, actor: context.member),
      :forbidden
    )
  end

  test "creator is protected and lookup requires an exact existing active account", context do
    for role <- [:viewer, :operator, :manager, :revoked] do
      assert_error(
        Threads.set_access(%{params(context, role) | email: to_string(context.owner.email)},
          actor: context.owner
        ),
        :owner_protected
      )
    end

    deleted = user()
    Ledger.update!(deleted, :security_state, %{deleted_at: DateTime.utc_now()})

    for email <- ["nobody@example.test", "example.test", to_string(deleted.email)] do
      assert {:error, _} =
               Threads.set_access(%{params(context, :viewer) | email: email},
                 actor: context.owner
               )
    end

    assert Ledger.read!(AccessChange, thread_id: context.thread.id) == []
    assert Ledger.read!(Grant, thread_id: context.thread.id) == []

    assert {:ok, _} =
             Threads.set_access(
               %{
                 params(context, :viewer)
                 | email: String.upcase(to_string(context.member.email))
               },
               actor: context.owner
             )

    assert [%{user_id: user_id}] = Ledger.read!(Grant, thread_id: context.thread.id)
    assert user_id == context.member.id
  end

  test "thread sharing rejects web roles, unknown actions and untyped actors", context do
    assert {:error, _} =
             Threads.set_access(%{params(context, :viewer) | role: :web}, actor: context.owner)

    assert Ledger.read!(Grant, thread_id: context.thread.id) == []
    refute Authorization.allowed?(context.thread, context.owner, "web")
    refute Authorization.allowed?(context.thread, context.owner, "unknown")
    refute Authorization.allowed?(context.thread, %{id: context.owner.id}, "manage")
    assert {:error, _} = Threads.set_access(params(context, :viewer))

    assert {:error, _} =
             Threads.set_access(params(context, :viewer), actor: %{id: context.owner.id})
  end

  test "raw resources cannot bypass sharing coordinators", context do
    for resource <- [Grant, AccessChange] do
      assert {:error, _} = Ash.read(resource, actor: context.owner)
      assert {:error, _} = Ash.read(resource)
    end

    assert {:error, _} =
             Ash.create(
               Grant,
               %{
                 thread_id: context.thread.id,
                 user_id: context.member.id,
                 role: :manager,
                 granted_by_id: context.owner.id
               },
               action: :grant,
               actor: context.owner
             )

    assert Ledger.read!(Grant, thread_id: context.thread.id) == []
  end

  test "grant pages are bounded, scoped and expose only recipient identities", context do
    members = [context.member, user(), user()]

    for member <- members do
      assert {:ok, _} = share(%{context | member: member}, :viewer)
    end

    stranger = user()
    private = create_thread(stranger)
    assert {:ok, _} = share(%{owner: stranger, member: user(), thread: private}, :manager)

    assert {:ok, first} =
             Threads.list_grants(%{thread_id: context.thread.id, limit: 1}, actor: context.owner)

    assert {:ok, second} =
             Threads.list_grants(
               %{thread_id: context.thread.id, limit: 1, after: first.next_cursor},
               actor: context.owner
             )

    assert {:ok, third} =
             Threads.list_grants(
               %{thread_id: context.thread.id, limit: 1, after: second.next_cursor},
               actor: context.owner
             )

    assert length(first.items) == 1
    assert length(second.items) == 1
    assert length(third.items) == 1
    assert is_binary(first.next_cursor)
    assert is_binary(second.next_cursor)
    assert third.next_cursor == nil
    assert first.owner.user_id == context.owner.id
    assert first.owner.email == to_string(context.owner.email)
    assert first.owner.role == :owner

    grants = first.items ++ second.items ++ third.items
    assert MapSet.new(grants, & &1.user_id) == MapSet.new(members, & &1.id)
    # Recipient identity plus the saved display zone (ADR-0195); nothing else.
    assert Enum.all?(
             grants,
             &(Enum.sort(Map.keys(&1)) == [:email, :id, :role, :time_zone, :user_id])
           )

    assert Enum.all?(grants, &is_nil(&1.time_zone))

    assert {:error, _} =
             Threads.list_grants(%{thread_id: context.thread.id, limit: 101},
               actor: context.owner
             )

    assert_error(Threads.list_grants(%{thread_id: private.id}, actor: context.owner), :forbidden)
  end

  test "current team roles are additive with grants and removed membership stops authorizing",
       context do
    admin = user()

    assert {:ok, team} =
             Marshall.Teams.create_team(
               %{
                 name: "thread-sharing-#{Ash.UUID.generate()}",
                 idempotency_key: Ash.UUID.generate()
               },
               actor: context.owner
             )

    set_team_member(team.id, context.member, :member, context.owner)
    set_team_member(team.id, admin, :admin, context.owner)
    thread = create_thread(context.owner, team.id)
    context = %{context | thread: thread}

    assert Authorization.permissions(thread, context.member) ==
             %{read: true, write: true, manage: false}

    assert Authorization.permissions(thread, admin) == %{read: true, write: true, manage: true}
    assert {:ok, _} = share(context, :viewer)
    assert Authorization.allowed?(thread, context.member, "write")
    assert {:ok, _} = share(context, :revoked)
    assert Authorization.allowed?(thread, context.member, "write")

    assert {:ok, _} = share(context, :viewer)
    set_team_member(team.id, context.member, :removed, context.owner)

    assert Authorization.permissions(thread, context.member) ==
             %{read: true, write: false, manage: false}

    assert {:ok, _} = share(context, :revoked)
    refute Authorization.allowed?(thread, context.member, "read")
    assert {:ok, []} = Threads.list_threads(%{}, actor: context.member)
  end

  test "a deleted recipient immediately loses previously granted authority", context do
    assert {:ok, _} = share(context, :manager)
    assert Authorization.allowed?(context.thread, context.member, "manage")
    Ledger.update!(context.member, :security_state, %{deleted_at: DateTime.utc_now()})
    refute Authorization.allowed?(context.thread, context.member, "read")

    assert_error(
      Threads.get_thread(%{thread_id: context.thread.id}, actor: context.member),
      :forbidden
    )

    result = Threads.list_threads(%{}, actor: context.member)
    assert match?({:ok, []}, result) or match?({:error, _}, result)
  end

  test "bound machine authority follows current thread grants without copying them", context do
    {thread, vm} = ready_thread(context.thread)
    context = %{context | thread: thread}

    for role <- [:viewer, :operator, :manager, :revoked] do
      assert {:ok, _} = share(context, role)

      for action <- ["read", "write", "manage"] do
        expected =
          role == :manager or (role == :operator and action in ["read", "write"]) or
            (role == :viewer and action == "read")

        assert MachineAuthorization.allowed?(vm, context.member, action) == expected
      end

      assert Ledger.read!(Marshall.Access.Grant, vm_id: vm.id) == []
    end

    assert {:ok, _} =
             Access.set_access(
               %{
                 vm_id: vm.id,
                 email: to_string(context.member.email),
                 role: :manager,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: context.owner
             )

    assert MachineAuthorization.allowed?(vm, context.member, "manage")
    refute Authorization.allowed?(thread, context.member, "read")
    assert {:ok, _} = share(context, :viewer)
    assert MachineAuthorization.allowed?(vm, context.member, "manage")
    assert {:ok, _} = share(context, :revoked)
    assert MachineAuthorization.allowed?(vm, context.member, "manage")

    assert_error(Threads.get_thread(%{thread_id: thread.id}, actor: context.member), :forbidden)
  end

  test "only operators and managers can submit prompts and revocation takes effect immediately",
       context do
    {thread, _vm} = ready_thread(context.thread)
    context = %{context | thread: thread}

    for role <- [:viewer, :operator, :manager, :revoked] do
      assert {:ok, _} = share(context, role)

      result =
        Threads.submit_prompt(
          %{thread_id: thread.id, prompt: "Inspect the work", request_key: Ash.UUID.generate()},
          actor: context.member
        )

      if role in [:operator, :manager] do
        assert {:ok, %{turn_id: turn_id}} = result
        assert [%{actor_id: actor_id}] = Ledger.read!(Marshall.Agents.Turn, id: turn_id)
        assert actor_id == context.member.id
      else
        assert_error(result, :forbidden)
      end
    end

    assert length(Ledger.read!(Marshall.Agents.Turn, actor_id: context.member.id)) == 2
  end

  test "viewers retain archived transcripts until their thread access is revoked", context do
    {thread, vm} = ready_thread(context.thread)
    context = %{context | thread: thread}
    assert {:ok, _} = share(context, :viewer)
    assert {:ok, active_events} = Threads.events(thread.id, context.member)
    assert is_list(active_events)

    Ledger.archive!(vm, :archive)

    assert {:ok, %{status: :archived}} =
             Threads.archive_thread(%{thread_id: thread.id}, actor: context.owner)

    assert {:ok, ^active_events} = Threads.events(thread.id, context.member)
    assert {:ok, _} = share(context, :revoked)
    assert Threads.events(thread.id, context.member) == {:error, :forbidden}
    assert {:ok, ^active_events} = Threads.events(thread.id, context.owner)
  end

  test "reopen moves inherited access to the new machine without replacing the thread grant",
       context do
    {thread, original_vm} = ready_thread(context.thread)
    assert {:ok, _} = share(%{context | thread: thread}, :operator)
    assert [%{id: grant_id}] = Ledger.read!(Grant, thread_id: thread.id)
    assert MachineAuthorization.allowed?(original_vm, context.member, "write")

    Ledger.archive!(original_vm, :archive)

    assert {:ok, %{status: :archived}} =
             Threads.archive_thread(%{thread_id: thread.id}, actor: context.owner)

    assert {:ok, reopened} = Threads.reopen_thread(%{thread_id: thread.id}, actor: context.owner)
    refute MachineAuthorization.allowed?(original_vm, context.member, "read")
    assert Authorization.allowed?(reopened, context.member, "write")

    {ready, replacement_vm} = ready_thread(reopened)
    assert ready.id == thread.id
    refute replacement_vm.id == original_vm.id
    assert [%{id: ^grant_id}] = Ledger.read!(Grant, thread_id: thread.id)
    assert MachineAuthorization.allowed?(replacement_vm, context.member, "write")
    refute MachineAuthorization.allowed?(original_vm, context.member, "read")
    assert Ledger.read!(Marshall.Access.Grant, user_id: context.member.id) == []
  end

  test "stale and foreign machine bindings never derive thread authority", context do
    {thread, vm} = ready_thread(context.thread)
    assert {:ok, _} = share(%{context | thread: thread}, :manager)
    assert MachineAuthorization.allowed?(vm, context.member, "manage")

    # Decisions read the current row, so a foreign owner or a non-sharing
    # profile is written to the machine row itself and then restored.
    with_machine_row(vm, "owner_id", Ecto.UUID.dump!(user().id), vm.owner_id, fn ->
      refute MachineAuthorization.allowed?(vm, context.member, "read")
    end)

    with_machine_row(vm, "profile", "customer", to_string(vm.profile), fn ->
      refute MachineAuthorization.allowed?(vm, context.member, "read")
    end)

    assert MachineAuthorization.allowed?(vm, context.member, "read")
    refute MachineAuthorization.allowed?(%{vm | id: Ash.UUID.generate()}, context.member, "read")

    Marshall.ThreadStateFixture.archived!(thread)
    refute MachineAuthorization.allowed?(vm, context.member, "read")

    assert {:ok, %{status: :archived}} =
             Threads.get_thread(%{thread_id: thread.id}, actor: context.member)
  end

  @spec with_machine_row(map(), String.t(), term(), term(), (-> term())) :: term()
  defp with_machine_row(vm, column, value, original, check) do
    update = fn value ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE compute_virtual_machines SET #{column} = $1 WHERE id = $2",
        [value, Ecto.UUID.dump!(vm.id)]
      )
    end

    update.(value)

    try do
      check.()
    after
      update.(if column == "owner_id", do: Ecto.UUID.dump!(original), else: original)
    end
  end

  @spec create_thread(User.t(), String.t() | nil) :: Thread.t()
  defp create_thread(actor, team_id \\ nil) do
    {:ok, thread} =
      Threads.create_thread(
        %{
          objective: "Inspect the deployment",
          mode: :medium,
          machine_spec: request(%{team_id: team_id}),
          idempotency_key: Ash.UUID.generate()
        },
        actor: actor
      )

    thread
  end

  @spec params(context(), role(), String.t()) :: access_arguments()
  defp params(context, role, key \\ Ash.UUID.generate()) do
    %{
      thread_id: context.thread.id,
      email: to_string(context.member.email),
      role: role,
      idempotency_key: key
    }
  end

  @spec share(context(), role(), String.t()) :: {:ok, AccessChange.t()} | {:error, term()}
  defp share(context, role, key \\ Ash.UUID.generate()),
    do: Threads.set_access(params(context, role, key), actor: context.owner)

  @spec assert_error({:error, term()}, atom()) :: true
  defp assert_error({:error, error}, reason) do
    assert Threads.error_reason(error) == reason
  end

  @spec set_team_member(String.t(), User.t(), :member | :admin | :removed, User.t()) :: map()
  defp set_team_member(team_id, member, role, actor) do
    {:ok, result} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team_id,
          email: to_string(member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: actor
      )

    result
  end

  # @cc [owner:ghuntley,label:verification] thread-sharing-synthetic-machine
  # This helper MUST use disposable admission fixtures and a synthetic running
  # observation. Its assertions MUST NOT be evidence of native VM isolation.
  @spec ready_thread(Thread.t()) :: {Thread.t(), VirtualMachine.t()}
  defp ready_thread(thread) do
    host_fixture()
    args = %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
    assert {:snooze, _} = ProvisionWorker.perform(%Oban.Job{args: args})
    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    assert :ok = ProvisionWorker.perform(%Oban.Job{args: args})
    [ready] = Ledger.read!(Thread, id: thread.id)
    assert ready.status == :ready
    {ready, vm}
  end
end
