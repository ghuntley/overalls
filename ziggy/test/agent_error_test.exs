defmodule Ziggy.AgentErrorTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  test "only exact provider rejection fields establish a context or compaction failure" do
    for code <- ["context_length_exceeded", "context_window_exceeded"] do
      assert :context_length_exceeded = Ziggy.AgentError.classify(%{"error" => %{"code" => code}})
    end

    for code <- ["unsupported_parameter", "unknown_parameter", "unsupported_value"] do
      assert :unsupported_compaction =
               Ziggy.AgentError.classify(%{
                 "error" => %{"code" => code, "param" => "compaction_trigger"}
               })

      assert :upstream_failed =
               Ziggy.AgentError.classify(%{"error" => %{"code" => code, "param" => "other"}})
    end

    assert :unsupported_compaction =
             Ziggy.AgentError.classify(%{"code" => "unsupported_compaction"})

    assert :incomplete = Ziggy.AgentError.terminal(%{"status" => "incomplete", "error" => nil})
    assert :cancelled = Ziggy.AgentError.terminal(%{"status" => "cancelled", "error" => nil})
    assert nil == Ziggy.AgentError.terminal(%{"status" => "completed", "error" => nil})
  end

  test "only exact closed pool and overload codes survive sanitization" do
    for {code, reason} <- [
          {"no_accounts", :no_accounts},
          {"pool_exhausted", :pool_exhausted},
          {"quota_exhausted", :quota_exhausted},
          {"server_is_overloaded", :server_is_overloaded}
        ] do
      assert Ziggy.AgentError.classify(%{"error" => %{"code" => code}}) == reason
      assert Ziggy.AgentError.classify(%{"error" => %{"type" => code}}) == reason
      assert Ziggy.AgentError.classify(%{"error" => %{"message" => code}}) == :upstream_failed
      assert Ziggy.AgentError.classify(code <> "_private") == :upstream_failed
    end

    assert Ziggy.AgentError.classify(%{"error" => %{"code" => "retryable_overload"}}) ==
             :upstream_failed
  end

  property "free-form provider errors never become recovery classes or diagnostics" do
    message = draw("message", string(:printable, min_length: 0, max_length: 256))
    assert :upstream_failed = Ziggy.AgentError.classify(%{"error" => %{"message" => message}})

    assert :upstream_failed =
             Ziggy.AgentError.classify(%{
               "error" => %{
                 "code" => "invalid_request",
                 "message" => message,
                 "param" => message
               }
             })
  end
end
