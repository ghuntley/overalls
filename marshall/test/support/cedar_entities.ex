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

  @spec thread(String.t(), String.t(), map(), map()) :: Entity.t()
  def thread(id, owner_id, grants \\ %{}, attributes \\ %{}) do
    Entity.new(
      "Thread",
      id,
      Map.merge(
        %{
          "owner" => user(owner_id),
          "owner_active" => true,
          "sharing" => true,
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

  @spec terminal_session(String.t(), String.t(), [String.t()]) :: Entity.t()
  def terminal_session(id, owner_id, viewer_ids \\ []) do
    Entity.new("TerminalSession", id, %{
      "owner" => user(owner_id),
      "viewers" => Enum.map(viewer_ids, &user/1)
    })
  end

  @doc "A Team entity: `owner` is the owner's id, `admins` include the owner."
  @spec team(String.t(), String.t(), [String.t()], [String.t()]) :: Entity.t()
  def team(id, owner_id, admins, members) do
    Entity.new("Team", id, %{
      "owner" => user(owner_id),
      "admins" => Enum.map(admins, &user/1),
      "members" => Enum.map(members, &user/1)
    })
  end

  @doc """
  An Integration entity. A team-owned integration has no user owner; pass an
  id no principal holds.
  """
  @spec integration(String.t(), String.t(), boolean(), [String.t()]) :: Entity.t()
  def integration(id, owner_id, live?, managers) when is_boolean(live?) do
    Entity.new("Integration", id, %{
      "owner" => user(owner_id),
      "live" => live?,
      "managers" => Enum.map(managers, &user/1)
    })
  end

  defp user(id), do: {"User", id}
  defp users(grants, role), do: grants |> Map.get(role, []) |> Enum.map(&user/1)
end
