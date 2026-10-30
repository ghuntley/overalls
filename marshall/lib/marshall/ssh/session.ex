defmodule Marshall.SSH.Session do
  @moduledoc "A gateway-bound SSH connection; expiry and key identity are durable."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban]

  postgres do
    table "ssh_sessions"
    repo Marshall.Repo

    custom_indexes do
      index [:gateway_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  cedar do
    control_plane "admin_accounts", [:revoke_for_admin]
    control_plane "admin_read", [:list_for_admin]

    internal [
      :read,
      :record,
      :approve,
      :close,
      :purge,
      :prune,
      :open_session,
      :session_status,
      :close_session,
      :watch_subscribe
    ]
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.SSH.Workers.PruneSessions
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:token_hash, :gateway_id, :gateway_generation, :key_id, :expires_at]
    end

    update :approve do
      accept [:key_id, :expires_at]
    end

    update :close do
      accept [:closed_at]
    end

    destroy :purge

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.SSH.Retention
    end

    action :open_session, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :public_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      run {Marshall.SSH.Authority, operation: :open}
    end

    action :session_status, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.SSH.Authority, operation: :status}
    end

    action :close_session, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.SSH.Authority, operation: :close}
    end

    action :watch_subscribe, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :machines, {:array, :string},
        allow_nil?: false,
        constraints: [max_length: 16, items: [min_length: 1, max_length: 63]]

      argument :threads, {:array, :uuid}, allow_nil?: false, constraints: [max_length: 16]
      run Marshall.SSH.Watch
    end

    action :list_for_admin, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run {Marshall.SSH.AdminActions, operation: :list_sessions}
    end

    action :revoke_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.SSH.AdminActions, operation: :revoke_session}
    end
  end

  # @cc [owner:ghuntley,label:protocol;security] ssh-session-change-hint
  # Approval and closure MUST emit an `:ssh_session` hint carrying only the
  # session UUID, delivered on commit, so `watch --session` learns of approval
  # without polling. Porsche re-reads the session status; the hint grants nothing.
  #
  # A closed or revoked session also wakes its attached gateway terminal
  # streams at once (ADR-0223); their recheck is the backstop.
  changes do
    change {Marshall.Control.Hints.Change, kind: :ssh_session, from: :id},
      on: [:update],
      where: [action_is([:approve, :close])]
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :gateway_generation, :integer, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :gateway, Marshall.SSH.Gateway, allow_nil?: false
    belongs_to :key, Marshall.SSH.Key
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
