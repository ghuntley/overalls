defmodule Marshall.Access.Change do
  @moduledoc "Immutable sharing request result; delayed retries cannot overwrite newer membership."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Access,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "access_changes"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :requested_by_id, :user_id, :role, :request_key, :grant_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:web, :viewer, :operator, :manager, :revoked]]

    attribute :request_key, :string, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :grant, Marshall.Access.Grant
  end

  identities do
    identity :idempotent_change, [:vm_id, :requested_by_id, :request_key]
  end
end
