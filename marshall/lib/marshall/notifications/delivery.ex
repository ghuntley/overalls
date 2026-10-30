defmodule Marshall.Notifications.Delivery do
  @moduledoc """
  One poke owed to one device (ADR-0225).

  The delivery id is Susan's idempotency key: every attempt for this row sends
  the same id, so a retried request never notifies twice. The row stores the
  closed kind, the canonical route path and an internal collapse key; it never
  stores ciphertext, push keys or decrypted content.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshPaperTrail.Resource, AshStateMachine]

  @type t :: %__MODULE__{}
  @type state :: :queued | :sending | :delivered | :retry_wait | :failed_permanent | :dropped
  @type drop_reason :: :device_inactive | :preference_off | :coalesced | :expired

  @open_states [:queued, :sending, :retry_wait]
  @terminal_states [:delivered, :failed_permanent, :dropped]

  @doc "Non-terminal states; at most one per device and collapse key."
  @spec open_states() :: [state()]
  def open_states, do: @open_states

  @doc "Terminal states."
  @spec terminal_states() :: [state()]
  def terminal_states, do: @terminal_states

  postgres do
    table "notification_deliveries"
    repo Marshall.Repo

    identity_wheres_to_sql open_collapse: "state IN ('queued', 'sending', 'retry_wait')"

    custom_indexes do
      index [:state, :updated_at]
      index [:finished_at], where: "finished_at IS NOT NULL"
      index [:device_id]
    end

    check_constraints do
      check_constraint :state, "notification_delivery_terminal_receipt",
        check: "(state IN ('queued', 'sending', 'retry_wait')) = (finished_at IS NULL)"

      check_constraint :drop_reason, "notification_delivery_drop_reason",
        check: "(state = 'dropped') = (drop_reason IS NOT NULL)"

      check_constraint :attempts, "notification_delivery_attempts",
        check: "attempts >= 0 AND attempts <= 64"
    end

    references do
      reference :device, on_delete: :restrict
      reference :user, on_delete: :restrict
    end
  end

  cedar do
    internal [
      :read,
      :history,
      :enqueue,
      :record_coalesced,
      :begin_send,
      :deliver,
      :retry_later,
      :fail_permanent,
      :drop,
      :prune,
      :reconcile
    ]
  end

  oban do
    scheduled_actions do
      schedule :prune, "23 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Notifications.Workers.Prune
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end

      schedule :reconcile, "* * * * *" do
        action :reconcile
        queue :notifications
        max_attempts 3
        worker_module_name Marshall.Notifications.Workers.Reconcile
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  # @cc [owner:ghuntley,label:security;persistence] notification-delivery-terminal-audit
  # Only terminal transitions enter the audit trail, with closed reasons and
  # HTTP status classes only. Routes, ciphertext and Susan bodies MUST NOT be
  # recorded in versions or diagnostics.
  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    change_tracking_mode :changes_only
    store_action_name? true
    on_actions [:deliver, :fail_permanent, :drop]
    ignore_actions [:enqueue]
    ignore_attributes [:route, :collapse_key, :inserted_at, :updated_at]
    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] notification-delivery-lifecycle
  # A delivery MUST move only queued -> sending -> delivered | retry_wait |
  # failed_permanent | dropped, and retry_wait -> sending | dropped |
  # failed_permanent. A stuck sending row MAY return to retry_wait for an
  # identical resend under the same delivery id. Terminal states are final.
  state_machine do
    state_attribute :state
    initial_states [:queued, :dropped]
    default_initial_state :queued

    transitions do
      transition :begin_send, from: [:queued, :retry_wait], to: :sending
      transition :deliver, from: :sending, to: :delivered
      transition :retry_later, from: :sending, to: :retry_wait
      transition :fail_permanent, from: [:sending, :retry_wait], to: :failed_permanent
      transition :drop, from: [:queued, :sending, :retry_wait], to: :dropped
    end
  end

  actions do
    defaults [:read]
    read :history

    create :enqueue do
      accept [:device_id, :user_id, :kind, :collapse_key, :route, :expires_at]
    end

    create :record_coalesced do
      accept [:device_id, :user_id, :kind, :collapse_key, :route, :expires_at, :finished_at]
      change set_attribute(:state, :dropped)
      change set_attribute(:drop_reason, :coalesced)
    end

    update :begin_send do
      accept [:attempts, :sending_started_at]
      change transition_state(:sending)
    end

    update :deliver do
      accept [:last_status, :finished_at]
      change transition_state(:delivered)
    end

    update :retry_later do
      accept [:last_status, :failure_reason, :next_attempt_at]
      change transition_state(:retry_wait)
    end

    update :fail_permanent do
      accept [:last_status, :failure_reason, :finished_at]
      change transition_state(:failed_permanent)
    end

    update :drop do
      accept [:drop_reason, :last_status, :finished_at]
      change transition_state(:dropped)
    end

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.Notifications.Retention
    end

    action :reconcile, :integer do
      run Marshall.Notifications.Reconciler
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:needs_input]]

    attribute :collapse_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :route, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 512]

    attribute :state, :atom,
      allow_nil?: false,
      default: :queued,
      public?: true,
      constraints: [
        one_of: [:queued, :sending, :delivered, :retry_wait, :failed_permanent, :dropped]
      ]

    attribute :drop_reason, :atom,
      public?: true,
      constraints: [one_of: [:device_inactive, :preference_off, :coalesced, :expired]]

    attribute :failure_reason, :atom,
      public?: true,
      constraints: [
        one_of: [
          :transport,
          :timeout,
          :server_error,
          :rate_limited,
          :rejected,
          :request_too_large,
          :exhausted,
          :unsealable
        ]
      ]

    attribute :attempts, :integer, allow_nil?: false, default: 0, constraints: [min: 0, max: 64]
    attribute :last_status, :integer, constraints: [min: 0, max: 599]
    attribute :next_attempt_at, :utc_datetime_usec
    attribute :sending_started_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :finished_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, Marshall.Notifications.Device,
      allow_nil?: false,
      attribute_writable?: true

    belongs_to :user, Marshall.Accounts.User do
      domain Marshall.Accounts
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :open_collapse, [:device_id, :collapse_key],
      where: expr(state in [:queued, :sending, :retry_wait])
  end
end
