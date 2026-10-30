defmodule Marshall.Accounts.UserDeletion do
  @moduledoc """
  Durable account retirement; completion requires all owned VMs to be reclaimed.

  `:administrator` deletions follow an already retired identity (ADR-0066).
  `:scim_retirement` deletions are scheduled at SCIM deactivation, may be
  cancelled by reactivation inside the grace period, and may delete machines
  only once that grace period has expired (ADR-0229). Every state change goes
  through a state-machine transition.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshStateMachine]

  @type t :: %__MODULE__{}

  postgres do
    table "account_user_deletions"
    repo Marshall.Repo

    custom_indexes do
      index [:email, :inserted_at]
    end
  end

  cedar do
    internal [
      :read,
      :record,
      :schedule_scim,
      :progress,
      :cancel,
      :reschedule,
      :escalate,
      :begin_finalization,
      :complete,
      :advance
    ]
  end

  oban do
    triggers do
      trigger :advance do
        action :advance
        queue :maintenance
        # SCIM retirements are driven by Marshall.Scim.RetirementWorker after
        # their deadline; this trigger only advances administrator deletions.
        where expr(
                kind == :administrator and is_nil(completed_at) and
                  state in [:scheduled, :finalizing]
              )

        scheduler_cron "* * * * *"
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        worker_module_name Marshall.Accounts.Workers.DeleteUserMachines
        scheduler_module_name Marshall.Accounts.Workers.ScheduleUserDeletions
      end
    end
  end

  state_machine do
    initial_states [:scheduled]
    default_initial_state :scheduled

    transitions do
      transition :cancel, from: [:scheduled], to: :cancelled
      transition :reschedule, from: [:cancelled], to: :scheduled
      transition :escalate, from: [:scheduled, :cancelled], to: :scheduled
      transition :begin_finalization, from: [:scheduled], to: :finalizing
      transition :complete, from: [:finalizing], to: :completed
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:user_id, :requested_by_id, :email]
      change set_attribute(:kind, :administrator)
      change run_oban_trigger(:advance)
    end

    # Scheduled at SCIM deactivation; nothing is deleted before the deadline.
    create :schedule_scim do
      accept [:user_id, :requested_by_id, :email]
      change set_attribute(:kind, :scim_retirement)
    end

    # Bounded progress counters only; state changes use the transitions below.
    update :progress do
      accept [:remaining, :blocked]
    end

    update :cancel do
      accept []
      require_atomic? false
      validate attribute_equals(:kind, :scim_retirement)
      change transition_state(:cancelled)
    end

    update :reschedule do
      accept [:email]
      require_atomic? false
      validate attribute_equals(:kind, :scim_retirement)
      change transition_state(:scheduled)
    end

    # An administrator retirement supersedes a pending SCIM retirement.
    update :escalate do
      accept [:requested_by_id, :email]
      require_atomic? false
      change set_attribute(:kind, :administrator)
      change transition_state(:scheduled)
      change run_oban_trigger(:advance)
    end

    update :begin_finalization do
      accept []
      require_atomic? false
      change transition_state(:finalizing)
    end

    update :complete do
      accept [:completed_at]
      require_atomic? false
      validate present(:completed_at)
      change transition_state(:completed)
    end

    action :advance, :map do
      argument :primary_key, :map, allow_nil?: false
      run Marshall.Accounts.DeleteUserMachines
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, Marshall.Accounts.EmailAddress, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :scheduled,
      constraints: [one_of: [:scheduled, :finalizing, :cancelled, :completed]]

    attribute :kind, :atom,
      allow_nil?: false,
      default: :administrator,
      constraints: [one_of: [:administrator, :scim_retirement]]

    attribute :remaining, :integer, allow_nil?: false, default: 0
    attribute :blocked, :boolean, allow_nil?: false, default: false
    attribute :completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :one_deletion, [:user_id]
  end

  # @cc [owner:ghuntley,label:security;recovery] user-deletion-machine-authority
  # Machine deletion MUST require an unfinished, uncancelled deletion for the
  # VM owner. An :administrator deletion additionally requires the retired
  # identity; a :scim_retirement deletion requires the live-UUID identity to be
  # inactive with an expired retirement deadline. Neither kind grants the other.
  @doc "Whether this deletion may delete the owner's machines at database time `now`."
  @spec machine_deletion_authorized?(t(), Marshall.Accounts.User.t() | nil, DateTime.t()) ::
          boolean()
  def machine_deletion_authorized?(
        %__MODULE__{completed_at: nil, state: state, user_id: user_id} = deletion,
        %Marshall.Accounts.User{id: user_id} = user,
        now
      )
      when state in [:scheduled, :finalizing] do
    case deletion.kind do
      :administrator ->
        not is_nil(user.deleted_at)

      :scim_retirement ->
        is_nil(user.deleted_at) and Marshall.Accounts.ScimRetirement.due?(user, now)
    end
  end

  def machine_deletion_authorized?(_deletion, _user, _now), do: false
end
