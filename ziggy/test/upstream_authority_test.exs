defmodule Ziggy.UpstreamAuthorityTest do
  use ExUnit.Case, async: true

  defmodule BlockedFinch do
    @spec stream_while(
            term(),
            pid(),
            map(),
            (term(), map() -> {:cont, map()} | {:halt, map()}),
            keyword()
          ) :: {:ok, map()}
    def stream_while(_request, owner, state, _callback, options) do
      send(owner, {:blocked_upstream, options})

      receive do
        :release -> {:ok, state}
      end
    end
  end

  test "authority expiry cancels an upstream read despite the longer Underclass silence budget" do
    owner = self()
    request_id = Ziggy.RequestId.generate()
    tasks = start_supervised!({Task.Supervisor, []})

    {:ok, route} =
      Ziggy.Route.resolve("POST", "/v1/responses", "", ~s({"model":"test","input":[]}))

    process =
      spawn(fn ->
        Ziggy.Upstream.stream(route, "synthetic-key", [], fn _ -> :ok end,
          finch: owner,
          finch_module: BlockedFinch,
          request_id: request_id,
          openai_origin: "https://panterloons.lorikeet-bangus.ts.net"
        )
      end)

    monitor = Process.monitor(process)

    on_exit(fn ->
      if Process.alive?(process) do
        cleanup_monitor = Process.monitor(process)
        Process.exit(process, :kill)
        assert_receive {:DOWN, ^cleanup_monitor, :process, ^process, :killed}, 1000
      end
    end)

    lease =
      start_supervised!(
        {Ziggy.Lease,
         owner: process,
         tasks: tasks,
         request_id: request_id,
         ttl_ms: 30_000,
         renewal_ms: 10_000,
         renew: fn -> :ok end}
      )

    assert_receive {:blocked_upstream, options}
    assert options[:receive_timeout] == 600_000
    send(lease, :expire)
    assert_receive {:DOWN, ^monitor, :process, ^process, :killed}, 1000
  end
end
