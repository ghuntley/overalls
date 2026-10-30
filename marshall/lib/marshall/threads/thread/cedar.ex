defmodule Marshall.Threads.Thread.Cedar do
  @moduledoc """
  The Cedar `Thread` entity in SQL: each schema attribute defined once, over
  the thread row, for record decisions and list reads alike.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr

  @sharing ["standard", "oss", "inception"]

  @impl true
  def type, do: "Thread"

  @impl true
  def resource, do: Marshall.Threads.Thread

  # Retained (archived) threads keep their transcript ACL.
  @impl true
  def read_action, do: :history

  # @cc [owner:ghuntley,label:security] thread-current-cedar-authority
  # Thread authority MUST use the current creator account, the immutable
  # creator, current thread grants and current membership of an unarchived
  # team. Grants and team roles count only on a sharing machine profile (a Cedar
  # forbid over `sharing`). Direct machine grants MUST NOT grant access to the
  # thread or its retained transcript.
  @impl true
  def filter("owner", :equals, principal), do: expr(creator_id == ^principal)

  def filter("owner_active", :truthy, _),
    do: expr(exists(creator, is_nil(deleted_at) and active == true))

  def filter("sharing", :truthy, _),
    do: expr(fragment("(?->>'profile') = ANY(?)", machine_spec, ^@sharing))

  def filter("viewers", :member, principal), do: grant(principal, :viewer)
  def filter("operators", :member, principal), do: grant(principal, :operator)
  def filter("managers", :member, principal), do: grant(principal, :manager)

  def filter("team_members", :member, principal),
    do: expr(exists(team, is_nil(archived_at)) and exists(team.members, user_id == ^principal))

  def filter("team_admins", :member, principal) do
    expr(
      exists(team, is_nil(archived_at)) and
        exists(team.members, user_id == ^principal and role in [:owner, :admin])
    )
  end

  def filter(_attribute, _use, _principal), do: :unsupported

  defp grant(principal, role), do: expr(exists(grants, user_id == ^principal and role == ^role))
end
