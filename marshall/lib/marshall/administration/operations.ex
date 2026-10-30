defmodule Marshall.Administration.Operations do
  @moduledoc "Bounded redacted operational status for the administrator console."

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Image
  alias Marshall.Ingress.{Publication, Route, Service}
  alias Marshall.SSH.Gateway

  @limit 128

  @spec snapshot(Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(actor) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      {:ok,
       %{
         images:
           read(Image, [
             :id,
             :name,
             :architecture,
             :minimum_memory_bytes,
             :minimum_disk_bytes,
             :enabled,
             :inserted_at
           ]),
         gateways: read(Gateway, [:id, :name, :generation, :enabled, :inserted_at]),
         services:
           read(Service, [
             :id,
             :name,
             :role,
             :host_id,
             :enabled,
             :generation,
             :addresses,
             :inserted_at
           ]),
         routes:
           read(Route, [
             :id,
             :vm_id,
             :host_id,
             :revision,
             :certificate_expires_at,
             :expires_at,
             :inserted_at
           ]),
         publications: read(Publication, [:zone, :revision])
       }}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  # @cc [owner:ghuntley,label:security] admin-operations-redaction
  # Operational status MUST be bounded and omit token hashes, private keys,
  # certificate material, DNS proofs, order URLs and gateway credentials.
  defp read(resource, fields) do
    sort_field = if :id in fields, do: :id, else: hd(fields)

    resource
    |> Ash.Query.select(fields)
    |> Ash.Query.sort(sort_field)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: SystemActor.compute())
  end
end
