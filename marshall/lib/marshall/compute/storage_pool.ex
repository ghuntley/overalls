# @cc [owner:ghuntley,label:capacity] pool-one-filesystem-once
# A host MUST NOT enroll one filesystem as multiple capacity pools or reuse a pool
# name for another filesystem. New pools MUST have unknown freshness and no
# fabricated total/free capacity before a complete host report.
defmodule Marshall.Compute.StoragePool do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_storage_pools"
    repo Marshall.Repo

    custom_indexes do
      index [:id, :host_id], unique: true
    end

    check_constraints do
      check_constraint :backend, "storage_backend_identity",
        check: """
        (backend = 'zfs' AND zpool_guid IS NOT NULL AND dataset_guid IS NOT NULL
          AND dataset IS NOT NULL
          AND filesystem_id = 'zfs:' || zpool_guid || ':' || dataset_guid)
        """
    end
  end

  cedar do
    internal [:read, :enroll, :configure_overhead, :report, :extend_freshness]
  end

  actions do
    defaults [:read]

    create :enroll do
      accept [
        :host_id,
        :name,
        :filesystem_id,
        :overhead_bytes,
        :backend,
        :zpool_guid,
        :dataset_guid,
        :dataset
      ]
    end

    update :configure_overhead do
      accept [:overhead_bytes]
    end

    update :report do
      accept [
        :total_bytes,
        :free_bytes,
        :allocations,
        :checkpoint_allocations,
        :reported_at,
        :observed_at,
        :storage_observation
      ]
    end

    # A busy host entry extends the freshness of the last real measurement
    # without touching its numbers (ADR-0163).
    update :extend_freshness do
      accept [:reported_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :filesystem_id, :string, allow_nil?: false

    attribute :backend, :atom,
      allow_nil?: false,
      default: :zfs,
      constraints: [one_of: [:zfs]]

    attribute :zpool_guid, :string, allow_nil?: false
    attribute :dataset_guid, :string, allow_nil?: false
    attribute :dataset, :string, allow_nil?: false

    attribute :storage_observation, :map, allow_nil?: false, default: %{}
    attribute :total_bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :free_bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]

    attribute :overhead_bytes, :integer,
      allow_nil?: false,
      default: 1_073_741_824,
      constraints: [min: 0]

    attribute :allocations, :map, allow_nil?: false, default: %{}
    attribute :checkpoint_allocations, :map, allow_nil?: false, default: %{}
    attribute :reported_at, :utc_datetime_usec
    attribute :observed_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_pool_per_filesystem, [:host_id, :filesystem_id]
    identity :one_pool_per_zpool, [:host_id, :zpool_guid], nils_distinct?: true
    identity :unique_name, [:host_id, :name]
  end

  @doc "Public immutable ZFS pool description."
  @spec descriptor(t()) :: map()
  def descriptor(pool) do
    base = Map.take(pool, [:id, :name, :filesystem_id])

    Map.merge(base, %{
      storage:
        pool
        |> Map.take([:backend, :zpool_guid, :dataset_guid, :dataset])
        |> OverallsProtocol.Storage.encode()
    })
  end
end
