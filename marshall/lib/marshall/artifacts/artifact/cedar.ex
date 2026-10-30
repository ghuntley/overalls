defmodule Marshall.Artifacts.Artifact.Cedar do
  @moduledoc """
  The Cedar `Artifact` entity in SQL: each schema attribute defined once, over
  the artifact row, for record decisions and list reads alike.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr

  @impl true
  def type, do: "Artifact"

  @impl true
  def resource, do: Marshall.Artifacts.Artifact

  @impl true
  def read_action, do: :read

  # @cc [owner:ghuntley,label:security] artifact-cedar-fresh
  # Artifact roles MUST come from the immutable owner, the actor's current
  # direct grant and current grants to unarchived teams of which the actor is
  # currently a member, with the artifact's current state. A retired or
  # SCIM-inactive owner denies every actor except moderation (a Cedar forbid).
  @impl true
  def filter("owner", :equals, principal), do: expr(owner_id == ^principal)

  def filter("owner_active", :truthy, _),
    do: expr(exists(owner, is_nil(deleted_at) and active == true))

  def filter("active", :truthy, _), do: expr(state == :active)
  def filter("owners", :member, principal), do: grant(principal, :owner)
  def filter("writers", :member, principal), do: grant(principal, :writer)
  def filter("viewers", :member, principal), do: grant(principal, :viewer)
  def filter(_attribute, _use, _principal), do: :unsupported

  defp grant(principal, role) do
    expr(
      exists(grants, role == ^role and user_id == ^principal) or
        exists(
          grants,
          role == ^role and not is_nil(team_id) and exists(team, is_nil(archived_at)) and
            exists(team.members, user_id == ^principal)
        )
    )
  end
end
