defmodule Marshall.Authorization.Resource.Verifier do
  @moduledoc "Compile-time completeness and schema conformance for Cedar mappings."
  use Spark.Dsl.Verifier
  alias Marshall.Authorization.Resource.Rule
  alias Spark.Dsl.Verifier

  @schema Path.expand("../../../../priv/cedar/schema.cedarschema", __DIR__)
  @external_resource @schema
  @control_plane_actions (fn ->
                            text = File.read!(@schema)

                            ~r/action\s+((?:"[a-z_]+"\s*,\s*)*"[a-z_]+")\s+appliesTo\s*\{[^}]*resource:\s*\[([^\]]*)\]/s
                            |> Regex.scan(text, capture: :all_but_first)
                            |> Enum.filter(fn [_, resources] ->
                              "ControlPlane" in String.split(resources, ~r/[\s,]+/, trim: true)
                            end)
                            |> Enum.flat_map(fn [names, _] ->
                              Regex.scan(~r/"([a-z_]+)"/, names, capture: :all_but_first)
                            end)
                            |> List.flatten()
                            |> MapSet.new()
                          end).()

  # @cc [owner:ghuntley,label:security] cedar-mapping-complete
  # Every Ash action MUST be named, at most once per principal kind; every named
  # action MUST exist; a refused action MUST NOT also be admitted; and every
  # control-plane Cedar action MUST apply to ControlPlane in the schema. Any
  # violation MUST fail compilation (deny by default).
  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    actions = dsl |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> MapSet.new()
    rules = Spark.Dsl.Extension.get_entities(dsl, [:cedar])
    named = Enum.flat_map(rules, & &1.actions)
    keyed = for r <- rules, a <- r.actions, do: {a, r.kind, r.service}

    unknown_cedar =
      for %Rule{kind: :control_plane, cedar_action: a} <- rules,
          not MapSet.member?(@control_plane_actions, a),
          do: a

    cond do
      MapSet.size(missing = MapSet.difference(actions, MapSet.new(named))) > 0 ->
        error(module, "unmapped actions #{inspect(Enum.sort(missing))}")

      MapSet.size(extra = MapSet.difference(MapSet.new(named), actions)) > 0 ->
        error(module, "mapping names unknown actions #{inspect(Enum.sort(extra))}")

      (dup = keyed -- Enum.uniq(keyed)) != [] ->
        error(module, "actions mapped twice by one principal kind #{inspect(Enum.uniq(dup))}")

      (bad = record_reads(dsl, rules)) != [] ->
        error(module, "record rules apply only to update and destroy actions #{inspect(bad)}")

      (refused = refused_and_admitted(rules)) != [] ->
        error(module, "refused actions also admitted #{inspect(refused)}")

      unknown_cedar != [] ->
        error(module, "Cedar actions not applying to ControlPlane #{inspect(unknown_cedar)}")

      true ->
        :ok
    end
  end

  defp record_reads(dsl, rules) do
    for %Rule{kind: :record} = r <- rules,
        a <- r.actions,
        Ash.Resource.Info.action(dsl, a).type not in [:update, :destroy],
        do: a
  end

  defp refused_and_admitted(rules) do
    refused = for %Rule{kind: :refused} = r <- rules, a <- r.actions, do: a
    admitted = for %Rule{kind: kind} = r <- rules, kind != :refused, a <- r.actions, do: a
    refused |> Enum.filter(&(&1 in admitted)) |> Enum.uniq()
  end

  defp error(module, message),
    do: {:error, Spark.Error.DslError.exception(module: module, path: [:cedar], message: message)}
end
