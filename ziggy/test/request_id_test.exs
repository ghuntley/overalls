defmodule Ziggy.RequestIdTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "new inference IDs contain the current timestamp and RFC UUIDv7 bits" do
    count = draw("count", integer(1..32))
    before = System.system_time(:millisecond)
    ids = Enum.map(1..count, fn _ -> Ziggy.RequestId.generate() end)
    after_generation = System.system_time(:millisecond)

    assert length(Enum.uniq(ids)) == count

    for id <- ids do
      assert Ziggy.RequestId.valid?(id)
      assert OverallsProtocol.uuid?(id)
      bytes = id |> String.replace("-", "") |> Base.decode16!(case: :lower)
      assert <<timestamp::48, 7::4, _::12, 2::2, _::62>> = bytes
      assert timestamp in before..after_generation
    end
  end

  test "only lowercase canonical RFC UUIDv7 identities are accepted" do
    valid = "01a19af4-2bf7-746b-ac25-51a8b9a8c39a"
    assert Ziggy.RequestId.valid?(valid)

    for invalid <- [
          String.upcase(valid),
          String.replace(valid, "-", ""),
          "urn:uuid:" <> valid,
          String.replace(valid, "-746b-", "-446b-"),
          String.replace(valid, "-ac25-", "-fc25-"),
          "00000000-0000-0000-0000-000000000000",
          nil,
          1,
          %{}
        ] do
      refute Ziggy.RequestId.valid?(invalid)
    end
  end
end
