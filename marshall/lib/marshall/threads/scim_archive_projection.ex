defmodule Marshall.Threads.ScimArchiveProjection do
  @moduledoc "Administrator-only, read-only projections retained after SCIM retirement."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "scim_thread_archive_projections"
    repo Marshall.Repo
  end

  cedar do
    internal [:read]
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :creator_id, :uuid, allow_nil?: false
    attribute :title, :string
    attribute :objective, :string, allow_nil?: false, sensitive?: true
    attribute :archived_at, :utc_datetime_usec, allow_nil?: false
    attribute :reason, :string, allow_nil?: false, default: "scim_retirement"
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
