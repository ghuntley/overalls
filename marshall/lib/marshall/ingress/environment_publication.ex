defmodule Marshall.Ingress.EnvironmentPublication do
  @moduledoc "Expiring child observations and single-use publication offers; not stream grants."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @binding [
    :host_id,
    :placement_id,
    :execution_epoch,
    :vm_generation,
    :environment_generation,
    :session_id,
    :host_epoch
  ]

  postgres do
    table "ingress_environment_publications"
    repo Marshall.Repo

    check_constraints do
      check_constraint :execution_epoch, "ingress_environment_publication_epochs",
        check:
          "execution_epoch > 0 AND vm_generation > 0 AND environment_generation > 0 AND host_epoch > 0"
    end
  end

  cedar do
    internal [:read, :record, :advance]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :offer_id, :offer_expires_at] ++ @binding
    end

    update :advance do
      accept [:offer_id, :offer_expires_at, :payload, :expires_at] ++ @binding
    end
  end

  # @cc [owner:ghuntley,label:recovery;protocol] inception-publication-dns-refresh
  # A committed child publication MUST notify the zone-wide DNS replicas in
  # the same transaction as its VM authority hint. The short publication lease
  # cannot rely on a periodic refresh under database load.
  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :vm, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:record, :advance])]

    # A child publication changes the zone-wide DNS snapshot as well as the
    # VM's authority. DNS replicas subscribe to this dedicated hint so a
    # short-lived nested proof is refreshed before its child lease expires.
    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:record, :advance])]
  end

  attributes do
    uuid_primary_key :id
    attribute :host_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :vm_generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :environment_generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :host_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :offer_id, :uuid, allow_nil?: false
    attribute :offer_expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :payload, :map
    attribute :expires_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :vm, [:vm_id]
  end
end
