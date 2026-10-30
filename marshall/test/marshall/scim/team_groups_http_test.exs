Code.require_file("team_fixture.exs", __DIR__)

defmodule Marshall.Scim.TeamGroupsHttpTest do
  @moduledoc "SCIM Groups over the real /scim/v2 endpoint, bearer authentication and Teams."
  use MarshallWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Marshall.Compute.Ledger
  alias Marshall.Scim.TeamFixture, as: Fixture
  alias Marshall.Teams.{ServiceOwner, Team, TeamMember, Transfer}

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    alice = Marshall.ComputeFixtures.user()
    bob = Marshall.ComputeFixtures.user()
    carol = Marshall.ComputeFixtures.user()
    %{token: Fixture.enable!(), alice: alice, bob: bob, carol: carol, owner: ServiceOwner.get!()}
  end

  test "POST creates a SCIM-managed team owned only by the hidden service owner", c do
    name = Fixture.team_name()

    logs =
      capture_log([metadata: [:event, :operation_status]], fn ->
        assert {201, body} =
                 Fixture.request(c.token, :post, "/Groups", Fixture.group(name, [c.alice.id]))

        send(self(), {:created, body})
      end)

    assert_received {:created, body}
    assert body["displayName"] == name
    assert [%{"value" => alice_id}] = body["members"]
    assert alice_id == c.alice.id

    [team] = Ledger.read!(Team, id: body["id"])
    assert team.management_mode == :scim_managed
    assert team.created_by_id == c.owner.id

    assert Fixture.memberships(team.id) ==
             Enum.sort([{c.owner.id, :owner}, {c.alice.id, :member}])

    assert [%{recorded_by_id: recorded_by}] =
             Ledger.read!(TeamMember, team_id: team.id, user_id: c.alice.id)

    assert recorded_by == c.owner.id
    assert logs =~ "team.membership_changed"

    # The service owner never appears in SCIM, member lists or the directory.
    assert {200, fetched} = Fixture.request(c.token, :get, "/Groups/#{team.id}")
    assert Enum.map(fetched["members"], & &1["value"]) == [c.alice.id]

    assert {:ok, members} = Marshall.Teams.list_team_members(%{team_id: team.id}, actor: c.alice)
    assert Enum.map(members, & &1.user_id) == [c.alice.id]

    assert {:ok, all} = Marshall.Teams.list_all_teams(%{}, actor: c.bob)

    assert %{member_count: 1, management_mode: :scim_managed} =
             Enum.find(all, &(&1.id == team.id))
  end

  test "PUT renames and replaces members without touching the owner membership", c do
    {201, %{"id" => id}} =
      Fixture.request(
        c.token,
        :post,
        "/Groups",
        Fixture.group(Fixture.team_name(), [c.alice.id, c.bob.id])
      )

    [alice_row] = Ledger.read!(TeamMember, team_id: id, user_id: c.alice.id)
    renamed = Fixture.team_name()

    assert {200, body} =
             Fixture.request(
               c.token,
               :put,
               "/Groups/#{id}",
               Fixture.group(renamed, [c.alice.id, c.carol.id])
             )

    assert body["displayName"] == renamed
    assert [%{name: ^renamed}] = Ledger.read!(Team, id: id)

    assert Fixture.memberships(id) ==
             Enum.sort([{c.owner.id, :owner}, {c.alice.id, :member}, {c.carol.id, :member}])

    # Unchanged members are matched by identity, not recreated.
    assert [%{id: alice_row_id}] = Ledger.read!(TeamMember, team_id: id, user_id: c.alice.id)
    assert alice_row_id == alice_row.id
  end

  # Regression from TeamScimPropertyTest: an explicitly empty member list used
  # to be decoded as "members absent", so the PUT left every member in place.
  test "PUT with an empty member list removes every member but keeps the owner", c do
    name = Fixture.team_name()

    {201, %{"id" => id}} =
      Fixture.request(c.token, :post, "/Groups", Fixture.group(name, [c.alice.id, c.bob.id]))

    assert {200, _body} = Fixture.request(c.token, :put, "/Groups/#{id}", Fixture.group(name, []))
    assert Fixture.memberships(id) == [{c.owner.id, :owner}]

    # A list whose entries carry no member value is ignored, not a clear-all.
    {201, %{"id" => other}} =
      Fixture.request(c.token, :post, "/Groups", Fixture.group(Fixture.team_name(), [c.carol.id]))

    body = %{Fixture.group(Fixture.team_name(), []) | "members" => [%{"display" => "x"}]}
    assert {200, _body} = Fixture.request(c.token, :put, "/Groups/#{other}", body)
    assert Fixture.memberships(other) == Enum.sort([{c.owner.id, :owner}, {c.carol.id, :member}])
  end

  test "PATCH adds and removes members idempotently and never removes the owner", c do
    {201, %{"id" => id}} =
      Fixture.request(c.token, :post, "/Groups", Fixture.group(Fixture.team_name(), [c.alice.id]))

    add =
      Fixture.patch([
        %{"op" => "add", "path" => "members", "value" => [%{"value" => c.bob.id}]}
      ])

    assert {200, _} = Fixture.request(c.token, :patch, "/Groups/#{id}", add)
    assert {200, _} = Fixture.request(c.token, :patch, "/Groups/#{id}", add)

    assert Fixture.memberships(id) ==
             Enum.sort([{c.owner.id, :owner}, {c.alice.id, :member}, {c.bob.id, :member}])

    remove =
      Fixture.patch([
        %{"op" => "remove", "path" => ~s(members[value eq "#{c.alice.id}"])}
      ])

    assert {200, _} = Fixture.request(c.token, :patch, "/Groups/#{id}", remove)
    assert Fixture.memberships(id) == Enum.sort([{c.owner.id, :owner}, {c.bob.id, :member}])

    remove_owner =
      Fixture.patch([
        %{"op" => "remove", "path" => ~s(members[value eq "#{c.owner.id}"])}
      ])

    assert {200, _} = Fixture.request(c.token, :patch, "/Groups/#{id}", remove_owner)

    clear = Fixture.patch([%{"op" => "remove", "path" => "members"}])
    assert {200, _} = Fixture.request(c.token, :patch, "/Groups/#{id}", clear)
    assert Fixture.memberships(id) == [{c.owner.id, :owner}]
  end

  test "DELETE revokes authority immediately and the worker archives the team", c do
    {201, %{"id" => id}} =
      Fixture.request(
        c.token,
        :post,
        "/Groups",
        Fixture.group(Fixture.team_name(), [c.alice.id, c.bob.id])
      )

    assert {204, nil} = Fixture.request(c.token, :delete, "/Groups/#{id}")

    [team] = Ledger.read!(Team, id: id)
    assert team.management_mode == :retiring
    assert Fixture.memberships(id) == [{c.owner.id, :owner}]
    assert {404, _} = Fixture.request(c.token, :get, "/Groups/#{id}")

    assert [job] =
             Oban.Testing.all_enqueued(
               repo: Marshall.Repo,
               worker: Marshall.Scim.TeamRetirementWorker
             )

    assert job.args == %{"team_id" => id}

    assert :ok =
             Oban.Testing.perform_job(Marshall.Scim.TeamRetirementWorker, job.args,
               repo: Marshall.Repo
             )

    assert Ledger.read!(Team, id: id) == []
    assert Ledger.read!(TeamMember, team_id: id) == []
    assert Ledger.read!(Transfer, team_id: id) == []
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(Team, id: id)

    # Idempotent re-delivery.
    assert :ok =
             Oban.Testing.perform_job(Marshall.Scim.TeamRetirementWorker, job.args,
               repo: Marshall.Repo
             )
  end

  test "SCIM refuses native teams and unauthenticated or disabled requests", c do
    native = Ash.Seed.seed!(Team, %{name: Fixture.team_name(), created_by_id: c.alice.id})

    Ash.Seed.seed!(TeamMember, %{
      team_id: native.id,
      user_id: c.alice.id,
      role: :owner,
      recorded_by_id: c.alice.id
    })

    assert {404, _} = Fixture.request(c.token, :get, "/Groups/#{native.id}")

    assert {status, _} =
             Fixture.request(
               c.token,
               :put,
               "/Groups/#{native.id}",
               Fixture.group(Fixture.team_name(), [c.bob.id])
             )

    assert status in 400..409
    assert {status, _} = Fixture.request(c.token, :delete, "/Groups/#{native.id}")
    assert status in 400..409
    assert [%{management_mode: :native}] = Ledger.read!(Team, id: native.id)

    assert {401, _} =
             Fixture.request("wrong", :post, "/Groups", Fixture.group(Fixture.team_name(), []))

    Fixture.disable!()

    assert {401, _} =
             Fixture.request(c.token, :post, "/Groups", Fixture.group(Fixture.team_name(), []))
  end
end
