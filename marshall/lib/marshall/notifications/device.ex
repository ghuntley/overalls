defmodule Marshall.Notifications.Device do
  @moduledoc """
  A Mila installation registered for content-free push pokes (ADR-0225).

  A device belongs to one user and is bound to the SSH key whose session
  registered it. It stores Susan's opaque push key encrypted with
  `Marshall.Vault`, the device's X25519 public key that pokes are sealed to,
  and the user's on/off preference. It never stores provider tokens, prompts
  or decrypted payloads.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshPaperTrail.Resource, AshStateMachine]

  @type t :: %__MODULE__{}
  @type state :: :pending | :active | :invalidated | :revoked
  @type platform :: :ios | :android | :macos | :windows

  @live_states [:pending, :active]

  # macOS shares APNs with iOS and Windows uses WNS (ADR-0235, ADR-0236); the
  # platform is what the device reported, the provider is sealed in its push key.
  @platforms [:ios, :android, :macos, :windows]

  @doc "States in which a device may still receive pokes or be refreshed."
  @spec live_states() :: [state()]
  def live_states, do: @live_states

  postgres do
    table "notification_devices"
    repo Marshall.Repo

    identity_wheres_to_sql live_device_key: "state IN ('pending', 'active')"

    custom_indexes do
      index [:user_id, :state]
      index [:key_id], where: "state IN ('pending', 'active')"
    end

    check_constraints do
      check_constraint :enc_public_key, "notification_device_x25519_key",
        check: "octet_length(enc_public_key) = 32"

      check_constraint :state, "notification_device_terminal_receipt",
        check: "(state IN ('pending', 'active')) = (finished_at IS NULL)"
    end

    references do
      reference :user, on_delete: :restrict
      reference :key, on_delete: :restrict
    end
  end

  cedar do
    control_plane "provision", [
      :register_for_user,
      :list_for_user,
      :remove_for_user,
      :set_preference_for_user
    ]

    internal [
      :read,
      :history,
      :register,
      :activate,
      :refresh,
      :set_preference,
      :invalidate,
      :revoke
    ]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:push_key])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  # @cc [owner:ghuntley,label:security;persistence] notification-device-digest-audit
  # Device versions MUST record state, preference and binding changes with the
  # push-key digest only: the push key (plain or encrypted) and the device's
  # public key MUST NOT enter audit versions or diagnostics.
  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    change_tracking_mode :changes_only
    store_action_name? true

    ignore_attributes [
      :push_key,
      :encrypted_push_key,
      :enc_public_key,
      :label,
      :inserted_at,
      :updated_at
    ]

    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  # @cc [owner:ghuntley,label:security;recovery] notification-device-lifecycle
  # Only named transitions may change state. invalidated and revoked are
  # terminal: a provider-unregistered or revoked device MUST NOT become active
  # again; re-registration creates a new device row.
  state_machine do
    state_attribute :state
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :activate, from: :pending, to: :active
      transition :refresh, from: :active, to: :active
      transition :invalidate, from: [:pending, :active], to: :invalidated
      transition :revoke, from: [:pending, :active, :invalidated], to: :revoked
    end
  end

  actions do
    defaults [:read]
    read :history

    create :register do
      accept [:user_id, :key_id, :platform, :push_key, :push_key_digest, :enc_public_key, :label]
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :refresh do
      accept [:key_id, :push_key, :push_key_digest, :label, :platform]
      change transition_state(:active)
    end

    update :set_preference do
      accept [:enabled]
    end

    update :invalidate do
      accept [:finished_at]
      change set_attribute(:state_reason, :provider_unregistered)
      change transition_state(:invalidated)
    end

    update :revoke do
      accept [:state_reason, :finished_at]
      change transition_state(:revoked)
    end

    action :register_for_user, :map do
      argument :platform, :atom, allow_nil?: false, constraints: [one_of: @platforms]
      argument :push_key, :string, allow_nil?: false, sensitive?: true
      argument :enc_public_key, :string, allow_nil?: false
      argument :label, :string, constraints: [max_length: 64]
      argument :key_id, :uuid, allow_nil?: false
      run {Marshall.Notifications.DeviceActions, operation: :register}
    end

    action :list_for_user, :map do
      run {Marshall.Notifications.DeviceActions, operation: :list}
    end

    action :remove_for_user, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.Notifications.DeviceActions, operation: :remove}
    end

    action :set_preference_for_user, :map do
      argument :id, :uuid, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false
      run {Marshall.Notifications.DeviceActions, operation: :preference}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :platform, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @platforms]

    attribute :push_key, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 16, max_length: 700, trim?: false]

    # First 16 hex characters of SHA-256 over the push key: replay comparison
    # and audit identity without retaining the key itself.
    attribute :push_key_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{16}\z/]

    attribute :enc_public_key, :binary, allow_nil?: false, sensitive?: true
    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true
    attribute :label, :string, constraints: [max_length: 64], public?: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :active, :invalidated, :revoked]]

    attribute :state_reason, :atom,
      public?: true,
      constraints: [one_of: [:removed, :key_revoked, :account_retired, :provider_unregistered]]

    attribute :finished_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User do
      domain Marshall.Accounts
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :key, Marshall.SSH.Key do
      domain Marshall.SSH
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :live_device_key, [:user_id, :enc_public_key],
      where: expr(state in [:pending, :active])
  end
end
