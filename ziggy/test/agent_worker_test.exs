defmodule Ziggy.AgentWorkerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @id "11111111-1111-7111-8111-111111111111"
  @claim "22222222-2222-4222-8222-222222222222"
  @private "synthetic-provider-private-detail"

  defmodule ControlFixture do
    use GenServer
    @type state :: %{owner: pid(), failures: non_neg_integer()}

    @spec start_link(state()) :: GenServer.on_start()
    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:request, "ziggy.admit", body, _}, _, state) do
      send(state.owner, {:admission, body})

      {:reply,
       {:ok,
        %{
          "request_id" => body["request_id"],
          "owner_id" => body["vm_id"],
          "admitted_at" => 1,
          "ttl_ms" => 30_000
        }}, state}
    end

    def handle_call({:request, "ziggy.agent_result", body, _}, _, state) do
      send(state.owner, {:delivered, body})

      if state.failures > 0 do
        {:reply, {:error, "unavailable"}, %{state | failures: state.failures - 1}}
      else
        {:reply, {:ok, %{"acknowledged" => body["call_id"]}}, state}
      end
    end

    def handle_call(:status, _, state), do: {:reply, :ready, state}
  end

  defmodule ProviderFixture do
    @behaviour Plug
    @type config :: %{owner: pid(), status: pos_integer(), content_type: binary(), body: binary()}

    @impl true
    @spec init(config()) :: config()
    def init(options), do: options

    @impl true
    @spec call(Plug.Conn.t(), config()) :: Plug.Conn.t()
    def call(conn, options) do
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(options.owner, {:provider_call, conn.request_path, Jason.decode!(request)})
      send(options.owner, {:request_id, Plug.Conn.get_req_header(conn, "x-request-id")})
      send(options.owner, {:forwarded_headers, conn.req_headers})

      conn
      |> Plug.Conn.put_resp_header("content-type", options.content_type)
      |> Plug.Conn.put_resp_header("x-request-id", "provider-foreign-id")
      |> Plug.Conn.put_resp_header("request-id", "provider-alias")
      |> Plug.Conn.send_resp(options.status, options.body)
    end
  end

  defmodule EvidenceFinch do
    @type event ::
            {:status, pos_integer()} | {:headers, [{binary(), binary()}]} | {:data, binary()}
    @type ending :: :ok | :transport_error

    @spec configure([event()], ending()) :: term()
    def configure(events, ending), do: Process.put(__MODULE__, {events, ending})

    @spec stream_while(
            Finch.Request.t(),
            term(),
            map(),
            (event(), map() -> {:cont, map()} | {:halt, map()}),
            keyword()
          ) :: {:ok, map()} | {:error, :closed, map()}
    def stream_while(request, _finch, initial, callback, options) do
      send(self(), {:provider_headers, request.headers})
      send(self(), {:provider_options, options})
      {events, ending} = Process.get(__MODULE__)

      state = Enum.reduce_while(events, initial, fn event, state -> callback.(event, state) end)
      if ending == :ok, do: {:ok, state}, else: {:error, :closed, state}
    end
  end

  defmodule TransportClosingFinch do
    @spec stream_while(
            term(),
            term(),
            map(),
            (term(), map() -> {:cont, map()} | {:halt, map()}),
            keyword()
          ) ::
            {:error, term(), map()}
    def stream_while(_request, _finch, state, callback, _options) do
      {:cont, state} = callback.({:status, 200}, state)
      {:cont, state} = callback.({:headers, [{"content-type", "text/event-stream"}]}, state)
      response = %{"status" => "completed", "output" => [%{"type" => "message"}]}

      chunk =
        "data: " <>
          Jason.encode!(%{"type" => "response.completed", "response" => response}) <> "\n\n"

      {:cont, state} = callback.({:data, chunk}, state)
      {:error, :closed, state}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ziggy-agent-worker-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({Ziggy.Spool, name: Ziggy.Spool, directory: dir, max_requests: 16})
    start_supervised!({Finch, name: Ziggy.Finch})
    start_supervised!({Task.Supervisor, name: Ziggy.Tasks})
    start_supervised!({DynamicSupervisor, name: Ziggy.Leases, strategy: :one_for_one})
    :ok
  end

  test "native compaction uses the existing route, preserves bodies and accounts Responses" do
    response = %{
      "status" => "completed",
      "output" => [%{"type" => "compaction", "encrypted_content" => "synthetic-compacted-state"}],
      "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
    }

    body =
      "data: " <>
        Jason.encode!(%{"type" => "response.completed", "response" => response}) <> "\n\n"

    config = configuration(200, "text/event-stream", body)

    request =
      request(%{"compaction_trigger" => "auto", "include" => ["reasoning.encrypted_content"]})

    assert :completed = Ziggy.AgentWorker.execute(config, work(request))
    assert_receive {:admission, %{"operation" => "responses"}}
    assert_receive {:provider_call, "/v1/responses", ^request}
    assert_receive {:request_id, [@id]}
    assert_receive {:delivered, %{"response" => ^response}}

    assert [%{"admission" => %{"operation" => "responses"}, "completion" => completion}] =
             Ziggy.Spool.pending(Ziggy.Spool)

    assert completion["tokens"] == %{"input_tokens" => 11, "output_tokens" => 3}
    assert completion["completeness"] == "complete"
    refute inspect(completion) =~ "synthetic-compacted-state"
    refute_receive {:provider_call, _, _}
  end

  test "summary compaction streams a completed message through the existing route" do
    summary_item = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Earlier work recorded."}]
    }

    response = %{
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 19, "output_tokens" => 6}
    }

    body =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => summary_item
        }) <>
        "\n\n" <>
        "data: " <>
        Jason.encode!(%{"type" => "response.completed", "response" => response}) <>
        "\n\n"

    config = configuration(200, "text/event-stream", body)
    request = request(%{"input" => [%{"role" => "system", "content" => "compact"}]})

    assert :completed = Ziggy.AgentWorker.execute(config, work(request))
    assert_receive {:admission, %{"operation" => "responses"}}
    assert_receive {:provider_call, "/v1/responses", ^request}

    assert_receive {:delivered, %{"response" => delivered}}
    assert delivered["status"] == "completed"
    assert delivered["output"] == [summary_item]
    assert delivered["usage"] == response["usage"]

    assert [%{"completion" => completion}] = Ziggy.Spool.pending(Ziggy.Spool)
    assert completion["tokens"] == response["usage"]
    assert completion["completeness"] == "complete"
    refute_receive {:provider_call, _, _}
  end

  test "ordinary JSON Responses retain maps and missing usage stays unknown" do
    response = %{"status" => "completed", "output" => [%{"type" => "message", "content" => []}]}
    config = configuration(200, "application/json", Jason.encode!(response))
    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, %{"response" => ^response}}

    assert [%{"completion" => %{"tokens" => %{}, "completeness" => "unknown"}}] =
             Ziggy.Spool.pending(Ziggy.Spool)
  end

  test "a transport close after a completed SSE response preserves the response" do
    config =
      configuration(200, "application/json", "{}")
      |> Map.put(:finch_module, TransportClosingFinch)

    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, %{"response" => %{"status" => "completed"}}}
  end

  test "chat admission retains chat operation accounting" do
    response = %{"choices" => [%{"message" => %{"content" => "synthetic reply"}}]}
    config = configuration(200, "application/json", Jason.encode!(response))
    request = %{"model" => "test", "messages" => []}
    assert :completed = Ziggy.AgentWorker.execute(config, work(request))
    assert_receive {:admission, %{"operation" => "chat"}}
    assert_receive {:provider_call, "/v1/chat/completions", ^request}
    assert_receive {:delivered, %{"response" => ^response}}
  end

  for {code, param, expected} <- [
        {"context_length_exceeded", nil, "context_length_exceeded"},
        {"unsupported_parameter", "compaction_trigger", "unsupported_compaction"},
        {"unknown_error", nil, "upstream_failed"},
        {"no_accounts", nil, "no_accounts"},
        {"pool_exhausted", nil, "pool_exhausted"},
        {"quota_exhausted", nil, "quota_exhausted"},
        {"server_is_overloaded", nil, "server_is_overloaded"},
        {"retryable_overload", nil, "upstream_failed"}
      ] do
    test "HTTP #{code} is sanitized before results or diagnostics" do
      body =
        Jason.encode!(%{
          "error" => %{"code" => unquote(code), "param" => unquote(param), "message" => @private}
        })

      config = configuration(400, "application/json", body)

      log =
        capture_log(fn ->
          assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
        end)

      assert_receive {:delivered, %{"response" => %{"error" => unquote(expected)}}}
      refute log =~ @private
      refute inspect(Ziggy.Spool.pending(Ziggy.Spool)) =~ @private

      assert [%{"completion" => %{"tokens" => %{}, "completeness" => "unknown"}}] =
               Ziggy.Spool.pending(Ziggy.Spool)
    end
  end

  for {label, headers, origin, ending, expected} <- [
        {"certified local proxy", [{"x-underclass-retry-safe", "pre-output-overload"}],
         "http://127.0.0.1:8080", :ok, "retryable_overload"},
        {"certified remote proxy", [{"x-underclass-retry-safe", "pre-output-overload"}],
         "https://panterloons.lorikeet-bangus.ts.net", :ok, "retryable_overload"},
        {"missing evidence", [], "http://127.0.0.1:8080", :ok, "server_is_overloaded"},
        {"duplicate evidence",
         List.duplicate({"x-underclass-retry-safe", "pre-output-overload"}, 2),
         "http://127.0.0.1:8080", :ok, "server_is_overloaded"},
        {"unknown evidence", [{"x-underclass-retry-safe", "true"}], "http://127.0.0.1:8080", :ok,
         "server_is_overloaded"},
        {"provider spoof", [{"x-underclass-retry-safe", "pre-output-overload"}],
         "https://api.openai.com", :ok, "server_is_overloaded"},
        {"ambiguous transport", [{"x-underclass-retry-safe", "pre-output-overload"}],
         "http://127.0.0.1:8080", :transport_error, "transport_error"}
      ] do
    test "#{label} has closed retry eligibility" do
      body = "data: {\"type\":\"error\",\"code\":\"server_is_overloaded\"}\n\n"

      config =
        evidence_configuration(
          body,
          unquote(Macro.escape(headers)),
          unquote(origin),
          unquote(ending)
        )

      assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
      assert_receive {:delivered, %{"response" => %{"error" => unquote(expected)}}}
      assert_receive {:provider_headers, headers}
      assert Enum.filter(headers, &(elem(&1, 0) == "x-request-id")) == [{"x-request-id", @id}]
      refute_receive {:provider_headers, _}
      assert_receive {:provider_options, options}
      expected_timeout = if unquote(origin) == "https://api.openai.com", do: 30_000, else: 600_000
      assert options[:receive_timeout] == expected_timeout
      assert options[:request_timeout] == :infinity

      assert [%{"completion" => completion}] = Ziggy.Spool.pending(Ziggy.Spool)
      assert {:ok, _} = OverallsProtocol.Inference.completion(Ziggy.Completion.wire(completion))
      refute Map.has_key?(completion, "retry_safe")
    end
  end

  for {label, prefix, suffix} <- [
        {"partial output",
         "data: {\"type\":\"response.output_text.delta\",\"delta\":\"private\"}\n\n", ""},
        {"unknown event", "data: {\"type\":\"unknown\"}\n\n", ""},
        {"malformed event", "data: invalid\n\n", ""},
        {"conflicting terminal", "",
         "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"},
        {"truncated frame", "", "data: partial"}
      ] do
    test "#{label} overrides the proxy evidence" do
      overload = "data: {\"type\":\"error\",\"code\":\"server_is_overloaded\"}\n\n"
      config = evidence_configuration(unquote(prefix) <> overload <> unquote(suffix))
      assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
      assert_receive {:delivered, %{"response" => %{"error" => "server_is_overloaded"}}}
    end
  end

  test "UUIDv4 model calls cannot contact admission or upstream" do
    config = configuration(200, "application/json", "{}")
    legacy = Map.put(work(request()), "id", "11111111-1111-4111-8111-111111111111")
    assert :admission_unavailable = Ziggy.AgentWorker.execute(config, legacy)
    refute_receive {:admission, _}
    refute_receive {:provider_call, _, _}
  end

  test "generic HTTP admission owns the UUIDv7 request header through the entire attempt" do
    response = %{"status" => "completed", "output" => []}
    config = configuration(200, "application/json", Jason.encode!(response))
    binding = work(request())["binding"]

    conn =
      Plug.Test.conn(:post, "http://llm.internal/v1/responses", Jason.encode!(request()))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header(
        "x-overalls-binding",
        Base.url_encode64(Jason.encode!(binding), padding: false)
      )
      |> Plug.Conn.put_req_header("x-request-id", "guest-controlled-id")
      |> Plug.Conn.put_req_header("x-underclass-retry-safe", "pre-output-overload")

    result = Ziggy.HTTP.call(conn, config)
    assert result.status == 200
    assert_receive {:admission, %{"request_id" => id}}
    assert Ziggy.RequestId.valid?(id)
    assert_receive {:request_id, [^id]}
    assert Plug.Conn.get_resp_header(result, "x-request-id") == [id]
    assert Plug.Conn.get_resp_header(result, "x-ziggy-request-id") == [id]
    assert Plug.Conn.get_resp_header(result, "request-id") == []
    assert_receive {:forwarded_headers, headers}
    refute List.keymember?(headers, "x-underclass-retry-safe", 0)
    refute inspect(headers) =~ "guest-controlled-id"
  end

  test "classified provider diagnostics retain the attempt ID and exclude error content" do
    body = Jason.encode!(%{"error" => %{"type" => "no_accounts", "message" => @private}})
    config = configuration(503, "application/json", body)

    log =
      capture_log([metadata: [:event, :request_id, :reason, :status, :duration_ms]], fn ->
        assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
      end)

    assert log =~ "ziggy.upstream_started"
    assert log =~ "ziggy.upstream_outcome"
    assert log =~ "ziggy.agent_provider_outcome"
    assert log =~ @id
    assert log =~ "no_accounts"
    assert log =~ "503"
    refute log =~ @private
    refute log =~ "synthetic-test-key"
  end

  test "collector overflow overrides otherwise certified overload" do
    overload = "data: {\"type\":\"error\",\"code\":\"server_is_overloaded\"}\n\n"
    config = evidence_configuration(overload <> String.duplicate("x", 2_097_153))
    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, %{"response" => %{"error" => "invalid_response"}}}
  end

  test "certified overload result delivery retries reuse the exact response and provider attempt" do
    body = "data: {\"type\":\"error\",\"code\":\"server_is_overloaded\"}\n\n"

    config =
      evidence_configuration(
        body,
        [{"x-underclass-retry-safe", "pre-output-overload"}],
        "http://127.0.0.1:8080",
        :ok,
        2
      )

    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, first}
    assert first["response"] == %{"error" => "retryable_overload"}
    assert_receive {:delivered, ^first}
    assert_receive {:delivered, ^first}
    assert_receive {:provider_headers, _}
    refute_receive {:provider_headers, _}
    assert length(Ziggy.Spool.pending(Ziggy.Spool)) == 1
  end

  test "incomplete SSE is a closed terminal result with its reported usage" do
    body =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.incomplete",
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => @private},
            "usage" => %{"input_tokens" => 8, "output_tokens" => 2}
          }
        }) <> "\n\n"

    config = configuration(200, "text/event-stream", body)
    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, %{"response" => %{"error" => "incomplete"}}}

    assert [
             %{
               "completion" => %{
                 "outcome" => "upstream_error",
                 "tokens" => %{"input_tokens" => 8, "output_tokens" => 2}
               }
             }
           ] =
             Ziggy.Spool.pending(Ziggy.Spool)
  end

  test "result delivery retries do not repeat the provider attempt or accounting slot" do
    config =
      configuration(
        400,
        "application/json",
        Jason.encode!(%{"error" => %{"code" => "context_length_exceeded"}}),
        2
      )

    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:provider_call, "/v1/responses", _}
    assert_receive {:delivered, first}
    assert_receive {:delivered, ^first}
    assert_receive {:delivered, ^first}
    refute_receive {:provider_call, _, _}
    assert length(Ziggy.Spool.pending(Ziggy.Spool)) == 1
  end

  test "an ambiguous result delivery leaves one completed slot without inference replay" do
    config =
      configuration(
        200,
        "application/json",
        Jason.encode!(%{"status" => "completed", "output" => []}),
        3
      )

    assert :result_unavailable = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:provider_call, "/v1/responses", _}
    refute_receive {:provider_call, _, _}
    assert length(Ziggy.Spool.completed(Ziggy.Spool, 16)) == 1
  end

  test "oversized output cannot reach Marshall even if a valid prefix was collected" do
    config =
      configuration(
        200,
        "application/json",
        Jason.encode!(%{"output" => String.duplicate("x", 1_048_576)})
      )

    assert :completed = Ziggy.AgentWorker.execute(config, work(request()))
    assert_receive {:delivered, %{"response" => %{"error" => "invalid_response"}}}
  end

  @spec configuration(pos_integer(), binary(), binary(), non_neg_integer()) :: map()
  defp configuration(status, content_type, body, failures \\ 0) do
    control = start_supervised!({ControlFixture, %{owner: self(), failures: failures}})

    provider =
      start_supervised!(
        {Bandit,
         plug:
           {ProviderFixture,
            %{owner: self(), status: status, content_type: content_type, body: body}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(provider)

    %{
      host_id: @id,
      control: %{client: control},
      credentials: %{openai: "synthetic-test-key"},
      openai_origin: "http://127.0.0.1:#{port}"
    }
  end

  @spec evidence_configuration(
          binary(),
          [{binary(), binary()}],
          binary(),
          EvidenceFinch.ending(),
          non_neg_integer()
        ) :: map()
  defp evidence_configuration(
         body,
         evidence \\ [{"x-underclass-retry-safe", "pre-output-overload"}],
         origin \\ "http://127.0.0.1:8080",
         ending \\ :ok,
         failures \\ 0
       ) do
    control = start_supervised!({ControlFixture, %{owner: self(), failures: failures}})

    EvidenceFinch.configure(
      [
        {:status, 200},
        {:headers, [{"content-type", "text/event-stream"} | evidence]},
        {:data, body}
      ],
      ending
    )

    %{
      host_id: @id,
      control: %{client: control},
      credentials: %{openai: "synthetic-test-key"},
      openai_origin: origin,
      finch_module: EvidenceFinch
    }
  end

  @spec request(map()) :: map()
  defp request(extra \\ %{}),
    do: Map.merge(%{"model" => "test", "input" => [], "stream" => true}, extra)

  @spec work(map()) :: map()
  defp work(request),
    do: %{
      "id" => @id,
      "claim_id" => @claim,
      "request" => request,
      "binding" => %{
        "host_id" => @id,
        "vm_id" => @id,
        "placement_id" => @id,
        "execution_epoch" => 1
      }
    }
end
