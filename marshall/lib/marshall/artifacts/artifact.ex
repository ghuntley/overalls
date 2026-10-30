defmodule Marshall.Artifacts.Artifact do
  @moduledoc "A versioned page. Content lives in immutable versions; this row is the head."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  @transitions [:request_delete, :admin_delete, :finish_delete]

  # @cc [owner:ghuntley,label:durability;security] artifact-states
  # An artifact MUST change state only through request_delete or admin_delete
  # (active -> deleting) and finish_delete (deleting -> deleted). Only active
  # artifacts accept publishes, grants, storage or views. Each transition MUST
  # write one lifecycle event in the same transaction.
  postgres do
    table "artifacts"
    repo Marshall.Repo

    custom_indexes do
      index [:owner_id, :updated_at, :id]
      index [:state, :updated_at]
    end

    check_constraints do
      check_constraint :state, "artifacts_state_valid",
        check: "state IN ('active', 'deleting', 'deleted')"
    end
  end

  cedar do
    internal [:read, :create, :advance, :request_delete, :admin_delete, :finish_delete]
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active

    transitions do
      transition :request_delete, from: [:active], to: :deleting
      transition :admin_delete, from: [:active], to: :deleting
      transition :finish_delete, from: [:deleting], to: :deleted
    end
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :create do
      accept [:owner_id, :title, :description, :format, :source_thread_id, :created_via]
    end

    update :advance do
      accept [:current_version, :title, :description, :format, :total_bytes, :file_count]
      validate attribute_equals(:state, :active)
    end

    update :request_delete do
      accept []
      change transition_state(:deleting)
      change set_attribute(:deleted_by_kind, :owner)
    end

    update :admin_delete do
      accept [:moderation_reason]
      require_attributes [:moderation_reason]
      change transition_state(:deleting)
      change set_attribute(:deleted_by_kind, :administrator)
    end

    update :finish_delete do
      accept []
      change transition_state(:deleted)
      change set_attribute(:total_bytes, 0)
      change set_attribute(:file_count, 0)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, where: [action_is(@transitions)]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false
    attribute :title, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 200]
    attribute :description, :string, constraints: [max_length: 1000]
    attribute :format, :atom, allow_nil?: false, constraints: [one_of: [:html, :markdown]]
    attribute :source_thread_id, :uuid

    attribute :created_via, :atom,
      allow_nil?: false,
      default: :agent,
      constraints: [one_of: [:agent, :web]]

    attribute :state, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :deleting, :deleted]]

    attribute :current_version, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :total_bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :file_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :deleted_by_kind, :atom, constraints: [one_of: [:owner, :administrator]]

    attribute :moderation_reason, :atom,
      constraints: [one_of: [:abuse, :legal, :security, :owner_request, :other]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, Marshall.Accounts.User, define_attribute?: false
    has_many :grants, Marshall.Artifacts.Grant, destination_attribute: :artifact_id
  end

  @spec transitions() :: [atom()]
  def transitions, do: @transitions
end
