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
  """

  @type use :: :equals | :member | :truthy

  @callback type() :: String.t()
  @callback resource() :: Ash.Resource.t()

  @doc "The internal read that sees every record a decision may concern."
  @callback read_action() :: atom()
  @callback filter(attribute :: String.t(), use(), principal_id :: String.t()) ::
              Ash.Expr.t() | boolean() | :unsupported
end
