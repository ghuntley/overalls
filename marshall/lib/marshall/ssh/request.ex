defmodule Marshall.SSH.Request do
  @moduledoc "Durable command identity and pinned results, independent of SSH connection lifetime."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ssh_requests"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record, :finish, :execute]
  end

  actions do
    defaults [:read]

    create :record do
      change Marshall.Compute.ServiceLevelAdmission

      accept [
        :request_id,
        :user_id,
        :command,
        :vm_id,
        :operation_id,
        :clone_request_id,
        :relocation_id,
        :relocation_retry_id,
        :resize_request_id,
        :wake_request_id,
        :status,
        :measurement_started_at,
        :result,
        :ssh_key_id
      ]
    end

    update :finish do
      accept [:status, :result]
    end

    action :execute, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :command, :map, allow_nil?: false, sensitive?: true
      run Marshall.SSH.Commands
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :request_id, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :command, :map, allow_nil?: false, sensitive?: true

    attribute :status, :atom,
      allow_nil?: false,
      constraints: [one_of: [:accepted, :succeeded, :failed, :superseded]]

    attribute :result, :map, allow_nil?: false, sensitive?: true
    attribute :measurement_started_at, :utc_datetime_usec

    # @cc [owner:ghuntley,label:security;observability] ssh-request-key-provenance
    # A receipt MUST record the SSH key whose session admitted it, so a
    # Porsche-originated change (thread prompt/answer/plan, web policy) names
    # its channel and key. Payload text is reduced to digests before storage.
    attribute :ssh_key_id, :uuid
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine
    belongs_to :clone_request, Marshall.Compute.CloneRequest
    belongs_to :relocation, Marshall.Compute.Relocation
    belongs_to :relocation_retry, Marshall.Compute.RelocationRetry
    belongs_to :resize_request, Marshall.Compute.ResizeRequest
    belongs_to :operation, Marshall.Compute.Operation
    belongs_to :wake_request, Marshall.Compute.WakeRequest
  end

  identities do
    identity :one_user_request, [:user_id, :request_id]
  end
end
