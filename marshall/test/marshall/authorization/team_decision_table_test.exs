defmodule Marshall.Authorization.TeamDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Accounts.User
  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.PasskeyFixture
  alias Marshall.Teams.Team

  @type action :: String.t()
  @type relation :: :owner | :admin | :member | :former | :stranger | :administrator
  @type state :: %{relation: relation(), archived: boolean()}

  @actions ~w(team_read team_manage_members team_manage_admins team_transfer)
  @relations [:owner, :admin, :member, :former, :stranger, :administrator]

  setup do
    owner = PasskeyFixture.user(false)

    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    former = PasskeyFixture.user(false)
    set_member!(team, owner, former, :member)
    set_member!(team, owner, former, :removed)

    %{
      team: team,
      owner: owner,
      admin: set_member!(team, owner, PasskeyFixture.user(false), :admin),
      member: set_member!(team, owner, PasskeyFixture.user(false), :member),
      former: former,
      stranger: PasskeyFixture.user(false),
      administrator: PasskeyFixture.elevate(PasskeyFixture.user(true)),
      target: PasskeyFixture.user(false)
    }
  end

  # @cc [owner:ghuntley,label:security;verification] team-decision-table
  # For every generated team archival state and every principal relation under
  # it, the SQL record decision, membership of the Cedar-derived list filter,
  # the Cedar decision over a hand-built entity of the live team, and the real
  # list-members and no-op set-member outcomes MUST all equal the intended
  # decision table below, written from the policy's intent and not from either
  # implementation.
  property "Team decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 40 do
    archived = draw("archived", member_of([true, false]))
    order = draw("order", member_of([@relations, Enum.reverse(@relations)]))
    if archived, do: sql!("UPDATE teams SET archived_at = now() WHERE id = $1", [c.team.id])

    try do
      for relation <- order, do: decide(c, %{relation: relation, archived: archived})
    after
      sql!("UPDATE teams SET archived_at = NULL WHERE id = $1", [c.team.id])
    end
  end

  @spec decide(map(), state()) :: :ok
  defp decide(c, state) do
    principal = Map.fetch!(c, state.relation)

    for action <- @actions do
      expected = expected(state, action)
      label = "#{inspect(state)} #{action}"

      assert Authorization.allowed?(principal, action, Team.Cedar, c.team.id) == expected,
             "record decision " <> label

      assert listed?(principal, action, c.team.id) == expected, "list filter " <> label

      # Archival removes the record rather than changing an attribute, so the
      # hand-built entity always describes the live team's roles.
      assert Cedar.allowed?(principal, action, entity(c)) ==
               expected(%{state | archived: false}, action),
             "hand-built entity " <> label
    end

    read = Marshall.Teams.list_team_members(%{team_id: c.team.id}, actor: principal)

    assert match?({:ok, _}, read) == expected(state, "team_read"),
           "list_members #{inspect(state)}"

    # Removing a non-member is a no-op that still requires team_manage_members.
    manage =
      Marshall.Teams.set_team_member(
        %{
          team_id: c.team.id,
          email: to_string(c.target.email),
          role: :removed,
          idempotency_key: Ash.UUID.generate()
        },
        actor: principal
      )

    assert match?({:ok, _}, manage) == expected(state, "team_manage_members"),
           "set_member #{inspect(state)}"

    :ok
  end

  # The intended table: the owner holds every team action, admins read and
  # manage ordinary members (appointing admins and transfer are the owner's),
  # current members read, everyone else (former members, strangers,
  # administrators without a membership) nothing; an archived team admits no one.
  @spec expected(state(), action()) :: boolean()
  def expected(state, action) do
    granted =
      case state.relation do
        :owner -> @actions
        :admin -> ~w(team_read team_manage_members)
        :member -> ~w(team_read)
        _ -> []
      end

    action in granted and not state.archived
  end

  @spec listed?(User.t(), action(), String.t()) :: boolean()
  defp listed?(principal, action, id) do
    Team
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, Team.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map()) :: Marshall.Authorization.Entity.t()
  defp entity(c) do
    Marshall.CedarEntities.team(
      c.team.id,
      c.owner.id,
      [c.owner.id, c.admin.id],
      [c.owner.id, c.admin.id, c.member.id]
    )
  end

  @spec set_member!(Team.t(), User.t(), User.t(), :admin | :member | :removed) :: User.t()
  defp set_member!(team, owner, user, role) do
    {:ok, _} =
      Marshall.Teams.set_team_member(
        %{
          team_id: team.id,
          email: to_string(user.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    user
  end

  @spec sql!(String.t(), [String.t()]) :: Postgrex.Result.t()
  defp sql!(statement, ids),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))
end
