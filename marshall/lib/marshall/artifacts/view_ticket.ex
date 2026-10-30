defmodule Marshall.Artifacts.ViewTicket do
  @moduledoc "A five-minute, single-version capability to fetch content on the content origin."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  # @cc [owner:ghuntley,label:security] artifact-view-ticket
  # Only the SHA-256 of a ticket is stored. A ticket is bound to one artifact,
  # version, user and content host, is valid for five minutes while `issued`,
  # and moves only to `expired` or `revoked`. Every fetch MUST still recheck
  # Cedar read and that the artifact is active.
  postgres do
    table "artifact_view_tickets"
    repo Marshall.Repo

    references do
      reference :artifact, on_delete: :delete
    end

    custom_indexes do
      index [:token_hash], unique: true
      index [:artifact_id, :state]
      index [:state, :expires_at]
    end
  end

  cedar do
    internal [:destroy, :read, :issue, :expire, :revoke]
  end

  state_machine do
    initial_states [:issued]
    default_initial_state :issued

    transitions do
      transition :expire, from: [:issued], to: :expired
      transition :revoke, from: [:issued], to: :revoked
    end
  end

  actions do
    defaults [:read, :destroy]

    create :issue do
      accept [:token_hash, :artifact_id, :version_number, :user_id, :content_host, :expires_at]
    end

    update :expire do
      accept []
      change transition_state(:expired)
    end

    update :revoke do
      accept []
      change transition_state(:revoked)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :version_number, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :user_id, :uuid, allow_nil?: false
    attribute :content_host, :string, allow_nil?: false, constraints: [max_length: 253]

    attribute :state, :atom,
      allow_nil?: false,
      default: :issued,
      constraints: [one_of: [:issued, :expired, :revoked]]

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true
  end
end
