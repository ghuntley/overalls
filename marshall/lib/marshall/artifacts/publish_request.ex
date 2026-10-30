defmodule Marshall.Artifacts.PublishRequest do
  @moduledoc "Guest-staged upload backing one large `artifact publish` tool call."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  # @cc [owner:ghuntley,label:security;capacity] artifact-publish-request-states
  # A staged publish MUST move only staging -> committed | refused | expired.
  # Chunks are accepted only while staging, only from the fenced executor of
  # the command's VM, only for declared files and only within the declared
  # limits. Staged chunks are released on every terminal state.
  postgres do
    table "artifact_publish_requests"
    repo Marshall.Repo

    custom_indexes do
      index [:command_id], unique: true
      index [:state, :expires_at]
    end
  end

  cedar do
    internal [:read, :open, :attach_stage, :commit, :refuse, :expire]
  end

  state_machine do
    initial_states [:staging]
    default_initial_state :staging

    transitions do
      transition :commit, from: [:staging], to: :committed
      transition :refuse, from: [:staging], to: :refused
      transition :expire, from: [:staging], to: :expired
    end
  end

  actions do
    defaults [:read]

    create :open do
      accept [:command_id, :user_id, :vm_id, :files, :expires_at]
    end

    update :attach_stage do
      accept [:stage_command_id]
      validate attribute_equals(:state, :staging)
    end

    update :commit do
      accept [:artifact_id, :version_number]
      change transition_state(:committed)
    end

    update :refuse do
      accept [:reason]
      change transition_state(:refused)
    end

    update :expire do
      accept []
      change transition_state(:expired)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :command_id, :uuid, allow_nil?: false
    attribute :stage_command_id, :uuid
    attribute :user_id, :uuid, allow_nil?: false
    attribute :vm_id, :uuid, allow_nil?: false
    # [%{"file_index" => i, "path" => target path or "index.html", "content_type" => ...}]
    attribute :files, {:array, :map}, allow_nil?: false
    attribute :artifact_id, :uuid
    attribute :version_number, :integer

    attribute :state, :atom,
      allow_nil?: false,
      default: :staging,
      constraints: [one_of: [:staging, :committed, :refused, :expired]]

    attribute :reason, :atom
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
