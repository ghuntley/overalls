defmodule Lilly.Host.ImageTemplateDurableCopyTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Command, ImageTemplate}

  @key :crypto.hash(:sha256, "template-copy-test")
  @arguments ["copy", "/source", "/target.pending", "5"]

  @typep ops :: %{
           attach: (<<_::256>>, 0..120_000 -> Command.durable_result()),
           run_durable: (Command.name(), [String.t()], pos_integer(), <<_::256>> ->
                           Command.durable_result()),
           remove_pending: (Path.t() -> :ok)
         }

  # A fake hostd: attach answers `attached`; each run_durable answers the next
  # entry of `runs`. Every call is reported to the test process.
  @spec ops(Command.durable_result(), [Command.durable_result()]) :: ops()
  defp ops(attached, runs) do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> runs end)

    %{
      attach: fn key, _wait ->
        send(parent, {:attach, key})
        attached
      end,
      run_durable: fn name, arguments, _timeout, key ->
        send(parent, {:run, name, arguments, key})
        Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      end,
      remove_pending: fn path ->
        send(parent, {:remove, path})
        :ok
      end
    }
  end

  @spec copy(ops()) :: Command.durable_result()
  defp copy(ops),
    do: ImageTemplate.durable_copy("/target.pending", @arguments, 300_000, @key, ops)

  # @cc [owner:ghuntley,label:verification;recovery] template-copy-replayed-failure-reruns
  # A replayed stored copy failure MUST start exactly one fresh copy under the
  # same key and return its result; a job running at re-run MUST surface as
  # job_running without another copy.
  test "a replayed timeout starts one fresh copy and returns its result" do
    assert {:ok, "copy\n"} = copy(ops({:error, :command_timeout}, [{:ok, "copy\n"}]))
    assert_received {:attach, @key}
    assert_received {:remove, "/target.pending"}
    assert_received {:run, :image_copy, @arguments, @key}
    refute_received {:run, _, _, _}
  end

  test "every stored utility failure is re-run" do
    for reason <- [:command_failed, :command_output_limit, :utility_unavailable, :job_unknown] do
      assert {:error, :command_timeout} =
               copy(ops({:error, reason}, [{:error, :command_timeout}]))

      assert_received {:run, :image_copy, @arguments, @key}
      refute_received {:run, _, _, _}
    end
  end

  test "a job running at re-run surfaces job_running without a second copy" do
    assert {:error, :job_running} =
             copy(ops({:error, :command_timeout}, [{:error, :job_running}]))

    assert_received {:run, :image_copy, @arguments, @key}
    refute_received {:run, _, _, _}
  end

  test "a running job, a stored success and lock errors are returned without a copy" do
    for attached <- [
          {:error, :job_running},
          {:ok, "copy\n"},
          {:error, :host_lock_required},
          {:error, :host_lock_unavailable}
        ] do
      assert attached == copy(ops(attached, []))
      refute_received {:remove, _}
      refute_received {:run, _, _, _}
    end
  end
end
