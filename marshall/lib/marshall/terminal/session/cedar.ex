defmodule Marshall.Terminal.Session.Cedar do
  @moduledoc """
  The Cedar `TerminalSession` entity in SQL: the session's owner and the users
  it is currently shared with, from unarchived terminal grants.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr

  @impl true
  def type, do: "TerminalSession"

  @impl true
  def resource, do: Marshall.Terminal.Session

  @impl true
  def read_action, do: :read

  # @cc [owner:ghuntley,label:security] terminal-session-cedar-fresh
  # Session use MUST come from the session's immutable owner or a current
  # (unarchived) terminal grant to the actor, read on every decision.
  @impl true
  def filter("owner", :equals, principal), do: expr(owner_id == ^principal)
  def filter("viewers", :member, principal), do: expr(exists(grants, user_id == ^principal))
  def filter(_attribute, _use, _principal), do: :unsupported
end
