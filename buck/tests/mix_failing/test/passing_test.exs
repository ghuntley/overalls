defmodule Overalls.MixFailingFixturePassingTest do
  use ExUnit.Case, async: true

  # A passing file beside the failing one, so the fixture runs sharded and a
  # failed shard must still fail the whole target.
  test "passes" do
    assert true
  end
end
