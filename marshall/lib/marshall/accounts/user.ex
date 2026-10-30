# @cc [owner:ghuntley,label:security] user-magic-link-browser-sign-in
# Opening a magic link in a browser MUST submit the token through the existing
# sign-in action without a second click. A plain GET MUST NOT consume the token.
# Registration and sign-in MUST share the unique case-insensitive email identity.
defmodule Marshall.Accounts.User do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshAuthentication, AshScim.User]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Marshall.Accounts.Token
      signing_secret Marshall.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      magic_link do
        identity_field :email
        registration_enabled? true
        require_interaction? true

        sender Marshall.Accounts.User.Senders.SendMagicLinkEmail
      end

      # The __Host- prefix requires Secure, Path=/ and no Domain, which the
      # strategy's cookie helper already emits; sibling *.apps.ghuntley.dev
      # origins therefore cannot plant a remembered credential on the apex.
      remember_me :remember_me do
        cookie_name :"__Host-remember_me"
      end
    end
  end

  cedar do
    control_plane "admin_accounts", [
      :invite_user,
      :delete_user,
      :reset_mfa,
      :set_administrator,
      :revoke_sessions_for_admin
    ]

    control_plane "admin_read", [:list_admin_users]
    control_plane "provision", [:security, :set_time_zone, :set_locale, :save_machine_defaults]
    record "account_self", "User", [:git_settings, :dismiss_newsletter]

    internal [
      :internal_lookup,
      :assign_administrator,
      :security_state,
      :scim_retirement_state,
      :scim_finalize,
      :store_time_zone,
      :store_locale,
      :store_machine_defaults
    ]

    service :ash_authentication, [
      :read,
      :get_by_subject,
      :get_by_email,
      :sign_in_with_remember_me,
      :sign_in_with_magic_link,
      :request_magic_link,
      :log_out_everywhere
    ]

    service :scim, [:read, :scim_read, :scim_create, :scim_update, :scim_destroy]
  end

  postgres do
    table "users"
    repo Marshall.Repo
  end

  # SCIM GET/list use :scim_read, which hides SCIM-deleted and retired
  # identities and the internal service owner (RFC 7644 section 3.6).
  scim do
    read_action :scim_read
    create_action :scim_create
    update_action :scim_update
    destroy_action :scim_destroy

    map :userName, attribute: :email
    map :externalId, attribute: :scim_external_id
    map :active, attribute: :active

    multivalued :emails do
      mirror_primary_to :email
      map :primary, value: true
      map :type, value: "work"
    end
  end

  actions do
    defaults [:read]

    read :scim_read do
      filter expr(
               is_nil(scim_deleted_at) and is_nil(deleted_at) and
                 email != "scim-service-owner@deleted.invalid"
             )
    end

    create :scim_create do
      accept [:email, :active, :scim_external_id]
      primary? true
      change {Marshall.Accounts.ScimLifecycle, mode: :create}
    end

    update :scim_update do
      accept [:email, :active, :scim_external_id]
      primary? true
      require_atomic? false
      change {Marshall.Accounts.ScimLifecycle, mode: :update}
    end

    # @cc [owner:ghuntley,label:security;recovery] scim-delete-soft-retirement
    # SCIM DELETE MUST NOT remove the row. It deactivates the identity into the
    # same grace-period retirement as active=false and hides it from SCIM reads.
    destroy :scim_destroy do
      soft? true
      require_atomic? false
      change {Marshall.Accounts.ScimLifecycle, mode: :delete}
    end

    # Internal: starts a missing grace period for an inactive SCIM identity.
    update :scim_retirement_state do
      accept [:scim_retirement_deadline]
      require_atomic? false
    end

    # Internal: the irreversible end of SCIM retirement (ScimFinalize).
    update :scim_finalize do
      accept [:deleted_at, :administrator, :active, :email, :mfa_generation, :scim_external_id]
      require_atomic? false
    end

    read :internal_lookup

    # @cc [owner:ghuntley,label:security] account-git-preferences-self-only
    # Git preferences MUST be writable only on the authenticated actor's live
    # account, with bounded validated identity fields and no owner reassignment.
    update :git_settings do
      accept [:git_username, :git_email, :commit_trailers_enabled]
      require_atomic? false
    end

    update :store_machine_defaults do
      accept [
        :launch_default_profile,
        :launch_default_image_id,
        :launch_default_vcpu,
        :launch_default_memory_bytes,
        :launch_default_disk_bytes,
        :machine_default_profile,
        :machine_default_image_id,
        :machine_default_vcpu,
        :machine_default_memory_bytes,
        :machine_default_disk_bytes,
        :thread_default_profile,
        :thread_default_image_id,
        :thread_default_vcpu,
        :thread_default_memory_bytes,
        :thread_default_disk_bytes
      ]

      require_atomic? false
    end

    update :security_state do
      accept [
        :mfa_enabled,
        :mfa_reset_required,
        :mfa_generation,
        :deleted_at,
        :email,
        :administrator
      ]

      require_atomic? false
    end

    update :store_time_zone do
      accept [:time_zone]
      require_atomic? false
      validate Marshall.Accounts.ValidTimeZone
    end

    action :set_time_zone, :map do
      argument :time_zone, :string,
        allow_nil?: true,
        constraints: [max_length: 64, trim?: true, allow_empty?: false]

      run Marshall.Accounts.Profile
    end

    update :store_locale do
      accept [:locale]
      require_atomic? false
      validate Marshall.Accounts.ValidLocale
    end

    # @cc [owner:ghuntley,label:security;product] newsletter-dismissal-self-only
    # A live account MAY dismiss its own newsletter invitation permanently;
    # input MUST NOT reset the preference or mutate another account.
    update :dismiss_newsletter do
      accept []
      require_atomic? true
      change set_attribute(:newsletter_dismissed, true)
    end

    # @cc [owner:ghuntley,label:security;protocol] locale-explicit-clear
    # Only an explicit nil MAY clear the saved locale. Empty or unsupported
    # strings MUST reach validation unchanged and refuse without a write.
    action :set_locale, :map do
      argument :locale, :string,
        allow_nil?: true,
        constraints: [max_length: 35, trim?: false, allow_empty?: true]

      run Marshall.Accounts.ProfileLocale
    end

    # @cc [owner:ghuntley,label:security;product] machine-defaults-self-only
    # Machine creation defaults MUST update only the authenticated actor's row.
    # The preset, profile, image and sizes MUST be validated by
    # Marshall.Accounts.MachineDefaults before any write; callers MUST NOT select
    # another user through an argument.
    action :save_machine_defaults, :map do
      argument :preset, :atom,
        allow_nil?: false,
        constraints: [one_of: [:launch, :machine, :thread]]

      argument :profile, :atom,
        allow_nil?: false,
        constraints: [one_of: [:standard, :oss]]

      argument :image_id, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      argument :vcpu, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 32]

      argument :memory_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :disk_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      run Marshall.Accounts.MachineDefaults
    end

    action :invite_user, :map do
      argument :email, Marshall.Accounts.EmailAddress, allow_nil?: false
      validate Marshall.Accounts.EligibleEmail
      run Marshall.Accounts.AccountLifecycle
    end

    action :delete_user, :map do
      argument :user_id, :uuid, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false, constraints: [max_length: 254]
      run Marshall.Accounts.AccountLifecycle
    end

    action :reset_mfa, :map do
      argument :user_id, :uuid, allow_nil?: false
      run Marshall.Accounts.AccountLifecycle
    end

    action :security, :map do
      argument :operation, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :status,
            :lock,
            :begin_register,
            :begin_verify,
            :finish_register,
            :finish_verify,
            :rename,
            :remove
          ]
        ]

      argument :payload, :map, default: %{}, sensitive?: true
      run Marshall.Accounts.Security
    end

    action :list_admin_users, :map do
      argument :after, :uuid
      argument :limit, :integer, default: 50, allow_nil?: false, constraints: [min: 1, max: 100]
      run Marshall.Accounts.AdminUsers
    end

    action :revoke_sessions_for_admin, :map do
      argument :user_id, :uuid, allow_nil?: false
      run Marshall.Accounts.AdminUsers
    end

    update :assign_administrator do
      accept [:administrator]
      require_atomic? false
    end

    action :set_administrator, :map do
      argument :user_id, :uuid, allow_nil?: false
      argument :administrator, :boolean, allow_nil?: false
      run Marshall.Accounts.Administrators
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    read :sign_in_with_remember_me do
      description "Resume a persistent browser credential under the account revocation lock."
      get? true
      transaction? true
      argument :token, :string, allow_nil?: false, sensitive?: true
      prepare Marshall.Accounts.RememberedLogin
      prepare AshAuthentication.Strategy.RememberMe.SignInPreparation
      metadata :token, :string, allow_nil?: false
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
        sensitive? true
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      change Marshall.Accounts.BootstrapAdministrator
      change Marshall.Accounts.RegistrationFence

      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange

      # @cc [owner:ghuntley,label:security;concurrency] magic-link-ordered-issuance
      # The authoritative issued login MUST be minted inside the fenced sign-in
      # transaction; a revocation committed after that transaction MUST include
      # it. The unfenced post-commit token minted by the strategy MUST be
      # revoked before the action returns.
      change Marshall.Accounts.MagicLinkSignIn

      # @cc [owner:ghuntley,label:security] magic-link-registration-mailbox
      # Verified token identities MUST pass bounded mailbox validation
      # before account creation/upsert, regardless of when the token was issued.
      # Email spelling MUST NOT select or replace a guest execution identity.
      validate Marshall.Accounts.EligibleEmail
      validate Marshall.Accounts.ScimMagicLinkDisabled

      change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
              strategy_name: :remember_me}

      metadata :token, :string do
        allow_nil? false
      end
    end

    action :request_magic_link do
      argument :email, Marshall.Accounts.EmailAddress do
        allow_nil? false
      end

      # @cc [owner:ghuntley,label:security] magic-link-request-mailbox
      # Requests MUST reject malformed mailboxes before token issuance or email
      # enqueue; domains and Linux-name eligibility MUST NOT restrict access.
      validate Marshall.Accounts.EligibleEmail
      validate Marshall.Accounts.ScimMagicLinkDisabled

      run AshAuthentication.Strategy.MagicLink.Request
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:security_state, :scim_finalize, :assign_administrator])]
  end

  attributes do
    uuid_primary_key :id

    attribute :git_username, Marshall.Accounts.GitUsername, allow_nil?: false, default: "Overalls"

    attribute :git_email, Marshall.Accounts.EmailAddress,
      allow_nil?: false,
      default: "noreply@overalls.dev"

    attribute :commit_trailers_enabled, :boolean, allow_nil?: false, default: true

    attribute :launch_default_profile, :atom,
      allow_nil?: false,
      default: :oss,
      constraints: [one_of: [:standard, :oss]]

    attribute :launch_default_image_id, :string,
      allow_nil?: true,
      constraints: [max_length: 128]

    attribute :launch_default_vcpu, :integer, allow_nil?: true, constraints: [min: 1, max: 32]
    attribute :launch_default_memory_bytes, :integer, allow_nil?: true, constraints: [min: 1]
    attribute :launch_default_disk_bytes, :integer, allow_nil?: true, constraints: [min: 1]

    attribute :machine_default_profile, :atom,
      allow_nil?: false,
      default: :standard,
      constraints: [one_of: [:standard, :oss]]

    attribute :machine_default_image_id, :string,
      allow_nil?: true,
      constraints: [max_length: 128]

    attribute :machine_default_vcpu, :integer, allow_nil?: true, constraints: [min: 1, max: 32]
    attribute :machine_default_memory_bytes, :integer, allow_nil?: true, constraints: [min: 1]
    attribute :machine_default_disk_bytes, :integer, allow_nil?: true, constraints: [min: 1]

    attribute :thread_default_profile, :atom,
      allow_nil?: false,
      default: :standard,
      constraints: [one_of: [:standard, :oss]]

    attribute :thread_default_image_id, :string,
      allow_nil?: true,
      constraints: [max_length: 128]

    attribute :thread_default_vcpu, :integer, allow_nil?: true, constraints: [min: 1, max: 32]
    attribute :thread_default_memory_bytes, :integer, allow_nil?: true, constraints: [min: 1]
    attribute :thread_default_disk_bytes, :integer, allow_nil?: true, constraints: [min: 1]

    attribute :mfa_enabled, :boolean, allow_nil?: false, default: false
    attribute :mfa_reset_required, :boolean, allow_nil?: false, default: false
    attribute :mfa_generation, :integer, allow_nil?: false, default: 0
    attribute :deleted_at, :utc_datetime_usec

    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :scim_external_id, :string, allow_nil?: true, public?: true
    attribute :scim_retirement_deadline, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :scim_deleted_at, :utc_datetime_usec, allow_nil?: true, public?: false

    attribute :administrator, :boolean, allow_nil?: false, default: false

    # Display preference only (ADR-0195): storage stays UTC and this never
    # enters authorization. Nil means "not saved"; the browser zone is used.
    attribute :time_zone, :string,
      allow_nil?: true,
      public?: false,
      constraints: [max_length: 64, allow_empty?: false]

    # Nil follows the browser; a stored locale is a display preference only.
    attribute :locale, :string,
      allow_nil?: true,
      public?: false,
      constraints: [max_length: 35, allow_empty?: false]

    attribute :newsletter_dismissed, :boolean,
      allow_nil?: false,
      public?: false,
      default: false

    attribute :email, Marshall.Accounts.EmailAddress do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
