defmodule Marshall.Scim.Configuration do
  @moduledoc "Singleton SCIM configuration with closed enable/disable transitions."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Scim,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshArchival.Resource]

  postgres do
    table "scim_configurations"
    repo Marshall.Repo
  end

  cedar do
    control_plane "admin_accounts", [:configure]
    internal [:read, :create, :enable, :disable, :rotate_token, :save_oidc]
  end

  state_machine do
    initial_states [:disabled]
    default_initial_state :disabled

    transitions do
      transition :enable, from: [:disabled], to: :enabled
      transition :disable, from: [:enabled], to: :disabled
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :token_digest,
        :state,
        :enabled_at,
        :oidc_issuer,
        :oidc_client_id,
        :oidc_client_secret
      ]
    end

    update :enable do
      accept []
      change transition_state(:enabled)
      require_atomic? false
    end

    update :disable do
      accept []
      change transition_state(:disabled)
      require_atomic? false
    end

    update :rotate_token do
      accept [:token_digest]
      require_atomic? false
    end

    update :save_oidc do
      accept [:oidc_issuer, :oidc_client_id, :oidc_client_secret]
      require_atomic? false
    end

    # One administrator operation per submission: enabling and rotating each
    # return a new bearer token once; disabling and saving OIDC settings never
    # mint a token. An empty client secret keeps the stored secret unless
    # clear_oidc_client_secret is true.
    action :configure, :map do
      argument :operation, :atom,
        allow_nil?: false,
        constraints: [one_of: [:enable, :disable, :rotate_token, :save_oidc]]

      argument :oidc_issuer, :string,
        allow_nil?: true,
        constraints: [max_length: 2048, allow_empty?: true]

      argument :oidc_client_id, :string,
        allow_nil?: true,
        constraints: [max_length: 512, allow_empty?: true]

      argument :oidc_client_secret, :string,
        allow_nil?: true,
        sensitive?: true,
        constraints: [max_length: 4096, allow_empty?: true]

      argument :clear_oidc_client_secret, :boolean, allow_nil?: false, default: false
      run Marshall.Scim.ConfigurationActions
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:disabled, :enabled]]

    attribute :key, :string, allow_nil?: false, default: "installation"
    attribute :token_digest, :string, allow_nil?: true, sensitive?: true
    attribute :oidc_issuer, :string, allow_nil?: true
    attribute :oidc_client_id, :string, allow_nil?: true
    attribute :oidc_client_secret, :string, allow_nil?: true, sensitive?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
    attribute :enabled_at, :utc_datetime_usec
  end

  identities do
    identity :singleton, [:key]
  end
end
