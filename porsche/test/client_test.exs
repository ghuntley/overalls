defmodule Porsche.ClientTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Porsche.Client

  @token "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
  @message %{"version" => 1, "session_token" => "synthetic-session"}

  setup_all do
    directory = Path.join(System.tmp_dir!(), "porsche-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    for name <- ["ca", "untrusted"] do
      {_output, 0} =
        System.cmd(
          "openssl",
          [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=" <> name,
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-keyout",
            Path.join(directory, name <> ".key"),
            "-out",
            Path.join(directory, name <> ".pem")
          ],
          stderr_to_stdout: true
        )
    end

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-subj",
          "/CN=localhost",
          "-keyout",
          Path.join(directory, "server.key"),
          "-out",
          Path.join(directory, "server.csr")
        ],
        stderr_to_stdout: true
      )

    extensions = Path.join(directory, "extensions")

    File.write!(
      extensions,
      "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n"
    )

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-days",
          "1",
          "-in",
          Path.join(directory, "server.csr"),
          "-CA",
          Path.join(directory, "ca.pem"),
          "-CAkey",
          Path.join(directory, "ca.key"),
          "-CAcreateserial",
          "-extfile",
          extensions,
          "-out",
          Path.join(directory, "server.pem")
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "only an HTTPS origin and canonical gateway credential are accepted" do
    assert {:ok, client} = Client.new("https://localhost/", @token)
    assert client.origin == "https://localhost"
    refute inspect(client) =~ @token

    for url <- [
          "http://localhost",
          "http://127.0.0.1",
          "https://user@localhost",
          "https://localhost/path",
          "https://localhost/?secret=x",
          "https://localhost/#x",
          "https://localhost:0",
          "https://[::1]",
          "https://[2001:db8::1]",
          "https://localhost:65536"
        ] do
      assert {:error, :invalid_configuration} = Client.new(url, @token)
    end

    assert {:error, :invalid_configuration} =
             Client.new("https://localhost", @token, verify: false)

    assert {:error, :invalid_configuration} = Client.new("https://localhost", @token <> "\n")
  end

  property "arbitrary credentials cannot escape the constructor's fixed result" do
    token = draw("token", binary(max_length: 200))

    case Client.new("https://localhost", token) do
      {:ok, client} -> refute inspect(client) =~ token
      {:error, :invalid_configuration} -> :ok
    end
  end

  test "real TLS sends one validated request and decodes the bounded object", context do
    {client, worker} = server(context, {:ok, %{"status" => "authenticated"}})
    assert {:ok, %{"status" => "authenticated"}} = Client.request(client, "session", @message)
    assert_receive {:upgrade, ^worker, headers}
    assert headers["authorization"] == "Bearer " <> @token
    assert headers["overalls-service"] == "porsche"
    assert_receive {:request, ^worker, "porsche.session", body}
    assert body == @message
  end

  test "TLS rejects an untrusted certificate and a wrong hostname", context do
    {client, worker} = server(context, {:ok, %{}})
    wrong_ca = connect(%{client | cacertfile: Path.join(context.directory, "untrusted.pem")})
    assert {:error, :transport_error} = Client.request(wrong_ca, "session", @message)
    refute_receive {:request, ^worker, _, _}

    {client, worker} = server(context, {:ok, %{}})

    wrong_host =
      connect(%{client | origin: String.replace(client.origin, "localhost", "127.0.0.1")})

    assert {:error, :transport_error} = Client.request(wrong_host, "session", @message)
    refute_receive {:request, ^worker, _, _}
  end

  test "refused upgrades, server errors and lost replies do not retry or expose remote text",
       context do
    {client, _worker} = server(context, {:refuse, 302})
    assert {:error, :transport_error} = Client.request(client, "session", @message)

    for {name, expected} <- [
          {"unauthorized", :unauthorized},
          {"approval_required", :unauthorized},
          {"temporarily_unavailable", :temporarily_unavailable},
          {"session_limit", :rate_limited},
          {"request_not_found", :not_found},
          {"synthetic_secret", :http_error}
        ] do
      {client, worker} = server(context, {:error, name})
      assert {:error, ^expected} = Client.request(client, "session", @message)
      assert_receive {:request, ^worker, _, _}
    end

    {client, worker} = server(context, :disconnect)
    assert {:error, :transport_error} = Client.request(client, "session", @message)
    assert_receive {:request, ^worker, _, _}
  end

  test "host, capacity, clone and relocation refusals preserve only closed public reasons",
       context do
    for reason <- [
          :insufficient_capacity,
          :host_unavailable,
          :clone_already_published,
          :clone_not_retryable,
          :clone_in_progress,
          :workload_not_stable,
          :checkpoint_unavailable,
          :vm_busy,
          :source_unavailable,
          :transfer_busy,
          :resize_in_progress,
          :relocation_in_progress,
          :relocation_committed,
          :relocation_finished,
          :relocation_retry_unavailable,
          :placement_changed,
          :name_unavailable,
          :machine_pinned,
          :machine_failed,
          :pin_limit,
          :idempotency_conflict,
          :thread_not_ready,
          :thread_busy,
          :stale_proposal,
          :stale_question,
          :already_answered,
          :already_implemented,
          :invalid_answers,
          :awaiting_answers,
          :machine_unavailable,
          :revision_conflict,
          :reserved_editor_port,
          :web_not_allowed,
          :terminal_unavailable,
          :terminal_open_pending,
          :unknown_session,
          :too_many_terminal_sessions,
          :opening_expired
        ] do
      {client, worker} = server(context, {:error, Atom.to_string(reason)})
      assert {:error, ^reason} = Client.request(client, "session", @message)
      assert_receive {:request, ^worker, _, _}
    end

    for {name, expected} <- [
          {"conflict", :conflict},
          {"vm_deleted", :conflict},
          {"owner_protected", :conflict},
          {"synthetic_secret", :http_error}
        ] do
      {client, _worker} = server(context, {:error, name})
      assert {:error, ^expected} = Client.request(client, "session", @message)
    end
  end

  test "invalid envelopes never send and oversized or malformed responses fail closed", context do
    {client, worker} = server(context, {:ok, %{}})

    assert {:error, :invalid_request} =
             Client.request(client, "session", Map.put(@message, "actor", "owner"))

    assert {:error, :invalid_request} = Client.request(client, "../session", @message)
    refute_receive {:request, ^worker, _, _}

    oversized = %{"padding" => String.duplicate("x", 1_048_577)}

    for {reply, reason} <- [
          {:invalid_frame, :transport_error},
          {{:ok, oversized}, :message_too_large}
        ] do
      {client, _worker} = server(context, reply)
      assert {:error, ^reason} = Client.request(client, "session", @message)
    end
  end

  test "a caller's remaining wait budget bounds the actual request", context do
    {client, _worker} = server(context, {:ok, %{}}, 250)
    assert {:error, :transport_error} = Client.request(client, "session", @message, timeout: 30)

    for options <- [[timeout: 0], [timeout: 5001], [timeout: "30"], [verify: false]] do
      assert {:error, :invalid_request} = Client.request(client, "session", @message, options)
    end
  end

  # A TLS control-socket stub answering every request with `reply`: a
  # document, an error name, an invalid frame, a dropped connection, or an
  # upgrade refused with an HTTP status.
  @spec server(map(), term(), non_neg_integer()) :: {Client.t(), pid()}
  defp server(context, reply, delay \\ 0) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        certfile: String.to_charlist(Path.join(context.directory, "server.pem")),
        keyfile: String.to_charlist(Path.join(context.directory, "server.key"))
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()
    worker = spawn(fn -> accept(listener, parent, reply, delay) end)

    on_exit(fn ->
      Process.exit(worker, :kill)
      :ssl.close(listener)
    end)

    {:ok, client} =
      Client.new("https://localhost:#{port}", @token,
        cacertfile: Path.join(context.directory, "ca.pem")
      )

    {connect(client), worker}
  end

  @spec connect(Client.t()) :: Client.t()
  defp connect(client) do
    client = %{client | control: :"porsche_control_#{System.unique_integer([:positive])}"}
    start_supervised!({Porsche.Control.Link, client}, id: client.control)
    wait(client.control, 50)
    client
  end

  defp wait(_control, 0), do: :ok

  defp wait(control, attempts) do
    if OverallsProtocol.Control.Client.ready?(control),
      do: :ok,
      else: (Process.sleep(20) && wait(control, attempts - 1)) || :ok
  end

  defp accept(listener, parent, reply, delay) do
    with {:ok, transport} <- :ssl.transport_accept(listener, 5000),
         {:ok, socket} <- :ssl.handshake(transport, 5000),
         {:ok, head, rest} <- head(socket, "") do
      headers = headers(head)
      send(parent, {:upgrade, self(), headers})

      case reply do
        {:refuse, status} ->
          :ssl.send(socket, "HTTP/1.1 #{status} Fixture\r\ncontent-length: 0\r\n\r\n")

        _ ->
          accept = OverallsProtocol.WebSocket.Handshake.accept(headers["sec-websocket-key"])

          :ssl.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n" <>
              "connection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n"
          )

          frames(socket, parent, reply, delay, rest)
      end

      :ssl.close(socket)
    end
  end

  defp head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      _ ->
        with {:ok, data} <- :ssl.recv(socket, 0, 5000), do: head(socket, buffer <> data)
    end
  end

  defp headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Map.new(fn line ->
      [name, value] = String.split(line, ": ", parts: 2)
      {String.downcase(name), value}
    end)
  end

  defp frames(socket, parent, reply, delay, buffer) do
    alias OverallsProtocol.Control.Envelope
    alias OverallsProtocol.WebSocket.Frame

    case Frame.decode(buffer, :server, 2_000_000) do
      {:ok, {:text, text}, rest} ->
        case Envelope.decode(text) do
          {:ok, {:hello, _}} ->
            welcome = %{conn: "stub", heartbeat_ms: 5_000, limits: %{"in_flight" => 64}}
            send_frame(socket, Envelope.encode({:welcome, welcome}))
            frames(socket, parent, reply, delay, rest)

          {:ok, {:req, %{id: id, op: op, body: body}}} ->
            send(parent, {:request, self(), op, body})
            Process.sleep(delay)

            case reply do
              :disconnect ->
                :ok

              :invalid_frame ->
                send_frame(socket, "not-a-control-message")

              {:ok, document} ->
                send_frame(socket, Envelope.encode({:res, %{id: id, result: {:ok, document}}}))
                frames(socket, parent, reply, delay, rest)

              {:error, name} ->
                send_frame(socket, Envelope.encode({:res, %{id: id, result: {:error, name}}}))
                frames(socket, parent, reply, delay, rest)
            end

          _ ->
            frames(socket, parent, reply, delay, rest)
        end

      {:ok, _other, rest} ->
        frames(socket, parent, reply, delay, rest)

      :more ->
        case :ssl.recv(socket, 0, 10_000) do
          {:ok, data} -> frames(socket, parent, reply, delay, buffer <> data)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp send_frame(socket, text) do
    {:ok, data} = OverallsProtocol.WebSocket.Frame.encode({:text, text}, :server, 2_000_000)
    :ssl.send(socket, data)
  end
end
