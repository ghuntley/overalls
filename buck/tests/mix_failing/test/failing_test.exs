defmodule Overalls.MixFailingFixtureTest do
  use ExUnit.Case, async: true

  # The regression test reads this marker from each build's failure output;
  # the run's nonce shows whether the suite ran again or a log was replayed.
  test "fails on purpose" do
    flunk(
      "mix_failing_fixture: deliberate failure run=#{System.unique_integer([:positive])}-#{System.system_time()}"
    )
  end
end
