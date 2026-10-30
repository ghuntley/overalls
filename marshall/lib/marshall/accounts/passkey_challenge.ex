defmodule Marshall.Accounts.PasskeyChallenge do
  @moduledoc "Single-use cross-node WebAuthn challenges, bound to login, user and purpose."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "account_passkey_challenges"
    repo Marshall.Repo

    custom_indexes do
      index [:user_id, :expires_at]
      index [:expires_at]
    end
  end

  cedar do
    internal [:read, :destroy, :record, :consume]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [:user_id, :login_jti, :generation, :purpose, :bytes, :expires_at]
    end

    update :consume do
      accept [:consumed_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :login_jti, :string, allow_nil?: false, sensitive?: true
    attribute :generation, :integer, allow_nil?: false
    attribute :purpose, :atom, allow_nil?: false, constraints: [one_of: [:register, :verify]]
    attribute :bytes, :binary, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :consumed_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end
end
