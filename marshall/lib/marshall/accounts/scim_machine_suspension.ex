defmodule Marshall.Accounts.ScimMachineSuspension do
  @moduledoc """
  A machine SCIM suspended while its owner's identity was inactive.

  Only machines recorded here are resumed by SCIM reactivation; machines the
  owner paused or stopped themselves have no row and are left untouched.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  @type t :: %__MODULE__{}

  postgres do
    table "scim_machine_suspensions"
    repo Marshall.Repo

    references do
      reference :user, on_delete: :restrict
      reference :vm, on_delete: :restrict
    end

    custom_indexes do
      index [:vm_id],
        unique: true,
        where: "state = 'suspended'",
        name: "scim_machine_suspensions_one_open_index"

      index [:user_id, :state]
    end
  end

  cedar do
    internal [:read, :record, :resume, :release]
  end

  state_machine do
    initial_states [:suspended]
    default_initial_state :suspended

    transitions do
      transition :resume, from: [:suspended], to: :resumed
      transition :release, from: [:suspended], to: :released
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:user_id, :vm_id, :kind, :retirement_deadline]
    end

    update :resume do
      accept []
      require_atomic? false
      change transition_state(:resumed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end

    update :release do
      accept []
      require_atomic? false
      change transition_state(:released)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: [:pause, :stop]]

    attribute :state, :atom,
      allow_nil?: false,
      default: :suspended,
      constraints: [one_of: [:suspended, :resumed, :released]]

    attribute :retirement_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end
end
