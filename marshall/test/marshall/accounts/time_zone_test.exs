defmodule Marshall.Accounts.TimeZoneTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog
  alias Marshall.Accounts.{TimeZones, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query

  defp user, do: Marshall.ComputeFixtures.user()

  defp set(actor, zone) do
    User
    |> Ash.ActionInput.for_action(:set_time_zone, %{time_zone: zone}, actor: actor)
    |> Ash.run_action()
  end

  defp stored(id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
    |> Map.fetch!(:time_zone)
  end

  @tag :hegel_case_sandbox
  property "set_time_zone round-trips valid zones and refuses everything else", test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    actor = user()
    curated = Enum.map(TimeZones.curated(), &elem(&1, 1))

    zone =
      draw(
        "zone",
        one_of([
          member_of(curated),
          constant("America/Argentina/Ushuaia"),
          string(:printable, max_length: 70),
          map(member_of(curated), &String.upcase/1)
        ])
      )

    before = stored(actor.id)

    case set(actor, zone) do
      {:ok, %{user_id: id, time_zone: saved}} ->
        assert id == actor.id
        assert TimeZones.valid?(zone)
        assert saved == String.trim(zone)
        assert stored(actor.id) == saved

      {:error, _} ->
        refute TimeZones.valid?(String.trim(zone)) and String.trim(zone) != ""
        assert stored(actor.id) == before
    end
  end

  test "a user changes only their own zone; nil clears it" do
    actor = user()
    other = user()
    assert {:ok, %{time_zone: "Australia/Adelaide"}} = set(actor, "Australia/Adelaide")
    assert stored(actor.id) == "Australia/Adelaide"
    assert stored(other.id) == nil

    # The action has no target argument; a forged one is rejected by Ash.
    assert {:error, _} =
             User
             |> Ash.ActionInput.for_action(
               :set_time_zone,
               %{time_zone: "Asia/Tokyo", user_id: other.id},
               actor: actor
             )
             |> Ash.run_action()

    assert stored(other.id) == nil
    assert stored(actor.id) == "Australia/Adelaide"

    assert {:ok, %{time_zone: nil}} = set(actor, nil)
    assert stored(actor.id) == nil
  end

  test "invalid zones are refused with the closed reason and leave the row unchanged" do
    actor = user()
    assert {:ok, _} = set(actor, "Europe/London")

    for bad <- ["Mars/Olympus", "australia/adelaide", "Etc/UTC; DROP", String.duplicate("x", 64)] do
      assert {:error, error} = set(actor, bad)
      assert Exception.message(error) =~ "invalid_time_zone"
      assert stored(actor.id) == "Europe/London"
    end

    # The internal store action refuses an unresolvable zone on its own.
    locked = Marshall.Accounts.Security.lock_user!(actor.id)

    assert_raise Ash.Error.Invalid, fn ->
      Ledger.update!(locked, :store_time_zone, %{time_zone: "Nowhere/Here"})
    end

    assert stored(actor.id) == "Europe/London"
  end

  test "non-user and retired actors are refused" do
    assert {:error, %Ash.Error.Forbidden{}} = set(SystemActor.compute(), "Europe/London")
    assert {:error, %Ash.Error.Forbidden{}} = set(nil, "Europe/London")

    retired = user()
    Ledger.update!(retired, :security_state, %{deleted_at: DateTime.utc_now()})
    # Cedar admission refuses a retired account before the coordinator runs.
    assert {:error, %Ash.Error.Forbidden{}} = set(retired, "Europe/London")
  end

  test "the change event carries the user id and never the zone text" do
    actor = user()
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log([metadata: [:event, :user_id, :time_zone, :zone]], fn ->
        assert {:ok, _} = set(actor, "Pacific/Chatham")
      end)

    assert logs =~ "event=account.time_zone_changed"
    assert logs =~ actor.id
    refute logs =~ "Chatham"
    refute logs =~ "time_zone="
  end
end
