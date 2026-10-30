defmodule Marshall.Terminal.TicketRetention do
  @moduledoc "Bounded durable cleanup of expired terminal viewer tickets."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Terminal.Ticket

  require Ash.Query

  @batch 500
  @retention_seconds 3600

  # @cc [owner:ghuntley,label:recovery;security] terminal-ticket-retention
  # Each cleanup transaction MUST purge at most 500 tickets expired for one
  # hour. A full batch MUST schedule a durable continuation atomically; active
  # tickets and terminal registry/audit rows MUST remain untouched.
  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -@retention_seconds)

      tickets =
        Ticket
        |> Ash.Query.filter(expires_at < ^cutoff)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(@batch)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      Enum.each(
        tickets,
        &Ash.destroy!(&1, action: :purge, actor: Marshall.Authorization.SystemActor.compute())
      )

      if length(tickets) == @batch do
        AshOban.schedule(Ticket, :prune, action_arguments: %{continuation: Ash.UUID.generate()})
      end

      length(tickets)
    end)
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
