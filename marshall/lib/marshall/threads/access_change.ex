defmodule Marshall.Threads.AccessChange do
  @moduledoc "Immutable thread-sharing receipt; replay never restores retired authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "thread_access_changes"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:thread_id, :requested_by_id, :user_id, :role, :request_key, :grant_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:viewer, :operator, :manager, :revoked]]

    attribute :request_key, :string, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :thread, Marshall.Threads.Thread, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :grant, Marshall.Threads.Grant
  end

  identities do
    identity :idempotent_change, [:thread_id, :requested_by_id, :request_key]
  end
end
