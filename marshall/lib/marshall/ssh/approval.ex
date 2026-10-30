defmodule Marshall.SSH.Approval do
  @moduledoc "Single-use browser approval bound to an attested SSH connection."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ssh_approvals"
    repo Marshall.Repo
  end

  cedar do
    control_plane "provision", [:inspect_approval, :approve_key]
    internal [:read, :record, :consume, :purge]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:token_hash, :session_id, :public_key, :fingerprint, :expires_at]
    end

    update :consume do
      accept [:consumed_at, :user_id]
    end

    destroy :purge

    action :inspect_approval, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      run {Marshall.SSH.Authority, operation: :inspect_approval}
    end

    action :approve_key, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]

      argument :label, :string,
        allow_nil?: false,
        default: "",
        constraints: [max_length: 128, allow_empty?: true]

      run {Marshall.SSH.Authority, operation: :approve_key}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :public_key, :string, allow_nil?: false, sensitive?: true
    attribute :fingerprint, :string, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :consumed_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :session, Marshall.SSH.Session, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User
  end

  identities do
    identity :token_hash, [:token_hash]
    identity :session, [:session_id]
  end
end
