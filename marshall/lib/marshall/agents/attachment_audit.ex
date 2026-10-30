defmodule Marshall.Agents.AttachmentAudit do
  @moduledoc "Append-only, content-free receipts for thread attachment operations."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @type t :: %__MODULE__{}

  postgres do
    table "agent_attachment_audits"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil"

    custom_indexes do
      index [:thread_id, :inserted_at, :id]
      index [:attachment_id, :inserted_at, :id]
    end
  end

  # @cc [owner:ghuntley,label:security] attachment-audit-content-free
  # Receipts MUST contain only identifiers, closed operation/outcome enums and time.
  # Receipt creation MUST share the transaction of the operation it records.
  # No update or destroy action may expose mutation of existing receipts.
  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:attachment_id, :thread_id, :actor_id, :operation, :outcome]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :attachment_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid

    attribute :operation, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :begin_upload,
          :put_chunk,
          :finish_upload,
          :read_chunk,
          :issue_token,
          :redeem_token,
          :delete,
          :expire_upload
        ]
      ]

    attribute :outcome, :atom,
      allow_nil?: false,
      constraints: [one_of: [:completed, :denied]]

    create_timestamp :inserted_at
  end
end
