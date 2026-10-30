defmodule Marshall.Artifacts.Authorization do
  @moduledoc "Artifact decisions: the Cedar artifact policy over current rows. No permission cache."
  alias Marshall.Accounts.User
  alias Marshall.Artifacts.{Artifact, Grant}
  alias Marshall.Compute.Ledger
  require Ash.Query

  @type action ::
          :read
          | :publish
          | :share
          | :delete
          | :storage_personal
          | :storage_shared_read
          | :storage_shared_write
          | :admin_delete
  @type role :: :owner | :writer | :viewer

  @actions %{
    read: "artifact_read",
    publish: "artifact_publish",
    share: "artifact_share",
    delete: "artifact_delete",
    storage_personal: "artifact_storage_personal",
    storage_shared_read: "artifact_storage_shared_read",
    storage_shared_write: "artifact_storage_shared_write",
    admin_delete: "artifact_admin_delete"
  }

  @spec actions() :: [action()]
  def actions, do: Map.keys(@actions)

  @spec allowed?(Artifact.t(), term(), action()) :: boolean()
  def allowed?(%Artifact{id: id}, %User{} = actor, action) when is_map_key(@actions, action),
    do: Marshall.Authorization.allowed?(actor, Map.fetch!(@actions, action), Artifact.Cedar, id)

  def allowed?(_, _, _), do: false

  @doc "May the actor create artifacts at all?"
  @spec create_allowed?(term()) :: boolean()
  def create_allowed?(actor), do: Marshall.Authorization.control_plane?(actor, "artifact_create")

  @spec require!(Artifact.t(), term(), action()) :: :ok
  def require!(artifact, actor, action) do
    unless allowed?(artifact, actor, action), do: Ledger.rollback(:forbidden)
    :ok
  end

  @doc "The actor's effective role, highest first, or nil."
  @spec role(Artifact.t(), User.t()) :: role() | nil
  def role(%Artifact{owner_id: id}, %User{id: id}), do: :owner

  def role(%Artifact{} = artifact, %User{} = actor) do
    roles = roles(artifact.id, actor.id)
    Enum.find([:owner, :writer, :viewer], &(&1 in roles))
  end

  @spec roles(String.t(), String.t()) :: [role()]
  defp roles(artifact_id, user_id) do
    direct =
      for grant <- Ledger.read!(Grant, artifact_id: artifact_id, user_id: user_id), do: grant.role

    teams =
      for grant <- team_grants(artifact_id),
          Ledger.read!(Marshall.Teams.Team, id: grant.team_id) != [],
          Marshall.Teams.member?(grant.team_id, user_id),
          do: grant.role

    Enum.uniq(direct ++ teams)
  end

  @spec team_grants(String.t()) :: [Grant.t()]
  defp team_grants(artifact_id) do
    Grant
    |> Ash.Query.filter(artifact_id == ^artifact_id and not is_nil(team_id))
    |> Ash.Query.limit(256)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
  end
end
