defmodule Marshall.MessageBoards.Board do
  @moduledoc "One durable message board per account and profile."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.MessageBoards.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @type t :: %__MODULE__{}
  postgres do
    table "message_boards"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"
    identity_index_names user_profile: "message_boards_user_id_profile_index"

    references do
      reference :user, on_delete: :delete
    end
  end

  cedar do
    internal [:read, :open]
  end

  actions do
    defaults [:read]

    create :open do
      accept [:user_id, :profile]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false
    attribute :profile, :atom, allow_nil?: false, constraints: [one_of: [:standard, :oss]]
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User do
      define_attribute? false
      source_attribute :user_id
    end
  end

  identities do
    identity :user_profile, [:user_id, :profile]
  end
end
