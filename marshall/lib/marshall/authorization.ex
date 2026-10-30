defmodule Marshall.Authorization do
  @moduledoc """
  The typed authorization API. Cedar policy in `priv/cedar` is the only place
  access rules live; this module applies it to every path that is not an Ash
  action entry (coordinators, SSH, terminals, snapshots).

  - `control_plane?/2` decides a Cedar action on `ControlPlane::"marshall"`.
  - `allowed?/4` decides a Cedar action on one record. The record is never
    turned into an entity in Elixir: the Cedar residual for the action is
    translated through the record type's `Marshall.Authorization.Record` module
    and checked in one query, `WHERE id = $1 AND <residual>`.
  - `prefetch/4` decides a whole page in one query and primes the decision
    scope, so later per-record calls in that scope cost nothing.
  - `filter/4` restricts a read to exactly the permitted rows.
  """
  alias Marshall.Authorization.{Cedar, DecisionSnapshot, Filter, SystemActor}
  require Ash.Query

  @spec control_plane?(term(), String.t()) :: boolean()
  def control_plane?(actor, action),
    do: Cedar.allowed?(actor, action, Cedar.entity("ControlPlane", "marshall"))

  # @cc [owner:ghuntley,label:security;performance] record-decision-one-query
  # A record decision MUST equal membership of that record in the Cedar-derived
  # read filter for the same principal and action, evaluated against current
  # rows (inside the caller's transaction when there is one). Within one
  # decision scope the result MAY be reused; it MUST NOT outlive the scope.
  @spec allowed?(term(), String.t(), module(), String.t() | nil) :: boolean()
  def allowed?(_actor, _action, _record, nil), do: false

  def allowed?(actor, action, record, id) do
    DecisionSnapshot.fetch({:cedar_record, record, action, key(actor), id}, fn ->
      case Filter.expression(actor, action, record) do
        decision when is_boolean(decision) ->
          decision and exists?(record, [id])

        expression ->
          record
          |> query()
          |> Ash.Query.filter(id == ^id)
          |> Ash.Query.do_filter(expression)
          |> Ash.exists?()
      end
    end)
  end

  @doc "Decide `action` for every id in one query and keep the results for this scope."
  @spec prefetch(term(), String.t(), module(), [String.t()]) :: MapSet.t(String.t())
  def prefetch(_actor, _action, _record, []), do: MapSet.new()

  def prefetch(actor, action, record, ids) do
    ids = Enum.uniq(ids)

    permitted =
      record
      |> query()
      |> Ash.Query.filter(id in ^ids)
      |> filter(actor, action, record)
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> MapSet.new(& &1.id)

    DecisionSnapshot.prime(
      Map.new(
        ids,
        &{{:cedar_record, record, action, key(actor), &1}, MapSet.member?(permitted, &1)}
      )
    )

    permitted
  end

  @spec filter(Ash.Query.t() | Ash.Resource.t(), term(), String.t(), module()) ::
          Ash.Query.t()
  def filter(query, actor, action, record), do: Filter.apply(query, actor, action, record)

  defp exists?(record, ids),
    do: record |> query() |> Ash.Query.filter(id in ^ids) |> Ash.exists?()

  defp query(record) do
    Ash.Query.for_read(record.resource(), record.read_action(), %{}, actor: SystemActor.compute())
  end

  # Decisions depend on the persisted principal and its presented login.
  defp key(%Marshall.Accounts.User{id: id} = user), do: {id, Marshall.Accounts.Security.jti(user)}
  defp key(other), do: other
end
