defmodule Marshall.Compute.AdminHostConfiguration do
  @moduledoc "Current-administrator host admission and scheduler-margin configuration."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:security;capacity;concurrency] admin-host-config-serialized
  # Host admission and CPU/RAM margins MUST be changed only by a current
  # administrator, under the host lock, and audited in the same transaction.
  # Enabling a host MUST require normal maintenance, protocol readiness and a
  # fresh report; physical limits remain deployment-owned observations.
  @impl true
  def run(input, _, %{actor: actor}) do
    unless Marshall.Authorization.control_plane?(actor, "admin_configure"),
      do: {:error, Ash.Error.Forbidden.exception([])},
      else: configure(input.arguments, actor)
  end

  defp configure(args, actor) do
    Ledger.transaction(fn ->
      # Enabling changes what guest-credential readers check; fence them out.
      host = Ledger.fence_host!(args.host_id) || Ledger.rollback(:unknown_host)
      Marshall.Accounts.Security.require_admin!(actor)

      if args.enabled and
           not (host.maintenance_mode == :normal and host.inventory["execution_ready"] == true and
                  Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, Ledger.now())),
         do: Ledger.rollback(:host_not_ready)

      Ledger.update!(host, :configure, %{
        enabled: args.enabled,
        overhead_cores: args.overhead_cores,
        overhead_memory_bytes: args.overhead_memory_bytes
      })

      Ledger.create!(AdminEvent, :record, %{
        actor_id: actor.id,
        target_id: host.id,
        kind: :host_configure
      })

      %{
        host_id: host.id,
        enabled: args.enabled,
        overhead_cores: args.overhead_cores,
        overhead_memory_bytes: args.overhead_memory_bytes
      }
    end)
  end
end
