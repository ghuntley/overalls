defmodule Marshall.Authorization.Resource.Info do
  @moduledoc "Introspection for resources' `cedar` mappings."
  alias Marshall.Authorization.Resource.Rule

  @spec rules(Ash.Resource.t() | Spark.Dsl.t()) :: [Rule.t()]
  def rules(resource), do: Spark.Dsl.Extension.get_entities(resource, [:cedar])

  @doc "The rules mapping `action`; empty when the resource declares none."
  @spec rules_for(Ash.Resource.t(), atom()) :: [Rule.t()]
  def rules_for(resource, action) do
    resource |> Spark.Dsl.Extension.get_persisted(:cedar_rules, %{}) |> Map.get(action, [])
  end
end
