defmodule Marshall.Accounts.GuestAccount do
  @moduledoc "Never-reused Linux guest identity for one Marshall User UUID."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "account_guest_accounts"
    repo Marshall.Repo
    identity_wheres_to_sql current_user: "retired_at IS NULL"

    check_constraints do
      check_constraint :username, "account_guest_accounts_username_uid",
        check: "username = 'u' || uid::text"
    end
  end

  cedar do
    internal [:read, :allocate, :retire]
  end

  paper_trail do
    sensitive_attributes :ignore
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    change_tracking_mode :changes_only
    store_action_name? true
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :allocate do
      accept [:user_id, :username, :uid]
    end

    update :retire do
      accept [:retired_at]
    end
  end

  attributes do
    uuid_primary_key :id
    # @cc [owner:ghuntley,label:persistence;security] guest-identity-canonical-name
    # Every current or retired account MUST retain its UUID and UID forever.
    # The stored login MUST equal u followed by its UID, enforced by PostgreSQL;
    # email changes MUST NOT replace the identity or alter its guest home.
    attribute :username, :string, allow_nil?: false, constraints: [max_length: 32]

    attribute :uid, :integer,
      allow_nil?: false,
      constraints: [min: 200_000, max: 999_999]

    attribute :retired_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :username_never_reused, [:username]
    identity :uid_never_reused, [:uid]
    identity :current_user, [:user_id], where: expr(is_nil(retired_at))
  end
end
