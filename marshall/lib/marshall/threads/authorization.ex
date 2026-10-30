defmodule Marshall.Threads.Authorization do
  @moduledoc "Fresh thread ACLs and their inherited authority on the current work machine."
  alias Marshall.Accounts.User
  alias Marshall.Authorization.{DecisionSnapshot, SystemActor}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}
  require Ash.Query

  @type role :: :viewer | :operator | :manager
  @type grants :: %{optional(role()) => [String.t()]}
  @type permissions :: %{read: boolean(), write: boolean(), manage: boolean()}

  @record Thread.Cedar

  @spec allowed?(Thread.t(), term(), String.t()) :: boolean()
  def allowed?(%Thread{id: id}, %User{} = actor, action)
      when action in ["read", "write", "manage"],
      do: Marshall.Authorization.allowed?(actor, action, @record, id)

  def allowed?(_, _, _), do: false

  @doc "Restrict a thread query to the threads `actor` may `action`."
  @spec filter(Ash.Query.t(), term(), String.t()) :: Ash.Query.t()
  def filter(query, actor, action),
    do: Marshall.Authorization.filter(query, actor, action, @record)

  @spec require!(Thread.t(), term(), String.t()) :: :ok
  def require!(thread, actor, action) do
    unless allowed?(thread, actor, action), do: Ledger.rollback(:forbidden)
    :ok
  end

  @spec permissions(Thread.t(), term()) :: permissions()
  def permissions(thread, actor) do
    %{
      read: allowed?(thread, actor, "read"),
      write: allowed?(thread, actor, "write"),
      manage: allowed?(thread, actor, "manage")
    }
  end

  @spec shareable?(Thread.t()) :: boolean()
  def shareable?(%Thread{machine_spec: spec}) do
    Map.get(spec, :profile, Map.get(spec, "profile")) in [
      :standard,
      :oss,
      :inception,
      "standard",
      "oss",
      "inception"
    ]
  end

  # @cc [owner:ghuntley,label:security;concurrency] thread-machine-acl-current-binding
  # The machine roster MUST read only the current thread binding whose creator
  # matches the VM owner and whose VM profile permits sharing. Retired
  # generations MUST NOT inherit a reopened thread's grants. These helpers MUST
  # NOT acquire thread locks: their callers may already hold a VM lock.
  @spec machine_user_ids(VirtualMachine.t()) :: [String.t()]
  def machine_user_ids(vm) do
    case machine_thread(vm) do
      %Thread{id: id} ->
        Grant
        |> Ash.Query.filter(thread_id == ^id)
        |> Ash.Query.limit(513)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(& &1.user_id)

      nil ->
        []
    end
  end

  @bound_statuses [:pending, :provisioning, :ready, :failed, :deleting]

  @spec machine_thread(VirtualMachine.t()) :: Thread.t() | nil
  defp machine_thread(vm) do
    if inherits?(vm) do
      DecisionSnapshot.fetch({:machine_thread, vm.id}, fn ->
        Thread
        |> Ash.Query.filter(
          machine_id == ^vm.id and creator_id == ^vm.owner_id and status in ^@bound_statuses
        )
        |> Ash.Query.limit(2)
        |> Ash.read!(actor: SystemActor.compute())
        |> current_binding()
      end)
    end
  end

  defp inherits?(vm),
    do: OverallsProtocol.ProfilePolicy.allows?(vm.profile, :sharing) and is_nil(vm.archived_at)

  defp current_binding([thread]), do: if(shareable?(thread), do: thread)
  defp current_binding(_), do: nil
end
