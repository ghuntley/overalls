# @cc [owner:ghuntley,label:capacity] host-enrollment-defaults
# A newly enrolled host MUST be disabled with unknown report freshness and zero
# observed CPU/RAM. Enrollment MUST NOT accept caller-supplied capacity, connection
# state or readiness that would make an unobserved host eligible for admission.
defmodule Marshall.Compute.Host do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_hosts"
    repo Marshall.Repo

    check_constraints do
      check_constraint :maintenance_mode, "maintenance_excludes_admission",
        check:
          "maintenance_mode IN ('normal', 'draining', 'evacuating', 'retired') AND (maintenance_mode IN ('normal', 'evacuating') OR enabled = false)"
    end
  end

  cedar do
    control_plane "admin_configure", [:configure_for_admin]
    internal [:read, :enroll, :configure, :maintenance, :connect, :disconnect, :report]
  end

  actions do
    defaults [:read]

    create :enroll do
      accept [
        :name,
        :architecture,
        :overhead_cores,
        :overhead_memory_bytes,
        :machine_id,
        :transfer_endpoint
      ]
    end

    update :configure do
      accept [:enabled, :overhead_cores, :overhead_memory_bytes]
    end

    action :configure_for_admin, :map do
      argument :host_id, :uuid, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false
      argument :overhead_cores, :integer, allow_nil?: false, constraints: [min: 0]
      argument :overhead_memory_bytes, :integer, allow_nil?: false, constraints: [min: 0]
      run Marshall.Compute.AdminHostConfiguration
    end

    update :maintenance do
      accept [:maintenance_mode, :enabled]
    end

    update :connect do
      accept [
        :connection_epoch,
        :connection_session_id,
        :report_sequence,
        :reported_at
      ]
    end

    update :disconnect do
      accept [:reported_at, :connection_epoch, :connection_session_id]
    end

    update :report do
      accept [
        :capacity,
        :report_sequence,
        :reported_at,
        :inventory,
        :effective_cores,
        :effective_memory_bytes
      ]
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :host, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:configure, :maintenance, :connect, :disconnect])]

    # A session or authority transition changes which routes the host's own
    # gateway catalog and the DNS zone may publish; hint both at once instead
    # of waiting for the next one-second read (ADR-0142).
    change {Marshall.Control.Hints.Change, kind: :gateway_catalog, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:configure, :maintenance, :connect, :disconnect])]

    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:configure, :maintenance, :connect, :disconnect])]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :architecture, :atom, allow_nil?: false, constraints: [one_of: [:x86_64]]
    attribute :enabled, :boolean, allow_nil?: false, default: false

    attribute :maintenance_mode, :atom,
      allow_nil?: false,
      default: :normal,
      constraints: [one_of: [:normal, :draining, :evacuating, :retired]]

    attribute :machine_id, :string,
      allow_nil?: false,
      constraints: [match: ~r/\Asha256:[0-9a-f]{64}\z/]

    # @cc [owner:ghuntley,label:security] host-transfer-pin-is-enrollment-authority
    # Transfer identity MUST be accepted only by trusted enrollment. Normal host
    # reports, sessions and admission configuration MUST NOT replace its pin.
    attribute :transfer_endpoint, Marshall.Compute.TransferEndpoint

    attribute :connection_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :connection_session_id, :uuid
    attribute :report_sequence, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :reported_at, :utc_datetime_usec
    attribute :effective_cores, :integer, allow_nil?: false, default: 0, constraints: [min: 0]

    attribute :effective_memory_bytes, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]

    attribute :overhead_cores, :integer, allow_nil?: false, default: 1, constraints: [min: 0]

    attribute :overhead_memory_bytes, :integer,
      allow_nil?: false,
      default: 1_073_741_824,
      constraints: [min: 0]

    attribute :inventory, :map, allow_nil?: false, default: %{}
    attribute :capacity, :map
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_machine, [:machine_id]
  end
end
