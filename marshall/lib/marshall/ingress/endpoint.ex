defmodule Marshall.Ingress.Endpoint do
  @moduledoc "Stable per-VM ingress identity, separate from mutable physical placement."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_endpoints"
    repo Marshall.Repo

    check_constraints do
      check_constraint :primary_port, "ingress_endpoint_port",
        check: "primary_port BETWEEN 1 AND 65535"

      # @cc [owner:ghuntley,label:security] ingress-endpoint-editor-port-reserved
      # TCP 4444 is reserved for Editor. PostgreSQL MUST refuse any endpoint row
      # whose primary port is 4444, so ordinary web authority never resolves it.
      check_constraint :primary_port, "ingress_endpoint_not_editor_port",
        check: "primary_port <> 4444"

      check_constraint :policy_revision, "ingress_endpoint_revision", check: "policy_revision > 0"

      check_constraint :visibility, "ingress_endpoint_visibility",
        check: "visibility IN ('private', 'public')"
    end
  end

  cedar do
    control_plane "provision", [:get_for_user, :get_for_ssh, :configure]
    internal [:read, :record, :change_policy]
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

    create :record do
      accept [:vm_id, :label]
    end

    update :change_policy do
      accept [:primary_port, :visibility, :policy_revision]
    end

    action :get_for_user, :map do
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Ingress.Endpoints, operation: :get}
    end

    action :get_for_ssh, :map do
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Ingress.Endpoints, operation: :ssh}
    end

    action :configure, :map do
      argument :vm_id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :primary_port, :integer, allow_nil?: false, constraints: [min: 1, max: 65535]
      argument :visibility, :atom, allow_nil?: false, constraints: [one_of: [:private, :public]]
      run {Marshall.Ingress.Endpoints, operation: :configure}
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :vm, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:change_policy])]

    # A recorded endpoint label joins its VM's host gateway catalog.
    change {Marshall.Control.Hints.Change,
            kind: :gateway_catalog, from: {Marshall.Control.Hints.Hosts, :of_vm_id}},
           on: [:create, :update, :destroy],
           where: [action_is([:record, :change_policy])]

    # The published zone lists routable VMs too (ADR-0142).
    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:record, :change_policy])]
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, allow_nil?: false, constraints: [min_length: 34, max_length: 63]

    attribute :primary_port, :integer,
      allow_nil?: false,
      default: 80,
      constraints: [min: 1, max: 65535]

    attribute :visibility, :atom,
      allow_nil?: false,
      default: :private,
      constraints: [one_of: [:private, :public]]

    attribute :policy_revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :vm, [:vm_id]
    identity :label, [:label]
  end
end
