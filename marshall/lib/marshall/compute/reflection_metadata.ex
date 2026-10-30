defmodule Marshall.Compute.ReflectionMetadata do
  @moduledoc "Owner-facing machine labels and comment, changed under fresh manage authority."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Compute.{Ledger, VirtualMachine}

  # @cc [owner:ghuntley,label:security;concurrency] reflection-metadata-manage
  # Labels and comment MUST change only after a fresh Cedar manage decision on
  # the locked machine; the write itself is the internal VM update.
  @impl true
  def run(input, _options, context) do
    Ledger.transaction(
      fn ->
        vm = Ledger.lock!(VirtualMachine, input.arguments.vm_id) || Ledger.rollback(:not_found)
        Marshall.Access.Authorization.require!(vm, context.actor, "manage")

        vm =
          Ledger.update!(vm, :reflection_metadata, %{
            labels: input.arguments.labels,
            comment: input.arguments.comment
          })

        %{id: vm.id, labels: vm.labels, comment: vm.comment}
      end,
      context.actor
    )
  end
end
