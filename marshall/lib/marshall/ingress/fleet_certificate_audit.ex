defmodule Marshall.Ingress.FleetCertificateAudit do
  @moduledoc "Administrator projection of certificate transitions and gateway receipts."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Ingress.{FleetCertificate, FleetCertificateAccount, FleetCertificateInstallation}
  require Ash.Query

  @type uncertain_order :: %{generation: pos_integer(), retry_after: DateTime.t()}

  # @cc [owner:ghuntley,label:security;observability] fleet-certificate-admin-audit
  # Audit reads MUST recheck current Control room read authority and return only bounded
  # certificate metadata, transition names, gateway receipt identifiers and
  # the bounded retry time for an uncertain order.
  # Ciphertext, decrypted keys, DNS proofs and ACME URLs MUST never escape.
  @impl true
  def run(_, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      certificates =
        FleetCertificate
        |> Ash.Query.sort(updated_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ash.read!(actor: SystemActor.compute())

      uncertain_order =
        FleetCertificate
        |> Ash.Query.filter(status == :pending and not is_nil(order_attempted_at))
        |> Ash.Query.sort(generation: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(actor: SystemActor.compute())
        |> List.first()
        |> uncertain_order()

      by_id = Map.new(certificates, &{&1.id, &1})

      transitions =
        FleetCertificate.Version
        |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ash.read!(actor: SystemActor.compute())

      installations =
        FleetCertificateInstallation
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ash.read!(actor: SystemActor.compute())

      accounts =
        FleetCertificateAccount.Version
        |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ash.read!(actor: SystemActor.compute())

      events =
        Enum.map(transitions, fn version ->
          row = Map.get(by_id, version.version_source_id)

          %{
            id: version.id,
            kind: :certificate,
            generation: if(row, do: row.generation),
            status: version.version_action_name,
            actor_kind: version.actor_kind,
            actor_id: version.actor_id,
            host_id: nil,
            fingerprint: if(row, do: row.fingerprint),
            expires_at: if(row, do: row.expires_at),
            inserted_at: version.version_inserted_at
          }
        end) ++
          Enum.map(installations, fn row ->
            %{
              id: row.id,
              kind: :installation,
              generation: row.generation,
              status: :installed,
              actor_kind: :system,
              actor_id: nil,
              host_id: row.host_id,
              fingerprint: row.fingerprint,
              expires_at: nil,
              inserted_at: row.inserted_at
            }
          end) ++
          Enum.map(accounts, fn version ->
            %{
              id: version.id,
              kind: :account,
              generation: nil,
              status: version.version_action_name,
              actor_kind: version.actor_kind,
              actor_id: version.actor_id,
              host_id: nil,
              fingerprint: nil,
              expires_at: nil,
              inserted_at: version.version_inserted_at
            }
          end)

      {:ok,
       %{
         items: events |> Enum.sort_by(&{&1.inserted_at, &1.id}, :desc) |> Enum.take(100),
         uncertain_order: uncertain_order
       }}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  @spec uncertain_order(FleetCertificate.t() | nil) :: uncertain_order() | nil
  defp uncertain_order(nil), do: nil

  defp uncertain_order(row),
    do: %{generation: row.generation, retry_after: DateTime.add(row.order_attempted_at, 3600)}
end
