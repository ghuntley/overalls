defmodule Marshall.Ingress.RotateFleetCertificate do
  @moduledoc "Administrator request for an immediate public wildcard generation."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{EnsureFleetCertificate, Error}

  # @cc [owner:ghuntley,label:security;concurrency;observability] fleet-emergency-rotation
  # A current elevated administrator MUST request rotation under the shared
  # issuance lock. The generation, PaperTrail actor and administrator audit row
  # MUST commit together; the diagnostic outcome MUST follow that commit.
  @impl true
  def run(_, _, %{actor: %User{} = actor}) do
    if allowed?(actor) do
      Ledger.transaction(
        fn ->
          unless allowed?(actor), do: Ledger.rollback(:forbidden)
          certificate = EnsureFleetCertificate.rotate!(actor.id)

          Ledger.create!(AdminEvent, :record, %{
            actor_id: actor.id,
            target_id: certificate.id,
            kind: :fleet_certificate_rotate
          })

          %{certificate_id: certificate.id, generation: certificate.generation}
        end,
        actor
      )
      |> Error.result()
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  rescue
    _ -> {:error, Error.exception(reason: :unavailable)}
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  @spec allowed?(User.t()) :: boolean()
  defp allowed?(actor),
    do: Marshall.Authorization.control_plane?(actor, "admin_operate")
end
