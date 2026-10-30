defmodule Marshall.GitHub.RestoreEpoch do
  @moduledoc "Singleton acknowledgement of the root-owned restore marker outside database backups."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "github_restore_epochs"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record, :apply_epoch]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:epoch]
    end

    update :apply_epoch do
      accept [:epoch]
    end
  end

  attributes do
    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      default: "github",
      constraints: [match: ~r/\Agithub\z/]

    attribute :epoch, :uuid, allow_nil?: false
    update_timestamp :updated_at
  end
end
