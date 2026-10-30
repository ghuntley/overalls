# @cc [owner:ghuntley,label:capacity] address-active-uniqueness
# A VM MUST have one retained address identity and each active profile/slot MUST
# be unique. Released addresses MUST remain in history while their slot becomes
# reusable only after physical deletion has been reconciled.
defmodule Marshall.Compute.NetworkAddress do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource]

  postgres do
    table "compute_network_addresses"
    repo Marshall.Repo
    identity_wheres_to_sql unique_address: "archived_at IS NULL"

    check_constraints do
      check_constraint :slot, "valid_address_slot", check: "slot BETWEEN 2 AND 65534"

      check_constraint :profile, "valid_address_profile",
        check: "profile IN ('customer', 'standard', 'oss', 'inception')"
    end
  end

  cedar do
    internal [:read, :history, :reserve, :release]
  end

  archive do
    exclude_read_actions([:history])
  end

  actions do
    defaults [:read]
    read :history

    create :reserve do
      accept [:vm_id, :profile, :slot]
    end

    destroy :release
  end

  attributes do
    uuid_primary_key :id

    attribute :profile, :atom,
      allow_nil?: false,
      constraints: [one_of: [:customer, :standard, :oss, :inception]]

    attribute :slot, :integer, allow_nil?: false, constraints: [min: 2, max: 65534]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :unique_vm, [:vm_id]
    identity :unique_address, [:profile, :slot], where: expr(is_nil(archived_at))
  end
end
