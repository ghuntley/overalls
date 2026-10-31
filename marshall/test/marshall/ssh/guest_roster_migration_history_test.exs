defmodule Marshall.SSH.GuestRosterMigrationHistoryTest do
  @moduledoc """
  Generated owner/grant/team/retirement roster histories against an independent
  oracle. The oracle derives expected writers purely from PostgreSQL (VM owner +
  unarchived grants + unarchived team members, excluding tombstoned users) plus
  the production Cedar write decision, then requires every expected writer to
  have a durable account_guest_accounts row whose name/UID the roster reports.
  Allocator result structs never seed the oracle; Cedar evaluation itself is
  covered by the authorization and team suites.
  """
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.{GuestAccount, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Credentials
  alias Marshall.SSH.GuestAccess
  require Ash.Query

  setup do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    %{admin: Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))}
  end

  # @cc [owner:ghuntley,label:verification;security] roster-candidates-postgres-oracle
  # The roster oracle MUST derive writer candidates from durable PostgreSQL
  # ownership/grants/membership and tombstone state, never from allocator
  # results, and retired users MUST leave the roster before cleanup commits.
  @tag :hegel
  # Each generated history runs serially through PostgreSQL: 48.6 s alone,
  # past ExUnit's 60 s default twice under host load.
  @tag timeout: 180_000
  test "generated grant, team and retirement histories match the PostgreSQL roster oracle", %{
    admin: admin
  } do
    Hegel.check(
      fn ->
        count = draw("count", integer(3..4))

        ops =
          draw(
            "ops",
            list_of(
              tuple(
                {(count - 1) |> then(&integer(0..&1)),
                 member_of([:grant, :revoke, :join, :leave, :retire])}
              ),
              min_length: 3,
              max_length: 10
            )
          )

        fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :oss})

        # Each generated history gets its own VM on this fixture's host; disable
        # earlier runs' hosts so placement is deterministic inside one sandbox.
        for host <- Ledger.read!(Marshall.Compute.Host), host.id != fixture.host.id do
          Ledger.update!(host, :configure, %{enabled: false})
        end

        {:ok, team} =
          Marshall.Teams.create_team(
            %{
              name: "roster-history-" <> Ash.UUID.generate(),
              idempotency_key: Ash.UUID.generate()
            },
            actor: fixture.owner
          )

        {:ok, vm} =
          Marshall.Compute.provision(
            Marshall.ComputeFixtures.request(%{team_id: team.id, profile: :oss, vcpu: 1}),
            actor: fixture.owner
          )

        {:ok, credential} = Credentials.rotate(vm.host_id, 3600)
        ziggy_token = credential.id <> "." <> credential.secret
        [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)
        # The boot proof keeps the operation pending; roster composition, not the
        # start receipt, is under test here (see GuestAccessTest for the fences).
        binding = %{
          "host_id" => vm.host_id,
          "vm_id" => vm.id,
          "placement_id" => vm.current_placement_id,
          "execution_epoch" => vm.execution_epoch,
          "generation" => vm.generation,
          "operation_id" => operation.id
        }

        users = for _ <- 1..count, do: Marshall.ComputeFixtures.user()
        state = %{grants: MapSet.new(), members: MapSet.new(), retired: MapSet.new()}
        versions = [roster!(binding, ziggy_token, vm, fixture, users, state)]

        {_state, versions} =
          Enum.reduce(ops, {state, versions}, fn {index, op}, {state, versions} ->
            user = Enum.at(users, index)

            state =
              case {op, MapSet.member?(state.retired, user.id)} do
                {:retire, false} ->
                  retire!(user, admin)
                  %{state | retired: MapSet.put(state.retired, user.id)}

                {:grant, false} ->
                  assert {:ok, _} =
                           Marshall.TerminalFixtures.grant(%{fixture | vm: vm}, user, :operator)

                  %{state | grants: MapSet.put(state.grants, user.id)}

                {:revoke, false} ->
                  assert {:ok, _} =
                           Marshall.TerminalFixtures.grant(%{fixture | vm: vm}, user, :revoked)

                  %{state | grants: MapSet.delete(state.grants, user.id)}

                {:join, false} ->
                  member!(team, user, fixture.owner, :member)
                  %{state | members: MapSet.put(state.members, user.id)}

                {:leave, false} ->
                  member!(team, user, fixture.owner, :removed)
                  %{state | members: MapSet.delete(state.members, user.id)}

                {_, true} ->
                  state
              end

            {state, [roster!(binding, ziggy_token, vm, fixture, users, state) | versions]}
          end)

        assert versions == Enum.uniq(versions)
        assert versions == Enum.sort(versions, :desc)
      end,
      test_cases: 100
    )
  end

  test "more than 512 roster candidates refuse; exactly 512 remain admitted" do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, credential} = Credentials.rotate(fixture.vm.host_id, 3600)
    ziggy_token = credential.id <> "." <> credential.secret

    binding = Marshall.TerminalFixtures.roster_binding(fixture.vm)

    # Web-only grants never confer write access, so the refusal must come from
    # the shared 512-candidate bound, not from per-candidate decision work.
    guests = for _ <- 1..512, do: Marshall.ComputeFixtures.user()
    [dropped | _] = guests

    for guest <- guests do
      Ledger.create!(Marshall.Access.Grant, :grant, %{
        vm_id: fixture.vm.id,
        user_id: guest.id,
        granted_by_id: fixture.owner.id,
        role: :web
      })
    end

    assert {:error, :unauthorized} = GuestAccess.roster(ziggy_token, binding)
    assert [] == Ledger.read!(GuestAccount)

    [grant] = Ledger.read!(Marshall.Access.Grant, vm_id: fixture.vm.id, user_id: dropped.id)
    Ledger.archive!(grant, :revoke)

    assert {:ok, roster} = GuestAccess.roster(ziggy_token, binding)
    assert roster.version > 0
    assert [%{username: username, uid: uid}] = roster.accounts
    assert [account] = Ledger.read!(GuestAccount, user_id: fixture.owner.id)
    assert %{username: account.username, uid: account.uid} == %{username: username, uid: uid}
  end

  @spec roster!(map(), String.t(), map(), map(), [User.t()], map()) :: non_neg_integer()
  defp roster!(binding, token, vm, fixture, users, state) do
    assert {:ok, roster} = GuestAccess.roster(token, binding)
    assert_roster(roster, vm, fixture, users, state)
    roster.version
  end

  # @cc [owner:ghuntley,label:verification] roster-oracle-independence
  # The oracle MUST recompute expected writers from raw access_grants,
  # team_members, users and account_guest_accounts rows. A writer without a
  # durable allocation, or a roster entry without a live writer, MUST fail.
  @spec assert_roster(map(), map(), map(), [User.t()], map()) :: :ok
  defp assert_roster(roster, vm, fixture, users, state) do
    candidates =
      [fixture.owner.id | MapSet.to_list(state.grants) ++ MapSet.to_list(state.members)]
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(state.retired, &1))

    live_ids =
      for id <- candidates,
          %User{} = user <- [live_user(id)],
          Marshall.Access.Authorization.allowed?(vm, user, "write"),
          do: id

    durable =
      GuestAccount
      |> Ash.Query.filter(user_id in ^live_ids and is_nil(retired_at))
      |> Ash.read!(actor: SystemActor.compute())

    expected = Enum.map(live_ids, &durable_identity(durable, &1))

    assert Enum.sort_by(roster.accounts, & &1.username) == Enum.sort_by(expected, & &1.username)
    assert length(Enum.uniq_by(roster.accounts, & &1.username)) == length(roster.accounts)
    assert length(Enum.uniq_by(roster.accounts, & &1.uid)) == length(roster.accounts)

    for user <- users, MapSet.member?(state.retired, user.id) do
      for account <- Ledger.read!(GuestAccount, user_id: user.id) do
        refute %{username: account.username, uid: account.uid} in roster.accounts
      end
    end

    :ok
  end

  @spec durable_identity([GuestAccount.t()], String.t()) :: %{
          username: String.t(),
          uid: integer()
        }
  defp durable_identity(durable, user_id) do
    case Enum.find(durable, &(&1.user_id == user_id)) do
      %GuestAccount{username: username, uid: uid} -> %{username: username, uid: uid}
      nil -> flunk("expected durable guest allocation missing for live writer")
    end
  end

  @spec live_user(String.t()) :: User.t() | nil
  defp live_user(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
    |> case do
      %User{deleted_at: nil} = user -> user
      _ -> nil
    end
  end

  @spec member!(map(), User.t(), User.t(), :member | :removed) :: :ok
  defp member!(team, user, owner, role) do
    assert {:ok, _} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(user.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  @spec retire!(User.t(), User.t()) :: :ok
  defp retire!(user, admin) do
    assert {:ok, %{deleting: true}} =
             User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: user.id, confirmation: to_string(user.email)},
               actor: admin
             )
             |> Ash.run_action()

    :ok
  end
end
