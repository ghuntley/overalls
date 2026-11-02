defmodule Marshall.Authorization.ArtifactDecisionTableTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Library, Publisher, Sharing}
  alias Marshall.Authorization
  alias Marshall.Authorization.{Cedar, SystemActor}
  alias Marshall.PasskeyFixture

  @type action :: String.t()
  @type relation ::
          :owner
          | :co_owner
          | :writer
          | :viewer
          | :team_writer
          | :team_viewer
          | :former_member
          | :stranger
          | :administrator
          | :unelevated_administrator
  @type state :: %{
          relation: relation(),
          artifact_state: :active | :deleting | :deleted,
          owner_state: :active | :inactive | :deleted,
          team_archived: boolean()
        }

  @content ~w(artifact_read artifact_publish artifact_share artifact_delete
              artifact_storage_personal artifact_storage_shared_read
              artifact_storage_shared_write)
  @writer ~w(artifact_read artifact_publish artifact_storage_personal
             artifact_storage_shared_read artifact_storage_shared_write)
  @viewer ~w(artifact_read artifact_storage_personal artifact_storage_shared_read)
  @actions @content ++ ["artifact_admin_delete"]
  @relations [
    :owner,
    :co_owner,
    :writer,
    :viewer,
    :team_writer,
    :team_viewer,
    :former_member,
    :stranger,
    :administrator,
    :unelevated_administrator
  ]

  setup do
    owner = PasskeyFixture.user(false)

    {:ok, %{artifact: artifact}} =
      Publisher.publish(owner, %{
        artifact_id: nil,
        base_version: 0,
        page: {:content, "decision table"},
        via: :web
      })

    writing_team = create_team!(owner)
    viewing_team = create_team!(owner)
    team_writer = set_member!(writing_team, owner, PasskeyFixture.user(false), :member)
    team_viewer = set_member!(viewing_team, owner, PasskeyFixture.user(false), :member)
    former = set_member!(writing_team, owner, PasskeyFixture.user(false), :member)
    set_member!(writing_team, owner, former, :removed)

    c = %{
      artifact: artifact,
      owner: owner,
      co_owner: PasskeyFixture.user(false),
      writer: PasskeyFixture.user(false),
      viewer: PasskeyFixture.user(false),
      team_writer: team_writer,
      team_viewer: team_viewer,
      former_member: former,
      stranger: PasskeyFixture.user(false),
      administrator: PasskeyFixture.elevate(PasskeyFixture.user(true)),
      unelevated_administrator: PasskeyFixture.user(true),
      teams: [writing_team.id, viewing_team.id]
    }

    share!(c, {:email, to_string(c.co_owner.email)}, :owner)
    share!(c, {:email, to_string(c.writer.email)}, :writer)
    share!(c, {:email, to_string(c.viewer.email)}, :viewer)
    share!(c, {:team, writing_team.id}, :writer)
    share!(c, {:team, viewing_team.id}, :viewer)
    c
  end

  # @cc [owner:ghuntley,label:security;verification] artifact-decision-table
  # For every generated artifact state, owner account state and team archival,
  # and every principal relation under it (owner, direct grants, team grants
  # through current or former membership, strangers and administrators), the
  # SQL record decision, membership of the Cedar-derived list filter, the Cedar
  # decision over a hand-built entity, and the real library listing MUST all
  # equal the intended decision table below, written from the policy's intent
  # and not from either implementation.
  property "Artifact decisions agree with the decision table on every path",
           c,
           profile: :ci,
           test_cases: 40 do
    # Every relation is decided under each generated state (see decide_all/2).
    state = %{
      relation: :owner,
      artifact_state: draw("artifact_state", member_of([:active, :deleting, :deleted])),
      owner_state: draw("owner_state", member_of([:active, :inactive, :deleted])),
      team_archived: draw("team_archived", member_of([true, false]))
    }

    decide_all(c, state)
  end

  @spec decide_all(map(), state()) :: :ok
  defp decide_all(c, state) do
    arrange(c, state)

    try do
      for relation <- @relations, do: decide(c, %{state | relation: relation})
    after
      restore(c)
    end

    :ok
  end

  @spec decide(map(), state()) :: :ok
  defp decide(c, state) do
    principal = Map.fetch!(c, state.relation)
    id = c.artifact.id

    for action <- @actions do
      expected = expected(state, action)
      label = "#{inspect(state)} #{action}"

      assert Authorization.allowed?(principal, action, Artifact.Cedar, id) == expected,
             "record decision " <> label

      assert listed?(principal, action, id) == expected, "list filter " <> label

      assert Cedar.allowed?(principal, action, entity(c, state)) == expected,
             "hand-built entity " <> label
    end

    listing = Library.list(principal)

    assert Enum.any?(listing.items, &(&1.id == id)) == expected(state, "artifact_read"),
           "library list #{inspect(state)}"

    :ok
  end

  # The intended table: the immutable owner and co-owners hold every content
  # action; writers (direct, or through a grant to an unarchived team of which
  # they are currently a member) read, publish and use all storage; viewers
  # read, keep personal storage and read shared storage. Former team members,
  # strangers and administrators hold no content action. Content needs an
  # active artifact and a current (neither deleted nor deactivated) owner.
  # Elevated administrators may moderation-delete any active artifact, whatever
  # the owner's state.
  @spec expected(state(), action()) :: boolean()
  def expected(state, "artifact_admin_delete"),
    do: state.relation == :administrator and state.artifact_state == :active

  def expected(state, action) do
    granted =
      case state.relation do
        :owner -> @content
        :co_owner -> @content
        :writer -> @writer
        :viewer -> @viewer
        :team_writer -> if state.team_archived, do: [], else: @writer
        :team_viewer -> if state.team_archived, do: [], else: @viewer
        _ -> []
      end

    action in granted and state.artifact_state == :active and state.owner_state == :active
  end

  @spec arrange(map(), state()) :: :ok
  defp arrange(c, state) do
    case state.owner_state do
      :active -> :ok
      :inactive -> sql!("UPDATE users SET active = false WHERE id = $1", [c.owner.id])
      :deleted -> sql!("UPDATE users SET deleted_at = now() WHERE id = $1", [c.owner.id])
    end

    unless state.artifact_state == :active,
      do:
        sql!("UPDATE artifacts SET state = '#{state.artifact_state}' WHERE id = $1", [
          c.artifact.id
        ])

    if state.team_archived,
      do: Enum.each(c.teams, &sql!("UPDATE teams SET archived_at = now() WHERE id = $1", [&1]))

    :ok
  end

  # Outcome paths roll back through the ledger, so each case's changes are
  # undone explicitly instead of inside a wrapping transaction.
  @spec restore(map()) :: :ok
  defp restore(c) do
    sql!("UPDATE users SET active = true, deleted_at = NULL WHERE id = $1", [c.owner.id])
    sql!("UPDATE artifacts SET state = 'active' WHERE id = $1", [c.artifact.id])
    Enum.each(c.teams, &sql!("UPDATE teams SET archived_at = NULL WHERE id = $1", [&1]))
    :ok
  end

  @spec listed?(User.t(), action(), String.t()) :: boolean()
  defp listed?(principal, action, id) do
    Artifact
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.compute())
    |> Authorization.filter(principal, action, Artifact.Cedar)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.any?(&(&1.id == id))
  end

  @spec entity(map(), state()) :: Marshall.Authorization.Entity.t()
  defp entity(c, state) do
    team = fn user -> if state.team_archived, do: [], else: [user.id] end

    Marshall.CedarEntities.artifact(
      c.artifact.id,
      c.owner.id,
      %{
        owner: [c.co_owner.id],
        writer: [c.writer.id | team.(c.team_writer)],
        viewer: [c.viewer.id | team.(c.team_viewer)]
      },
      state.artifact_state == :active,
      %{"owner_active" => state.owner_state == :active}
    )
  end

  @spec share!(map(), {:email, String.t()} | {:team, String.t()}, :owner | :writer | :viewer) ::
          :ok
  defp share!(c, recipient, role) do
    {:ok, _} = Sharing.set_access(c.owner, c.artifact.id, recipient, role, Ash.UUID.generate())
    :ok
  end

  @spec create_team!(User.t()) :: Marshall.Teams.Team.t()
  defp create_team!(owner) do
    {:ok, team} =
      Marshall.Teams.create_team(
        %{
          name: "team-" <> binary_part(Ash.UUID.generate(), 0, 8),
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    team
  end

  @spec set_member!(Marshall.Teams.Team.t(), User.t(), User.t(), :member | :removed) :: User.t()
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
