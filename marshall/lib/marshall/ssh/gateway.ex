defmodule Marshall.SSH.Gateway do
  @moduledoc "Revocable Porsche service identity, independent of end-user keys."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ssh_gateways"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :ready, :record, :rotate, :configure, :ensure, :disable]
  end

  actions do
    defaults [:read]

    action :ready, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.SSH.Authority, operation: :gateway_ready}
    end

    create :record do
      accept [:name, :token_hash]
    end

    update :rotate do
      accept [:token_hash, :generation, :enabled]
    end

    action :configure, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      run {Marshall.SSH.Authority, operation: :configure_gateway}
    end

    action :ensure, :map do
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      run {Marshall.SSH.Authority, operation: :ensure_gateway}
    end

    action :disable, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.SSH.Authority, operation: :disable_gateway}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :generation, :integer, allow_nil?: false, default: 1
    attribute :enabled, :boolean, allow_nil?: false, default: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :name, [:name]
    identity :token_hash, [:token_hash]
  end
end
