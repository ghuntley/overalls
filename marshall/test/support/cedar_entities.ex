defmodule Marshall.CedarEntities do
  @moduledoc """
  Hand-built Cedar entities for testing the policy itself, independently of
  the SQL attribute definitions production uses. Attributes not given default
  to a live owner on a profile with every capability.
  """
  alias Marshall.Authorization.Entity

  @spec vm(String.t(), String.t(), map(), map()) :: Entity.t()
  def vm(id, owner_id, grants \\ %{}, attributes \\ %{}) do
    Entity.new(
      "VM",
      id,
      Map.merge(
        %{
          "owner" => user(owner_id),
          "owner_active" => true,
          "sharing" => true,
          "terminal" => true,
          "web_enabled" => true,
          "web_users" => users(grants, :web),
          "viewers" => users(grants, :viewer),
          "operators" => users(grants, :operator),
          "managers" => users(grants, :manager),
          "team_admins" => users(grants, :team_admins),
          "team_members" => users(grants, :team_members)
        },
        attributes
      )
    )
  end

  @spec artifact(String.t(), String.t(), map(), boolean(), map()) :: Entity.t()
  def artifact(id, owner_id, grants, active?, attributes \\ %{}) when is_boolean(active?) do
    Entity.new(
      "Artifact",
      id,
      Map.merge(
        %{
          "owner" => user(owner_id),
          "owner_active" => true,
          "owners" => users(grants, :owner),
          "writers" => users(grants, :writer),
          "viewers" => users(grants, :viewer),
          "active" => active?
        },
        attributes
      )
    )
  end

  defp user(id), do: {"User", id}
  defp users(grants, role), do: grants |> Map.get(role, []) |> Enum.map(&user/1)
end
