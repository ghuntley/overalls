defmodule Marshall.Administration.JobSnapshot do
  @moduledoc "Redacted job state maintained transactionally by the Oban capture trigger."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Administration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban]

  @states [
    :available,
    :suspended,
    :scheduled,
    :executing,
    :retryable,
    :completed,
    :discarded,
    :cancelled
  ]

  postgres do
    table "admin_job_snapshots"
    repo Marshall.Repo

    custom_indexes do
      index [:expires_at, :id]
      index [:state, :id]
      index [:queue, :id]
      index [:worker, :id]
      index [:captured_at, :id]
      index [:raw_present, :state]
    end
  end

  cedar do
    control_plane "admin_jobs", [:retry_for_admin]
    control_plane "admin_read", [:list_for_admin, :get_for_admin]
    internal [:read, :expire]
  end

  oban do
    scheduled_actions do
      schedule :expire, "*/5 * * * *" do
        action :expire
        queue :default
        max_attempts 5
        worker_module_name Marshall.Administration.Workers.ExpireJobHistory
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    action :list_for_admin, :map do
      argument :limit, :integer, default: 50, allow_nil?: false, constraints: [min: 1, max: 100]
      argument :before, :integer, constraints: [min: 1]
      argument :state, :atom, constraints: [one_of: @states]
      argument :queue, :string, constraints: [min_length: 1, max_length: 128]
      argument :worker, :string, constraints: [min_length: 1, max_length: 256]
      argument :since, :utc_datetime_usec
      run {Marshall.Administration.Jobs, operation: :list}
    end

    action :get_for_admin, :map do
      argument :id, :integer, allow_nil?: false, constraints: [min: 1]
      argument :events_before, :integer, constraints: [min: 1]
      run {Marshall.Administration.Jobs, operation: :get}
    end

    action :retry_for_admin, :map do
      argument :id, :integer, allow_nil?: false, constraints: [min: 1]
      argument :request_id, :uuid, allow_nil?: false
      run {Marshall.Administration.Jobs, operation: :retry}
    end

    action :expire, :integer do
      argument :continuation, :uuid
      run Marshall.Administration.ExpireJobHistory
    end
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :state, :atom, allow_nil?: false, constraints: [one_of: @states]
    attribute :queue, :string, allow_nil?: false
    attribute :worker, :string, allow_nil?: false
    attribute :attempt, :integer, allow_nil?: false
    attribute :max_attempts, :integer, allow_nil?: false
    attribute :priority, :integer, allow_nil?: false
    attribute :error_count, :integer, allow_nil?: false, default: 0
    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false
    attribute :scheduled_at, :utc_datetime_usec
    attribute :attempted_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :discarded_at, :utc_datetime_usec
    attribute :cancelled_at, :utc_datetime_usec
    attribute :captured_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec
    attribute :raw_present, :boolean, allow_nil?: false, default: true
    attribute :subject_kind, :atom, constraints: [one_of: [:operation, :relocation, :drain]]
    attribute :subject_id, :uuid
  end
end
