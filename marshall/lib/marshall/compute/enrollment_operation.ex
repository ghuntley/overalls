defmodule Marshall.Compute.EnrollmentOperation do
  @moduledoc "Immutable operator retry identity; credential secrets remain in HostCredential."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_enrollment_operations"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:id, :request, :kind, :host_id, :credential_id]
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :request, :map, allow_nil?: false
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: [:prepare, :rotate]]
    attribute :credential_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end
end
