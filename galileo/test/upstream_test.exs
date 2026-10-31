defmodule Galileo.UpstreamTest do
  # These real TLS histories require progress inside 600ms leases. Keep their
  # fixture execution separate from unrelated ExUnit modules; cancellation and
  # renewal still run concurrently under the original deadlines in every case.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Galileo.Upstream
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  defmodule UploadOrigin do
    @behaviour Plug
    @impl true
    def init(options), do: options

    @impl true
    def call(conn, owner) do
      if String.starts_with?(conn.request_path, "/history/"),
        do: send(owner, {:origin_attempt, conn.request_path}),
        else: send(owner, :origin_attempt)

      if String.starts_with?(conn.request_path, "/history/partial/") do
        partial(conn)
      else
        ordinary(conn, owner)
      end
    end

    @spec partial(Plug.Conn.t()) :: Plug.Conn.t()
    defp partial(conn) do
      ["", "history", "partial", chunks, size] = String.split(conn.request_path, "/")
      {chunks, ""} = Integer.parse(chunks)
      {size, ""} = Integer.parse(size)
      true = chunks in 1..5 and size in 1..256
      conn = Plug.Conn.send_chunked(conn, 200)

      conn =
        Enum.reduce(1..chunks, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("p", size))
          conn
        end)

      receive do
        :never_sent -> conn
      after
        2000 ->
          case Plug.Conn.chunk(conn, "late") do
            {:ok, conn} -> conn
            {:error, _} -> conn
          end
      end
    end

    @spec ordinary(Plug.Conn.t(), pid()) :: Plug.Conn.t()
    defp ordinary(conn, owner) do
      if conn.request_path == "/stall" do
        receive do
          :never_sent -> Plug.Conn.send_resp(conn, 200, "late")
        after
          2_000 -> Plug.Conn.send_resp(conn, 200, "late")
        end
      else
        consume(conn, owner, 0)
      end
    end

    defp consume(conn, owner, count) do
      case Plug.Conn.read_body(conn, length: 16_384, read_length: 16_384) do
        {:more, bytes, conn} ->
          send(owner, {:origin_chunk, byte_size(bytes)})
          consume(conn, owner, count + byte_size(bytes))

        {:ok, bytes, conn} ->
          send(owner, {:origin_chunk, byte_size(bytes)})
          Plug.Conn.send_resp(conn, 200, Integer.to_string(count + byte_size(bytes)))
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-partial-response-cutoff
  # Generated partial response prefixes MUST survive unchanged before refusal,
  # invalid renewal, expiry or consumer halt. No late bytes or replay may be
  # delivered after the single attempt returns cancelled.
  # Each case retains its lease/quiet windows and retires a 2s origin handler.
  @tag timeout: 300_000
  property "partial responses stop at lease or consumer cancellation" do
    origin = start_origin()
    chunks = draw("chunks", integer(1..5))
    size = draw("size", integer(1..256))
    terminal = draw("terminal", member_of([:refused, :invalid, :expired, :halt]))

    owner = self()
    nonce = make_ref()
    path = "/history/partial/#{chunks}/#{size}"

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 600},
        method: "GET",
        path: path,
        query: "",
        body_state: :empty,
        pull: fn state -> {:ok, "", state} end,
        headers: [],
        consume: fn
          {:data, bytes} ->
            send(owner, {:partial_data, nonce, bytes})
            if terminal == :halt, do: :halt, else: :ok

          _ ->
            :ok
        end,
        renew: fn ->
          case terminal do
            :refused -> {:error, :unauthorized}
            :invalid -> {:ok, %{ttl: 0}}
            :expired -> Process.sleep(1200)
            :halt -> {:ok, %{ttl: 600}}
          end
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    delivered = delivered_partial(nonce, [])
    expected = String.duplicate("p", size * chunks)
    assert result.outcome == :cancelled
    assert result.status == 200
    assert result.response_bytes == byte_size(delivered)
    assert byte_size(delivered) > 0
    assert String.starts_with?(expected, delivered)
    if terminal != :halt, do: assert(delivered == expected)
    refute_receive {:partial_data, ^nonce, _}, 100
    assert_receive {:origin_attempt, ^path}
    refute_receive {:origin_attempt, ^path}, 100
  end

  @spec delivered_partial(reference(), [binary()]) :: binary()
  defp delivered_partial(nonce, chunks) do
    receive do
      {:partial_data, ^nonce, bytes} -> delivered_partial(nonce, [bytes | chunks])
    after
      0 -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  setup context do
    if Map.get(context, :hegel, false), do: %{}, else: %{origin: start_origin()}
  end

  # @cc [owner:ghuntley,label:verification] upstream-origin-case-custody
  # Each generated case MUST own its TLS origin and retire its listener and
  # stalled request handlers before the next case or replay. Ordinary tests
  # retain test-scoped origin ownership.
  @spec start_origin() :: String.t()
  defp start_origin do
    origin =
      Overalls.HegelFixtures.start_fixture!(
        {Bandit,
         plug: {UploadOrigin, self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(origin)
    "https://localhost:#{port}"
  end

  defp authorization(headers, peer \\ nil),
    do: %{
      target: "https://api.example.test",
      strip_prefix: nil,
      headers: headers,
      peer: peer,
      ttl: 5000
    }

  # @cc [owner:ghuntley,label:verification;reliability] galileo-bodiless-request-framing
  # Generated bodiless guest requests MUST reach a raw TLS origin with no
  # transfer-encoding and no body bytes; only methods anticipating content
  # carry an explicit zero content-length. The origin answers without draining
  # and closes, as the GitHub machine fixture does.
  property "bodiless guest requests are forwarded without chunked framing", profile: :ci do
    method = draw("method", member_of(~w(GET HEAD DELETE OPTIONS POST PUT PATCH)))
    guest = draw("guest", member_of([[], [{"content-length", "0"}], [{"Content-Length", " 0 "}]]))
    assert Upstream.request_content(guest) == :none

    {origin, listener} = raw_origin(self())

    try do
      result =
        Upstream.stream(%{target: origin, headers: [], ttl: 5000},
          method: method,
          path: "/bodiless",
          query: "",
          body_state: :empty,
          request_content: Upstream.request_content(guest),
          pull: fn state -> {:ok, "", state} end,
          headers: guest,
          consume: fn _ -> :ok end,
          renew: fn -> {:ok, %{ttl: 5000}} end,
          transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
        )

      assert_receive {:raw_request, head, trailing}, 2000
      [request_line | lines] = String.split(head, "\r\n")
      assert request_line == method <> " /bodiless HTTP/1.1"

      framing =
        for line <- lines,
            [name, value] = String.split(line, ":", parts: 2),
            String.downcase(name) in ["content-length", "transfer-encoding"],
            do: {String.downcase(name), String.trim(value)}

      expected = if method in ~w(POST PUT PATCH), do: [{"content-length", "0"}], else: []
      assert framing == expected
      assert trailing == ""
      assert result.outcome == :completed
      assert result.status == 200
      refute_receive {:raw_request, _, _}, 50
    after
      :ssl.close(listener)
    end
  end

  property "guest framing with content keeps the streamed request body" do
    framing =
      draw(
        "framing",
        member_of([
          [{"transfer-encoding", "chunked"}],
          [{"content-length", "1"}],
          [{"Content-Length", "4096"}],
          [{"content-length", "0"}, {"transfer-encoding", "chunked"}]
        ])
      )

    assert Upstream.request_content([{"accept", "*/*"} | framing]) == :stream
  end

  test "a source with content despite bodiless framing is streamed once", %{origin: origin} do
    owner = self()

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :unread,
        request_content: :none,
        pull: fn
          :unread -> {:more, "unframed", :tail}
          :tail -> {:ok, "!", :read}
        end,
        headers: [],
        consume: fn event ->
          send(owner, event)
          :ok
        end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.body_state == :read
    assert_receive :origin_attempt
    refute_receive :origin_attempt
    assert_receive {:data, "9"}
  end

  test "a failing source with bodiless framing never reaches the origin", %{origin: origin} do
    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "DELETE",
        path: "/bodiless",
        query: "",
        body_state: :unread,
        request_content: :none,
        pull: fn _ -> {:error, :truncated} end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :source_error
    assert result.body_state == :unread
    refute_receive :origin_attempt, 200
  end

  @spec raw_origin(pid()) :: {String.t(), :ssl.sslsocket()}
  defp raw_origin(owner) do
    {:ok, listener} =
      :ssl.listen(0,
        certfile: String.to_charlist(Path.join(@fixtures, "localhost.pem")),
        keyfile: String.to_charlist(Path.join(@fixtures, "localhost.key")),
        ip: {127, 0, 0, 1},
        mode: :binary,
        active: false,
        reuseaddr: true
      )

    {:ok, {_, port}} = :ssl.sockname(listener)

    spawn_link(fn ->
      with {:ok, transport} <- :ssl.transport_accept(listener, 2000),
           {:ok, socket} <- :ssl.handshake(transport, 2000) do
        {head, rest} = raw_head(socket, "")
        reply = "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        :ok = :ssl.send(socket, reply)
        send(owner, {:raw_request, head, rest <> raw_drain(socket, "")})
        :ssl.close(socket)
      end
    end)

    {"https://localhost:#{port}", listener}
  end

  @spec raw_head(:ssl.sslsocket(), binary()) :: {binary(), binary()}
  defp raw_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, bytes} = :ssl.recv(socket, 0, 2000)
        raw_head(socket, buffer <> bytes)
    end
  end

  @spec raw_drain(:ssl.sslsocket(), binary()) :: binary()
  defp raw_drain(socket, buffer) do
    case :ssl.recv(socket, 0, 200) do
      {:ok, bytes} -> raw_drain(socket, buffer <> bytes)
      {:error, _} -> buffer
    end
  end

  test "injected headers override guest duplicates and strip transport headers" do
    guest = [
      {"authorization", "Bearer guest-attempt"},
      {"x-api-token", "guest"},
      {"host", "evil.test"},
      {"content-length", "999"},
      {"connection", "keep-alive"},
      {"x-forwarded-for", "1.2.3.4"},
      {"accept", "text/plain"},
      {"content-type", "application/json"}
    ]

    authorization = authorization([{"authorization", "Bearer platform"}, {"x-api-token", "sk-1"}])
    headers = Upstream.headers(authorization, guest)

    assert {"authorization", "Bearer platform"} in headers
    assert {"x-api-token", "sk-1"} in headers
    refute {"authorization", "Bearer guest-attempt"} in headers
    refute {"x-api-token", "guest"} in headers

    refute Enum.any?(headers, fn {name, _} -> name in ["host", "content-length", "connection"] end)

    refute Enum.any?(headers, fn {name, _} -> String.starts_with?(name, "x-forwarded") end)
    assert {"content-type", "application/json"} in headers
    assert {"accept", "text/plain"} in headers
    assert Upstream.origin(authorization) == "https://api.example.test"
  end

  test "peer requests carry only the canonical host and platform token" do
    token = "galileo_peer_" <> String.duplicate("a", 43)
    peer = %{endpoint: "https://bob.example.test", token: token}
    authorization = authorization([{"authorization", "Bearer x"}], peer)

    headers =
      Upstream.headers(authorization, [{"authorization", "guest"}, {"accept", "text/html"}])

    assert headers == [{"host", "bob.example.test"}, {"authorization", "galileo-peer " <> token}]
    assert Upstream.origin(authorization) == "https://bob.example.test"
  end

  property "guest headers never override injected names regardless of case" do
    name =
      draw(
        "name",
        member_of(["Authorization", "AUTHORIZATION", "authorization", "aUtHoRiZaTiOn"])
      )

    value = draw("value", string(:alphanumeric, min_length: 1, max_length: 16))
    authorization = authorization([{"authorization", "Bearer platform"}])
    headers = Upstream.headers(authorization, [{name, value}])

    assert Enum.count(headers, fn {header_name, _} ->
             String.downcase(header_name) == "authorization"
           end) == 1
  end

  test "uploads are pulled incrementally on one verified TLS attempt", %{origin: origin} do
    chunks = [:binary.copy(<<1>>, 65_536), :binary.copy(<<2>>, 65_536), "tail"]
    owner = self()

    pull = fn
      [] ->
        {:ok, "", []}

      [last] ->
        send(owner, {:pulled, last})
        {:ok, last, []}

      [next | rest] ->
        send(owner, {:pulled, next})
        {:more, next, rest}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: chunks,
        pull: pull,
        headers: [{"content-length", Integer.to_string(Enum.sum(Enum.map(chunks, &byte_size/1)))}],
        consume: fn event ->
          send(owner, event)
          :ok
        end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.status == 200
    assert result.body_state == []
    assert_receive :origin_attempt
    refute_receive :origin_attempt
    assert_receive {:pulled, first}
    assert byte_size(first) == 65_536
    assert_receive {:pulled, second}
    assert byte_size(second) == 65_536
    assert_receive {:pulled, "tail"}
    assert_receive {:data, "131076"}
  end

  test "owner-bound sources require cancellation before any origin or body effect", %{
    origin: origin
  } do
    owner = self()

    assert_raise ArgumentError, "owner-bound source requires frontend cancellation", fn ->
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :empty,
        pull_in_owner: true,
        pull: fn state ->
          send(owner, :source_pulled)
          {:ok, "", state}
        end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )
    end

    refute_receive :source_pulled
    refute_receive :origin_attempt
  end

  test "an upload lasting beyond a short lease renews the same attempt", %{origin: origin} do
    owner = self()

    pull = fn
      0 ->
        Process.sleep(300)
        {:more, :binary.copy(<<1>>, 32_768), 1}

      1 ->
        Process.sleep(300)
        {:more, :binary.copy(<<2>>, 32_768), 2}

      2 ->
        Process.sleep(300)
        {:ok, "tail", 3}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: 0,
        pull: pull,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :upload_renewed)
          {:ok, %{ttl: 500}}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.body_state == 3
    assert_receive :origin_attempt
    assert_receive :upload_renewed
    assert_receive :upload_renewed
    refute_receive :origin_attempt
  end

  test "renewal refusal during upload closes the same attempt without retry", %{origin: origin} do
    owner = self()

    pull = fn
      :first ->
        {:more, :binary.copy(<<1>>, 32_768), :blocked}

      :blocked ->
        send(owner, :upload_blocked)
        Process.sleep(400)
        {:ok, :binary.copy(<<2>>, 32_768), :finished}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :first,
        pull: pull,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :upload_renewal_refused)
          {:error, :unauthorized}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :cancelled
    assert result.body_state == :blocked
    assert_receive :origin_attempt
    assert_receive :upload_blocked
    assert_receive :upload_renewal_refused
    refute_receive :origin_attempt, 200
  end

  test "source failure aborts without retrying the authorized request", %{origin: origin} do
    pull = fn
      :first -> {:more, :binary.copy(<<1>>, 65_536), :truncate}
      :truncate -> {:error, :truncated}
    end

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :first,
        pull: pull,
        headers: [{"content-length", "131072"}],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :source_error
    assert result.body_state == :truncate
    # Bandit may dispatch before or after receiving the complete body. Either way,
    # there can be at most the one connection created before source truncation.
    receive do
      :origin_attempt -> :ok
    after
      50 -> :ok
    end

    refute_receive :origin_attempt, 200
    refute_receive {:origin_chunk, 131_072}
  end

  # @cc [owner:ghuntley,label:verification;security] galileo-generated-single-attempt
  # A source failure before, during or after a partial upload MUST NOT replay
  # the same guest-selected path at the local TLS origin's request handler.
  # Four retained 200ms quiet windows require at least 80s over 100 cases.
  @tag timeout: 180_000
  property "generated source failures never replay one upstream request", profile: :ci do
    origin = start_origin()

    sizes =
      draw(
        "sizes",
        list_of(member_of([1, 16383, 16384, 16385, 65536]), min_length: 2, max_length: 4)
      )

    for mode <- [:before, :middle, :after, :success] do
      path = "/history/" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

      fail_at =
        case mode do
          :before -> 0
          :middle -> div(length(sizes), 2)
          :after -> length(sizes)
          :success -> nil
        end

      pull = fn {index, remaining} ->
        cond do
          index == fail_at ->
            {:error, :truncated}

          remaining == [] ->
            {:ok, "", {index, []}}

          true ->
            [size | rest] = remaining
            bytes = :binary.copy(<<index + 1>>, size)

            if rest == [] and is_nil(fail_at),
              do: {:ok, bytes, {index + 1, rest}},
              else: {:more, bytes, {index + 1, rest}}
        end
      end

      result =
        Upstream.stream(%{target: origin, headers: [], ttl: 5000},
          method: "POST",
          path: path,
          query: "",
          body_state: {0, sizes},
          pull: pull,
          headers: [],
          consume: fn _ -> :ok end,
          renew: fn -> {:ok, %{ttl: 5000}} end,
          transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
        )

      assert result.outcome == if(is_nil(fail_at), do: :completed, else: :source_error)
      {pulled_chunks, _remaining} = result.body_state
      assert pulled_chunks == (fail_at || length(sizes))

      # Upstream.stream/2 is synchronous; count handler dispatches that have
      # arrived by return plus a bounded quiet window for local dispatch.
      attempts = attempt_count(path)
      assert attempts <= 1
      if is_nil(fail_at), do: assert(attempts == 1)
    end
  end

  @spec attempt_count(binary()) :: non_neg_integer()
  defp attempt_count(path) do
    receive do
      {:origin_attempt, ^path} -> 1 + attempt_count(path)
    after
      200 -> 0
    end
  end

  test "TLS verifies the authorized target hostname before pulling body", %{origin: origin} do
    mismatched = String.replace(origin, "localhost", "localhost.localdomain")
    owner = self()

    result =
      Upstream.stream(%{target: mismatched, headers: [], ttl: 5000},
        method: "POST",
        path: "/upload",
        query: "",
        body_state: :unread,
        pull: fn state ->
          send(owner, :body_pulled)
          {:ok, "secret", state}
        end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 5000}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :transport_error
    assert result.body_state == :unread
    refute_receive :body_pulled
    refute_receive :origin_attempt
  end

  test "a refused renewal cancels one stalled upstream attempt", %{origin: origin} do
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           Upstream.stream(%{target: origin, headers: [], ttl: 500},
             method: "GET",
             path: "/stall",
             query: "",
             body_state: :empty,
             pull: fn state -> {:ok, "", state} end,
             headers: [],
             consume: fn _ -> :ok end,
             renew: fn ->
               send(owner, {:renewed, System.monotonic_time(:millisecond)})
               {:error, :unauthorized}
             end,
             transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
           )

         send(owner, {:result, result})
       end}
    )

    assert_receive :origin_attempt, 1000
    assert_receive {:renewed, refused_at}, 1000
    assert_receive {:result, %{outcome: :cancelled}}, 1000
    assert System.monotonic_time(:millisecond) - refused_at < 750
    refute_receive :origin_attempt
  end

  test "a silent upstream remains open across response polling intervals while renewals succeed",
       %{
         origin: origin
       } do
    owner = self()

    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "GET",
        path: "/stall",
        query: "",
        body_state: :empty,
        pull: fn state -> {:ok, "", state} end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn ->
          send(owner, :silent_renewed)
          {:ok, %{ttl: 500}}
        end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :completed
    assert result.status == 200
    assert_receive :origin_attempt
    assert_receive :silent_renewed
    assert_receive :silent_renewed
    assert_receive :silent_renewed
    refute_receive :origin_attempt
  end

  test "an already expired admission cannot open an origin", %{origin: origin} do
    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "GET",
        path: "/stall",
        query: "",
        body_state: :empty,
        pull: fn state -> {:ok, "", state} end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> flunk("expired authority must not renew") end,
        lease_expires_at: System.monotonic_time(:millisecond) - 1,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :transport_error
    refute_receive :origin_attempt, 0
  end

  test "a renewal cannot restart its absolute lifetime after authority delay", %{origin: origin} do
    result =
      Upstream.stream(%{target: origin, headers: [], ttl: 500},
        method: "GET",
        path: "/stall",
        query: "",
        body_state: :empty,
        pull: fn state -> {:ok, "", state} end,
        headers: [],
        consume: fn _ -> :ok end,
        renew: fn -> {:ok, %{ttl: 500, expires_at: System.monotonic_time(:millisecond) - 1}} end,
        transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
      )

    assert result.outcome == :cancelled
    assert_receive :origin_attempt
    refute_receive :origin_attempt, 0
  end

  test "a renewal call cannot outlive the current lease", %{origin: origin} do
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           Upstream.stream(%{target: origin, headers: [], ttl: 500},
             method: "GET",
             path: "/stall",
             query: "",
             body_state: :empty,
             pull: fn state -> {:ok, "", state} end,
             headers: [],
             consume: fn _ -> :ok end,
             renew: fn ->
               send(owner, :renewal_started)

               receive do
                 :never_sent -> {:ok, %{ttl: 500}}
               end
             end,
             transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
           )

         send(owner, {:late_result, result})
       end}
    )

    assert_receive :origin_attempt, 1000
    assert_receive :renewal_started, 1000
    assert_receive {:late_result, %{outcome: :cancelled}}, 1000
    refute_receive :origin_attempt
  end

  # @cc [owner:ghuntley,label:verification;security] generated-galileo-lease-cutoff
  # After zero or one valid renewals, refusal, an invalid TTL or a renewal
  # blocked beyond expiry MUST cancel the one TLS attempt without response data.
  # Three lease histories and quiet windows take up to about 3.1s per case.
  @tag timeout: 600_000
  property "generated renewal histories close one upstream attempt", profile: :ci do
    origin = start_origin()
    ttl = draw("ttl", integer(600..700))
    valid_prefix = draw("valid_prefix", integer(0..1))

    for terminal <- [:refused, :invalid, :expired] do
      owner = self()
      calls = :atomics.new(1, [])

      result =
        Upstream.stream(%{target: origin, headers: [], ttl: ttl},
          method: "GET",
          path: "/stall",
          query: "",
          body_state: :empty,
          pull: fn state -> {:ok, "", state} end,
          headers: [],
          consume: fn event ->
            send(owner, {:upstream_event, event})
            :ok
          end,
          renew: fn ->
            call = :atomics.add_get(calls, 1, 1)

            if call <= valid_prefix do
              {:ok, %{ttl: ttl}}
            else
              case terminal do
                :refused -> {:error, :unauthorized}
                :invalid -> {:ok, %{ttl: 499}}
                :expired -> Process.sleep(ttl * 2)
              end
            end
          end,
          transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
        )

      assert result.outcome == :cancelled
      assert result.status == nil
      assert result.response_bytes == 0
      assert :atomics.get(calls, 1) == valid_prefix + 1
      assert_receive :origin_attempt, 1000
      refute_receive {:upstream_event, {:data, _}}
      refute_receive :origin_attempt, 100
    end
  end

  # @cc [owner:ghuntley,label:verification;security] stalled-upload-lease-termination
  # Generated refused, invalid and expired renewals MUST finish the streaming
  # caller and terminate a blocked source reader without another upstream attempt
  # or body delivery. The reader handshake, not elapsed time, proves it blocked.
  # Each case retains a 300–600ms lease and three 100ms quiet windows.
  @tag timeout: 180_000
  property "lease cancellation terminates a stalled upload reader", profile: :ci do
    origin = start_origin()
    terminal = draw("terminal", member_of([:refused, :invalid, :expired]))
    owner_bound = draw("owner_bound", boolean())

    owner = self()
    nonce = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        stream_owner = self()

        result =
          Upstream.stream(%{target: origin, headers: [], ttl: 600},
            method: "POST",
            path: "/upload",
            query: "",
            body_state: :blocked,
            pull_in_owner: owner_bound,
            cancel_frontend: fn ->
              send(owner, {:frontend_cancelled, nonce})
              send(stream_owner, {:release, nonce})
              :ok
            end,
            pull: fn _ ->
              send(owner, {:reader_blocked, nonce, self()})

              receive do
                {:release, ^nonce} -> {:ok, "late", :done}
              end
            end,
            headers: [],
            consume: fn event ->
              send(owner, {:delivered, nonce, event})
              :ok
            end,
            renew: fn ->
              case terminal do
                :refused ->
                  {:error, :unauthorized}

                :invalid ->
                  {:ok, %{ttl: 0}}

                :expired ->
                  receive do
                    :never -> {:ok, %{ttl: 600}}
                  end
              end
            end,
            transport_opts: [verify: :verify_peer, cacertfile: Path.join(@fixtures, "ca.pem")]
          )

        send(owner, {:stream_result, nonce, result})
      end)

    try do
      assert_receive {:reader_blocked, ^nonce, reader}, 2000
      reader_monitor = Process.monitor(reader)
      assert_receive {:stream_result, ^nonce, %{outcome: :cancelled, response_bytes: 0}}, 2000
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1000
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 1000
      assert_receive {:frontend_cancelled, ^nonce}, 1000
      refute_receive {:frontend_cancelled, ^nonce}
      refute_receive {:delivered, ^nonce, _}
      assert_receive :origin_attempt, 1000
      refute_receive :origin_attempt, 100
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end
  end
end
