defmodule Marshall.Notifications.InstallIdentity do
  @moduledoc """
  This deployment's Ed25519 install identity (ADR-0224, ADR-0225).

  Generated once, on first need, and kept as a single row whose seed is
  encrypted with `Marshall.Vault` like every other Marshall credential. Susan
  uses the public key to apply per-install limits without any signup; the
  seed never leaves this process except as signatures.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak]

  @type t :: %__MODULE__{}

  postgres do
    table "notification_install_identities"
    repo Marshall.Repo

    check_constraints do
      check_constraint :singleton, "notification_install_identity_singleton",
        check: "singleton = true"
    end
  end

  cedar do
    internal [:read, :generate]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:seed])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  actions do
    defaults [:read]

    create :generate do
      accept [:seed, :public_key]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :singleton, :boolean, allow_nil?: false, default: true

    attribute :seed, :binary, allow_nil?: false, sensitive?: true

    # Base64url raw Ed25519 public key, the `overalls-install-key` header value.
    attribute :public_key, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[A-Za-z0-9_-]{43}\z/]

    create_timestamp :inserted_at
  end

  identities do
    identity :singleton, [:singleton]
  end
end
