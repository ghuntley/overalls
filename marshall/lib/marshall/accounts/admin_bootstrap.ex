defmodule Marshall.Accounts.AdminBootstrap do
  @moduledoc "Permanent bootstrap latch and serialization point for administrator membership."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "account_admin_bootstrap"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :complete]
  end

  actions do
    defaults [:read]

    update :complete do
      accept []
      change set_attribute(:completed, true)
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false
    attribute :completed, :boolean, allow_nil?: false, default: false
  end
end
