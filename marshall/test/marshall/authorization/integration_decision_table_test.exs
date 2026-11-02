defmodule Marshall.Authorization.IntegrationDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Accounts.User
  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.Compute.Ledger
  alias Marshall.Galileo.Integration
  alias Marshall.PasskeyFixture

  @type action :: String.t()
  @type kind :: :user | :team
  @type relation ::
          :owner
          | :team_owner
          | :team_admin
          | :team_member
          | :former_admin
          | :stranger
          | :administrator
          | :unelevated_administrator
  @type state :: %{
          kind: kind(),
          relation: relation(),
          owner_state: :active | :inactive | :deleted,
          team_archived: boolean(),
          integration_archived: boolean()
        }

  @actions ~w(integration_read integration_manage)
  @relations [
    :owner,
    :team_owner,
    :team_admin,
    :team_member,
    :former_admin,
    :stranger,
    :administrator,
    :unelevated_administrator
  ]

  setup do
    owner = PasskeyFixture.user(false)
    team_owner = PasskeyFixture.user(false)

    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
          idempotency_key: Ash.UUID.generate()
        },
        actor: team_owner
      )

    former_admin = set_member!(team, team_owner, PasskeyFixture.user(false), :admin)
    set_member!(team, team_owner, former_admin, :removed)

    %{
      team: team,
      owner: owner,
      team_owner: team_owner,
      team_admin: set_member!(team, team_owner, PasskeyFixture.user(false), :admin),
      team_member: set_member!(team, team_owner, PasskeyFixture.user(false), :member),
      former_admin: former_admin,
      stranger: PasskeyFixture.user(false),
      administrator: PasskeyFixture.elevate(PasskeyFixture.user(true)),
      unelevated_administrator: PasskeyFixture.user(true),
      integrations: %{
        user: register!(%{owner_id: owner.id}),
        team: register!(%{team_id: team.id})
      }
    }
  end

  # @cc [owner:ghuntley,label:security;verification] integration-decision-table
  # For every generated integration ownership (user or team), user-owner
  # account state, team archival and integration archival, and every principal
  # relation under it, the SQL record decision (over `:history`, so archived rows are decided),
  # membership of the Cedar-derived filter over the same read, the Cedar
  # decision over a hand-built entity, and the real `show_integration` outcome
  # MUST all equal the intended decision table below, written from the policy's
  # intent and not from either implementation.
  property "Integration decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 48 do
    # Every relation is decided under each generated state (see decide_all/2).
    state = %{
      kind: draw("kind", member_of([:user, :team])),
      relation: :owner,
      owner_state: draw("owner_state", member_of([:active, :inactive, :deleted])),
      team_archived: draw("team_archived", member_of([true, false])),
      integration_archived: draw("integration_archived", member_of([true, false]))
    }

    decide_all(c, state)
  end

  @spec decide_all(map(), state()) :: :ok
  defp decide_all(c, state) do
    integration = Map.fetch!(c.integrations, state.kind)
    arrange(c, state, integration)

    try do
      for relation <- @relations, do: decide(c, %{state | relation: relation}, integration)
    after
      restore(c, integration)
    end

    :ok
  end

  @spec decide(map(), state(), Integration.t()) :: :ok
  defp decide(c, state, integration) do
    principal = Map.fetch!(c, state.relation)

    for action <- @actions do
      expected = expected(state, action)
      label = "#{inspect(state)} #{action}"

      assert Authorization.allowed?(principal, action, Integration.Cedar, integration.id) ==
               expected,
             "record decision " <> label

      assert listed?(principal, action, integration.id) == expected, "list filter " <> label

      assert Cedar.allowed?(principal, action, entity(c, state)) == expected,
             "hand-built entity " <> label
    end

    # The product view resolves only unarchived names before deciding.
    outcome = Marshall.Galileo.show_integration(%{name: integration.name}, actor: principal)

    assert match?({:ok, _}, outcome) ==
             (expected(state, "integration_read") and not state.integration_archived),
           "show_integration #{inspect(state)}"

    :ok
  end

  # The intended table: the user owner of a user-owned integration, the
  # current owner and admins of the owning team, and elevated administrators
  # read and manage; nobody else does. An integration is live only while its
  # user owner is current (neither deleted nor deactivated) or its owning team
  # is unarchived; a dead integration admits no one, administrators included.
  # Removing (archiving) the integration itself does not change the decision.
  @spec expected(state(), action()) :: boolean()
  def expected(state, action) do
    live =
      case state.kind do
        :user -> state.owner_state == :active
        :team -> not state.team_archived
      end

    role? =
      case {state.kind, state.relation} do
        {_, :administrator} -> true
        {:user, :owner} -> true
        {:team, :team_owner} -> true
        {:team, :team_admin} -> true
        _ -> false
      end

    action in @actions and live and role?
  end

  @spec arrange(map(), state(), Integration.t()) :: :ok
  defp arrange(c, state, integration) do
    case state.owner_state do
      :active -> :ok
      :inactive -> sql!("UPDATE users SET active = false WHERE id = $1", [c.owner.id])
      :deleted -> sql!("UPDATE users SET deleted_at = now() WHERE id = $1", [c.owner.id])
    end

    if state.team_archived,
      do: sql!("UPDATE teams SET archived_at = now() WHERE id = $1", [c.team.id])

    if state.integration_archived,
      do:
        sql!("UPDATE galileo_integrations SET archived_at = now() WHERE id = $1", [
          integration.id
        ])

    :ok
  end

  # Outcome paths roll back through the ledger, so each case's changes are
  # undone explicitly instead of inside a wrapping transaction.
  @spec restore(map(), Integration.t()) :: :ok
  defp restore(c, integration) do
    sql!("UPDATE users SET active = true, deleted_at = NULL WHERE id = $1", [c.owner.id])
    sql!("UPDATE teams SET archived_at = NULL WHERE id = $1", [c.team.id])
    sql!("UPDATE galileo_integrations SET archived_at = NULL WHERE id = $1", [integration.id])
    :ok
  end

  @spec listed?(User.t(), action(), String.t()) :: boolean()
  defp listed?(principal, action, id) do
    Integration
    |> Ash.Query.for_read(Integration.Cedar.read_action(), %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, Integration.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map(), state()) :: Marshall.Authorization.Entity.t()
  defp entity(c, state) do
    integration = Map.fetch!(c.integrations, state.kind)

    case state.kind do
      :user ->
        Marshall.CedarEntities.integration(
          integration.id,
          c.owner.id,
          state.owner_state == :active,
          []
        )

      :team ->
        managers = if state.team_archived, do: [], else: [c.team_owner.id, c.team_admin.id]

        # A team-owned integration has no user owner: an id no principal holds.
        Marshall.CedarEntities.integration(
          integration.id,
          Ash.UUID.generate(),
          not state.team_archived,
          managers
        )
    end
  end

  @spec register!(%{optional(:owner_id) => String.t(), optional(:team_id) => String.t()}) ::
          Integration.t()
  defp register!(ownership) do
    Ledger.create!(
      Integration,
      :register,
      Map.merge(
        %{
          name: "int-" <> binary_part(Ash.UUID.generate(), 0, 8),
          target: "https://upstream.example.test",
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        ownership
      )
    )
  end

  @spec set_member!(Marshall.Teams.Team.t(), User.t(), User.t(), :admin | :member | :removed) ::
          User.t()
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
