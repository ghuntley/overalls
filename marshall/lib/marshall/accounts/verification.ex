defmodule Marshall.Accounts.Verification do
  @moduledoc "Durable second-factor completion and fixed elevation bound to one stored login."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban]

  postgres do
    table "account_verifications"
    repo Marshall.Repo
  end

  cedar do
    internal [:prune, :read, :destroy, :record, :verify]
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        worker_module_name Marshall.Accounts.Workers.PruneSecurity
      end
    end
  end

  actions do
    action :prune, :atom do
      run Marshall.Accounts.PruneSecurity
    end

    defaults [:read, :destroy]

    create :record do
      accept [
        :id,
        :user_id,
        :generation,
        :primary_at,
        :verified_at,
        :elevated_until,
        :credential_id
      ]
    end

    update :verify do
      accept [:generation, :verified_at, :elevated_until, :credential_id]
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, sensitive?: true
    attribute :generation, :integer, allow_nil?: false
    attribute :primary_at, :utc_datetime_usec
    attribute :verified_at, :utc_datetime_usec
    attribute :elevated_until, :utc_datetime_usec
    attribute :credential_id, :uuid
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end
end
