defmodule Marshall.Agents.Attachment do
  @moduledoc "Thread-owned attachment metadata and state machine."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "agent_attachments"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"
    identity_index_names thread_idempotency: "agent_attachments_thread_id_idempotency_key_index"

    references do
      reference :thread, on_delete: :restrict
      reference :owner, on_delete: :restrict
    end

    custom_indexes do
      index [:thread_id, :state, :inserted_at]
    end
  end

  cedar do
    internal [
      :read,
      :create_pending,
      :begin_upload,
      :touch_upload,
      :publish,
      :quarantine,
      :fail,
      :begin_delete,
      :finish_delete
    ]
  end

  state_machine do
    state_attribute :state
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :begin_upload, from: [:pending, :failed], to: :uploading
      transition :publish, from: [:uploading], to: :available
      transition :quarantine, from: [:uploading, :available], to: :quarantined
      transition :fail, from: [:pending, :uploading], to: :failed

      transition :begin_delete,
        from: [:available, :quarantined, :failed, :deleting],
        to: :deleting

      transition :finish_delete, from: [:deleting], to: :deleted
    end
  end

  actions do
    defaults [:read]

    create :create_pending do
      accept [:thread_id, :owner_id, :idempotency_key, :display_name, :sha256, :size_bytes]
    end

    update :begin_upload do
      accept []
      change transition_state(:uploading)
      change set_attribute(:failure_reason, nil)
    end

    update :touch_upload do
      accept []
      validate attribute_equals(:state, :uploading)
    end

    update :publish do
      accept [:storage_key, :sha256, :size_bytes, :media_type]
      change transition_state(:available)
    end

    update :quarantine do
      accept [:failure_reason]
      change transition_state(:quarantined)
    end

    update :fail do
      accept [:failure_reason]
      change transition_state(:failed)
    end

    update :begin_delete do
      accept []
      change transition_state(:deleting)
      change set_attribute(:download_token_hash, nil)
      change set_attribute(:download_token_expires_at, nil)
    end

    update :finish_delete do
      accept []
      change transition_state(:deleted)
      change set_attribute(:storage_key, nil)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :owner_id, :uuid, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [
        one_of: [:pending, :uploading, :available, :quarantined, :failed, :deleting, :deleted]
      ]

    attribute :storage_key, :string
    attribute :sha256, :string
    attribute :size_bytes, :integer
    attribute :media_type, :string
    attribute :display_name, :string
    attribute :idempotency_key, :string, allow_nil?: false
    attribute :failure_reason, :string
    attribute :download_token_hash, :string, sensitive?: true
    attribute :download_token_expires_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :thread, Marshall.Threads.Thread do
      define_attribute? false
      source_attribute :thread_id
    end

    belongs_to :owner, Marshall.Accounts.User do
      define_attribute? false
      source_attribute :owner_id
    end
  end

  identities do
    identity :thread_idempotency, [:thread_id, :idempotency_key]
  end
end
