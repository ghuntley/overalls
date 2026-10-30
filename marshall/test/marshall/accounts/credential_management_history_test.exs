defmodule Marshall.Accounts.CredentialManagementHistoryTest do
  @moduledoc """
  Generated credential-management histories over the real security ceremony and
  SSH key actions, with an independent raw-SQL oracle for passkeys, SSH keys,
  verification receipts, account MFA state and stored session tokens.
  Elevation and login completion are recomputed from receipt fields, never
  from `Security.recent?/1` or `Security.passkey_verified?/2` alone.
  """
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.PasskeyFixture
  alias Marshall.Accounts.{Security, User}
  alias Marshall.SSH

  @typep passkey :: %{
           id: String.t(),
           credential_id: binary(),
           label: String.t(),
           public_key: binary(),
           device: map()
         }
  @typep ssh_key :: %{id: String.t(), fingerprint: String.t(), label: String.t()}

  @typep session :: %{
           actor: User.t(),
           jti: String.t(),
           live: boolean(),
           verified: boolean(),
           verified_generation: non_neg_integer() | nil,
           elevated: boolean(),
           bound_credential: String.t() | nil
         }

  @typep model :: %{
           user_id: String.t(),
           admin: boolean(),
           mfa: boolean(),
           generation: non_neg_integer(),
           passkeys: [passkey()],
           ssh_active: [ssh_key()],
           ssh_archived: [String.t()],
           sessions: [session()],
           current: non_neg_integer(),
           step: non_neg_integer(),
           seed: binary()
         }

  # Registration and verification ceremonies retain one challenge row each;
  # the account admits at most ten retained challenges per sixty-second
  # window, so generated histories keep at most eight ceremonies.
  @max_ceremonies 8

  # @cc [owner:ghuntley,label:verification;security] credential-management-history-oracle
  # Generated histories MUST invoke the real security ceremony and SSH key
  # actions and compare every credential effect against an independent raw-SQL
  # model, never through Security.recent? alone. The model MUST track each
  # session receipt's verified marker, the MFA generation at verification and
  # the durably retained credential binding, because removing the last passkey
  # bumps the generation while preserving receipt rows. Every refusal MUST
  # preserve the exact prior credential/session inventory, and ordinary
  # last-passkey removal MUST disable MFA and revoke every stored session,
  # including its own.
  @tag timeout: 120_000
  @tag :hegel_case_sandbox
  property "generated passkey and SSH key histories match the raw inventory oracle",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    admin = draw("admin", boolean())
    seed = draw("seed", binary(length: 16))
    operations = draw("operations", operations())
    run_history(admin, seed, operations)
  end

  @spec run_history(boolean(), binary(), [atom()]) :: :ok
  defp run_history(admin, seed, operations) do
    {actor, token} = login(user(admin))
    _ = token

    model = %{
      user_id: actor.id,
      admin: admin,
      mfa: false,
      generation: 0,
      passkeys: [],
      ssh_active: [],
      ssh_archived: [],
      sessions: [new_session(actor)],
      current: 0,
      step: 0,
      seed: seed
    }

    assert_oracle(model)

    Enum.reduce(operations, model, fn operation, model ->
      model
      |> Map.update!(:step, &(&1 + 1))
      |> transition(operation)
      |> tap(&assert_oracle/1)
    end)

    :ok
  end

  @spec operations() :: Hegel.Gen.t([atom()])
  defp operations do
    map(
      list_of(
        member_of([
          :register,
          :verify,
          :rename,
          :remove,
          :add_ssh,
          :remove_ssh,
          :register,
          :verify,
          :rename,
          :remove,
          :add_ssh,
          :remove_ssh,
          :relogin
        ]),
        max_length: 14
      ),
      fn ops ->
        {kept, _ceremonies} =
          Enum.map_reduce(ops, 0, fn op, ceremonies ->
            cond do
              op in [:register, :verify] and ceremonies < @max_ceremonies ->
                {op, ceremonies + 1}

              op in [:register, :verify] ->
                {:skip, ceremonies}

              true ->
                {op, ceremonies}
            end
          end)

        Enum.reject(kept, &(&1 == :skip))
      end
    )
  end

  @spec new_session(User.t()) :: session()
  defp new_session(actor) do
    %{
      actor: actor,
      jti: Security.jti(actor),
      live: true,
      verified: false,
      verified_generation: nil,
      elevated: false,
      bound_credential: nil
    }
  end

  # ------------------------------------------------------------- transitions

  @spec transition(model(), atom()) :: model()
  defp transition(model, :register) do
    session = current(model)

    cond do
      not session.live ->
        assert_refusal(action(session.actor, :begin_register), :unauthorized)
        model

      model.passkeys != [] and not session.elevated ->
        assert_refusal(action(session.actor, :begin_register), :mfa_required)
        model

      length(model.passkeys) >= 10 ->
        assert_refusal(action(session.actor, :begin_register), :credential_limit)
        model

      true ->
        device = authenticator()
        label = pick_label(model, "passkey")
        {:ok, challenge} = action(session.actor, :begin_register)
        payload = Map.put(registration(challenge, device), "label", label)
        assert {:ok, %{registered: true}} = action(session.actor, :finish_register, payload)

        {id, public_key} = fetch_passkey_row(model.user_id, device.id)

        key = %{
          id: id,
          credential_id: device.id,
          label: label,
          public_key: public_key,
          device: device
        }

        %{model | mfa: true, passkeys: model.passkeys ++ [key]}
    end
  end

  defp transition(model, :verify) do
    session = current(model)

    cond do
      not session.live ->
        assert_refusal(action(session.actor, :begin_verify), :unauthorized)
        model

      model.passkeys == [] ->
        assert_refusal(action(session.actor, :begin_verify), :enrollment_required)
        model

      true ->
        key = pick_list(model, model.passkeys)
        {:ok, challenge} = action(session.actor, :begin_verify)

        assert {:ok, %{verified: true}} =
                 action(session.actor, :finish_verify, assertion(challenge, key.device))

        put_session(model, %{
          session
          | verified: true,
            verified_generation: model.generation,
            elevated: true,
            bound_credential: key.id
        })
    end
  end

  defp transition(model, :rename) do
    session = current(model)

    cond do
      not session.live ->
        assert_refusal(
          action(session.actor, :rename, %{"id" => Ash.UUID.generate(), "label" => "x"}),
          :unauthorized
        )

        model

      not session.elevated ->
        id =
          case model.passkeys do
            [] -> Ash.UUID.generate()
            [%{id: id} | _] -> id
          end

        assert_refusal(
          action(session.actor, :rename, %{"id" => id, "label" => "x"}),
          :mfa_required
        )

        model

      true ->
        key = pick_list(model, model.passkeys)
        label = pick_label(model, "renamed")

        assert {:ok, %{updated: true}} =
                 action(session.actor, :rename, %{"id" => key.id, "label" => label})

        update_in(model, [:passkeys], fn keys ->
          Enum.map(keys, fn k -> if k.id == key.id, do: %{k | label: label}, else: k end)
        end)
    end
  end

  defp transition(model, :remove) do
    session = current(model)

    cond do
      not session.live ->
        assert_refusal(
          action(session.actor, :remove, %{"id" => Ash.UUID.generate()}),
          :unauthorized
        )

        model

      not session.elevated ->
        id =
          case model.passkeys do
            [] -> Ash.UUID.generate()
            [%{id: id} | _] -> id
          end

        assert_refusal(action(session.actor, :remove, %{"id" => id}), :mfa_required)
        model

      length(model.passkeys) == 1 and model.admin ->
        [%{id: id}] = model.passkeys
        assert_refusal(action(session.actor, :remove, %{"id" => id}), :last_admin_passkey)
        model

      true ->
        key = pick_list(model, model.passkeys)
        assert {:ok, %{updated: true}} = action(session.actor, :remove, %{"id" => key.id})
        remove_passkey(model, key)
    end
  end

  defp transition(model, :add_ssh) do
    session = current(model)

    if session.live do
      label = pick_label(model, "ssh")
      bytes = pick_bytes(model)
      public_key = ssh_public_key(bytes)
      fingerprint = ssh_fingerprint(bytes)

      assert {:ok, key} =
               SSH.add_key(%{public_key: public_key, label: label}, actor: session.actor)

      assert key.fingerprint == fingerprint

      update_in(model, [:ssh_active], fn keys ->
        keys ++ [%{id: key.id, fingerprint: fingerprint, label: label}]
      end)
    else
      # Entry authorization requires only a live stored login; a passkey receipt
      # is not part of ordinary SSH-key authority.
      assert_forbidden(
        SSH.add_key(%{public_key: ssh_public_key(pick_bytes(model))}, actor: session.actor)
      )

      model
    end
  end

  defp transition(model, :remove_ssh) do
    session = current(model)

    if session.live do
      case model.ssh_active do
        [] ->
          assert_ssh_refusal(
            SSH.remove_key(%{id: Ash.UUID.generate()}, actor: session.actor),
            :key_not_found
          )

          model

        keys ->
          key = pick_list(model, keys)
          assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: key.id}, actor: session.actor)

          model
          |> update_in([:ssh_active], fn active -> Enum.reject(active, &(&1.id == key.id)) end)
          |> update_in([:ssh_archived], &(&1 ++ [key.id]))
      end
    else
      case model.ssh_active do
        [] ->
          assert_forbidden(SSH.remove_key(%{id: Ash.UUID.generate()}, actor: session.actor))

        [%{id: id} | _] ->
          assert_forbidden(SSH.remove_key(%{id: id}, actor: session.actor))
      end

      model
    end
  end

  defp transition(model, :relogin) do
    {actor, _token} = login(Security.current(model.user_id))

    model
    |> update_in([:sessions], &(&1 ++ [new_session(actor)]))
    |> Map.put(:current, length(model.sessions))
  end

  @spec remove_passkey(model(), passkey()) :: model()
  defp remove_passkey(model, key) do
    model = update_in(model, [:passkeys], &Enum.reject(&1, fn k -> k.id == key.id end))

    if model.passkeys == [] do
      # Removing the final passkey of an ordinary account disables MFA and
      # revokes every stored session, including the one issuing the removal.
      # Receipt rows retain their historical credential binding.
      sessions =
        Enum.map(model.sessions, fn s ->
          %{s | live: false, elevated: false}
        end)

      %{model | mfa: false, generation: model.generation + 1, sessions: sessions}
    else
      sessions =
        Enum.map(model.sessions, fn s ->
          # Elevation dies with the removal of the credential the verification
          # receipt is bound to; the durable receipt itself is retained.
          if s.bound_credential == key.id, do: %{s | elevated: false}, else: s
        end)

      %{model | sessions: sessions}
    end
  end

  # ------------------------------------------------------------------ oracle

  @spec assert_oracle(model()) :: :ok
  defp assert_oracle(model) do
    dumped = Ecto.UUID.dump!(model.user_id)

    %{rows: [[mfa, reset_required, generation, deleted_at]]} =
      query!(
        "SELECT mfa_enabled, mfa_reset_required, mfa_generation, deleted_at FROM users WHERE id=$1",
        [dumped]
      )

    assert mfa == model.mfa
    assert generation == model.generation
    refute reset_required
    assert is_nil(deleted_at)

    %{rows: passkey_rows} =
      query!(
        "SELECT id::text, label, credential_id, public_key FROM account_passkeys WHERE user_id=$1 ORDER BY inserted_at, id",
        [dumped]
      )

    assert MapSet.new(
             Enum.map(passkey_rows, fn [id, label, credential_id, public_key] ->
               {id, label, credential_id, public_key}
             end)
           ) ==
             MapSet.new(
               Enum.map(model.passkeys, &{&1.id, &1.label, &1.credential_id, &1.public_key})
             )

    %{rows: ssh_rows} =
      query!("SELECT id::text, fingerprint, label, archived_at FROM ssh_keys WHERE user_id=$1", [
        dumped
      ])

    {active_rows, archived_rows} =
      Enum.split_with(ssh_rows, fn [_id, _fp, _label, archived] -> is_nil(archived) end)

    assert MapSet.new(
             Enum.map(active_rows, fn [id, fingerprint, label, _] -> {id, fingerprint, label} end)
           ) ==
             MapSet.new(Enum.map(model.ssh_active, &{&1.id, &1.fingerprint, &1.label}))

    assert MapSet.new(Enum.map(archived_rows, fn [id, _, _, _] -> id end)) ==
             MapSet.new(model.ssh_archived)

    active_passkey_ids = MapSet.new(Enum.map(passkey_rows, fn [id | _] -> id end))

    for session <- model.sessions do
      assert_session_oracle(model, session, generation, mfa, active_passkey_ids)
    end

    :ok
  end

  @spec assert_session_oracle(
          model(),
          session(),
          non_neg_integer(),
          boolean(),
          MapSet.t(String.t())
        ) ::
          :ok
  defp assert_session_oracle(model, session, generation, mfa, active_passkey_ids) do
    %{rows: token_rows} =
      query!(
        "SELECT purpose FROM tokens WHERE jti=$1 AND subject=$2 AND purpose='user' AND (expires_at AT TIME ZONE 'utc') > clock_timestamp()",
        [session.jti, "user?id=" <> model.user_id]
      )

    live_token? = token_rows != []

    assert live_token? == session.live,
           "session live token divergence for #{short(session)}: #{inspect(token_rows)}"

    %{rows: [[v_generation, verified, fresh, credential_id]]} =
      query!(
        """
        SELECT generation,
               verified_at IS NOT NULL,
               CASE
                 WHEN verified_at IS NULL OR elevated_until IS NULL THEN false
                 ELSE (verified_at AT TIME ZONE 'utc') <= clock_timestamp()
                      AND clock_timestamp() < (elevated_until AT TIME ZONE 'utc')
                      AND ((elevated_until AT TIME ZONE 'utc') - (verified_at AT TIME ZONE 'utc'))
                          <= interval '900 seconds'
               END,
               credential_id::text
        FROM account_verifications WHERE id=$1 AND user_id=$2
        """,
        [session.jti, Ecto.UUID.dump!(model.user_id)]
      )

    assert verified == session.verified,
           "verification receipt marker divergence for #{short(session)}"

    assert credential_id == session.bound_credential,
           "verification credential binding divergence for #{short(session)}"

    credential_alive? =
      is_binary(credential_id) and MapSet.member?(active_passkey_ids, credential_id)

    completed_raw = verified and v_generation == generation and credential_alive?

    completed_model = expected_receipt?(model, session)

    assert completed_raw == completed_model,
           "raw completion recomputation diverged from the model for #{short(session)}"

    recent_raw =
      live_token? and mfa and completed_raw and credential_alive? and fresh

    assert recent_raw == session.elevated,
           "raw elevation recomputation diverged for #{short(session)}"

    assert Security.passkey_verified?(session.jti, model.user_id) == completed_raw,
           "Security.passkey_verified?/2 disagreed with the raw recomputation for #{short(session)}"

    assert Security.recent?(session.actor) == recent_raw,
           "Security.recent?/1 disagreed with the raw recomputation for #{short(session)}"

    :ok
  end

  @spec expected_receipt?(model(), session()) :: boolean()
  defp expected_receipt?(model, session) do
    session.verified and session.verified_generation == model.generation and
      is_binary(session.bound_credential) and
      Enum.any?(model.passkeys, &(&1.id == session.bound_credential))
  end

  @spec short(session()) :: String.t()
  defp short(session), do: String.slice(session.jti, 0, 6)

  @spec assert_refusal({:ok, term()} | {:error, term()}, atom()) :: :ok
  defp assert_refusal(result, reason) do
    case result do
      # Cedar admission refuses an actor without a current login before the
      # coordinator would report :unauthorized.
      {:error, %Ash.Error.Forbidden{}} when reason == :unauthorized ->
        :ok

      {:error, %Ash.Error.Unknown{errors: errors}} ->
        assert Enum.any?(errors, fn
                 %{error: "unknown error: " <> text} -> text == ":#{reason}"
                 _ -> false
               end),
               "expected refusal :#{reason}, got: #{inspect(result)}"

      other ->
        flunk("expected refusal :#{reason}, got: #{inspect(other)}")
    end

    :ok
  end

  @spec assert_ssh_refusal({:ok, term()} | {:error, term()}, atom()) :: :ok
  defp assert_ssh_refusal(result, reason) do
    case result do
      {:error, %{errors: errors}} when is_list(errors) ->
        assert Enum.any?(errors, &match?(%Marshall.SSH.Error{reason: ^reason}, &1)),
               "expected SSH refusal :#{reason}, got: #{inspect(result)}"

      {:error, %Marshall.SSH.Error{reason: ^reason}} ->
        :ok

      other ->
        flunk("expected SSH refusal :#{reason}, got: #{inspect(other)}")
    end

    :ok
  end

  @spec assert_forbidden({:ok, term()} | {:error, term()}) :: :ok
  defp assert_forbidden(result) do
    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "expected forbidden, got: #{inspect(result)}"

    :ok
  end

  @spec query!(String.t(), [term()]) :: Postgrex.Result.t()
  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  @spec fetch_passkey_row(String.t(), binary()) :: {String.t(), binary()}
  defp fetch_passkey_row(user_id, credential_id) do
    %{rows: [[id, public_key]]} =
      query!(
        "SELECT id::text, public_key FROM account_passkeys WHERE user_id=$1 AND credential_id=$2",
        [Ecto.UUID.dump!(user_id), credential_id]
      )

    {id, public_key}
  end

  # ---------------------------------------------------------------- helpers

  @spec current(model()) :: session()
  defp current(model), do: Enum.at(model.sessions, model.current)

  @spec put_session(model(), session()) :: model()
  defp put_session(model, session),
    do: %{model | sessions: List.replace_at(model.sessions, model.current, session)}

  @spec pick_list(model(), [a]) :: a when a: var
  defp pick_list(model, list) do
    index = rem(:erlang.phash2({model.seed, model.step}), length(list))
    Enum.at(list, index)
  end

  @spec pick_label(model(), String.t()) :: String.t()
  defp pick_label(model, prefix) do
    suffix =
      {model.seed, model.step, prefix}
      |> :erlang.phash2()
      |> Integer.to_string(16)

    prefix <> "-" <> suffix
  end

  @spec pick_bytes(model()) :: binary()
  defp pick_bytes(model) do
    :crypto.hash(:sha256, model.seed <> Integer.to_string(model.step) <> model.user_id)
  end

  @spec ssh_public_key(binary()) :: String.t()
  defp ssh_public_key(bytes) do
    "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
  end

  @spec ssh_fingerprint(binary()) :: String.t()
  defp ssh_fingerprint(bytes) do
    {:ok, parsed} = OverallsProtocol.SSHKey.parse(ssh_public_key(bytes))
    parsed.fingerprint
  end
end
