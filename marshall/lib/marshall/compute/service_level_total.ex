defmodule Marshall.Compute.ServiceLevelTotal do
  @moduledoc "Permanent fixed-name reliability aggregates, independent of process lifetime."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_service_level_totals"
    repo Marshall.Repo
    migration_defaults bucket_counts: "nil"

    check_constraints do
      check_constraint :requests, "service_level_totals_partition",
        check:
          "requests = successes + failures AND requests >= 0 AND successes >= 0 AND failures >= 0 AND duration_sum_us >= 0"
    end
  end

  cedar do
    internal [:read, :initialize, :add]
  end

  actions do
    defaults [:read]

    create :initialize do
      accept [:service, :started_at]
    end

    update :add do
      accept [:requests, :successes, :failures, :duration_sum_us, :bucket_counts]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :service, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :marshall_ready,
          :lilly_physical,
          :porsche_physical,
          :porsche_clone,
          :porsche_relocate,
          :porsche_retry,
          :porsche_cancel
        ]
      ]

    attribute :started_at, :utc_datetime_usec, allow_nil?: false
    attribute :requests, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :successes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :failures, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :duration_sum_us, :integer, allow_nil?: false, default: 0, constraints: [min: 0]

    attribute :bucket_counts, {:array, :integer},
      allow_nil?: false,
      default: [0, 0, 0, 0, 0, 0, 0, 0],
      constraints: [min_length: 8, max_length: 8, items: [min: 0]]
  end

  identities do
    identity :one_service, [:service]
  end
end
