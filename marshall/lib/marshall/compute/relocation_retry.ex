defmodule Marshall.Compute.RelocationRetry do
  @moduledoc "Retained historical destination retry requests; current admission creates none."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_relocation_retries"
    repo Marshall.Repo
    identity_wheres_to_sql one_pending_retry: "finished_at IS NULL"

    references do
      reference :relocation, match_with: [vm_id: :vm_id]

      reference :stop_operation,
        match_with: [relocation_id: :relocation_id, stop_generation: :generation]

      reference :start_operation,
        match_with: [relocation_id: :relocation_id, start_generation: :generation]
    end

    check_constraints do
      check_constraint :start_generation, "relocation_retry_activation_complete",
        check: """
        stop_generation > 0 AND (
          (start_operation_id IS NULL AND start_generation IS NULL)
          OR (start_operation_id IS NOT NULL AND start_generation IS NOT NULL AND start_generation > stop_generation AND finished_at IS NOT NULL)
        )
        """
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] relocation-retry-retained-identity
  # Every retained actor/relocation/key MUST identify one immutable retry and its
  # original stop authority. Historical activation references name a later
  # generation of that relocation; supersession grants no execution authority.
  # Current public actions MUST NOT create, activate or alter these records.
  cedar do
    internal [:read]
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :activated, :superseded]]

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :stop_generation, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :start_generation, :integer, constraints: [min: 1, max: 9_223_372_036_854_775_807]
    attribute :finished_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :relocation, Marshall.Compute.Relocation, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :stop_operation, Marshall.Compute.Operation, allow_nil?: false
    belongs_to :start_operation, Marshall.Compute.Operation
  end

  identities do
    identity :request_identity, [:relocation_id, :requested_by_id, :request_key]
    identity :one_pending_retry, [:relocation_id], where: expr(is_nil(finished_at))
  end
end
