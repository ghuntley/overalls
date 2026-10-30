defmodule Marshall.Access.Authorization do
  @moduledoc """
  VM decisions: the Cedar VM policy over current rows, through
  `Marshall.Compute.VirtualMachine.Cedar`. No permission cache: a decision is
  reused only within one DecisionSnapshot batch.
  """
  alias Marshall.Accounts.User
  alias Marshall.Authorization.{DecisionSnapshot, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query

  @record VirtualMachine.Cedar

  # @cc [owner:ghuntley,label:security] customer-owner-only-access
  # Customer VM access MUST require the immutable owner, even for administrators,
  # and MUST deny web access. Unknown profiles MUST deny. A machine whose owner
  # is retired or SCIM-inactive MUST deny every actor, so collaborators cannot
  # wake a SCIM-suspended machine during the grace period. These are Cedar
  # forbids; this module adds no rule of its own.
  @spec allowed?(VirtualMachine.t(), term(), String.t()) :: boolean()
  def allowed?(%VirtualMachine{id: id}, %User{} = actor, action)
      when action in ["read", "write", "manage", "web"],
      do: Marshall.Authorization.allowed?(actor, action, @record, id)

  def allowed?(_, _, _), do: false

  @doc "Decide read, write and manage for a page of VMs in the current batch."
  @spec prefetch([VirtualMachine.t()], User.t()) :: :ok
  def prefetch(vms, %User{} = actor) do
    if DecisionSnapshot.active?() and vms != [] do
      ids = Enum.map(vms, & &1.id)

      for action <- ["read", "write", "manage"],
          do: Marshall.Authorization.prefetch(actor, action, @record, ids)
    end

    :ok
  end

  @doc "Restrict a VM query to the machines `actor` may `action`."
  @spec filter(Ash.Query.t() | Ash.Resource.t(), term(), String.t()) :: Ash.Query.t()
  def filter(query, actor, action),
    do: Marshall.Authorization.filter(query, actor, action, @record)

  @spec require!(VirtualMachine.t(), term(), String.t()) :: :ok
  def require!(vm, actor, action) do
    unless allowed?(vm, actor, action), do: Ledger.rollback(:forbidden)
    :ok
  end

  # @cc [owner:ghuntley,label:security] access-administrative-lease-deadline
  # Leases relying on administrator override MUST NOT outlive the fixed passkey
  # deadline. Ordinary owner/sharing rights MUST retain their normal lifetime.
  @spec deadline!(VirtualMachine.t(), Marshall.Accounts.User.t(), String.t(), DateTime.t()) ::
          DateTime.t()
  def deadline!(vm, actor, action, maximum) do
    require!(vm, actor, action)

    if allowed?(vm, %Marshall.Accounts.User{id: actor.id}, action) do
      maximum
    else
      expiry = Marshall.Accounts.Security.elevated_until(actor) || Ledger.rollback(:mfa_required)
      if DateTime.compare(expiry, maximum) == :lt, do: expiry, else: maximum
    end
  end

  @doc "The VM row serializes access mutation with lifecycle. Never acquire its host lock afterward."
  @spec live_vm!(String.t(), term(), String.t(), boolean(), boolean()) :: VirtualMachine.t()
  def live_vm!(id, actor, action, lock \\ true, allow_deleting \\ false) do
    query = VirtualMachine |> Ash.Query.filter(id == ^id)
    query = if lock, do: Ash.Query.lock(query, :for_update), else: query
    vm = Ash.read_one!(query, actor: SystemActor.compute()) || Ledger.rollback(:forbidden)
    require!(vm, actor, action)
    if vm.desired_state == :deleted and not allow_deleting, do: Ledger.rollback(:vm_deleted)
    vm
  end
end
