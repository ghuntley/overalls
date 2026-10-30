defmodule Marshall.Galileo.Integration.Cedar do
  @moduledoc "The Cedar `Integration` entity in SQL, over the integration row."
  @behaviour Marshall.Authorization.Record
  import Ash.Expr

  @impl true
  def type, do: "Integration"

  @impl true
  def resource, do: Marshall.Galileo.Integration

  # Decisions see removed integrations too, so a closed name's replays reach
  # its coordinator refusal; liveness is the `live` attribute below.
  @impl true
  def read_action, do: :history

  # @cc [owner:ghuntley,label:security] cedar-integration-fresh-managers
  # Integration managers MUST be the owning unarchived team's current owner and
  # admins, or the user owner alone. An integration is live only while its user
  # owner is current or its owning team exists unarchived; a Cedar forbid denies
  # every action otherwise. Stored secrets never influence authorization.
  @impl true
  def filter("owner", :equals, principal), do: expr(owner_id == ^principal)

  def filter("live", :truthy, _) do
    expr(
      (not is_nil(owner_id) and exists(owner, is_nil(deleted_at) and active == true)) or
        (is_nil(owner_id) and not is_nil(team_id) and exists(team, is_nil(archived_at)))
    )
  end

  def filter("managers", :member, principal) do
    expr(
      exists(team, is_nil(archived_at)) and
        exists(team.members, user_id == ^principal and role in [:owner, :admin])
    )
  end

  def filter(_attribute, _use, _principal), do: :unsupported
end
