defmodule Marshall.Ingress.FleetCertificateInstallation do
  @moduledoc "Durable gateway acknowledgement of an installed wildcard generation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_fleet_certificate_installations"
    repo Marshall.Repo

    custom_indexes do
      index [:host_id, :zone, :generation], unique: true
    end
  end

  cedar do
    internal [:read, :record, :rebind_service]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :record do
      accept [:host_id, :service_id, :service_generation, :zone, :generation, :fingerprint]
    end

    update :rebind_service do
      accept [:service_generation]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :host_id, :uuid, allow_nil?: false
    attribute :service_id, :uuid, allow_nil?: false
    attribute :service_generation, :integer, allow_nil?: false, constraints: [min: 1]
    # Generations restart per zone, so an acknowledgement belongs to one zone.
    attribute :zone, :string, allow_nil?: false, constraints: [max_length: 253]
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :fingerprint, :string, allow_nil?: false, constraints: [max_length: 64]
    create_timestamp :inserted_at
  end
end
