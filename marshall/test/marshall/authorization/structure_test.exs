defmodule Marshall.Authorization.StructureTest do
  use ExUnit.Case, async: true
  alias Marshall.Authorization.AshAuthorizer
  alias Marshall.Authorization.Resource.Info

  @resources (fn ->
                {:ok, modules} = :application.get_key(:marshall, :modules)

                modules
                |> Enum.filter(&(Code.ensure_loaded?(&1) and Ash.Resource.Info.resource?(&1)))
                |> Enum.sort()
              end).()

  # @cc [owner:ghuntley,label:security] authorization-single-authorizer
  # Every Marshall Ash resource, including generated paper-trail versions, MUST
  # use the Cedar authorizer and no other, and every action MUST carry a Cedar
  # mapping. Ash.Policy and authorization bypasses MUST NOT appear in Marshall code.
  test "every resource is authorized by Cedar alone and maps every action" do
    assert length(@resources) > 150

    for resource <- @resources do
      assert Ash.Resource.Info.authorizers(resource) == [AshAuthorizer], inspect(resource)

      for action <- Ash.Resource.Info.actions(resource),
          do:
            assert(
              Info.rules_for(resource, action.name) != [],
              "#{inspect(resource)}.#{action.name}"
            )
    end
  end

  test "Marshall code holds no Ash.Policy authorizer, bypass or authorize?: false" do
    sources =
      Path.wildcard(Path.expand("../../../lib/**/*.{ex,heex}", __DIR__))

    assert sources != []

    for path <- sources, text = File.read!(path) do
      refute text =~ "Ash.Policy", path
      refute text =~ "authorize?: false", path
      # Only the authorizer reads AshAuthentication's own flag, to name its principal.
      unless String.ends_with?(path, "authorization/ash_authorizer.ex"),
        do: refute(text =~ ~r/ash_(authentication|scim)\?: true/, path)

      refute text =~ "authorize_if", path
    end
  end
end
