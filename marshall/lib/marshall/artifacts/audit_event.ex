defmodule Marshall.Artifacts.AuditEvent do
  @moduledoc "Append-only, payload-free artifact receipt kept for ninety days."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @kinds [
    :created,
    :published,
    :publish_refused,
    :read,
    :listed,
    :ticket_issued,
    :content_refused,
    :shared,
    :unshared,
    :deleted,
    :admin_deleted,
    :purged,
    :storage_written,
    :storage_deleted,
    :storage_refused
  ]

  @reasons [
    :forbidden,
    :not_found,
    :inactive,
    :stale_base_version,
    :edit_not_found,
    :edit_ambiguous,
    :page_too_large,
    :too_many_files,
    :publish_too_large,
    :version_too_large,
    :invalid_path,
    :manifest_conflict,
    :quota_exceeded,
    :upload_refused,
    :staging_unavailable,
    :abuse,
    :legal,
    :security,
    :owner_request,
    :other
  ]

  postgres do
    table "artifact_audit_events"
    repo Marshall.Repo

    custom_indexes do
      index [:artifact_id, :inserted_at, :id]
      index [:actor_id, :inserted_at, :id]
      index [:inserted_at, :id]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:artifact_id, :actor_id, :kind, :via, :reason, :version, :bytes]
      change set_attribute(:expires_at, &__MODULE__.expires_at/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :artifact_id, :uuid
    attribute :actor_id, :uuid
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: @kinds]

    attribute :via, :atom,
      allow_nil?: false,
      constraints: [one_of: [:agent, :web, :admin, :content, :system]]

    attribute :reason, :atom, constraints: [one_of: @reasons]
    attribute :version, :integer, constraints: [min: 0]
    attribute :bytes, :integer, constraints: [min: 0]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at, default: &Marshall.Compute.Ledger.now/0
  end

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc false
  @spec expires_at() :: DateTime.t()
  def expires_at, do: DateTime.add(Marshall.Compute.Ledger.now(), 90, :day)
end
