defmodule Marshall.Authorization.Resource.Persist do
  @moduledoc "Persists each action's rules so authorization is one map lookup."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    rules =
      for rule <- Transformer.get_entities(dsl, [:cedar]),
          action <- rule.actions,
          reduce: %{},
          do: (acc -> Map.update(acc, action, [rule], &(&1 ++ [rule])))

    {:ok, Transformer.persist(dsl, :cedar_rules, rules)}
  end
end
