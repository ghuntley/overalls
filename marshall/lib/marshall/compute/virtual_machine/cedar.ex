defmodule Marshall.Compute.VirtualMachine.Cedar do
  @moduledoc """
  The Cedar `VM` entity in SQL. Each schema attribute is defined once here, as
  an Ash expression over the machine row, and both record decisions and list
  reads evaluate the Cedar residual through these definitions.
  """
  @behaviour Marshall.Authorization.Record
  import Ash.Expr
  alias OverallsProtocol.ProfilePolicy

  @profiles [:customer, :standard, :oss, :inception]
  @bound_statuses [:pending, :provisioning, :ready, :failed, :deleting]

  @impl true
  def type, do: "VM"

  @impl true
  def resource, do: Marshall.Compute.VirtualMachine

  # Decisions see archived machines too, so a deleted machine's receipts and
  # idempotent replays stay decided on its row; coordinators check liveness.
  @impl true
  def read_action, do: :history

  # @cc [owner:ghuntley,label:security] access-fresh-cedar-entity
  # VM membership MUST come from current rows only: the immutable owner, the
  # actor's unarchived machine grants, unarchived grants on the machine's single
  # current thread binding (created by the VM owner, on a sharing profile), and
  # current membership of an unarchived owning team. Sources are additive;
  # customer-profile and capability limits are Cedar forbids over `sharing`,
  # `terminal` and `web_enabled`, and every role requires a current owner account.
  @impl true
  def filter("owner", :equals, principal), do: expr(owner_id == ^principal)

  def filter("owner_active", :truthy, _),
    do: expr(exists(owner, is_nil(deleted_at) and active == true))

  def filter("sharing", :truthy, _), do: expr(profile in ^profiles(:sharing))
  def filter("terminal", :truthy, _), do: expr(profile in ^profiles(:terminal))
  def filter("web_enabled", :truthy, _), do: expr(profile in ^profiles(:web))

  def filter("web_users", :member, principal), do: machine_grant(principal, :web)
  def filter("viewers", :member, principal), do: role(principal, :viewer)
  def filter("operators", :member, principal), do: role(principal, :operator)
  def filter("managers", :member, principal), do: role(principal, :manager)

  def filter("team_members", :member, principal),
    do: expr(exists(team, is_nil(archived_at)) and exists(team.members, user_id == ^principal))

  def filter("team_admins", :member, principal) do
    expr(
      exists(team, is_nil(archived_at)) and
        exists(team.members, user_id == ^principal and role in [:owner, :admin])
    )
  end

  def filter(_attribute, _use, _principal), do: :unsupported

  defp role(principal, role) do
    machine = machine_grant(principal, role)
    thread = thread_grant(principal, role)
    expr(^machine or ^thread)
  end

  defp machine_grant(principal, role),
    do: expr(exists(access_grants, user_id == ^principal and role == ^role))

  # Thread grants reach the machine only through exactly one current binding.
  defp thread_grant(principal, role) do
    sharing = Enum.map(profiles(:sharing), &Atom.to_string/1)

    expr(
      count(current_threads,
        query: [filter: expr(creator_id == parent(owner_id) and status in ^@bound_statuses)]
      ) == 1 and
        exists(
          current_threads,
          creator_id == parent(owner_id) and status in ^@bound_statuses and
            fragment("(?->>'profile') = ANY(?)", machine_spec, ^sharing) and
            exists(grants, user_id == ^principal and role == ^role)
        )
    )
  end

  defp profiles(capability), do: Enum.filter(@profiles, &ProfilePolicy.allows?(&1, capability))
end
