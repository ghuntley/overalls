defmodule Marshall.Access.SharingTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute}
  alias Marshall.Access.{Authorization, Change, Grant}
  alias Marshall.Compute.{Ledger, VirtualMachine}

  setup do
    fixture = host_fixture()
    owner = user()
    member = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    %{owner: owner, member: member, vm: vm, fixture: fixture}
  end

  test "sharing logs follow the outer commit and do not duplicate an idempotent receipt", c do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    key = Ash.UUID.generate()

    rollback_logs =
      ExUnit.CaptureLog.capture_log([level: :info, metadata: [:event]], fn ->
        assert {:error, :test_rollback} =
                 Ledger.transaction(fn ->
                   assert {:ok, _} = share(c, :viewer, key)
                   Ledger.rollback(:test_rollback)
                 end)
      end)

    refute rollback_logs =~ "event=vm.access_changed"
    assert Ledger.read!(Change, vm_id: c.vm.id) == []

    commit_logs =
      ExUnit.CaptureLog.capture_log([level: :info, metadata: [:event]], fn ->
        assert {:ok, :ok} =
                 Ledger.transaction(fn ->
                   assert {:ok, _} = share(c, :viewer, key)
                   assert {:ok, _} = share(c, :viewer, key)
                   :ok
                 end)
      end)

    assert length(Regex.scan(~r/event=vm\.access_changed/, commit_logs)) == 1
  end

  test "persisted role replacement drives the real Cedar permission matrix", context do
    Hegel.check(
      fn ->
        roles =
          draw(
            "roles",
            list_of(member_of([:web, :viewer, :operator, :manager, :revoked]),
              min_length: 1,
              max_length: 8
            )
          )

        for role <- roles do
          assert {:ok, _} = share(context, role)

          for action <- ["read", "write", "manage", "web"] do
            expected =
              (action == "web" and role != :revoked) or role == :manager or
                (role == :operator and action in ["read", "write"]) or
                (role == :viewer and action == "read")

            assert Authorization.allowed?(context.vm, context.member, action) == expected
            assert Authorization.allowed?(context.vm, context.owner, action)
          end

          assert length(Ledger.read!(Grant, vm_id: context.vm.id, user_id: context.member.id)) ==
                   if(role == :revoked, do: 0, else: 1)
        end
      end,
      test_cases: 100
    )
  end

  test "delayed retries preserve subsequent revocation and reject changed semantics", context do
    key = Ash.UUID.generate()
    assert {:ok, original} = share(context, :manager, key)
    assert {:ok, _} = share(context, :revoked)
    assert {:ok, replay} = share(context, :manager, key)
    assert replay.id == original.id
    refute Authorization.allowed?(context.vm, context.member, "manage")
    assert {:error, error} = share(context, :viewer, key)
    assert Exception.message(error) =~ "idempotency_conflict"
    assert length(Ledger.read!(Change)) == 2

    assert [%{archived_at: %DateTime{}, revoked_by_id: owner}] =
             Ledger.history!(Grant, vm_id: context.vm.id)

    assert owner == context.owner.id
    assert Enum.any?(Ledger.read!(Grant.Version), &(&1.version_action_name == :revoke))
  end

  test "administrator sharing inventory returns bounded identity projection and revokes",
       context do
    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{
        email: "admin-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })
      |> Marshall.PasskeyFixture.verified_session()

    assert {:ok, _} = share(context, :viewer)

    assert {:ok, [grant]} = Access.list_grants_for_admin(%{}, actor: admin)
    assert grant.vm_id == context.vm.id
    assert grant.email == context.member.email
    refute Map.has_key?(grant, :terminal_bytes)

    assert {:ok, %{revoked: true}} = Access.revoke_grant_for_admin(%{id: grant.id}, actor: admin)
    assert {:ok, []} = Access.list_grants_for_admin(%{}, actor: admin)

    assert [%{kind: :vm_grant_revoke, target_id: id}] =
             Ledger.read!(Marshall.Accounts.AdminEvent, target_id: grant.id)

    assert id == grant.id
  end

  test "administrator workload inventory returns bounded owner projection", context do
    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{
        email: "admin-vm-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })
      |> Marshall.PasskeyFixture.verified_session()

    assert {:ok, %{items: [vm]}} = Compute.list_vms_for_admin(%{}, actor: admin)
    assert vm.id == context.vm.id
    assert vm.owner_email == context.owner.email
    refute Map.has_key?(vm, :terminal_bytes)
    refute Map.has_key?(vm, :private_key)
  end

  test "manager may share and manage lifecycle; viewers and operators cannot", context do
    for role <- [:web, :viewer, :operator] do
      assert {:ok, _} = share(context, role)

      assert {:error, _} =
               Compute.lifecycle(
                 %{vm_id: context.vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                 actor: context.member
               )

      assert {:error, _} = Access.set_access(params(context, :manager), actor: context.member)
      assert {:error, _} = Access.list_grants(%{vm_id: context.vm.id}, actor: context.member)
    end

    assert {:ok, _} = share(context, :manager)

    assert {:ok, operation} =
             Compute.lifecycle(
               %{vm_id: context.vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
               actor: context.member
             )

    assert operation.requested_by_id == context.member.id

    assert {:ok, %{owner: %{role: :owner}, items: [%{role: :manager}]}} =
             Access.list_grants(%{vm_id: context.vm.id}, actor: context.member)

    assert {:ok, _} = Access.set_access(params(context, :viewer), actor: context.member)
    refute Authorization.allowed?(context.vm, context.member, "manage")
  end

  test "ownership is protected, recipient lookup is exact, and unregistered users are not invited",
       context do
    for role <- [:viewer, :operator, :manager, :revoked] do
      request = %{params(context, role) | email: to_string(context.owner.email)}
      assert {:error, error} = Access.set_access(request, actor: context.owner)
      assert Exception.message(error) =~ "owner_protected"
    end

    assert {:error, _} =
             Access.set_access(%{params(context, :viewer) | email: "nobody@example.test"},
               actor: context.owner
             )

    assert {:error, _} =
             Access.set_access(%{params(context, :viewer) | email: "example.test"},
               actor: context.owner
             )

    assert {:ok, _} =
             Access.set_access(
               %{
                 params(context, :viewer)
                 | email: String.upcase(to_string(context.member.email))
               },
               actor: context.owner
             )

    assert length(Ledger.read!(Change)) == 1
  end

  test "user-scoped reads are bounded and do not leak internal ledger fields", context do
    stranger = user()
    assert {:ok, %{items: [], next_cursor: nil}} = Compute.list_vms(%{}, actor: stranger)
    assert {:error, _} = Compute.get_vm(%{vm_id: context.vm.id}, actor: stranger)
    assert {:ok, _} = share(context, :viewer)
    assert {:ok, vm} = Compute.get_vm(%{vm_id: context.vm.id}, actor: context.member)
    assert vm.permissions == %{read: true, write: false, manage: false}
    assert vm.host == context.fixture.host.name
    refute Map.has_key?(vm, :host_id)
    refute Map.has_key?(vm, :idempotency_key)
    refute vm.owner
    assert {:ok, %{items: [shared]}} = Compute.list_vms(%{}, actor: context.member)
    assert shared.id == vm.id
    assert shared.host == context.fixture.host.name
    assert {:error, _} = Compute.list_vms(%{limit: 101}, actor: context.owner)
    assert {:ok, _} = share(context, :revoked)
    assert {:ok, %{items: []}} = Compute.list_vms(%{}, actor: context.member)
    assert {:error, _} = Compute.get_vm(%{vm_id: context.vm.id}, actor: context.member)
    assert {:ok, _} = Compute.get_vm(%{vm_id: context.vm.id}, actor: context.owner)
  end

  test "web-only sharing permits web authorization without exposing management pages", context do
    assert {:ok, _} = share(context, :web)
    assert Authorization.allowed?(context.vm, context.member, "web")

    for action <- ["read", "write", "manage"] do
      refute Authorization.allowed?(context.vm, context.member, action)
    end

    assert {:ok, %{items: [], next_cursor: nil}} = Compute.list_vms(%{}, actor: context.member)
    assert {:error, _} = Compute.get_vm(%{vm_id: context.vm.id}, actor: context.member)
    assert {:ok, _} = share(context, :revoked)
    refute Authorization.allowed?(context.vm, context.member, "web")
  end

  test "public users cannot bypass coordinators or enumerate registered accounts", context do
    for resource <- [Grant, Change, VirtualMachine] do
      assert {:error, _} = Ash.read(resource, actor: context.owner)
      assert {:error, _} = Ash.read(resource)
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(Ash.Query.for_read(Marshall.Accounts.User, :internal_lookup),
               actor: context.owner
             )

    assert {:error, _} =
             Access.set_access(params(context, :viewer), actor: %{id: context.owner.id})

    assert {:error, _} = Access.set_access(params(context, :viewer))

    assert {:error, _} =
             Ash.create(
               Grant,
               %{
                 vm_id: context.vm.id,
                 user_id: context.member.id,
                 role: :manager,
                 granted_by_id: context.owner.id
               },
               action: :grant,
               actor: context.owner
             )
  end

  test "deleted intent rejects grant mutation but remains visible until archival", context do
    assert {:ok, _} = share(context, :viewer)

    assert {:ok, _} =
             Compute.lifecycle(
               %{vm_id: context.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: context.owner
             )

    assert {:error, error} = share(context, :manager)
    assert Exception.message(error) =~ "vm_deleted"

    assert {:ok, %{desired_state: :deleted}} =
             Compute.get_vm(%{vm_id: context.vm.id}, actor: context.member)
  end

  test "cursor pages bound VM and grant results without exposing unrelated machines", context do
    members = [context.member, user(), user()]

    for member <- members do
      assert {:ok, _} =
               Access.set_access(%{params(context, :viewer) | email: to_string(member.email)},
                 actor: context.owner
               )
    end

    {:ok, first} = Access.list_grants(%{vm_id: context.vm.id, limit: 1}, actor: context.owner)

    {:ok, second} =
      Access.list_grants(%{vm_id: context.vm.id, limit: 1, after: first.next_cursor},
        actor: context.owner
      )

    {:ok, third} =
      Access.list_grants(%{vm_id: context.vm.id, limit: 1, after: second.next_cursor},
        actor: context.owner
      )

    assert length(first.items) == 1 and length(second.items) == 1 and length(third.items) == 1
    assert third.next_cursor == nil

    assert MapSet.new(first.items ++ second.items ++ third.items, & &1.user_id) ==
             MapSet.new(members, & &1.id)

    {:ok, another} = Compute.provision(request(%{vcpu: 1}), actor: context.owner)
    {:ok, _private} = Compute.provision(request(%{vcpu: 1}), actor: user())
    {:ok, first} = Compute.list_vms(%{limit: 1}, actor: context.owner)
    {:ok, second} = Compute.list_vms(%{limit: 1, after: first.next_cursor}, actor: context.owner)
    assert second.next_cursor == nil

    assert MapSet.new(first.items ++ second.items, & &1.id) ==
             MapSet.new([context.vm.id, another.id])
  end

  test "catalog excludes unavailable hosts and does not count CPU once per pool", context do
    [host] = Ledger.read!(Marshall.Compute.Host, id: context.vm.host_id)
    {:ok, before} = Compute.catalog(%{}, actor: context.owner)
    assert before.available.vcpu == 2

    pool =
      Marshall.ComputeFixtures.pool_fixture(host, %{
        name: "second",
        zpool_guid: "3",
        dataset_guid: "4",
        dataset: "other/lilly",
        overhead_bytes: 0
      })

    Ledger.update!(pool, :report, %{
      total_bytes: 1_073_741_824,
      free_bytes: 1_073_741_824,
      allocations: %{},
      reported_at: Ledger.now()
    })

    {:ok, after_pool} = Compute.catalog(%{}, actor: context.owner)
    assert after_pool.available.vcpu == before.available.vcpu
    assert after_pool.available.memory_bytes == before.available.memory_bytes
    assert after_pool.available.disk_bytes == before.available.disk_bytes + 1_073_741_824
    Ledger.update!(host, :disconnect, %{reported_at: nil})

    assert {:ok, %{images: [], available: %{vcpu: 0, memory_bytes: 0, disk_bytes: 0}}} =
             Compute.catalog(%{}, actor: context.owner)
  end

  defp params(context, role, key \\ Ash.UUID.generate()),
    do: %{
      vm_id: context.vm.id,
      email: to_string(context.member.email),
      role: role,
      idempotency_key: key
    }

  defp share(context, role, key \\ Ash.UUID.generate()),
    do: Access.set_access(params(context, role, key), actor: context.owner)
end
