defmodule Marshall.Accounts.Security do
  @moduledoc "Session-bound passkey ceremonies and current database-backed elevation."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{User, Login, Passkey, PasskeyChallenge, Verification, AdminEvent}
  alias Marshall.Compute.Ledger
  alias Marshall.Authorization.SystemActor
  alias AshAuthentication.Strategy.WebAuthn
  require Ash.Query
  require Marshall.Events

  @email_proof_seconds 300
  @elevation_seconds 900

  @spec bind(User.t(), String.t()) :: User.t()
  def bind(user, jti), do: Ash.Resource.put_metadata(user, :login_jti, jti)

  @spec jti(term()) :: String.t() | nil
  def jti(%User{} = user), do: user.__metadata__[:login_jti]
  def jti(_), do: nil

  @spec current(String.t()) :: User.t() | nil
  def current(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
  end

  @spec primary(User.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def primary(user, token_id) do
    Ledger.transaction(fn ->
      user = lock_user!(user.id)

      unless proof(token_id, user.id) do
        Ledger.create!(Verification, :record, %{
          id: token_id,
          user_id: user.id,
          generation: user.mfa_generation,
          primary_at: Ledger.now()
        })
      end
    end)
  end

  @doc "Whether this login has a current retained passkey verification receipt."
  @spec passkey_verified?(String.t() | nil, String.t()) :: boolean()
  def passkey_verified?(token_id, user_id) do
    case current(user_id) do
      %User{deleted_at: nil, active: true} = user ->
        case proof(token_id, user_id) do
          %Verification{verified_at: %DateTime{}, generation: generation, credential_id: key_id} ->
            generation == user.mfa_generation and
              match?([%Passkey{}], Ledger.read!(Passkey, id: key_id, user_id: user_id))

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # @cc [owner:ghuntley,label:security] elevation-fixed-session-deadline
  # Elevation MUST bind a live stored login, current account generation and a
  # retained credential. Database time at each call decides expiry; activity and
  # token renewal MUST NOT extend the fixed fifteen-minute window.
  @spec recent?(term()) :: boolean()
  def recent?(%User{} = actor) do
    with token_id when is_binary(token_id) <- jti(actor),
         {:ok, _} <- Login.token_present(token_id, actor.id),
         %User{deleted_at: nil, active: true, mfa_reset_required: false} = user <-
           current(actor.id),
         %Verification{} = verification <- proof(token_id, user.id),
         true <- verification.generation == user.mfa_generation,
         true <-
           elevation_fresh?(verification.verified_at, verification.elevated_until, Ledger.now()),
         [%Passkey{user_id: id}] <- Ledger.read!(Passkey, id: verification.credential_id),
         true <- id == user.id do
      true
    else
      _ -> false
    end
  end

  def recent?(_), do: false

  @spec elevated_until(User.t()) :: DateTime.t() | nil
  def elevated_until(actor) do
    if recent?(actor), do: proof(jti(actor), actor.id).elevated_until
  end

  @spec elevation_fresh?(DateTime.t() | nil, DateTime.t() | nil, DateTime.t()) :: boolean()
  def elevation_fresh?(%DateTime{} = verified, %DateTime{} = expiry, now),
    do:
      DateTime.compare(verified, now) != :gt and DateTime.compare(now, expiry) == :lt and
        DateTime.diff(expiry, verified, :microsecond) <= @elevation_seconds * 1_000_000

  def elevation_fresh?(_, _, _), do: false

  @spec email_fresh?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def email_fresh?(%DateTime{} = primary, now),
    do:
      DateTime.compare(primary, now) != :gt and
        DateTime.diff(now, primary, :microsecond) <= @email_proof_seconds * 1_000_000

  def email_fresh?(_, _), do: false

  @spec require_admin!(User.t()) :: :ok
  def require_admin!(actor) do
    unless Marshall.Authorization.control_plane?(actor, "admin_accounts"),
      do: Ledger.rollback(:mfa_required)

    :ok
  end

  @impl true
  def run(input, _, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(fn ->
        user = lock_user!(actor.id)
        token_id = jti(actor)

        unless is_binary(token_id) and match?({:ok, _}, Login.token_present(token_id, user.id)),
          do: Ledger.rollback(:unauthorized)

        perform(input.arguments.operation, input.arguments.payload, bind(user, token_id))
      end)

    with {:ok, {outcome, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit_event(event)
      {:ok, outcome}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp perform(:status, _, actor) do
    keys = credentials(actor.id)
    verification = proof(jti(actor), actor.id)

    {%{
       credentials: Enum.map(keys, &Map.take(&1, [:id, :label, :inserted_at])),
       enabled: actor.mfa_enabled,
       reset_required: actor.mfa_reset_required,
       verified: passkey_verified?(jti(actor), actor.id),
       recent: recent?(actor),
       expires_at: verification && verification.elevated_until
     }, nil}
  end

  defp perform(:lock, _, actor) do
    if verification = proof(jti(actor), actor.id),
      do: Ledger.update!(verification, :verify, %{elevated_until: nil})

    {%{locked: true}, {:mfa_locked, actor.id}}
  end

  defp perform(:begin_register, _, actor) do
    enrollment!(actor)
    keys = credentials(actor.id)
    if length(keys) >= 10, do: Ledger.rollback(:credential_limit)
    challenge = challenge!(actor, :register)

    %{
      id: challenge.id,
      publicKey: %{
        challenge: encode(challenge.bytes),
        rp: %{id: rp_id(), name: "Overalls"},
        user: %{
          id: encode(actor.id),
          name: to_string(actor.email),
          displayName: to_string(actor.email)
        },
        pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}],
        timeout: 60_000,
        attestation: "none",
        authenticatorSelection: %{userVerification: "required", residentKey: "preferred"},
        excludeCredentials: Enum.map(keys, &%{type: "public-key", id: encode(&1.credential_id)})
      }
    }
  end

  defp perform(:begin_verify, _, actor) do
    keys = credentials(actor.id)
    if keys == [], do: Ledger.rollback(:enrollment_required)
    challenge = challenge!(actor, :verify)

    %{
      id: challenge.id,
      publicKey: %{
        challenge: encode(challenge.bytes),
        rpId: rp_id(),
        timeout: 60_000,
        userVerification: "required",
        allowCredentials: Enum.map(keys, &%{type: "public-key", id: encode(&1.credential_id)})
      }
    }
  end

  defp perform(:finish_register, payload, actor) do
    enrollment!(actor)
    if length(credentials(actor.id)) >= 10, do: Ledger.rollback(:credential_limit)
    challenge = consume!(payload["id"], actor, :register)
    params = Map.take(payload, ["attestation_object", "client_data_json", "label"])

    result =
      with {:ok, _} <- decode(params["attestation_object"]),
           {:ok, _} <- decode(params["client_data_json"]) do
        ceremony(fn ->
          WebAuthn.Actions.add_credential(strategy(), params,
            challenge: wax(challenge),
            user: actor
          )
        end)
      end

    case result do
      {:ok, key} ->
        Ledger.update!(actor, :security_state, %{mfa_enabled: true, mfa_reset_required: false})
        audit!(actor.id, key.id, :passkey_add)
        {%{registered: true}, {:passkey_registered, actor.id}}

      _ ->
        {%{error: "Passkey registration failed. Try again."},
         {:passkey_verify_failed, actor.id, :registration_failed}}
    end
  end

  defp perform(:finish_verify, payload, actor) do
    challenge = consume!(payload["id"], actor, :verify)

    with {:ok, raw_id} <- decode(payload["raw_id"]),
         %Passkey{} = key <- Enum.find(credentials(actor.id), &(&1.credential_id == raw_id)),
         {:ok, auth_data} <- decode(payload["authenticator_data"]),
         {:ok, signature} <- decode(payload["signature"]),
         {:ok, client_data} <- decode(payload["client_data_json"]),
         {:ok, result} <-
           ceremony(fn ->
             Wax.authenticate(raw_id, auth_data, signature, client_data, wax(challenge), [
               {raw_id, key.public_key}
             ])
           end),
         true <-
           key.sign_count == 0 or result.sign_count == 0 or result.sign_count > key.sign_count do
      Ledger.update!(key, :update, %{sign_count: result.sign_count})
      now = Ledger.now()

      attrs = %{
        generation: actor.mfa_generation,
        verified_at: now,
        elevated_until: DateTime.add(now, @elevation_seconds),
        credential_id: key.id
      }

      case proof(jti(actor), actor.id) do
        nil ->
          Ledger.create!(
            Verification,
            :record,
            Map.merge(attrs, %{id: jti(actor), user_id: actor.id})
          )

        verification ->
          Ledger.update!(verification, :verify, attrs)
      end

      audit!(actor.id, actor.id, :mfa_verify)

      {%{verified: true, expires_at: DateTime.add(now, @elevation_seconds)},
       {:passkey_verified, actor.id}}
    else
      _ ->
        {%{error: "Passkey verification failed. Try again."},
         {:passkey_verify_failed, actor.id, :verification_failed}}
    end
  end

  defp perform(operation, payload, actor) when operation in [:rename, :remove] do
    unless recent?(actor), do: Ledger.rollback(:mfa_required)
    keys = credentials(actor.id)
    key = Enum.find(keys, &(&1.id == payload["id"])) || Ledger.rollback(:unknown_credential)

    event =
      if operation == :rename do
        label = payload["label"]
        unless valid_label?(label), do: Ledger.rollback(:invalid_label)
        Ledger.update!(key, :update, %{label: label})
        nil
      else
        if length(keys) == 1 and actor.administrator, do: Ledger.rollback(:last_admin_passkey)
        Ledger.archive!(key, :destroy)

        if length(keys) == 1 do
          Ledger.update!(actor, :security_state, %{
            mfa_enabled: false,
            mfa_generation: actor.mfa_generation + 1
          })

          Marshall.Accounts.AccountLifecycle.revoke_tokens!(actor.id)
        end

        audit!(actor.id, key.id, :passkey_remove)
        {:passkey_removed, actor.id, actor.id}
      end

    {%{updated: true}, event}
  end

  # @cc [owner:ghuntley,label:security] passkey-label-closed-refusal
  # A rename label MUST be validated before any credential write: a missing,
  # non-binary, blank-only or over-80-grapheme label is a closed refusal that
  # rolls the transaction back and MUST NOT raise the Ash constraint error out
  # of the action. Stored values keep the resource's trimming and length rule.
  @spec valid_label?(term()) :: boolean()
  defp valid_label?(label) when is_binary(label) do
    trimmed = String.trim(label)
    trimmed != "" and String.length(trimmed) <= 80
  end

  defp valid_label?(_), do: false

  defp enrollment!(actor) do
    if credentials(actor.id) == [] do
      case proof(jti(actor), actor.id) do
        %Verification{primary_at: %DateTime{} = primary} ->
          unless email_fresh?(primary, Ledger.now()),
            do: Ledger.rollback(:fresh_email_required)

        _ ->
          Ledger.rollback(:fresh_email_required)
      end
    else
      unless recent?(actor), do: Ledger.rollback(:mfa_required)
    end
  end

  defp challenge!(actor, purpose) do
    # Bound both outstanding challenges and retained history per account.
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "DELETE FROM account_passkey_challenges WHERE user_id = $1 AND expires_at <= clock_timestamp()",
      [Ecto.UUID.dump!(actor.id)],
      log: false
    )

    if length(Ledger.read!(PasskeyChallenge, user_id: actor.id)) >= 10,
      do: Ledger.rollback(:try_later)

    Ledger.create!(PasskeyChallenge, :record, %{
      user_id: actor.id,
      login_jti: jti(actor),
      generation: actor.mfa_generation,
      purpose: purpose,
      bytes: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.add(Ledger.now(), 60)
    })
  end

  # @cc [owner:ghuntley,label:security;concurrency] passkey-consumption
  # Challenge consumption MUST serialize across nodes, bind user/login/purpose
  # and generation, and commit even on a failed cryptographic assertion.
  defp consume!(id, actor, purpose) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Ledger.rollback(:invalid_challenge)
    challenge = Ledger.lock!(PasskeyChallenge, id) || Ledger.rollback(:invalid_challenge)

    unless challenge.user_id == actor.id and challenge.login_jti == jti(actor) and
             challenge.generation == actor.mfa_generation and challenge.purpose == purpose and
             is_nil(challenge.consumed_at) and
             DateTime.compare(challenge.expires_at, Ledger.now()) == :gt,
           do: Ledger.rollback(:invalid_challenge)

    Ledger.update!(challenge, :consume, %{consumed_at: Ledger.now()})
  end

  # Malformed authenticator CBOR may raise in the upstream decoder. Convert it
  # inside the transaction so the consumed challenge cannot be replayed.
  defp ceremony(function) do
    function.()
  rescue
    _ -> {:error, :invalid_webauthn}
  end

  defp wax(challenge) do
    # PostgreSQL already enforces the deadline, including after cross-node failover.
    options = [origin: origin(), rp_id: rp_id(), user_verification: "required", timeout: 60]

    wax =
      if challenge.purpose == :register,
        do: Wax.new_registration_challenge(options),
        else: Wax.new_authentication_challenge(options)

    %{wax | bytes: challenge.bytes}
  end

  defp strategy,
    do: %WebAuthn{
      resource: User,
      credential_resource: Passkey,
      rp_id: rp_id(),
      rp_name: "Overalls",
      origin: origin(),
      user_verification: "required"
    }

  defp origin, do: MarshallWeb.Endpoint.url()
  defp rp_id, do: URI.parse(origin()).host
  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode(value) when is_binary(value) and byte_size(value) <= 65_536,
    do: Base.url_decode64(value, padding: false)

  defp decode(_), do: :error
  defp credentials(id), do: Ledger.read!(Passkey, user_id: id)
  defp proof(nil, _), do: nil

  defp proof(token_id, user_id),
    do: List.first(Ledger.read!(Verification, id: token_id, user_id: user_id))

  # @cc [owner:ghuntley,label:security;concurrency] account-participant-lock-order
  # Account administration MUST lock unique actor/target IDs in sorted order.
  # Actor-only locks MUST exclude authority changes but permit foreign-key
  # references from unrelated team work. The target MUST retain FOR UPDATE before
  # dependent locks or writes, avoiding a later key-change upgrade. Callers MUST
  # validate missing/retired rows; locking never establishes live identity.
  @spec lock_admin_participants!(String.t(), String.t()) :: %{String.t() => User.t() | nil}
  def lock_admin_participants!(actor_id, target_id) do
    [actor_id, target_id]
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn id ->
      mode = if id == target_id, do: "FOR UPDATE", else: "FOR NO KEY UPDATE"

      user =
        User
        |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.lock(mode)
        |> Ash.read_one!()

      {id, user}
    end)
  end

  @spec lock_user!(String.t()) :: User.t()
  def lock_user!(id) do
    user =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!()

    unless (user && is_nil(user.deleted_at)) and user.active, do: Ledger.rollback(:unauthorized)
    user
  end

  @spec audit!(String.t(), String.t(), atom()) :: AdminEvent.t()
  def audit!(actor_id, target_id, kind),
    do:
      Ledger.create!(AdminEvent, :record, %{actor_id: actor_id, target_id: target_id, kind: kind})

  defp emit_event({:passkey_registered, user_id}),
    do: Marshall.Events.emit("passkey.registered", user_id: user_id)

  defp emit_event({:passkey_verified, user_id}),
    do: Marshall.Events.emit("passkey.verified", user_id: user_id)

  defp emit_event({:passkey_verify_failed, user_id, reason}),
    do: Marshall.Events.emit("passkey.verify_failed", user_id: user_id, reason: reason)

  defp emit_event({:passkey_removed, user_id, actor_id}),
    do: Marshall.Events.emit("passkey.removed", user_id: user_id, actor_id: actor_id)

  defp emit_event({:mfa_locked, user_id}),
    do: Marshall.Events.emit("mfa.locked", user_id: user_id)

  defp emit_event(nil), do: :ok
end
