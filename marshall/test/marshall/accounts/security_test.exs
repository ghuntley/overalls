defmodule Marshall.Accounts.SecurityTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.PasskeyFixture
  alias Marshall.Accounts.{Security, User, Verification, PasskeyChallenge}
  alias Marshall.Compute.Ledger
  alias Marshall.Authorization.Cedar

  @tag :hegel_case_sandbox
  property "elevation expires exactly at fifteen minutes and rejects future verification" do
    Marshall.DataCase.isolate_property_case()
    offset = draw("offset", integer(-1_000_000..1_000_000))
    verified = ~U[2026-09-18 00:00:00.000000Z]
    now = DateTime.add(verified, offset, :millisecond)

    assert Security.elevation_fresh?(verified, DateTime.add(verified, 900), now) ==
             (offset >= 0 and offset < 900_000)
  end

  @tag :hegel_case_sandbox
  property "first enrollment email proof expires exactly at five minutes" do
    Marshall.DataCase.isolate_property_case()
    offset = draw("offset", integer(-1_000_000..1_000_000))
    primary = ~U[2026-09-18 00:00:00.000000Z]
    now = DateTime.add(primary, offset, :millisecond)

    assert Security.email_fresh?(primary, now) ==
             (offset >= 0 and offset <= 300_000)
  end

  @tag :hegel_case_sandbox
  property "revocation and generation changes fence arbitrary verification sequences",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    events =
      draw(
        "events",
        list_of(member_of([:verify, :lock, :expire, :generation, :revoke]),
          min_length: 1,
          max_length: 12
        )
      )

    {actor, token} = login(user())
    key = register(actor)

    Enum.reduce(events, {true, false}, fn event, {live, _elevated} ->
      elevated =
        case event do
          :verify ->
            result =
              case action(actor, :begin_verify) do
                {:ok, challenge} -> action(actor, :finish_verify, assertion(challenge, key))
                error -> error
              end

            assert match?({:ok, %{verified: true}}, result) == live
            live

          :lock ->
            action(actor, :lock)
            false

          :expire ->
            [proof] = Ledger.read!(Verification, id: Security.jti(actor))
            Ledger.update!(proof, :verify, %{elevated_until: Ledger.now()})
            false

          :generation ->
            current = Security.current(actor.id)

            Ledger.update!(current, :security_state, %{
              mfa_generation: current.mfa_generation + 1
            })

            false

          :revoke ->
            AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
            false
        end

      live = live and event != :revoke
      assert Security.recent?(actor) == (live and elevated)
      {live, elevated}
    end)
  end

  test "real WebAuthn enrollment and assertion enable session-specific MFA and admin elevation" do
    user = user(true)
    {actor, token} = login(user)
    {other_session, _} = login(user)
    refute Security.recent?(actor)
    assert Cedar.allowed?(actor, "admin_read", Cedar.entity("ControlPlane", "marshall"))
    refute Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))
    key = register(actor)
    refute Security.passkey_verified?(Security.jti(actor), user.id)
    assert {:ok, %{verified: true}} = verify(actor, key)
    assert Security.recent?(actor)
    assert Security.passkey_verified?(Security.jti(actor), user.id)
    refute Security.passkey_verified?(Security.jti(other_session), user.id)
    refute Security.recent?(other_session)
    assert Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    refute Security.recent?(actor)
  end

  test "replayed and cross-session challenges fail; failed assertions consume their challenge" do
    {actor, _} = login(user())
    key = register(actor)
    {:ok, challenge} = action(actor, :begin_verify)
    bad = assertion(challenge, key, origin: "https://wrong.example")
    assert {:ok, %{error: _}} = action(actor, :finish_verify, bad)
    assert {:error, _} = action(actor, :finish_verify, assertion(challenge, key))
    {:ok, challenge} = action(actor, :begin_verify)
    {other, _} = login(actor)
    assert {:error, _} = action(other, :finish_verify, assertion(challenge, key))
    assert {:ok, %{verified: true}} = action(actor, :finish_verify, assertion(challenge, key))
    assert {:error, _} = action(actor, :finish_verify, assertion(challenge, key))
  end

  test "user verification is mandatory and expired challenges cannot elevate" do
    {actor, _} = login(user())
    key = register(actor)
    {:ok, challenge} = action(actor, :begin_verify)
    assert {:ok, %{error: _}} = action(actor, :finish_verify, assertion(challenge, key, flags: 1))
    {:ok, challenge} = action(actor, :begin_verify)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE account_passkey_challenges SET expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(challenge.id)]
    )

    assert {:error, _} = action(actor, :finish_verify, assertion(challenge, key))
    refute Security.recent?(actor)
  end

  test "expiry locks mutation authority without undoing the passkey receipt" do
    actor = elevate(user(true))
    [proof] = Ledger.read!(Verification, id: Security.jti(actor))
    Ledger.update!(proof, :verify, %{elevated_until: Ledger.now()})
    assert Security.passkey_verified?(Security.jti(actor), actor.id)
    refute Security.recent?(actor)

    assert {:error, _} =
             User
             |> Ash.ActionInput.for_action(
               :set_administrator,
               %{user_id: user().id, administrator: true},
               actor: actor
             )
             |> Ash.run_action()

    assert {:ok, %{recent: false}} = action(actor, :status)
  end

  test "lock now, demotion and deletion cannot be bypassed with stale actors" do
    actor = elevate(user(true))
    assert {:ok, %{locked: true}} = action(actor, :lock)
    refute Security.recent?(actor)
    assert {:ok, %{verified: true}} = verify(actor, actor.__metadata__.test_authenticator)
    Ledger.update!(Security.current(actor.id), :assign_administrator, %{administrator: false})
    refute Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))
    Ledger.update!(Security.current(actor.id), :security_state, %{deleted_at: Ledger.now()})
    refute Security.recent?(actor)
    refute Cedar.allowed?(actor, "provision", Cedar.entity("ControlPlane", "marshall"))
  end

  test "administrative leases stop at elevation expiry while ownership retains its lifetime" do
    actor = elevate(user(true))
    owner = user()

    _host = Marshall.ComputeFixtures.host_fixture()
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)

    maximum = DateTime.add(Ledger.now(), 1_200)
    deadline = Security.elevated_until(actor)
    assert Marshall.Access.Authorization.deadline!(vm, actor, "read", maximum) == deadline
    assert Marshall.Access.Authorization.deadline!(vm, owner, "read", maximum) == maximum
    {:ok, _} = action(actor, :lock)

    assert {:error, :forbidden} =
             Ledger.transaction(fn ->
               Marshall.Access.Authorization.deadline!(vm, actor, "read", maximum)
             end)
  end

  test "revoked browser identity cannot retain ordinary ownership permissions" do
    {actor, token} = login(user())
    resource = Marshall.CedarEntities.vm(Ash.UUID.generate(), actor.id)
    assert Cedar.allowed?(actor, "read", resource)
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    refute Cedar.allowed?(actor, "read", resource)
  end

  test "counter rollback is rejected and the failed challenge stays consumed" do
    {actor, _} = login(user())
    key = register(actor)
    {:ok, first} = action(actor, :begin_verify)

    assert {:ok, %{verified: true}} =
             action(actor, :finish_verify, assertion(first, key, counter: 2))

    {:ok, second} = action(actor, :begin_verify)
    assert {:ok, %{error: _}} = action(actor, :finish_verify, assertion(second, key, counter: 1))
    assert {:error, _} = action(actor, :finish_verify, assertion(second, key, counter: 3))
  end

  test "ordinary last-key removal revokes sessions; administrators must keep a key" do
    ordinary = elevate(user())
    admin = elevate(user(true))

    for actor <- [ordinary, admin] do
      [key] = Ledger.read!(Marshall.Accounts.Passkey, user_id: actor.id)
      result = action(actor, :remove, %{"id" => key.id})
      assert match?({:ok, _}, result) == not actor.administrator
    end

    refute Security.current(ordinary.id).mfa_enabled
    refute Security.recent?(ordinary)
    assert :error = Marshall.Accounts.Login.present(Security.jti(ordinary), ordinary.id)
    assert Security.recent?(admin)
  end

  test "malformed attestation cannot roll back single-use challenge consumption" do
    {actor, _} = login(user())
    {:ok, challenge} = action(actor, :begin_register)

    payload =
      registration(challenge, authenticator())
      |> Map.put("attestation_object", Base.url_encode64(CBOR.encode(%{}), padding: false))

    assert {:ok, %{error: _}} = action(actor, :finish_register, payload)
    assert {:error, _} = action(actor, :finish_register, registration(challenge, authenticator()))
    refute Security.current(actor.id).mfa_enabled
  end

  test "a failed enrollment cannot activate MFA" do
    {actor, _} = login(user())
    {:ok, challenge} = action(actor, :begin_register)

    assert {:ok, %{error: _}} =
             action(
               actor,
               :finish_register,
               registration(challenge, authenticator(), origin: "https://wrong.example")
             )

    refute Security.current(actor.id).mfa_enabled
    assert [%{consumed_at: %DateTime{}}] = Ledger.read!(PasskeyChallenge, id: challenge.id)
  end

  test "ceremony outcome events carry closed reasons and no ceremony secrets" do
    {actor, _} = login(user())
    device = authenticator()
    label_marker = "label-secret-#{System.unique_integer([:positive])}"
    origin_marker = "https://evil-#{System.unique_integer([:positive])}.example"

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    parent = self()

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:user_id, :reason]],
        fn ->
          {:ok, challenge} = action(actor, :begin_register)

          payload =
            Map.put(registration(challenge, device), "label", label_marker)

          assert {:ok, %{registered: true}} = action(actor, :finish_register, payload)

          {:ok, challenge} = action(actor, :begin_verify)

          assert {:ok, %{verified: true}} =
                   action(actor, :finish_verify, assertion(challenge, device))

          {:ok, challenge} = action(actor, :begin_register)
          failed_registration = registration(challenge, device, origin: origin_marker)
          assert {:ok, %{error: _}} = action(actor, :finish_register, failed_registration)

          {:ok, challenge} = action(actor, :begin_verify)
          failed_assertion = assertion(challenge, device, origin: origin_marker)
          assert {:ok, %{error: _}} = action(actor, :finish_verify, failed_assertion)
          send(parent, {:ceremony, failed_registration, failed_assertion})
        end
      )

    assert_receive {:ceremony, failed_registration, failed_assertion}

    assert logs =~ "Passkey registered"
    assert logs =~ "Passkey verified"
    assert logs =~ "user_id=" <> actor.id

    assert logs =~ "Passkey verification failed"
    assert logs =~ "reason=registration_failed"
    assert logs =~ "reason=verification_failed"
    assert length(Regex.scan(~r/Passkey verification failed/, logs)) == 2

    refute logs =~ label_marker
    refute logs =~ origin_marker
    refute logs =~ failed_registration["attestation_object"]
    refute logs =~ failed_registration["client_data_json"]
    refute logs =~ failed_assertion["signature"]
    refute logs =~ failed_assertion["client_data_json"]
  end

  # @cc [owner:ghuntley,label:verification] challenge-retention-bound
  # The per-account challenge bound MUST count retained rows (any purpose,
  # unconsumed or consumed), refuse issuance beyond ten with the specific
  # :try_later boundary, prune expired rows on each issuance and admit fresh
  # ceremonies once pruning freed capacity; the bound MUST NOT be attempt-based.
  test "challenge issuance prunes expired rows and bounds retained challenges per account" do
    {actor, _} = login(user())

    challenges =
      Enum.map(1..10, fn _ ->
        {:ok, challenge} = action(actor, :begin_register)
        challenge
      end)

    retained = Ledger.read!(PasskeyChallenge, user_id: actor.id)
    assert length(retained) == 10
    assert Enum.all?(retained, &is_nil(&1.consumed_at))

    # The eleventh retained challenge hits the specific capacity boundary.
    assert {:error, full} = action(actor, :begin_register)
    assert inspect(full) =~ "try_later"

    # Refusal does not consume or delete retained rows.
    assert length(Ledger.read!(PasskeyChallenge, user_id: actor.id)) == 10

    expiring = challenges |> Enum.take(3) |> Enum.map(&Ecto.UUID.dump!(&1.id))

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE account_passkey_challenges SET expires_at = clock_timestamp() - interval '1 second' WHERE id = ANY($1::uuid[])",
      [expiring]
    )

    # Expired rows are retained until the next issuance prunes them.
    assert length(Ledger.read!(PasskeyChallenge, user_id: actor.id)) == 10

    assert {:ok, fresh} = action(actor, :begin_register)

    remaining = Ledger.read!(PasskeyChallenge, user_id: actor.id)
    assert length(remaining) == 8
    assert fresh.id in Enum.map(remaining, & &1.id)

    assert Enum.all?(remaining, fn row ->
             row.id == fresh.id or DateTime.compare(row.expires_at, Ledger.now()) == :gt
           end)

    # Refilling to the bound produces the same specific boundary again.
    for _ <- 1..2, do: assert({:ok, _} = action(actor, :begin_register))
    assert {:error, full_again} = action(actor, :begin_register)
    assert inspect(full_again) =~ "try_later"
    assert length(Ledger.read!(PasskeyChallenge, user_id: actor.id)) == 10
  end
end
