defmodule Marshall.Accounts.AdministratorsTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.{AdminBootstrap, AdminEvent, User}
  alias Marshall.Authorization.Cedar
  alias Marshall.Compute.Ledger

  @administrator_event_kinds [:bootstrap, :grant, :revoke]

  test "a current administrator can grant and revoke another account with audit" do
    admin = user(true)
    target = user(false)
    assert {:ok, %{administrator: true}} = set_role(admin, target, true)
    assert allowed?(Marshall.PasskeyFixture.verified_session(target))
    assert {:ok, %{administrator: false}} = set_role(admin, target, false)
    refute allowed?(target)
    assert Enum.sort(Enum.map(administrator_events(), & &1.kind)) == [:grant, :revoke]
  end

  test "self-demotion fails with one administrator or several" do
    admin = user(true)
    assert {:error, _} = set_role(admin, admin, false)
    user(true)
    assert {:error, _} = set_role(admin, admin, false)
    assert allowed?(admin)
    assert administrator_events() == []
  end

  test "forged and stale administrator structs cannot authorize changes" do
    admin = user(true)
    other = user(true)
    ordinary = user(false)
    refute allowed?(%{ordinary | administrator: true})
    assert {:error, _} = set_role(ordinary, ordinary, true)
    assert {:ok, _} = set_role(other, admin, false)
    refute allowed?(admin)
    assert {:error, _} = set_role(admin, ordinary, true)
  end

  test "admin guest access does not grant internal compute authority" do
    admin = user(true)
    vm = Marshall.CedarEntities.vm(Ash.UUID.generate(), Ash.UUID.generate())
    for action <- ~w(read write manage web), do: assert(Cedar.allowed?(admin, action, vm))
    refute Cedar.allowed?(admin, "coordinate", Cedar.entity("Internal", "test"))
  end

  test "first successful verified registration grants admin only once" do
    assert [%{completed: false}] = Ledger.read!(AdminBootstrap)
    assert {:ok, first} = register("first@example.test")
    assert first.administrator
    assert {:ok, second} = register("second@example.test")
    refute second.administrator
    assert {:ok, same} = register("first@example.test")
    assert same.id == first.id
    assert [%{completed: true}] = Ledger.read!(AdminBootstrap)
    assert [%{kind: :bootstrap, target_id: id}] = administrator_events()
    assert id == first.id
  end

  test "role changes emit correlated structured events after commit" do
    admin = user(true)
    target = user(false)

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :user_id, :actor_id, :operation_status]],
        fn ->
          assert {:ok, _} = set_role(admin, target, true)
          assert {:ok, _} = set_role(admin, target, true)
          assert {:ok, _} = set_role(admin, target, false)
        end
      )

    assert logs =~ "Administrator role changed"
    assert logs =~ "user_id=" <> target.id
    assert logs =~ "actor_id=" <> admin.id
    assert logs =~ "operation_status=granted"
    assert logs =~ "operation_status=revoked"
    assert length(Regex.scan(~r/Administrator role changed/, logs)) == 2
  end

  test "bootstrap emits its structured event exactly once at first registration" do
    parent = self()

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :user_id]],
        fn ->
          assert {:ok, first} = register("boot-a@example.test")
          assert {:ok, _} = register("boot-b@example.test")
          assert {:ok, _} = register("boot-a@example.test")
          send(parent, {:bootstrapped, first.id})
        end
      )

    assert_receive {:bootstrapped, id}
    assert logs =~ "Administrator bootstrapped"
    assert logs =~ "user_id=" <> id
    assert length(Regex.scan(~r/Administrator bootstrapped/, logs)) == 1
  end

  test "failed registration does not consume bootstrap" do
    assert {:error, _} = register("person@bad_domain.test")
    assert [%{completed: false}] = Ledger.read!(AdminBootstrap)
    assert [] = administrator_events()
    assert {:ok, %{administrator: true}} = register("valid@example.test")
  end

  test "completed bootstrap cannot reopen when no administrators exist" do
    [bootstrap] = Ledger.read!(AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    assert {:ok, %{administrator: false}} = register("later@example.test")
    assert [] = administrator_events()
  end

  defp user(admin),
    do:
      Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: admin})
      |> then(fn user ->
        if admin, do: Marshall.PasskeyFixture.verified_session(user), else: user
      end)

  defp allowed?(user),
    do: Cedar.allowed?(user, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))

  defp set_role(actor, target, enabled) do
    User
    |> Ash.ActionInput.for_action(
      :set_administrator,
      %{user_id: target.id, administrator: enabled},
      actor: actor
    )
    |> Ash.run_action()
  end

  defp administrator_events do
    AdminEvent
    |> Ledger.read!()
    |> Enum.filter(&(&1.kind in @administrator_event_kinds))
  end

  defp register(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    User
    |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.create()
  end
end
