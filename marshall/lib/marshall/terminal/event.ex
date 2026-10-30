defmodule Marshall.Terminal.Event do
  @moduledoc "Append-only terminal audit receipts: actor, session, kind. No payloads or bytes."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "terminal_events"
    repo Marshall.Repo

    custom_indexes do
      index [:vm_id, :inserted_at]
      index [:actor_id, :inserted_at]
    end
  end

  cedar do
    internal [:read, :record, :recent]
  end

  actions do
    defaults [:read]

    # @cc [owner:ghuntley,label:security] terminal-events-carry-no-payloads
    # record MUST accept exactly the receipt identifiers and a bounded kind
    # enum; terminal bytes, titles-as-data, tokens and request payloads MUST
    # NOT be stored.
    create :record do
      primary? true
      accept [:vm_id, :actor_id, :session_id, :guest_session_id, :kind, :request_id]
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :guest_session_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :opened,
          :attached,
          :detached,
          :closed,
          :kill_requested,
          :killed,
          :denied,
          :shared,
          :revoked
        ]
      ]

    attribute :request_id, :string, public?: true, constraints: [max_length: 64]

    create_timestamp :inserted_at
  end
end
