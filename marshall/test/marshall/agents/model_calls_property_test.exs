defmodule Marshall.Agents.ModelCallsPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "only bounded inference overloads are retried", test_cases: 100 do
    check all(
            iteration <- integer(1..5),
            purpose <- one_of([constant(:inference), constant(:summary)]),
            error <-
              one_of([constant("upstream_failed"), constant("server_is_overloaded"), string()])
          ) do
      expected =
        purpose == :inference and iteration < 3 and
          error in ["upstream_failed", "server_is_overloaded"]

      assert Marshall.Agents.ModelCalls.retryable_provider_response?(purpose, iteration, %{
               "error" => error
             }) == expected
    end
  end
end
