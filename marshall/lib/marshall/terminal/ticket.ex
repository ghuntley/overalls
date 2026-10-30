defmodule Marshall.Terminal.Ticket do
  @moduledoc "Hashed, short-lived, single-use browser or SSH attachment authority."

  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban]

  postgres do
    table "terminal_tickets"
    repo Marshall.Repo

    custom_indexes do
      index [:expires_at]
    end
  end

  cedar do
    internal [:destroy, :read, :create, :purge, :prune]
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Terminal.Workers.PruneTickets
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:token_hash, :session_id, :actor_id, :mode, :ssh_session_id, :expires_at]
    end

    destroy :purge

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.Terminal.TicketRetention
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, allow_nil?: false, public?: true
    attribute :mode, :atom, allow_nil?: false, public?: true, constraints: [one_of: [:rw, :ro]]
    # An SSH-issued ticket (ADR-0223) is bound to the issuing Porsche
    # connection's SSH session; a browser ticket leaves it nil.
    attribute :ssh_session_id, :uuid, allow_nil?: true, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
