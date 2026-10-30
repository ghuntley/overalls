defmodule Marshall.Ingress.Relay do
  @moduledoc "Single-use one-hop connection handoff with independently renewed execution authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "ingress_relays"
    repo Marshall.Repo

    check_constraints do
      check_constraint :origin_host_id, "ingress_relay_distinct_hosts",
        check: "origin_host_id <> destination_host_id"

      check_constraint :token_hash, "ingress_relay_hashes",
        check: "octet_length(token_hash) = 32 AND octet_length(stream_token_hash) = 32"
    end

    custom_indexes do
      index [:origin_service_id, :stream_token_hash], unique: true
      index [:expires_at, :id]
    end
  end

  # @cc [owner:ghuntley,label:security;persistence] ingress-relay-handoff-binding
  # Only hashes of the relay capability and inner stream ticket may persist.
  # The immutable binding MUST name one source, destination and exact stream;
  # consume may happen once, and renewal may change only its expiry.
  cedar do
    internal [:read, :record, :consume, :renew, :purge, :consume_connection, :renew_connection]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :token_hash,
        :stream_token_hash,
        :origin_service_id,
        :origin_service_generation,
        :destination_service_id,
        :destination_service_generation,
        :origin_host_id,
        :destination_host_id,
        :origin_address,
        :destination_address,
        :destination_port,
        :purpose,
        :binding,
        :consume_by,
        :expires_at
      ]
    end

    update :consume do
      accept [:consumed_at]
    end

    update :renew do
      accept [:expires_at]
    end

    destroy :purge

    for action <- [:consume_connection, :renew_connection] do
      action action, :map do
        argument :service_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :capability, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :ticket, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :purpose, :atom, allow_nil?: false, constraints: [one_of: [:ssh, :web, :editor]]
        argument :peer_address, :string, allow_nil?: false, constraints: [max_length: 13]
        run {Marshall.Ingress.Relays, operation: action}
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :stream_token_hash, :binary, allow_nil?: false, sensitive?: true

    for name <- [
          :origin_service_id,
          :destination_service_id,
          :origin_host_id,
          :destination_host_id
        ] do
      attribute name, :uuid, allow_nil?: false
    end

    for name <- [:origin_service_generation, :destination_service_generation] do
      attribute name, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :origin_address, :string, allow_nil?: false
    attribute :destination_address, :string, allow_nil?: false
    attribute :destination_port, :integer, allow_nil?: false, constraints: [min: 1, max: 65_535]
    attribute :purpose, :atom, allow_nil?: false, constraints: [one_of: [:ssh, :web, :editor]]
    attribute :binding, :map, allow_nil?: false
    attribute :consume_by, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :consumed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
