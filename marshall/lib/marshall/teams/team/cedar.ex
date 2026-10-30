defmodule Marshall.Teams.Team.Cedar do
  @moduledoc """
  The Cedar `Team` entity in SQL, from the team's current unarchived
  memberships; an archived team is no longer readable and admits no one.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr

  @impl true
  def type, do: "Team"

  @impl true
  def resource, do: Marshall.Teams.Team

  @impl true
  def read_action, do: :read

  # @cc [owner:ghuntley,label:security] cedar-team-fresh-membership
  # Team roles MUST come from current unarchived memberships on every decision;
  # the owner is the member holding the owner role and admins include the
  # owner, so ownership changes take effect on the next evaluation.
  @impl true
  def filter("owner", :equals, principal),
    do: expr(exists(members, user_id == ^principal and role == :owner))

  def filter("admins", :member, principal),
    do: expr(exists(members, user_id == ^principal and role in [:owner, :admin]))

  def filter("members", :member, principal), do: expr(exists(members, user_id == ^principal))
  def filter(_attribute, _use, _principal), do: :unsupported
end
