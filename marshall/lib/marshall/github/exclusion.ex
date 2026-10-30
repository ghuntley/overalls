defmodule Marshall.GitHub.Exclusion do
  @moduledoc "Owner-selected VM refusal, independent of connection and execution generation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "github_exclusions"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :exclude, :remove]
  end

  actions do
    defaults [:read]

    create :exclude do
      accept [:user_id, :vm_id]
    end

    destroy :remove
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :one_per_user_vm, [:user_id, :vm_id]
  end
end
