defmodule Marshall.Authorization.Record do
  @moduledoc """
  One Cedar entity type backed by an Ash resource, defined in SQL. Each schema
  attribute of the type is defined once, as an Ash expression over the row, and
  both single-record decisions and list reads evaluate the Cedar residual
  through those definitions; no Elixir code assembles the entity.

  `filter/3` receives the Cedar attribute name and how a residual policy uses
  it: `:equals` (`resource.attr == principal`), `:member`
  (`resource.attr.contains(principal)`) or `:truthy` (a Boolean attribute).
  It returns an Ash expression over the resource, or `:unsupported`, which makes
  the whole filter fail closed.

  `members/2` is optional. Given several `{attribute, use}` membership uses
  (`:equals` or `:member`) that one residual disjunction tests, it returns a
  single expression admitting exactly the rows their disjunction admits, so
  SQL reads each membership source once; `:unsupported` keeps them separate.
  """

  @type use :: :equals | :member | :truthy

  @callback type() :: String.t()
  @callback resource() :: Ash.Resource.t()

  @doc "The internal read that sees every record a decision may concern."
  @callback read_action() :: atom()
  @callback filter(attribute :: String.t(), use(), principal_id :: String.t()) ::
              Ash.Expr.t() | boolean() | :unsupported

  @callback members([{attribute :: String.t(), use()}], principal_id :: String.t()) ::
              Ash.Expr.t() | boolean() | :unsupported

  @optional_callbacks members: 2
end
