defmodule Marshall.Terminal.PersonalSessionTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.GuestAccounts
  alias Marshall.Compute.Ledger
  alias Marshall.Terminal.Authority
  import Marshall.TerminalFixtures

  @tag :hegel_case_sandbox
  property "automatic retries share the SSH identity and never replace an exited shell",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    fixture = terminal_fixture()
    stream = stream_fixture(fixture.host.id, &Overalls.HegelFixtures.start_supervised!/1)

    assert {:ok, account} =
             Ledger.transaction(fn -> GuestAccounts.ensure!(fixture.owner.id) end)

    assert {:ok, session} = Authority.open_personal_session(fixture.vm, fixture.owner)

    retries = draw("retries", integer(1..8))

    for _ <- 1..retries do
      assert {:ok, repeated} = Authority.open_personal_session(fixture.vm, fixture.owner)
      assert repeated.id == session.id
    end

    assert {:ok, [listed]} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert listed.user == account.username
    assert {:ok, same} = Ledger.transaction(fn -> GuestAccounts.ensure!(fixture.owner.id) end)
    assert {same.id, same.uid} == {account.id, account.uid}

    send(stream, {:guest_exited, session.guest_session_id})
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:error, _} = Authority.open_personal_session(fixture.vm, fixture.owner)
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
  end

  test "email changes preserve an open personal terminal and future shell identity" do
    fixture = terminal_fixture()
    stream_fixture(fixture.host.id)
    assert {:ok, account} = Ledger.transaction(fn -> GuestAccounts.ensure!(fixture.owner.id) end)
    assert {:ok, session} = Authority.open_personal_session(fixture.vm, fixture.owner)
    assert {:ok, ticket} = Authority.ticket(session, fixture.owner)

    changed =
      Ledger.update!(fixture.owner, :security_state, %{email: "9terminal+tag@example.test"})

    assert {:ok, same} = Authority.open_personal_session(fixture.vm, changed)
    assert same.id == session.id
    assert same.guest_session_id == session.guest_session_id
    assert {:ok, [listed]} = Authority.list_sessions(fixture.vm, changed)
    assert listed.user == account.username
    assert {:ok, _} = Authority.ticket(session, changed)
    assert is_binary(ticket)
    assert {:ok, current} = Ledger.transaction(fn -> GuestAccounts.ensure!(changed.id) end)

    assert {current.id, current.uid, current.username, current.retired_at} ==
             {account.id, account.uid, account.username, nil}
  end

  test "viewers cannot allocate accounts or shells; operators get their own account" do
    fixture = terminal_fixture()
    stream_fixture(fixture.host.id)
    viewer = Marshall.ComputeFixtures.user()
    assert {:ok, _} = grant(fixture, viewer, :viewer)
    assert {:error, :forbidden} = Authority.open_personal_session(fixture.vm, viewer)
    assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
    assert {:ok, _} = grant(fixture, viewer, :operator)
    assert {:ok, session} = Authority.open_personal_session(fixture.vm, viewer)
    assert {:ok, account} = Ledger.transaction(fn -> GuestAccounts.ensure!(viewer.id) end)
    assert {:ok, [listed]} = Authority.list_sessions(fixture.vm, viewer)
    assert listed.user == account.username
    assert session.owner_id == viewer.id
    assert {:ok, _} = grant(fixture, viewer, :revoked)
    assert {:error, :forbidden} = Authority.open_personal_session(fixture.vm, viewer)
    assert {:error, :forbidden} = Authority.ticket(session, viewer)
  end

  test "a restart or changed execution can open a new default with the same account" do
    fixture = terminal_fixture()
    stream = stream_fixture(fixture.host.id)
    {:ok, account} = Ledger.transaction(fn -> GuestAccounts.ensure!(fixture.owner.id) end)

    for field <- [:generation, :execution_epoch] do
      assert {:ok, previous} = Authority.open_personal_session(fixture.vm, fixture.owner)
      send(stream, {:guest_exited, previous.guest_session_id})
      assert {:ok, []} = Authority.list_sessions(fixture.vm, fixture.owner)
      [current] = Ledger.read!(Marshall.Compute.VirtualMachine, id: fixture.vm.id)
      Ash.Seed.update!(current, %{field => Map.fetch!(current, field) + 1})
      assert {:ok, next} = Authority.open_personal_session(fixture.vm, fixture.owner)
      refute next.id == previous.id
      assert {:ok, [listed]} = Authority.list_sessions(fixture.vm, fixture.owner)
      assert listed.user == account.username
    end
  end
end
