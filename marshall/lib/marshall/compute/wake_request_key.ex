defmodule Marshall.Compute.WakeRequestKey do
  @moduledoc "Durable actor/VM request identity for coalesced wake demand."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_wake_request_keys"
    repo Marshall.Repo

    references do
      reference :wake_request, match_with: [vm_id: :vm_id]
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] wake-coalesced-key-history
  # Every accepted keyed demand MUST retain its exact actor/VM/key to wake
  # mapping under the VM lock, even when joining another actor's active wake.
  # Completion or cancellation MUST NOT discard or redirect that identity.
  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :requested_by_id, :request_key, :wake_request_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :wake_request, Marshall.Compute.WakeRequest, allow_nil?: false
  end

  identities do
    identity :request_identity, [:vm_id, :requested_by_id, :request_key]
  end
end
