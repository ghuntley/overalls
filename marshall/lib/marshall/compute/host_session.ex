# @cc [owner:ghuntley,label:recovery] host-session-consumed-history
# Consumed session IDs and their host/epoch bindings MUST remain immutable
# and retained so a delayed open cannot reuse an old nonce as a new session.
defmodule Marshall.Compute.HostSession do
  @moduledoc "Durable session nonces prevent a delayed session-open retry from replacing its successor."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_host_sessions"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :open]
  end

  actions do
    defaults [:read]

    create :open do
      accept [:id, :host_id, :epoch]
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :epoch, :integer, allow_nil?: false, constraints: [min: 1]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_per_epoch, [:host_id, :epoch]
  end
end
