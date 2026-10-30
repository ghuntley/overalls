defmodule Marshall.Editor.Audit do
  @moduledoc "Bounded administrator projection of redacted editor transitions."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor

  @type item :: %{
          id: String.t(),
          kind: atom(),
          action: atom(),
          target_id: String.t(),
          actor_id: String.t() | nil,
          actor_kind: atom() | nil,
          inserted_at: DateTime.t()
        }

  @impl true
  def run(_, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      items =
        [
          {Marshall.Editor.Login.Version, :editor_login},
          {Marshall.Editor.Credential.Version, :editor_credential},
          {Marshall.Editor.Lease.Version, :editor_lease}
        ]
        |> Enum.flat_map(fn {resource, kind} -> versions(resource, kind) end)
        |> Enum.sort_by(&{&1.inserted_at, &1.id}, :desc)
        |> Enum.take(100)

      {:ok, %{items: items}}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  @spec versions(module(), atom()) :: [item()]
  defp versions(resource, kind) do
    resource
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.map(fn version ->
      %{
        id: version.id,
        kind: kind,
        action: version.version_action_name,
        target_id: version.version_source_id,
        actor_id: version.actor_id,
        actor_kind: version.actor_kind,
        inserted_at: version.version_inserted_at
      }
    end)
  end
end
