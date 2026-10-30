defmodule Marshall.Ingress.Route do
  @moduledoc "Durable gateway readiness report bound to current physical execution."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_routes"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :revision, "ingress_route_positive_revisions",
        check:
          "revision > 0 AND service_generation > 0 AND execution_epoch > 0 AND generation > 0"

      check_constraint :certificate_fingerprint, "ingress_route_certificate_fingerprint",
        check: "certificate_fingerprint ~ '^[0-9a-f]{64}$'"

      check_constraint :expires_at, "ingress_route_certificate_lifetime",
        check: "expires_at <= certificate_expires_at"
    end
  end

  cedar do
    internal [:read, :record, :replace, :refresh, :current, :report_ready]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    ignore_actions [:refresh]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :vm_id,
        :host_id,
        :placement_id,
        :service_id,
        :service_generation,
        :execution_epoch,
        :generation,
        :revision,
        :certificate_fingerprint,
        :certificate_expires_at,
        :expires_at
      ]
    end

    update :replace do
      accept [
        :host_id,
        :placement_id,
        :service_id,
        :service_generation,
        :execution_epoch,
        :generation,
        :revision,
        :certificate_fingerprint,
        :certificate_expires_at,
        :expires_at
      ]
    end

    update :refresh do
      accept [:expires_at, :revision]
    end

    action :current, :map do
      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]
      run {Marshall.Ingress.Routes, operation: :current}
    end

    action :report_ready, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :vm_id, :uuid, allow_nil?: false
      argument :placement_id, :uuid, allow_nil?: false

      for name <- [:service_generation, :execution_epoch, :generation] do
        argument name, :integer,
          allow_nil?: false,
          constraints: [min: 1, max: 9_223_372_036_854_775_807]
      end

      argument :certificate_fingerprint, :string,
        allow_nil?: false,
        constraints: [max_length: 64, trim?: false]

      argument :certificate_expires_at, :utc_datetime_usec, allow_nil?: false
      run {Marshall.Ingress.Routes, operation: :report}
    end
  end

  changes do
    # A new or replaced route changes the published zone (ADR-0142).
    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:record, :replace])]
  end

  attributes do
    uuid_primary_key :id

    for name <- [:service_generation, :execution_epoch, :generation, :revision] do
      attribute name, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :certificate_fingerprint, :string, allow_nil?: false, constraints: [max_length: 64]
    attribute :certificate_expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
  end

  identities do
    identity :vm, [:vm_id]
  end
end
