# @cc [owner:ghuntley,label:product] pin-single-live-row
# Each user/VM pair MUST have at most one unarchived pin row. Re-pinning MUST
# reuse that row through the `unpinned → pinned` transition rather than insert
# a second row, and the row's `pinned_at` MUST be refreshed on every repin so
# pinned ordering follows the latest pin. Removal when the VM is archived is a
# soft-delete (`remove`), never a state; a removed pin cannot be repinned.
defmodule Marshall.Access.Pin do
  @moduledoc "A per-user machine pin whose owner-held pinned state fences deletion."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Access,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "machine_pins"
    repo Marshall.Repo
    identity_wheres_to_sql current_pin: "archived_at IS NULL"

    custom_indexes do
      # The lifecycle guard asks "is this VM pinned by its owner?" under the VM lock.
      index [:vm_id, :user_id],
        where: "state = 'pinned' AND archived_at IS NULL",
        name: "machine_pins_pinned_index"
    end
  end

  cedar do
    control_plane "provision", [:pin_machine, :unpin_machine]
    internal [:read, :history, :pin, :unpin, :repin, :remove]
  end

  state_machine do
    initial_states [:pinned]
    default_initial_state :pinned

    transitions do
      transition :unpin, from: [:pinned], to: :unpinned
      transition :repin, from: [:unpinned], to: :pinned
    end
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

  actions do
    defaults [:read]
    read :history

    create :pin do
      accept [:user_id, :vm_id, :pinned_at]
    end

    update :unpin do
      accept []
      change transition_state(:unpinned)
    end

    update :repin do
      accept [:pinned_at]
      change transition_state(:pinned)
    end

    destroy :remove

    action :pin_machine, :struct do
      constraints instance_of: __MODULE__
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Access.Pins, operation: :pin}
    end

    action :unpin_machine, :struct do
      constraints instance_of: __MODULE__
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Access.Pins, operation: :unpin}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :pinned_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :current_pin, [:user_id, :vm_id], where: expr(is_nil(archived_at))
  end
end
