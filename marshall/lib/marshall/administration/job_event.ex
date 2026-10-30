defmodule Marshall.Administration.JobEvent do
  @moduledoc "Bounded safe job transitions, retained independently of raw Oban jobs."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Administration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "admin_job_events"
    repo Marshall.Repo

    custom_indexes do
      index [:job_id, :id]
      index [:expires_at, :id]
    end
  end

  cedar do
    internal [:read]
  end

  actions do
    defaults [:read]
  end

  attributes do
    integer_primary_key :id
    attribute :job_id, :integer, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :available,
          :suspended,
          :scheduled,
          :executing,
          :retryable,
          :completed,
          :discarded,
          :cancelled
        ]
      ]

    attribute :attempt, :integer, allow_nil?: false
    attribute :error_count, :integer, allow_nil?: false
    attribute :captured_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
  end
end
