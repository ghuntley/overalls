defmodule Marshall.Accounts.CredentialManagementBoundsTest do
  @moduledoc """
  Fixed refusal, bound and failure/recovery checks for the credential
  management surfaces: passkey ceremonies and owner SSH key actions.
  Refusals are asserted by closed reason and by an unchanged raw credential
  and session inventory.
  """
  use Marshall.DataCase, async: false
  import Marshall.PasskeyFixture
  alias Marshall.Accounts.{AdminEvent, Security, User}
  alias Marshall.SSH

  test "first enrollment requires a fresh email receipt within five minutes" do
    # No fresh-email receipt at all.
    plain = user()
    {:ok, _token, %{"jti" => jti}} = AshAuthentication.Jwt.token_for_user(plain)
    actor = Security.bind(plain, jti)
    assert_refusal(action(actor, :begin_register), :fresh_email_required)

    # A receipt older than the five-minute primary window.
    {aged, _} = login(user())
    age_primary!(Security.jti(aged), -301)
    assert_refusal(action(aged, :begin_register), :fresh_email_required)

    # 299 seconds remain inside the window; the full ceremony succeeds.
    {admitted, _} = login(user())
    age_primary!(Security.jti(admitted), -299)
    {:ok, challenge} = action(admitted, :begin_register)
    device = authenticator()
    payload = registration(challenge, device)

    assert {:ok, %{registered: true}} = action(admitted, :finish_register, payload)
    assert Security.current(admitted.id).mfa_enabled

    # A fresh login receives its own fresh primary window.
    {fresh, _} = login(Security.current(aged.id))
    assert {:ok, _} = action(fresh, :begin_register)
  end

  test "credential changes require recent elevation and an existing credential" do
    {actor, _} = login(user())
    device = register(actor)
    original = passkey_rows(actor.id)
    challenges = challenge_count(actor.id)

    for {op, payload} <- [
          {:rename, %{"id" => hd(original).id, "label" => "other"}},
          {:remove, %{"id" => hd(original).id}},
          {:begin_register, %{}}
        ] do
      assert_refusal(action(actor, op, payload), :mfa_required)
    end

    refute Security.recent?(actor)
    assert passkey_rows(actor.id) == original
    assert challenge_count(actor.id) == challenges

    # Elevation expiry only locks mutation authority; the completed login stays.
    assert {:ok, %{verified: true}} = verify(actor, device)

    [proof] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.Verification, id: Security.jti(actor))

    Marshall.Compute.Ledger.update!(proof, :verify, %{
      elevated_until: Marshall.Compute.Ledger.now()
    })

    refute Security.recent?(actor)
    assert Security.passkey_verified?(Security.jti(actor), actor.id)

    assert_refusal(
      action(actor, :rename, %{"id" => hd(original).id, "label" => "other"}),
      :mfa_required
    )

    assert passkey_rows(actor.id) == original

    # Elevation does not invent unknown credentials.
    elevated = elevate(user())
    unknown = Ash.UUID.generate()

    assert_refusal(
      action(elevated, :rename, %{"id" => unknown, "label" => "x"}),
      :unknown_credential
    )

    assert_refusal(action(elevated, :remove, %{"id" => unknown}), :unknown_credential)
  end

  test "administrators keep a last passkey; ordinary last removal revokes every session" do
    admin = elevate(user(true))
    [admin_key] = passkey_rows(admin.id)
    assert_refusal(action(admin, :remove, %{"id" => admin_key.id}), :last_admin_passkey)
    assert Security.recent?(admin)
    assert Security.current(admin.id).mfa_enabled

    ordinary_user = user()
    {first, _} = login(ordinary_user)
    device = register(first)
    [key] = passkey_rows(first.id)
    assert {:ok, %{verified: true}} = verify(first, device)
    {second, _} = login(Security.current(ordinary_user.id))
    assert {:ok, %{verified: true}} = verify(second, device)
    assert Security.recent?(second)

    generation = Security.current(first.id).mfa_generation
    assert {:ok, %{updated: true}} = action(first, :remove, %{"id" => key.id})

    current = Security.current(first.id)
    refute current.mfa_enabled
    assert current.mfa_generation == generation + 1
    assert passkey_rows(first.id) == []
    assert live_logins(first.id) == 0
    assert Marshall.Accounts.Login.present(Security.jti(first), first.id) == :error
    assert Marshall.Accounts.Login.present(Security.jti(second), first.id) == :error

    # Every management operation on the revoked sessions refuses.
    assert_refusal(action(first, :status), :unauthorized)
    assert_refusal(action(second, :begin_verify), :unauthorized)

    # The credential lifecycle remained audited.
    kinds =
      Marshall.Compute.Ledger.read!(AdminEvent, actor_id: first.id) |> Enum.map(& &1.kind)

    assert Enum.sort(kinds) == [:mfa_verify, :mfa_verify, :passkey_add, :passkey_remove]
  end

  test "removing the proving credential kills elevation; another credential preserves it" do
    keeps = user()
    {keeps_actor, _} = login(keeps)
    [first_device, second_device] = enroll(keeps_actor, 2)
    [first, second] = rows_for(keeps_actor.id, [first_device, second_device])

    assert {:ok, %{updated: true}} =
             action(keeps_actor, :rename, %{"id" => first.id, "label" => "usb"})

    assert {:ok, %{updated: true}} = action(keeps_actor, :remove, %{"id" => second.id})

    assert Security.recent?(keeps_actor)
    assert Security.passkey_verified?(Security.jti(keeps_actor), keeps_actor.id)
    assert [%{id: first_id, label: "usb"}] = passkey_rows(keeps_actor.id)
    assert first_id == first.id

    loses = user()
    {loses_actor, _} = login(loses)
    [proving_device, other_device] = enroll(loses_actor, 2)
    [proving, other] = rows_for(loses_actor.id, [proving_device, other_device])
    assert {:ok, %{updated: true}} = action(loses_actor, :remove, %{"id" => proving.id})

    refute Security.recent?(loses_actor)
    refute Security.passkey_verified?(Security.jti(loses_actor), loses_actor.id)
    assert {:ok, _} = Marshall.Accounts.Login.present(Security.jti(loses_actor), loses_actor.id)
    assert Security.current(loses_actor.id).mfa_enabled
    assert [%{id: old_id}] = passkey_rows(loses_actor.id)
    assert old_id == other.id

    # Recovery is a fresh assertion on a retained credential, not a new login.
    assert {:ok, %{verified: true, expires_at: %DateTime{}}} = verify(loses_actor, other_device)
    assert Security.recent?(loses_actor)
    assert Marshall.Accounts.Login.present(Security.jti(loses_actor), loses_actor.id) != :error
    assert [%{id: ^old_id}] = passkey_rows(loses_actor.id)
  end

  test "exactly ten passkeys register; the eleventh refuses before challenge creation" do
    actor = elevate(user())

    # Each ceremony retains a challenge row for one minute; aging expired rows
    # exercises the same prune path sixty-second passage would.
    for cycle <- 0..1 do
      for _ <- 1..if(cycle == 0, do: 4, else: 5) do
        register(actor, authenticator())
      end

      if cycle == 0, do: expire_challenges!(actor.id)
    end

    assert length(passkey_rows(actor.id)) == 10
    assert_refusal(action(actor, :begin_register), :credential_limit)
    assert length(passkey_rows(actor.id)) == 10
  end

  test "register completion refuses at the credential limit without consuming the challenge" do
    actor = elevate(user())

    for _ <- 2..9, do: register(actor, authenticator())
    assert length(passkey_rows(actor.id)) == 9

    expire_challenges!(actor.id)
    {:ok, challenge} = action(actor, :begin_register)
    payload = registration(challenge, authenticator())

    # A tenth credential admitted out of band (another elevated session raced).
    Ash.Seed.seed!(Marshall.Accounts.Passkey, %{
      user_id: actor.id,
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: %{1 => 2},
      label: "Raced"
    })

    assert_refusal(action(actor, :finish_register, payload), :credential_limit)
    assert length(passkey_rows(actor.id)) == 10

    [%{id: id, consumed_at: consumed_at}] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.PasskeyChallenge, id: challenge.id)

    assert id == challenge.id
    assert is_nil(consumed_at)
  end

  test "ten retained challenges refuse the next; expiry prunes and recovery succeeds" do
    actor = elevate(user())
    device = device_of(actor)

    # elevate() left two retained challenge rows (registration and elevation).
    assert challenge_count(actor.id) == 2

    admitted =
      Enum.reduce_while(1..12, 0, fn _, admitted ->
        case action(actor, :begin_verify) do
          {:ok, _challenge} -> {:cont, admitted + 1}
          {:error, _} -> {:halt, admitted}
        end
      end)

    assert admitted == 8
    assert challenge_count(actor.id) == 10
    assert_refusal(action(actor, :begin_verify), :try_later)

    # Expired challenges are pruned on admission; a fresh ceremony recovers.
    expire_challenges!(actor.id)

    {:ok, challenge} = action(actor, :begin_verify)
    assert {:ok, %{verified: true}} = action(actor, :finish_verify, assertion(challenge, device))
    assert challenge_count(actor.id) == 1
  end

  test "malformed and oversized payloads consume the challenge without credential effects" do
    actor = elevate(user())
    device = device_of(actor)
    baseline = passkey_rows(actor.id)
    baseline_mfa = Security.current(actor.id)

    oversized_attestation = fn challenge ->
      registration(challenge, device)
      |> Map.put("attestation_object", String.duplicate("A", 65_537))
    end

    boundary_attestation = fn challenge ->
      garbage = :crypto.strong_rand_bytes(49_152)
      assert byte_size(Base.url_encode64(garbage, padding: false)) == 65_536

      registration(challenge, device)
      |> Map.put("attestation_object", Base.url_encode64(garbage, padding: false))
    end

    invalid_base64 = fn challenge ->
      registration(challenge, device)
      |> Map.put("attestation_object", "!!!not base64 url!!!")
    end

    malformed_cbor = fn challenge ->
      registration(challenge, device)
      |> Map.put("attestation_object", Base.url_encode64(<<255, 255, 255>>, padding: false))
    end

    oversized_client_data = fn challenge ->
      registration(challenge, device)
      |> Map.put("client_data_json", String.duplicate("A", 65_537))
    end

    long_label = fn challenge ->
      registration(challenge, device) |> Map.put("label", String.duplicate("l", 81))
    end

    malformed_variants = [
      oversized_attestation,
      boundary_attestation,
      invalid_base64,
      malformed_cbor,
      oversized_client_data,
      long_label
    ]

    for variant <- malformed_variants do
      {:ok, challenge} = action(actor, :begin_register)
      assert {:ok, %{error: _}} = action(actor, :finish_register, variant.(challenge))

      assert [%{consumed_at: %DateTime{}}] =
               Marshall.Compute.Ledger.read!(Marshall.Accounts.PasskeyChallenge,
                 id: challenge.id
               )

      assert passkey_rows(actor.id) == baseline
    end

    assert Security.current(actor.id) == baseline_mfa

    # Retained challenges bound a fresh burst; expire them before the next block.
    expire_challenges!(actor.id)

    # Failed assertions on the verification side consume their challenge too.
    for {field, value} <- [
          {"authenticator_data", String.duplicate("A", 65_537)},
          {"signature", "!!!not base64 url!!!"},
          {"client_data_json", String.duplicate("A", 65_537)}
        ] do
      {:ok, challenge} = action(actor, :begin_verify)
      payload = Map.put(assertion(challenge, device), field, value)
      assert {:ok, %{error: _}} = action(actor, :finish_verify, payload)

      assert [%{consumed_at: %DateTime{}}] =
               Marshall.Compute.Ledger.read!(Marshall.Accounts.PasskeyChallenge,
                 id: challenge.id
               )
    end

    assert passkey_rows(actor.id) == baseline
    # A correct ceremony still succeeds afterwards; failure left no residue.
    {:ok, challenge} = action(actor, :begin_verify)
    assert {:ok, %{verified: true}} = action(actor, :finish_verify, assertion(challenge, device))
  end

  test "a rename above the label bound is refused without touching the credential" do
    actor = elevate(user())
    [key] = passkey_rows(actor.id)

    # The passkey-label-closed-refusal contract: over-bound labels are a closed
    # refusal (rolled back), never a raised Ash constraint error.
    assert_refusal(
      action(actor, :rename, %{"id" => key.id, "label" => String.duplicate("l", 81)}),
      :invalid_label
    )

    assert passkey_rows(actor.id) == [key]
    assert Security.recent?(actor)
  end

  test "SSH keys admit exactly one hundred and refuse oversized material" do
    {actor, _} = login(user())

    assert_forbidden_reason(
      SSH.add_key(%{public_key: "x" <> String.duplicate("x", 4096), label: "big"}, actor: actor),
      :invalid_public_key_input
    )

    assert {:error, %Ash.Error.Invalid{}} =
             SSH.add_key(
               %{public_key: ssh_public_key(<<0::256>>), label: String.duplicate("l", 129)},
               actor: actor
             )

    assert ssh_key_ids(actor.id) == []

    for n <- 1..99 do
      assert {:ok, key} =
               SSH.add_key(%{public_key: ssh_public_key(<<n::256>>), label: "key-#{n}"},
                 actor: actor
               )

      assert key.id
    end

    assert length(ssh_key_ids(actor.id)) == 99

    assert {:ok, hundredth} =
             SSH.add_key(%{public_key: ssh_public_key(<<100::256>>)}, actor: actor)

    assert length(ssh_key_ids(actor.id)) == 100
    assert hundredth.id in ssh_key_ids(actor.id)

    assert_ssh_reason(
      SSH.add_key(%{public_key: ssh_public_key(<<101::256>>)}, actor: actor),
      :key_limit
    )

    assert length(ssh_key_ids(actor.id)) == 100

    # The bound counts live keys; removing one re-admits registration.
    assert {:ok, %{revoked: true}} = SSH.remove_key(%{id: hundredth.id}, actor: actor)
    assert {:ok, _} = SSH.add_key(%{public_key: ssh_public_key(<<101::256>>)}, actor: actor)
    assert length(ssh_key_ids(actor.id)) == 100
  end

  # ---------------------------------------------------------------- helpers

  @spec assert_refusal(term(), atom()) :: :ok
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

  @spec assert_ssh_reason(term(), atom()) :: :ok
  defp assert_ssh_reason(result, reason) do
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

  @spec assert_forbidden_reason(term(), atom()) :: :ok
  defp assert_forbidden_reason(result, :invalid_public_key_input) do
    # Oversized public-key arguments fail at input validation, before parsing.
    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "expected invalid input, got: #{inspect(result)}"

    :ok
  end

  @spec age_primary!(String.t(), integer()) :: :ok
  defp age_primary!(jti, seconds) do
    %{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE account_verifications SET primary_at = clock_timestamp() + ($2 || ' seconds')::interval WHERE id = $1",
        [jti, Integer.to_string(seconds)],
        log: false
      )

    :ok
  end

  @spec expire_challenges!(String.t()) :: :ok
  defp expire_challenges!(user_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE account_passkey_challenges SET expires_at = clock_timestamp() - interval '1 second' WHERE user_id = $1",
      [Ecto.UUID.dump!(user_id)],
      log: false
    )

    :ok
  end

  @spec passkey_rows(String.t()) :: [map()]
  defp passkey_rows(user_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text, label, credential_id, public_key FROM account_passkeys WHERE user_id=$1 ORDER BY inserted_at, id",
        [Ecto.UUID.dump!(user_id)],
        log: false
      )

    Enum.map(rows, fn [id, label, credential_id, public_key] ->
      %{id: id, label: label, credential_id: credential_id, public_key: public_key}
    end)
  end

  @spec ssh_key_ids(String.t()) :: [String.t()]
  defp ssh_key_ids(user_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text FROM ssh_keys WHERE user_id=$1 AND archived_at IS NULL ORDER BY id",
        [Ecto.UUID.dump!(user_id)],
        log: false
      )

    Enum.map(rows, &hd/1)
  end

  @spec challenge_count(String.t()) :: non_neg_integer()
  defp challenge_count(user_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM account_passkey_challenges WHERE user_id=$1",
        [Ecto.UUID.dump!(user_id)],
        log: false
      )

    count
  end

  @spec live_logins(String.t()) :: non_neg_integer()
  defp live_logins(user_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM tokens WHERE subject=$1 AND purpose='user' AND (expires_at AT TIME ZONE 'utc') > clock_timestamp()",
        ["user?id=" <> user_id],
        log: false
      )

    count
  end

  @spec ssh_public_key(binary()) :: String.t()
  defp ssh_public_key(bytes) do
    "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
  end

  @spec device_of(User.t()) :: map()
  defp device_of(actor) do
    [row] = passkey_rows(actor.id)
    assert row.credential_id == actor.__metadata__.test_authenticator.id
    actor.__metadata__.test_authenticator
  end

  @spec rows_for(String.t(), [map()]) :: [map()]
  defp rows_for(user_id, devices) do
    rows = passkey_rows(user_id)

    Enum.map(devices, fn device ->
      Enum.find(rows, &(&1.credential_id == device.id)) ||
        flunk("registered passkey row not found for device")
    end)
  end

  @spec enroll(User.t(), pos_integer()) :: [map()]
  defp enroll(actor, count) do
    [first | rest] = Enum.map(1..count, fn _ -> authenticator() end)
    register(actor, first)
    assert {:ok, %{verified: true}} = verify(actor, first)
    for device <- rest, do: register(actor, device)
    [first | rest]
  end
end
