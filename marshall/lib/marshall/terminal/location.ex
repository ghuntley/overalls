defmodule Marshall.Terminal.Location do
  @moduledoc "Expiring host-stream routing metadata; never carries terminal data."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "terminal_stream_locations"
    repo Marshall.Repo
  end

  cedar do
    internal [:destroy, :read, :publish, :renew]
  end

  actions do
    defaults [:read, :destroy]

    create :publish do
      primary? true
      accept [:host_id, :nonce, :uri, :expires_at]
      upsert? true
      upsert_fields [:nonce, :uri, :expires_at]
    end

    update :renew do
      accept [:expires_at]
    end
  end

  attributes do
    attribute :host_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :nonce, :uuid, allow_nil?: false
    attribute :uri, :string, allow_nil?: false, constraints: [max_length: 512]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
  end
end
