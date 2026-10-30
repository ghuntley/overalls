defmodule Marshall.Accounts.Passkey do
  @moduledoc "WebAuthn public credentials; mutations are confined to the ceremony coordinator."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "account_passkeys"
    repo Marshall.Repo

    custom_indexes do
      index [:user_id]
    end
  end

  cedar do
    internal [:read, :destroy, :create, :update]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:credential_id, :public_key, :sign_count, :label, :user_id]
    end

    update :update do
      primary? true
      accept [:sign_count, :label]
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:destroy])]
  end

  attributes do
    uuid_primary_key :id
    attribute :credential_id, :binary, allow_nil?: false, sensitive?: true

    attribute :public_key, AshAuthentication.Strategy.WebAuthn.CoseKey,
      allow_nil?: false,
      sensitive?: true

    attribute :sign_count, :integer, allow_nil?: false, default: 0

    attribute :label, :string,
      allow_nil?: false,
      default: "Passkey",
      constraints: [max_length: 80]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_credential, [:credential_id]
  end
end
