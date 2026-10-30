defmodule Marshall.Authorization.Principal do
  @moduledoc """
  The persisted Cedar principal for a user, loaded in one internal query.

  This is authorization infrastructure: it reads account, login, verification
  and passkey rows directly rather than through authorized Ash actions, so that
  establishing a principal never itself requires an authorization decision.
  """
  alias Marshall.Repo

  @elevation_seconds 900

  @type t :: %__MODULE__{
          id: String.t(),
          administrator: boolean(),
          elevated: boolean(),
          active: boolean(),
          login: :present | :absent | :none
        }
  @enforce_keys [:id, :administrator, :elevated, :active, :login]
  defstruct @enforce_keys

  # @cc [owner:ghuntley,label:security] principal-single-query
  # One statement MUST decide, against database time: the user exists and is not
  # deleted; whether the presented login JTI names a current user-purpose token
  # for this subject; and elevation, which requires that login, an active user
  # without a pending MFA reset, a verification for this JTI and user at the
  # current MFA generation that is fresh within the bounded elevation window, and
  # that verification's passkey still belonging to the user. Administrator comes
  # only from the persisted row. A missing or deleted user returns nil.
  @spec load(String.t(), String.t() | nil) :: t() | nil
  def load(user_id, jti) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH now AS (SELECT clock_timestamp() AT TIME ZONE 'UTC' AS at)
        SELECT u.administrator,
               u.active,
               t.jti IS NOT NULL AS login_present,
               (t.jti IS NOT NULL AND u.active AND NOT u.mfa_reset_required
                 AND v.generation = u.mfa_generation
                 AND v.verified_at <= now.at AND now.at < v.elevated_until
                 AND v.elevated_until - v.verified_at <= make_interval(secs => $3)
                 AND p.id IS NOT NULL) AS elevated
        FROM users u
        CROSS JOIN now
        LEFT JOIN tokens t
          ON $2::text IS NOT NULL AND t.jti = $2 AND t.purpose = 'user'
         AND t.subject = 'user?id=' || u.id::text AND t.expires_at > now.at
        LEFT JOIN account_verifications v ON v.id = $2 AND v.user_id = u.id
        LEFT JOIN account_passkeys p ON p.id = v.credential_id AND p.user_id = u.id
        WHERE u.id = $1 AND u.deleted_at IS NULL
        """,
        [Ecto.UUID.dump!(user_id), jti, @elevation_seconds],
        log: false
      )

    case rows do
      [[administrator, active, login_present, elevated]] ->
        %__MODULE__{
          id: user_id,
          administrator: administrator,
          active: active,
          elevated: elevated == true,
          login:
            cond do
              is_nil(jti) -> :none
              login_present -> :present
              true -> :absent
            end
        }

      [] ->
        nil
    end
  end
end
