defmodule Marshall.Terminal.Session do
  @moduledoc "Durable terminal authority bindings; stores no display metadata, token or bytes."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource, AshStateMachine]

  postgres do
    table "terminal_sessions"
    repo Marshall.Repo

    check_constraints do
      check_constraint :execution_epoch, "terminal_session_positive_execution_epoch",
        check: "execution_epoch > 0"

      check_constraint :guest_session_id, "terminal_session_positive_guest_session",
        check: "guest_session_id > 0"

      check_constraint :kill_status, "terminal_session_kill_status",
        check: "kill_status IN ('idle', 'pending', 'confirmed', 'retired')"
    end

    custom_indexes do
      index [:vm_id], where: "archived_at IS NULL"
      index [:vm_id, :guest_session_id], unique: true, where: "archived_at IS NULL"
    end
  end

  cedar do
    internal [:read, :request_kill, :confirm_kill, :retire_kill, :open, :close, :list_for_vm]
  end

  archive do
    exclude_read_actions([:history])
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

  # @cc [owner:ghuntley,label:recovery] terminal-kill-durable-intent
  # Kill intent MUST precede guest dispatch and remain pending across transport
  # failure. Only guest acknowledgement or authoritative absence may confirm it;
  # placement retirement MUST be distinguished from confirmed guest termination.
  state_machine do
    state_attribute :kill_status
    initial_states [:idle]
    default_initial_state :idle

    transitions do
      transition :request_kill, from: :idle, to: :pending
      transition :confirm_kill, from: :pending, to: :confirmed
      transition :retire_kill, from: :pending, to: :retired
    end
  end

  actions do
    defaults [:read]

    update :request_kill do
      accept []
      change transition_state(:pending)
    end

    update :confirm_kill do
      accept []
      change transition_state(:confirmed)
    end

    update :retire_kill do
      accept []
      change transition_state(:retired)
    end

    # @cc [owner:ghuntley,label:security] registry-open-binds-placement
    # create MUST bind the exact placement, epoch and guest session identity of
    # the created terminal and MUST NOT accept terminal bytes, tokens or any
    # other secret.
    create :open do
      primary? true

      accept [
        :vm_id,
        :owner_id,
        :placement_id,
        :execution_epoch,
        :guest_session_id
      ]
    end

    destroy :close do
      accept []
    end

    read :list_for_vm do
      argument :vm_id, :uuid, allow_nil?: false

      filter expr(vm_id == ^arg(:vm_id) and is_nil(archived_at))
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :vm, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:request_kill, :confirm_kill, :retire_kill, :close])]

    # Session list changes for `watch --machine` (ADR-0222), keyed by machine.
    change {Marshall.Control.Hints.Change, kind: :terminal_session, from: :vm_id},
      on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false, public?: true
    attribute :owner_id, :uuid, allow_nil?: false, public?: true
    attribute :placement_id, :uuid, allow_nil?: false, public?: true
    attribute :execution_epoch, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :guest_session_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, Marshall.Accounts.User do
      domain Marshall.Accounts
      allow_nil? false
      attribute_writable? true
    end

    has_many :grants, Marshall.Terminal.Grant, destination_attribute: :session_id
  end
end
