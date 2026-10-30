defmodule Marshall.Authorization.Filter do
  @moduledoc """
  Read filters derived from Cedar. For each `{action, entity type}` the policy
  set is partially evaluated once, with principal and resource unknown, and the
  residual policies are kept as a template. A read binds the loaded principal's
  attributes into the template and translates what remains, which names only
  resource attributes, into an Ash filter through the type's
  `Marshall.Authorization.Record` module. Postgres then does the work: no Cedar
  call happens per row or per request.

  Anything the translator does not recognise fails closed: the filter is `false`.
  """
  alias Marshall.Authorization.{Cedar, Native}
  require Marshall.Events

  @type result :: boolean() | Ash.Expr.t()
  @typep principal :: %{type: String.t(), id: String.t(), attributes: map()}
  @typep template :: [{:permit | :forbid, [term()]}]

  # @cc [owner:ghuntley,label:security;performance] cedar-filter-fail-closed
  # A read filter MUST admit a row only when the translated residual of the
  # current policy set admits it for the current principal. Unknown residual
  # shapes, attributes, missing policy state and unknown principals MUST yield
  # `false`; forbid residuals MUST subtract from every permit.
  @doc "The Ash filter admitting exactly the rows `actor` may `action`."
  @spec expression(term(), String.t(), module()) :: result()
  def expression(actor, action, record) do
    with {:ok, principal} <- Cedar.principal(actor),
         {:ok, template} <- template(principal.type, action, record.type()) do
      bind(template, principal, record)
    else
      _ -> false
    end
  catch
    {:unsupported, reason} ->
      Marshall.Events.emit("cedar.filter_unsupported", reason: reason)
      false
  end

  @doc "Apply `expression/3` to a query or to a resource's base query."
  @spec apply(Ash.Query.t() | Ash.Resource.t(), term(), String.t(), module()) :: Ash.Query.t()
  def apply(query, actor, action, record) do
    query = Ash.Query.new(query)

    case expression(actor, action, record) do
      true -> query
      expression -> Ash.Query.do_filter(query, expression)
    end
  end

  # Residual templates depend only on the policy set, so they are computed once
  # per engine and key and shared through :persistent_term.
  @spec template(String.t(), String.t(), String.t()) :: {:ok, template()} | :error
  defp template(principal_type, action, type) do
    with engine when not is_nil(engine) <- Cedar.engine() do
      key = {__MODULE__, engine, principal_type, action, type}

      case :persistent_term.get(key, nil) do
        nil ->
          template = compute(engine, principal_type, action, type)
          :persistent_term.put(key, template)
          {:ok, template}

        template ->
          {:ok, template}
      end
    else
      _ -> :error
    end
  end

  defp compute(engine, principal_type, action, type) do
    case Native.residuals(engine, principal_type, action, type) do
      {:allow, _} ->
        [{:permit, [{:when, %{"Value" => true}}]}]

      {:deny, _} ->
        []

      {:residual, policies} ->
        Enum.map(policies, &parse/1)
    end
  end

  defp parse(json) do
    policy = JSON.decode!(json)

    for scope <- ~w(principal action resource),
        policy[scope] != %{"op" => "All"},
        do: throw({:unsupported, :scope})

    effect =
      case policy["effect"] do
        "permit" -> :permit
        "forbid" -> :forbid
      end

    conditions =
      for %{"kind" => kind, "body" => body} <- policy["conditions"] || [] do
        {String.to_existing_atom(kind), body}
      end

    {effect, conditions}
  end

  @spec bind(template(), principal(), module()) :: result()
  defp bind(template, principal, record) do
    {permits, forbids} =
      Enum.split_with(template, fn {effect, _} -> effect == :permit end)

    any = fn policies ->
      Enum.reduce(policies, false, fn {_, conditions}, acc ->
        disjoin(acc, conditions(conditions, principal, record))
      end)
    end

    conjoin(any.(permits), negate(any.(forbids)))
  end

  defp conditions(conditions, principal, record) do
    Enum.reduce(conditions, true, fn
      {:when, body}, acc -> conjoin(acc, boolean(body, principal, record))
      {:unless, body}, acc -> conjoin(acc, negate(boolean(body, principal, record)))
    end)
  end

  # Boolean-valued expressions: constants, connectives, and the residual forms
  # Cedar leaves after binding the action and the principal type.
  defp boolean(%{"Value" => value}, _, _) when is_boolean(value), do: value

  defp boolean(%{"&&" => %{"left" => l, "right" => r}}, p, rec),
    do: conjoin(boolean(l, p, rec), boolean(r, p, rec))

  defp boolean(%{"||" => %{"left" => l, "right" => r}}, p, rec),
    do: disjoin(boolean(l, p, rec), boolean(r, p, rec))

  defp boolean(%{"!" => %{"arg" => arg}}, p, rec), do: negate(boolean(arg, p, rec))

  defp boolean(%{"==" => %{"left" => l, "right" => r}}, p, rec),
    do: equals(value(l, p), value(r, p), rec)

  defp boolean(%{"!=" => %{"left" => l, "right" => r}}, p, rec),
    do: negate(equals(value(l, p), value(r, p), rec))

  defp boolean(%{"in" => %{"left" => l, "right" => r}}, p, _rec) do
    case {value(l, p), value(r, p)} do
      {{:entity, _} = entity, {:set, items}} -> entity in items
      {{:entity, _} = left, {:entity, _} = right} -> left == right
      {{:principal, uid}, {:set, items}} -> {:entity, uid} in items
      {{:principal, uid}, {:entity, _} = right} -> {:entity, uid} == right
      _ -> throw({:unsupported, :in})
    end
  end

  defp boolean(%{"is" => %{"left" => l, "entity_type" => type} = is}, p, _rec) do
    if Map.has_key?(is, "in"), do: throw({:unsupported, :is_in})

    case value(l, p) do
      {:principal, {principal_type, _}} -> principal_type == type
      {:entity, {entity_type, _}} -> entity_type == type
      _ -> throw({:unsupported, :is})
    end
  end

  defp boolean(%{"contains" => %{"left" => l, "right" => r}}, p, rec) do
    case {value(l, p), value(r, p)} do
      {{:resource_attr, attr}, {:principal, _}} -> attribute(rec, attr, :member, p.id)
      {{:set, items}, {:entity, _} = entity} -> entity in items
      {{:set, items}, {:principal, uid}} -> {:entity, uid} in items
      _ -> throw({:unsupported, :contains})
    end
  end

  defp boolean(%{"." => _} = expr, p, rec) do
    case value(expr, p) do
      {:resource_attr, attr} -> attribute(rec, attr, :truthy, p.id)
      bool when is_boolean(bool) -> bool
      _ -> throw({:unsupported, :attribute})
    end
  end

  defp boolean(_, _, _), do: throw({:unsupported, :expression})

  defp equals({:principal, uid}, {:entity, other}, _rec), do: uid == other
  defp equals({:entity, other}, {:principal, uid}, _rec), do: uid == other
  defp equals({:entity, a}, {:entity, b}, _rec), do: a == b
  defp equals({:principal, _}, {:principal, _}, _rec), do: true

  defp equals({:resource_attr, attr}, {:principal, {_, id}}, rec),
    do: attribute(rec, attr, :equals, id)

  defp equals({:principal, {_, id}}, {:resource_attr, attr}, rec),
    do: attribute(rec, attr, :equals, id)

  defp equals(_, _, _), do: throw({:unsupported, :equals})

  # Values: entity literals, sets, the bound principal and its attributes, and
  # resource attribute references left for SQL.
  defp value(%{"Value" => %{"__entity" => %{"type" => type, "id" => id}}}, _p),
    do: {:entity, {type, id}}

  defp value(%{"Value" => value}, _p) when is_boolean(value), do: value
  defp value(%{"Set" => items}, p), do: {:set, Enum.map(items, &value(&1, p))}
  defp value(%{"Var" => "principal"}, p), do: {:principal, {qualify(p.type), p.id}}
  defp value(%{"Var" => "resource"}, _p), do: :resource

  defp value(%{"." => %{"left" => %{"Var" => "principal"}, "attr" => attr}}, p) do
    case Map.fetch(p.attributes, attr) do
      {:ok, value} when is_boolean(value) -> value
      _ -> throw({:unsupported, :principal_attribute})
    end
  end

  defp value(%{"." => %{"left" => %{"Var" => "resource"}, "attr" => attr}}, _p),
    do: {:resource_attr, attr}

  defp value(_, _), do: throw({:unsupported, :value})

  defp attribute(record, attr, use, principal_id) do
    case record.filter(attr, use, principal_id) do
      :unsupported -> throw({:unsupported, :record_attribute})
      expression -> expression
    end
  end

  defp qualify(type), do: "Marshall::" <> type

  # Constant-folding connectives over `true | false | Ash expression`.
  defp conjoin(false, _), do: false
  defp conjoin(_, false), do: false
  defp conjoin(true, other), do: other
  defp conjoin(other, true), do: other
  defp conjoin(a, b), do: Ash.Query.BooleanExpression.new(:and, a, b)

  defp disjoin(true, _), do: true
  defp disjoin(_, true), do: true
  defp disjoin(false, other), do: other
  defp disjoin(other, false), do: other
  defp disjoin(a, b), do: Ash.Query.BooleanExpression.new(:or, a, b)

  defp negate(bool) when is_boolean(bool), do: not bool
  defp negate(other), do: Ash.Query.Not.new(other)
end
